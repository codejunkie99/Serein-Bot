import AppKit
import ObjectiveC
import SereinCore
import WebKit

/// One turn's context after the user pressed Send.
struct PreparedTurn {
  /// What the CLI receives: the rendered context blocks, then the user's words.
  var prompt: String
  var context: String
  var plan: Bool
  var approved: Bool
  var pictures: [String]
  /// This turn's private picture folder; the only folder the agent may read pictures from.
  /// Deleted when the run ends (`AgentHub.finish`) or when the send fails.
  var folder: URL? = nil
  /// Page, tab, selection, element or console chips: text from websites (OwnSetup.applies).
  var webContent = false
  /// This turn's staged documents with their digests (no text): the only files an upload may send.
  var documents: [PageContext.Document] = []
  /// The hosts and document names the chips hand the model, for the reply's source line.
  var read: ReplySources? = nil
}

/// Context chips for the composer: the page, selected text, pointed elements, other tabs and
/// pictures, plus plan mode. Nothing is ever taken from a private tab.
@MainActor final class ComposerContext: ObservableObject {
  static let shared: ComposerContext = {
    // Pictures and turn folders left from an earlier launch are never offered to an agent.
    TurnAttachments.removeStale(root: ComposerContext.attachmentRoot)
    return ComposerContext()
  }()
  static var attachmentRoot: URL { TurnAttachments.root() }
  init() { PagePointer.installContextMenu() }
  /// A newly created task asks its own composer to unfold its destination/model controls.
  @Published var taskOptionsThreadID: String?
  @Published var page: PageContext.Page?
  @Published var selection: PageContext.Selection?
  @Published var elements: [PageContext.Element] = [] {
    didSet {
      if !moving {
        Self.discard(oldValue.compactMap(\.picture), keeping: elements.compactMap(\.picture))
      }
    }
  }
  @Published var tabs: [PageContext.Page] = []
  @Published var pictures: [PageContext.Picture] = [] {
    didSet { if !moving { Self.discard(oldValue.map(\.path), keeping: pictures.map(\.path)) } }
  }
  /// Documents the user attached (DocumentAttachments.swift): their text goes with the message,
  /// and only these files can be uploaded in the turn they go with.
  @Published var documents: [PageContext.Document] = [] {
    didSet { if !moving { Self.discard(oldValue.map(\.path), keeping: documents.map(\.path)) } }
  }
  /// Console errors the user added from a regular tab (ConsoleWatch.swift). Off by default.
  @Published var console: ConsoleSnapshot?
  /// True while chips move between the composer and a thread or queued message, so their
  /// picture files are kept.
  private var moving = false
  /// Chips the user attached in threads that are not open; they come back with the thread.
  private var stash: [String: Chips] = [:]

