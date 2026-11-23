import SereinCore
import SwiftUI
import WebKit

/// The page-world half of page tools (PageTools): a `modelContext` registry for pages that publish
/// tools from script. Agent tabs get it, top document only, and only while Settings › Privacy ›
/// Page tools is on when the tab opens. It keeps each tool's `execute` to itself and relays only
/// the name, description and schema to PageKit as a message from this same window. A call comes
/// back the same way with the exact JSON text the person approved. A page can post these messages
/// too; whatever it posts is still only the page's own untrusted words.
@MainActor enum PageToolRegistry {
  static func install(on tab: BrowserTab, controller: WKUserContentController) {
    guard tab.owner != nil, PageTools.isEnabled() else { return }
    controller.addUserScript(
      WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
  }

  /// A page that already has a registry (the browser's own) keeps it, and offers Serein nothing.
  static let script = """
    (()=>{try{
    if(window.top!==window||navigator.modelContext||document.modelContext)return;
    const post=window.postMessage.bind(window),later=queueMicrotask.bind(window),stringify=JSON.stringify,parse=JSON.parse;
    const tools=new Map();let queued=false;
    const text=(v,n)=>{try{return String(v==null?'':v).slice(0,n)}catch(_){return ''}};
    const send=()=>{queued=false;const list=[];for(const t of tools.values()){if(list.length>=32)break;list.push({name:t.name,description:t.description,schema:t.schema})}try{post({sereinPageTools:'list',tools:list},'*')}catch(_){}};
    const changed=()=>{if(!queued){queued=true;later(send)}};
    const unregister=name=>{if(tools.delete(text(name,64)))changed()};
    const register=t=>{
      const name=text(t&&t.name,64),description=text(t&&t.description,1000),execute=t&&t.execute;
      if(!/^[A-Za-z0-9_.-]{1,64}$/.test(name)||typeof execute!=='function')throw new TypeError('A tool needs a name of letters, digits, _ . or -, a description and execute.');
      if(tools.has(name))throw new DOMException('A tool named '+name+' is already registered.','InvalidStateError');
      let schema='{"type":"object","properties":{}}';try{if(t.inputSchema!=null)schema=text(stringify(t.inputSchema),8000)}catch(_){}
      tools.set(name,{name,description,schema,execute});changed();
      return {unregister(){unregister(name)}}};
    const context=Object.freeze({
      registerTool(t){return register(t)},
      unregisterTool(name){unregister(name)},
      provideContext(o){tools.clear();changed();for(const t of Array.from((o&&o.tools)||[]))register(t)},
      clearContext(){tools.clear();changed()}});
    for(const o of [navigator,document])try{Object.defineProperty(o,'modelContext',{value:context,configurable:true,enumerable:true})}catch(_){}
    addEventListener('message',e=>{const d=e.data;if(e.source!==window||!d||typeof d!=='object'||d.sereinPageTools!=='call')return;
      const id=text(d.id,64),tool=tools.get(text(d.name,64));
      const reply=(ok,value)=>{let out='';try{out=typeof value==='string'?value:stringify(value===undefined?null:value)}catch(_){out=text(value,20000)}try{post({sereinPageTools:'result',id,ok,text:text(out,20000)},'*')}catch(_){}};
      if(!tool){reply(false,'This page has no tool by that name now.');return}
      let input;try{input=parse(text(d.input,20000))}catch(_){reply(false,'The arguments are not JSON.');return}
      const client={requestUserInteraction(){return Promise.reject(new DOMException('Serein does not hand the person to a page tool.','NotAllowedError'))}};
      Promise.resolve().then(()=>tool.execute(input,client)).then(v=>reply(true,v),err=>reply(false,text(err&&err.message||err,500)))});
    // PageKit starts with the parsed document: tools registered before it listens are sent again.
    addEventListener('load',changed);addEventListener('pageshow',changed);
    }catch(_){}})();
    """
}

extension BrowserModel {
  /// page_tool: refused while the switch is off, on a host the person did not list, and in a
  /// scheduled run. Otherwise every call asks, whatever Autopilot says, with the host, the tool's
  /// name and the exact arguments on the card. After the yes the page version, the host and the
  /// tool's listing must be the ones approved; PageKit checks the listing once more as it calls.
  func pageTool(_ tab: BrowserTab, task id: String, arguments a: [String: Any]) async throws -> [String: Any] {
    guard PageTools.isEnabled() else { throw SereinError.invalid(PageTools.offMessage) }
    let host = tab.web.url?.host?.lowercased() ?? ""
    guard PageTools.allows(host: host) else { throw SereinError.invalid(PageTools.notAllowed(host)) }
    let relay = relayTask(id, tasks[id])
    guard !isUnattended(task: id) else { throw SereinError.invalid(PageTools.scheduledMessage) }
    let name = String((a["name"] as? String ?? "").prefix(64))
    guard let sent = PageTools.exactArguments(a["arguments"]) else {
      throw SereinError.invalid("arguments must be a JSON object of at most \(PageTools.argumentLimit) bytes.")
    }
    if HandBack.containsCardNumber(sent) { throw SereinError.invalid(HandBack.message) }
    if let site = URL(string: tab.address)?.absoluteString, !site.isEmpty {
      try await authorizeSite(site, taskID: id)
    }
    guard let tool = try await pageTools(tab).first(where: { $0.name == name }) else {
      throw SereinError.invalid(PageTools.missing(name))
    }
    if let check = await tab.verificationCheck() { throw check }
    if await tab.hasUserSteps() { throw SereinError.invalid(HandBack.message) }
    let version = PageTools.version(page: tab.pageVersion, host: host)
    let gate = PageTools.gate(tool, site: host, pageVersion: version)
    let effect = PageTools.effect(gate)
    let intent = ApprovalGate.record(gate, effect: effect, mint: { UUID().uuidString })
    if let pending = tasks[id]?.pendingApprovals {
      tasks[id]?.pendingApprovals = ApprovalGate.mergePending(pending, intent)
    }
    // The task's level and the site's rule decide; a card shows the exact arguments.
    let decision = try ApprovalDoor.answer(
      .init(
        .effect(effect), standing(task: id, else: RelayOrchestrator.standing(relay, present: !isUnattended(task: id))),
        site: SiteRules.rule(for: tab.address), taskID: id),
      facts: .init(
        secureField: false, botCheck: false, pays: .no, covered: false, path: nil,
        hostKeyChanged: nil, runsAnything: false, ref: "")
    ).decision()
    let answer: ApprovalGate.HumanAnswer
    if decision == .auto {
      answer = .yes
    } else {
      guard let askRelay = relay ?? RelayOrchestrator.shared else { throw SereinError.invalid(ActionAdmission.needsPerson) }
      answer = await askRelay.confirmAnswer(
        PageTools.cardTitle(host: host), PageTools.cardDetail(tool, effect: effect), thread: threadID(forTask: id),
        more: sent, moreName: "the arguments", site: host, moreOpen: true)
    }
    guard tasks[id]?.finished == false else { throw SereinError.invalid("The task ended while awaiting approval") }
    let liveHost = tab.web.url?.host?.lowercased() ?? ""
    let live = (try? await pageTools(tab))?.first { $0.name == name }
    let liveVersion = PageTools.version(page: tab.pageVersion, host: liveHost)
    let liveEffect = live.map { PageTools.effect(PageTools.gate($0, site: liveHost, pageVersion: liveVersion)) } ?? effect
    guard ApprovalGate.pressCheck(
      intent: intent, answer: answer, liveElement: live?.stamp ?? "", liveVersion: liveVersion, liveEffect: liveEffect)
      == .proceed
    else {
      throw SereinError.invalid(ActionAdmission.blocked(
        answer: answer, decision: decision, effectChanged: liveEffect != intent.effect))
    }
    // The switch or the site may have been turned off, or the site set to Never, while the card waited.
    guard PageTools.allows(host: liveHost) else { throw SereinError.invalid(PageTools.notAllowed(liveHost)) }
    try checkSiteRule(tab)
    if await tab.hasUserSteps() { throw SereinError.invalid(HandBack.message) }
    guard !tab.sleeping, tasks[id]?.finished == false else { throw SereinError.invalid("The task ended during this operation") }
    let raw: Any?
    do {
      raw = try await tab.web.callAsyncJavaScript(
        "return await globalThis.__serein.callTool(name, input, stamp)",
        arguments: ["name": tool.name, "input": sent, "stamp": tool.stamp], in: nil, contentWorld: BrowserTab.world)
    } catch {
      let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
      throw SereinError.invalid(detail ?? error.localizedDescription)
    }
    guard tasks[id] != nil else { throw SereinError.invalid("The task ended during this operation") }
    let reply = raw as? [String: Any] ?? [:]
    if reply["changed"] as? Bool == true { throw SereinError.invalid(ActionAdmission.pageChanged) }
    var out = PageTools.result(tool: tool.name, ok: reply["ok"] as? Bool == true, text: reply["text"] as? String ?? "")
    out["tab"] = tab.id
    return out
  }

