import SereinCore
import SwiftUI
import WebKit

/// Recent console errors per regular tab: uncaught exceptions, unhandled promise rejections,
/// failed resource loads and blocked requests, up to 50 per page, plus the page's own
/// console.error and console.warn calls, labelled as reported by the page. The watcher runs in Serein's
/// isolated world, so pages cannot see it or post to it. Private tabs and agent tabs get no
/// watcher. Nothing leaves the tab until the user adds "Console errors" to a message.
@MainActor final class ConsoleWatch: NSObject, WKScriptMessageHandler {
  static let handlerName = "sereinConsole"
  private weak var tab: BrowserTab?
  init(tab: BrowserTab) { self.tab = tab }

  static func install(on tab: BrowserTab, controller: WKUserContentController) {
    guard !tab.privateMode, tab.owner == nil else { return }
    controller.addUserScript(
      WKUserScript(
        source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true,
        in: BrowserTab.world))
    controller.add(ConsoleWatch(tab: tab), contentWorld: BrowserTab.world, name: handlerName)
    // The page's own console.error / console.warn calls need the page world. Same tabs only.
    controller.addUserScript(
      WKUserScript(
        source: PageConsoleWatch.script, injectionTime: .atDocumentStart, forMainFrameOnly: true,
        in: .page))
    controller.add(PageConsoleWatch(tab: tab), contentWorld: .page, name: PageConsoleWatch.handlerName)
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    // Agent tabs (even one the user later took over) and source views never collect.
    guard let tab, message.frameInfo.isMainFrame, !tab.privateMode, tab.owner == nil,
      tab.takenFrom == nil, !tab.hiddenFromAgents
    else { return }
    if (message.body as? [String: Any])?["kind"] as? String == "page" {
      ConsoleWatchStore.shared.reset(tab.id)
      return
    }
    guard let entry = ConsoleEntry(message: message.body) else { return }
    ConsoleWatchStore.shared.add(entry, tab: tab.id)
  }

  /// Listens for error events only; it never wraps or changes the page's own objects.
  /// A page that throws in a loop is limited to 100 reports every 10 seconds.
  static let script = """
    (()=>{try{
    if(window.__sereinConsoleWatch)return;
    Object.defineProperty(window,'__sereinConsoleWatch',{value:true});
    const post=m=>{try{webkit.messageHandlers.sereinConsole.postMessage(m)}catch(_){}};
    let sent=0,since=Date.now();
    const send=m=>{const now=Date.now();if(now-since>10000){since=now;sent=0}if(++sent>100)return;post(m)};
    const text=(v,n)=>{try{return String(v==null?'':v).slice(0,n||2000)}catch(_){return ''}};
    post({kind:'page'});
    addEventListener('error',e=>{
      const t=e.target;
      if(t&&t!==window&&t.tagName){
        const url=text(t.currentSrc||t.src||t.href||'',600);
        send({kind:'resource',message:'Failed to load '+text(t.tagName,20).toLowerCase()+(url?' '+url:''),source:url});
        return}
      send({kind:'exception',message:text(e.message||'Error'),source:text(e.filename,600),line:e.lineno|0,column:e.colno|0})
    },true);
    addEventListener('unhandledrejection',e=>{
      let r=e.reason,m='';
      try{m=r&&r.stack?r.stack:r&&r.message?r.message:r}catch(_){}
      send({kind:'rejection',message:'Unhandled rejection: '+(text(m)||'no reason given')})
    });
    document.addEventListener('securitypolicyviolation',e=>{
      send({kind:'policy',message:'Blocked by content security policy: '+text(e.violatedDirective,200)+(e.blockedURI?' '+text(e.blockedURI,600):''),source:text(e.sourceFile,600),line:e.lineNumber|0,column:e.columnNumber|0})
    });
    }catch(_){}})();
    """
}