  /// The chips attached for one message. Queued, held and approval messages carry the chips
  /// captured with them (or none), never whatever is attached when they finally go out.
  struct Chips {
    var page: PageContext.Page?
    var selection: PageContext.Selection?
    var elements: [PageContext.Element] = []
    var tabs: [PageContext.Page] = []
    var pictures: [PageContext.Picture] = []
    var console: ConsoleSnapshot? = nil
    var documents: [PageContext.Document] = []
    static let empty = Chips()
    var isEmpty: Bool {
      page == nil && selection == nil && elements.isEmpty && tabs.isEmpty && pictures.isEmpty
        && console == nil && documents.isEmpty
    }
    var picturePaths: [String] { pictures.map(\.path) + elements.compactMap(\.picture) }
    /// Every waiting file these chips hold: pictures and documents.
    var filePaths: [String] { picturePaths + documents.map(\.path) }
  }
  /// What is attached in the composer now.
  var current: Chips {
    Chips(
      page: page, selection: selection, elements: elements, tabs: tabs, pictures: pictures,
      console: console, documents: documents)
  }
  /// Detaches the composer's chips (keeping their pictures) for a message sent later.
  func take() -> Chips {
    let chips = current
    moving = true
    clearChips()
    moving = false
    return chips
  }
  /// Puts chips back in the composer, replacing what is there.
  func put(_ chips: Chips) {
    let old = take()
    moving = true
    page = chips.page
    selection = chips.selection
    elements = chips.elements
    tabs = chips.tabs
    pictures = chips.pictures
    console = chips.console
    documents = chips.documents
    moving = false
    Self.release(old, keeping: chips)
  }
  /// Deletes the waiting picture and document files of chips that will never be sent.
  static func release(_ chips: Chips, keeping: Chips = .empty) {
    discard(chips.filePaths, keeping: keeping.filePaths)
  }
  /// Chips are per thread: leaving a thread keeps its chips for when it is opened again.
  func switchThread(from old: String, to new: String) {
    guard old != new else { return }
    let current = take()
    if !current.isEmpty { stash[old] = current }
    if let saved = stash.removeValue(forKey: new) {
      moving = true
      page = saved.page
      selection = saved.selection
      elements = saved.elements
      tabs = saved.tabs
      pictures = saved.pictures
      console = saved.console
      documents = saved.documents
      moving = false
    }
  }
  /// A deleted thread's waiting chips are dropped.
  func forget(thread: String) {
    if let saved = stash.removeValue(forKey: thread) { Self.release(saved) }
  }
  /// The page the Ask panel moved to; the user confirms before it is attached.
  @Published var pageOffer: String?
  @Published var planMode = false
  /// Threads whose last turn proposed a plan; "go ahead" there re-sends with edits allowed.
  @Published var awaitingApproval = Set<String>()
  /// The rendered context of each thread's last turn, for "Show what was sent".
  @Published var lastSent: [String: String] = [:]
  /// True while the task panel shows the page thread Ask opened (Ask lives in the panel now).
  var askOpen: Bool {
    let dock = TaskDock.shared
    return dock.open && askThreadID != nil && dock.threadID == askThreadID
  }
  /// The page thread Ask opened in the task panel.
  @Published var askThreadID: String?
  /// Bumped to put the cursor in the task panel's composer; `wantsComposerFocus` covers a
  /// composer that appears after the request.
  @Published var focusComposer = 0
  var wantsComposerFocus = false
  /// The address the page chip was last captured from.
  var attachedURL: String?
  @Published var pointing = false
  @Published var devFact: (address: String, text: String)?
  @Published var notice: String?

  var hasChips: Bool {
    page != nil || selection != nil || !elements.isEmpty || !tabs.isEmpty || !pictures.isEmpty
      || console != nil || !documents.isEmpty
  }

  // MARK: Turn