  /// A read's `page_tools`: fenced, while the switch is on and the site is listed; only a count
  /// and where to allow the site otherwise; nothing at all while the switch is off.
  func pageToolListing(_ raw: Any?, tab: BrowserTab) -> [String: Any]? {
    guard PageTools.isEnabled() else { return nil }
    let tools = PageTools.tools(raw)
    guard !tools.isEmpty else { return nil }
    let host = tab.web.url?.host?.lowercased() ?? ""
    guard PageTools.allows(host: host) else { return ["offered": tools.count, "note": PageTools.notAllowed(host)] }
    return PageTools.listing(tools)
  }

  private func pageTools(_ tab: BrowserTab) async throws -> [PageTools.Tool] {
    let raw = try await tab.script("globalThis.__serein.pageTools()")
    return PageTools.tools(raw)
  }
}

/// Settings › Privacy › Tools that sites offer: the switch (off on a fresh install) and the sites allowed,
/// which start empty. Stored in GateSettings with the other gate switches.
struct PageToolSettings: View {
  @Environment(\.palette) private var p
  @State private var enabled = PageTools.isEnabled()
  @State private var sites = PageTools.sites()
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle("Let agents use tools that sites offer", isOn: $enabled)
        .onChange(of: enabled) { _, on in PageTools.setEnabled(on) }
        .accessibilityHint("Off by default. Only the sites listed below, and you approve every call.")
      Text("Some sites publish tools for AI agents. With this on, an agent may ask to call one on a site you list here. Every call shows the site, the tool and exactly what will be sent, and waits for you; scheduled tasks never call one. What a site says about its tools is treated as untrusted. Applies to agent tabs opened after you turn it on.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      Text("Sites allowed").font(UIStyle.meta).foregroundStyle(p.ink)
      if sites.isEmpty {
        Text("None. Page tools work on no site until you add one.").role(.meta)
      }
      ForEach(sites, id: \.self) { host in
        HStack(spacing: 8) {
          Text(host).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
          Button("Remove") { save(sites.filter { $0 != host }) }
            .buttonStyle(QuietButton())
            .accessibilityLabel("Remove \(host) from page tools")
        }
      }
      HStack(spacing: 8) {
        TextField("Add a site, such as example.com", text: $draft)
          .textFieldStyle(.serein)
          .onSubmit { add() }
          .accessibilityLabel("Site to allow page tools on")
        Button("Add") { add() }.buttonStyle(QuietButton()).disabled(TaskPass.host(draft).isEmpty)
          .accessibilityLabel("Add site to page tools")
      }
      Text("Only the exact site you add: a subdomain is another site.").role(.meta)
    }.font(UIStyle.body).foregroundStyle(p.ink).controlSize(.small)
      .accessibilityElement(children: .contain)
  }

  private func add() {
    let host = TaskPass.host(draft)
    guard !host.isEmpty else { return }
    save(sites + [host])
    draft = ""
  }
  private func save(_ hosts: [String]) {
    PageTools.setSites(hosts)
    sites = PageTools.sites()
  }
}