/// console.error and console.warn calls the page makes itself. The wrapper runs in the page world,
/// so the page can see it, replace it and post to this handler with anything it likes. Entries are
/// therefore only ever shown as "reported by the page", capped, rate limited here (not only in the
/// script), and used for nothing but the opt-in "Console errors" text.
@MainActor final class PageConsoleWatch: NSObject, WKScriptMessageHandler {
  static let handlerName = "sereinPageConsole"
  private weak var tab: BrowserTab?
  init(tab: BrowserTab) { self.tab = tab }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let tab, message.frameInfo.isMainFrame, message.webView === tab.web, !tab.privateMode,
      tab.owner == nil, tab.takenFrom == nil, !tab.hiddenFromAgents
    else { return }
    // A report from the page we just left can arrive after the new one committed.
    if let from = message.frameInfo.request.url, let now = tab.web.url, from != now { return }
    guard let entry = ConsoleEntry(pageReport: message.body) else { return }
    ConsoleWatchStore.shared.addPageReport(entry, tab: tab.id)
  }

  /// Calls the original first and never throws, so the page behaves as before. Each report is a
  /// level and a text of at most 500 characters; the page is limited to 50 and a short burst.
  /// Only primitives are turned into text: objects, errors and functions are named by type and
  /// never read, so no page getter, toJSON or Proxy trap runs because of Serein.
  static let script = """
    (()=>{try{
    const h=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.sereinPageConsole;
    if(!h||!console)return;
    const post=h.postMessage.bind(h);
    let sent=0,burst=0,since=Date.now();
    const one=v=>{try{
      const t=typeof v;
      if(t==='string')return v.slice(0,500);
      if(v===null||t==='undefined'||t==='number'||t==='boolean'||t==='bigint'||t==='symbol')return String(v);
      return t==='function'?'[function]':'[object]'}catch(_){return '[unprintable]'}};
    const wrap=(level)=>{
      const orig=console[level];
      if(typeof orig!=='function')return;
      console[level]=function(...a){
        try{
          const now=Date.now();if(now-since>10000){since=now;burst=0}
          if(sent<50&&burst<20){
            let m='';for(let i=0;i<a.length&&m.length<500;i++)m+=(i?' ':'')+one(a[i]).slice(0,500);
            sent++;burst++;post({level:level,message:m.slice(0,500)})}
        }catch(_){}
        return orig.apply(this,a)}};
    wrap('error');wrap('warn');
    }catch(_){}})();
    """
}

/// Per-tab logs, in memory only.
@MainActor final class ConsoleWatchStore: ObservableObject {
  static let shared = ConsoleWatchStore()
  /// Errors per tab, repeats included, for the "Console errors (N)" offer.
  @Published private(set) var counts: [String: Int] = [:]
  private var logs: [String: ConsoleLog] = [:]

  func add(_ entry: ConsoleEntry, tab: String) {
    if logs[tab] == nil && logs.count > 100 { prune() }
    logs[tab, default: ConsoleLog()].add(entry)
    counts[tab] = logs[tab]?.entries.count
  }
  func addPageReport(_ entry: ConsoleEntry, tab: String) {
    if logs[tab] == nil && logs.count > 100 { prune() }
    guard logs[tab, default: ConsoleLog()].addPageReport(entry) else { return }
    counts[tab] = logs[tab]?.entries.count
  }
  func reset(_ tab: String) {
    guard logs[tab] != nil else { return }
    logs[tab] = nil
    counts[tab] = nil
  }
  /// What would be attached for this tab now, or nil when it has none or may not share.
  func snapshot(_ tab: BrowserTab) -> ConsoleSnapshot? {
    guard Self.mayShare(tab), let log = logs[tab.id], !log.isEmpty else { return nil }
    return ConsoleSnapshot(tabID: tab.id, url: tab.address, title: tab.title, entries: log.entries)
  }
  func count(_ tab: BrowserTab) -> Int { Self.mayShare(tab) ? counts[tab.id] ?? 0 : 0 }
  static func mayShare(_ tab: BrowserTab) -> Bool {
    !tab.privateMode && tab.owner == nil && tab.takenFrom == nil && !tab.hiddenFromAgents
  }
  /// Drops logs of tabs that are gone.
  private func prune() {
    let live = Set((BrowserContext.browser?.tabs ?? []).map(\.id))
    logs = logs.filter { live.contains($0.key) }
    counts = counts.filter { live.contains($0.key) }
  }
}

extension ComposerContext {
  /// The console block for a turn: only from a tab that is still regular and open.
  func consoleBlock(browser: BrowserModel?, chips: Chips? = nil) -> String {
    guard let snapshot = (chips ?? current).console,
      let tab = browser?.tabs.first(where: { $0.id == snapshot.tabID }),
      ConsoleWatchStore.mayShare(tab)
    else { return "" }
    return ConsoleErrors.render(snapshot)
  }
}

/// "Page errors (N)" under the composer when the current page has errors. Off by default:
/// nothing is attached until the user adds it.
struct ConsoleErrorsOffer: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var store = ConsoleWatchStore.shared
  @ObservedObject var context = ComposerContext.shared
  @Environment(\.palette) var p
  var tab: BrowserTab? {
    guard let tab = browser.active, ConsoleWatchStore.mayShare(tab) else { return nil }
    return tab
  }
  var body: some View {
    if let tab, store.count(tab) > 0, context.console?.tabID != tab.id {
      HStack(spacing: 6) {
        Button {
          context.console = store.snapshot(tab)
        } label: {
          HStack(spacing: 6) {
            InterfaceIcon(systemName: "plus", size: 10)
            Text("Page errors (\(store.count(tab)))").font(UIStyle.font(12, weight: .medium))
          }.foregroundStyle(p.secondary).padding(.horizontal, 10).frame(height: 26)
            .overlay(Capsule().strokeBorder(p.line)).contentShape(Capsule())
        }.buttonStyle(.pressable)
          .help("Errors reported by \(tab.title). Add them to your message to investigate this webpage.")
          .accessibilityLabel("Add webpage console errors, \(store.count(tab))")
        Spacer(minLength: 0)
      }.padding(.horizontal, 16).padding(.top, 10)
    }
  }
}