  /// The context for the next turn. Re-checks that no source tab has become private.
  func turn(browser: BrowserModel?, chips: Chips? = nil, plan: Bool? = nil) -> PageContext.Turn {
    let chips = chips ?? current
    let shared = Set((browser?.tabs ?? []).filter { !$0.privateMode && !$0.hiddenFromAgents }.map(\.id))
    var turn = PageContext.Turn(
      page: chips.page.flatMap { shared.contains($0.id) ? $0 : nil },
      selection: chips.selection, elements: chips.elements,
      tabs: chips.tabs.filter { shared.contains($0.id) }, pictures: chips.pictures,
      documents: chips.documents, plan: plan ?? planMode)
    if browser?.active?.privateMode == true || browser?.active?.hiddenFromAgents == true {
      turn.selection = nil
      turn.elements = []
    }
    let pageData = turn.page != nil || turn.selection != nil || !turn.elements.isEmpty
    if pageData, let fact = devFact, let address = browser?.active?.address,
      DevServer.localPort(address) != nil, sameOrigin(fact.address, address)
    {
      turn.facts = [fact.text]
    }
    return turn
  }
  /// The chips a reply in a chat that its own CLI answers sends (LinkedSessions): a pointed
  /// element goes as text, and its picture only while the CLI has room after the person's own.
  static func forCLI(_ chips: Chips, pictures limit: Int) -> Chips {
    var chips = chips
    var room = limit - chips.pictures.count
    for i in chips.elements.indices where chips.elements[i].picture != nil {
      if room > 0 && !chips.elements[i].sensitive { room -= 1 } else { chips.elements[i].picture = nil }
    }
    return chips
  }
  /// Exactly what goes with the draft. A chat that its own CLI answers gets the same blocks with
  /// no plan step, and the words as typed (AgentModel.send).
  func preview(browser: BrowserModel?, agent: AgentModel, draft: String) -> String {
    if agent.repliesInApp {
      let limit = agent.provider.driver.map(HarnessCommands.pictures) ?? 0
      let turn = turn(browser: browser, chips: Self.forCLI(current, pictures: limit), plan: false)
      return ConsoleErrors.attach(consoleBlock(browser: browser), to: PageContext.render(turn))
        + draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var turn = turn(browser: browser)
    // The composer's own draft: the person's words, so an edited plan counts (`PlanDraft.approves`).
    if awaitingApproval.contains(agent.conversationID) && PlanDraft.approves(draft) {
      turn.plan = false
      turn.approvedPlan = true
    }
    return ConsoleErrors.attach(consoleBlock(browser: browser), to: PageContext.render(turn)) + AgentPrivacy.redact(draft)
  }
  /// Called by `AgentModel.send` once the destination is known.
  /// `chips` nil uses what is attached in the composer now.
  /// `byPerson`: the words are the person's own (never Serein's dispatch or a run it started), so
  /// an edited plan may be their yes. Otherwise only a plain approval phrase is.
  func prepare(
    _ prompt: String, agent: AgentModel, browser: BrowserModel, chips: Chips? = nil,
    plan: Bool? = nil, byPerson: Bool = false
  ) -> PreparedTurn {
    var turn = turn(browser: browser, chips: chips, plan: plan)
    let approving =
      awaitingApproval.contains(agent.conversationID)
      && (byPerson ? PlanDraft.approves(prompt) : PageContext.isApproval(prompt))
    if approving {
      // Edits are allowed for this one turn by `AgentModel.send`; the user's own
      // "Allow project edits" setting is never changed here.
      turn.plan = false
      turn.approvedPlan = true
    }
    // Copy this turn's pictures and documents into a fresh private folder; only that folder is
    // granted, and only its documents can be uploaded.
    var folder: URL?
    do {
      folder = try TurnAttachments.stage(&turn, root: Self.attachmentRoot)
    } catch {
      TurnAttachments.remap(&turn, [:])
      notice = "Pictures and documents could not be prepared, so they were left out."
    }
    let console = consoleBlock(browser: browser, chips: chips)
    let context = ConsoleErrors.attach(console, to: PageContext.render(turn))
    return PreparedTurn(
      prompt: context + AgentPrivacy.redact(prompt), context: context, plan: turn.plan, approved: approving,
      pictures: turn.picturePaths, folder: folder, webContent: turn.webContent || !console.isEmpty,
      documents: turn.documents.map { var d = $0; d.text = ""; return d }, read: ReplySources.carried(turn))
  }
  /// Deletes a turn's picture folder.
  static func release(_ folder: URL?) {
    if let folder { TurnAttachments.remove(folder, root: attachmentRoot) }
  }
  /// Deletes waiting pictures and documents that no chip uses any more.
  static func discard(_ old: [String], keeping: [String]) {
    let kept = Set(keeping)
    for path in old where !kept.contains(path) {
      TurnAttachments.discard(path, root: attachmentRoot)
    }
  }
  /// Called after the run started: chips are spent, and a plan waits for approval.
  /// `chips` are the chips the turn carried when they were not the composer's own.
  func commit(_ turn: PreparedTurn, threadID: String, chips: Chips? = nil) {
    lastSent[threadID] = turn.context
    if let chips {
      // The turn copied its pictures into its own folder; the waiting originals can go.
      Self.release(chips, keeping: current)
    } else {
      page = nil
      selection = nil
      elements = []
      tabs = []
      pictures = []
      console = nil
      documents = []
    }
    if turn.plan {
      awaitingApproval.insert(threadID)
    } else {
      awaitingApproval.remove(threadID)
      if turn.approved { planMode = false }
    }
  }
  /// Statements for the router, so a localhost page routes to the project serving it.
  func routingFacts(browser: BrowserModel) -> [String] {
    guard let fact = devFact, let address = browser.active?.address,
      browser.active?.privateMode == false, sameOrigin(fact.address, address)
    else { return [] }
    return [fact.text]
  }
  func clearChips() {
    page = nil
    selection = nil
    elements = []
    tabs = []
    pictures = []
    console = nil
    documents = []
  }

  // MARK: Capture

  /// "Ask Serein About This Page" (⌥⌘E, ⋯): Serein's chat shows beside the page, as ⌘E does
  /// (a peek when Serein is hidden, never a switch away from the page), with the page attached as
  /// a chip: its title, address, text and the current selection, as untrusted data. Nothing is
  /// sent until you write. The page keeps the main view.
  func openAsk(browser: BrowserModel) {
    guard browser.section == ShellSection.browser, let tab = browser.active else {
      browser.notice = "Open a page first, then ask about it."
      return
    }
    guard !tab.privateMode else {
      browser.notice = "Private tabs are never shared with agents."
      return
    }
    guard !tab.hiddenFromAgents else {
      browser.notice = tab.isSourceView
        ? "Source views are never shared with agents." : SiteRules.personLine(SiteRules.site(tab.address) ?? "this site", verb: "read")
      return
    }
    SereinPageChip.shared.restore(tab.id)
    SereinRouter.show()
    Task {
      let captured = await Self.capture(tab)
      let picked = await Self.selectedText(tab)
      guard !tab.privateMode, !tab.hiddenFromAgents else { return }
      var chip = Self.pageChip(captured, selection: picked)
      chip.page = SereinPageChip.page(tab)
      chip.sensitive = captured.sensitive
      SereinSurface.main.attach(chip)
    }
  }
  /// The chip ⌥⌘E attaches: “Ramen guide · eater.com · with text”, carrying what the page says
  /// (never a password or payment page's text) and the selection.
  static func pageChip(_ page: PageContext.Page, selection: String?) -> SereinAttachment {
    let title = AgentPrivacy.redact(page.title)
    var body = "URL: \(AgentPrivacy.url(page.url))\nTitle: \(title)\n"
    if page.unavailable {
      body += "Page text: unavailable. Only the URL and title are known."
    } else if page.sensitive && page.text.isEmpty {
      body += CurrentPageContext.sensitiveRefusal + "."
    } else {
      body += "\n" + CurrentPageContext.text(page.text)
    }
    if let selection = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty {
      body += "\n\nSelected on the page:\n" + AgentPrivacy.redact(String(selection.prefix(PageContext.selectionLimit)))
    }
    let host = URL(string: page.url)?.host ?? ""
    let words = TabText.clip(title.isEmpty ? (host.isEmpty ? "This page" : host) : title, 48)
    // “· with text” says the page's whole text goes with the next message, not only its address.
    let withText = !page.unavailable && !page.text.isEmpty
    return SereinAttachment(title: host.isEmpty || title.isEmpty ? words : "\(words) · \(host)", icon: "globe", body: body,
                            suffix: withText ? "with text" : nil,
                            note: withText ? "Serein gets this page’s text with your message" : nil)
  }
  func refreshSelection(_ tab: BrowserTab) async {
    guard !tab.privateMode, !tab.hiddenFromAgents else { return }
    if let picked = await Self.selectedText(tab), !picked.isEmpty {
      selection = PageContext.Selection(url: tab.address, title: tab.title, text: picked)
    }
  }
  /// Captures the page text and the current selection for chips.
  func attachPage(_ tab: BrowserTab, browser: BrowserModel) async {
    guard !tab.privateMode, !tab.hiddenFromAgents else { return }
    attachedURL = tab.address
    pageOffer = nil
    let captured = await Self.capture(tab)
    guard !tab.privateMode else { return }
    page = captured
    await refreshSelection(tab)
    await detectDevServer(tab, browser: browser)
  }
  /// Adds or removes another tab for "Ask about these tabs" (six pages at most, with this one).
  func toggleTab(_ tab: BrowserTab, browser: BrowserModel) {
    if let i = tabs.firstIndex(where: { $0.id == tab.id }) {
      tabs.remove(at: i)
      return
    }
    guard !tab.privateMode, !tab.hiddenFromAgents else { return }
    guard tabs.count + (page == nil ? 0 : 1) < PageContext.maxTabs else {
      notice = "Up to \(PageContext.maxTabs) pages at once. Remove one to add another."
      return
    }
    let placeholder = PageContext.Page(
      id: tab.id, url: tab.sleepingAddress ?? tab.address, title: tab.title, text: "",
      sensitive: false, unavailable: true)
    tabs.append(placeholder)
    Task {
      // A sleeping tab has no page to read: load it first.
      if tab.sleeping {
        tab.wake()
        try? await Task.sleep(nanoseconds: 300_000_000)
        await tab.settle()
      }
      let captured = await Self.capture(tab)
      if let i = tabs.firstIndex(where: { $0.id == tab.id }) { tabs[i] = captured }
    }
  }
  static func capture(_ tab: BrowserTab) async -> PageContext.Page {
    let fallback = PageContext.Page(
      id: tab.id, url: tab.sleepingAddress ?? tab.address, title: tab.title, text: "",
      sensitive: false, unavailable: true)
    guard !tab.sleeping, !tab.privateMode else { return fallback }
    // A source view shows another page's raw markup, hidden inputs included: never shared.
    if tab.hiddenFromAgents {
      return PageContext.Page(
        id: tab.id, url: tab.address, title: tab.title, text: "", sensitive: true)
    }
    let result = await withTimeout(3) { () -> (String, Bool)? in
      let sensitive = await tab.pageIsSensitive()
      if sensitive { return ("", true) }
      guard let outline = try? await tab.script("globalThis.__serein.readContext()") as? [String: Any],
        outline["sensitive"] as? Bool == false,
        let documentID = outline["documentID"] as? String,
        let text = outline["text"] as? String,
        !(await tab.pageIsSensitive()),
        let final = try? await tab.script("globalThis.__serein.probe()") as? [String: Any],
        final["id"] as? String == documentID, final["steps"] as? Bool == false,
        final["revision"] as? Int == outline["revision"] as? Int,
        !tab.web.isLoading, !tab.privateMode, !tab.hiddenFromAgents
      else { return ("", true) }
      return (text, false)
    }
    guard let (text, sensitive) = result ?? nil else { return fallback }
    // Do not cut here. Page text is redacted before it is limited; a prefix would
    // leave the start of a key that straddles the limit.
    return PageContext.Page(
      id: tab.id, url: tab.address, title: tab.title, text: text, sensitive: sensitive)
  }
  static func selectedText(_ tab: BrowserTab) async -> String? {
    guard !tab.privateMode, !tab.sleeping, !tab.hiddenFromAgents else { return nil }
    try? await PagePointer.ensure(tab)
    let value = try? await tab.script("globalThis.__sereinPoint.selection()") as? [String: Any]
    guard value?["sensitive"] as? Bool == false else { return nil }
    return value?["text"] as? String
  }
  func attachPicture(_ data: Data, name: String) {
    guard pictures.count < 6 else {
      notice = "Up to 6 pictures per message."
      return
    }
    guard let png = Self.png(data), png.count < 8_000_000 else {
      notice = "That picture could not be attached."
      return
    }
    do {
      let url = try Self.attachmentURL(name: "picture")
      try png.write(to: url, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      pictures.append(PageContext.Picture(path: url.path, name: name))
    } catch { notice = error.localizedDescription }
  }
  static func png(_ data: Data) -> Data? {
    guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init)
    else { return nil }
    return rep.representation(using: .png, properties: [:])
  }
  static func attachmentURL(name: String, extension ext: String = "png") throws -> URL {
    let folder = attachmentRoot
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).\(ext)")
  }

  // MARK: Dev servers

  /// Finds the project whose dev server answers on this localhost page.
  func detectDevServer(_ tab: BrowserTab, browser: BrowserModel) async {
    let address = tab.address
    guard let port = DevServer.localPort(address) else { return }
    // The fact can reach routing prompts, so only listed projects are matched.
    let projects = browser.shareableProjects.map { ($0.id, $0.name, $0.path) }
    let found = await Task.detached(priority: .utility) { () -> (DevServer.Candidate, Bool)? in
      let candidates = projects.map { id, name, path in
        DevServer.Candidate(
          id: id, name: name, path: path,
          ports: (try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("package.json")))
            .map(DevServer.ports(packageJSON:)) ?? [])
      }
      let folder = Self.listenerFolder(port: port)
      return DevServer.match(port: port, listenerFolder: folder, projects: candidates).map {
        ($0, folder != nil)
      }
    }.value
    if let (project, byProcess) = found {
      devFact = (address, DevServer.fact(page: origin(address), project: project, byProcess: byProcess))
    } else if devFact.map({ sameOrigin($0.address, address) }) == true {
      devFact = nil
    }
  }
  /// The working folder of the process listening on a local port, from `lsof`.
  nonisolated static func listenerFolder(port: Int) -> String? {
    guard let pids = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]),
      let pid = pids.split(whereSeparator: \.isNewline).first.map(String.init), Int(pid) != nil,
      let cwd = run("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"])
    else { return nil }
    return cwd.split(whereSeparator: \.isNewline).first { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
  }
  nonisolated static func run(_ path: String, _ arguments: [String]) -> String? {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: path)
    child.arguments = arguments
    let out = Pipe()
    child.standardOutput = out
    child.standardError = FileHandle.nullDevice
    do { try child.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(2)
    while child.isRunning && Date() < deadline { usleep(20_000) }
    if child.isRunning {
      child.terminate()
      return nil
    }
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }
  func origin(_ address: String) -> String {
    guard let url = URL(string: address), let scheme = url.scheme, let host = url.host else {
      return address
    }
    return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
  }
  func sameOrigin(_ a: String, _ b: String) -> Bool { origin(a) == origin(b) }
}

/// Runs `body`, or returns nil after `seconds`. Returns on time even when `body` never
/// finishes (for example a page script that never answers); `body` is left to end on its own.
func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @MainActor () async -> T) async -> T? {
  let once = ResumeOnce<T?>()
  return await withCheckedContinuation { continuation in
    once.set(continuation)
    let work = Task { @MainActor in await body() }
    let timer = Task {
      // Cancelled because the work finished: report nothing, the value is on its way.
      do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
      work.cancel()
      once.resume(nil)
    }
    // The work finished first: stop the timer, which would otherwise sleep out its full time.
    Task { @MainActor in
      let value = await work.value
      timer.cancel()
      once.resume(value)
    }
  }
}

/// Resumes a continuation exactly once, from whichever side finishes first.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Never>?
  private var early: T?
  private var done = false
  func set(_ c: CheckedContinuation<T, Never>) {
    lock.lock()
    if done, let value = early {
      lock.unlock()
      c.resume(returning: value)
      return
    }
    continuation = c
    lock.unlock()
  }
  func resume(_ value: T) {
    lock.lock()
    guard !done else {
      lock.unlock()
      return
    }
    done = true
    if let c = continuation {
      continuation = nil
      lock.unlock()
      c.resume(returning: value)
    } else {
      early = value
      lock.unlock()
    }
  }
}
