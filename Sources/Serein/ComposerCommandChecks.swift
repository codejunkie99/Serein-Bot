#if DEBUG
import AppKit
import SereinCore

@MainActor func checkComposerCommands() async throws {
  guard let path = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"],
    FixtureApprovals.isAllowed(root: URL(fileURLWithPath: path)) else {
    throw SereinError.invalid("Command checks require a marked synthetic temporary library")
  }
  let browser = try BrowserModel(root: URL(fileURLWithPath: path))
  defer { browser.shutdown() }
  let agent = AgentModel(browser: browser, discoverProviders: false)
  let commands = ComposerCommands.shared
  var count = 0
  func check(_ yes: Bool, _ message: String) throws {
    guard yes else { throw SereinError.invalid("Slash commands: " + message) }; count += 1
  }
  func show(_ text: String, owner: String = "test") {
    agent.draft = text
    commands.update(agent: agent, browser: browser, owner: owner, focused: true,
      selection: NSRange(location: (text as NSString).length, length: 0))
  }
  func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
  }
  show("/")
  try check(ComposerDropdown.shared.open?.kind == .commands && commands.rows.contains { $0.name == "codex:mcp" }, "opens for selected harness")
  _ = commands.key(key(125), owner: "test")
  try check(commands.highlighted == 1, "Down selects next row")
  _ = commands.key(key(126), owner: "test")
  try check(commands.highlighted == 0, "Up selects previous row")
  try check(!commands.key(key(36, modifiers: .shift), owner: "test"), "Shift Return stays a newline")
  try check(!commands.key(key(125), owner: "other"), "another composer cannot drive this menu")
  show("/mo")
  _ = commands.key(key(48), owner: "test")
  try check(agent.draft == "/model " && ComposerDropdown.shared.open == nil, "Tab completes without executing")
  show("/plan")
  _ = commands.key(key(53), owner: "test")
  commands.update(agent: agent, browser: browser, owner: "test", focused: true, selection: NSRange(location: 5, length: 0))
  try check(ComposerDropdown.shared.open == nil && agent.draft == "/plan", "Escape preserves draft and stays closed")
  show("/a")
  try check(commands.rows.map(\.name) == ["agents"], "prefix narrows after dismissal")
  show("/plan")
  try check(ComposerDropdown.shared.open?.kind == .commands && commands.rows.map(\.name) == ["plan"], "editing back to a dismissed query reopens the menu")
  show("/plan on")
  try check(commands.submit(agent: agent, browser: browser, owner: "test") && ComposerContext.shared.planMode && agent.draft.isEmpty, "plan on executes locally")
  agent.draft = "/plan surprise"
  _ = commands.submit(agent: agent, browser: browser, owner: "test")
  try check(agent.draft == "/plan surprise" && agent.error != nil, "bad arguments keep draft")
  agent.draft = "/unknown"
  let before = agent.hub.runs.count
  _ = commands.submit(agent: agent, browser: browser, owner: "test")
  try check(agent.hub.runs.count == before && agent.draft == "/unknown", "unknown commands never reach a provider")
  agent.draft = "//compact"
  try check(!commands.submit(agent: agent, browser: browser, owner: "test"), "literal escape bypasses command dispatcher")
  agent.draft = "/mcp"
  _ = commands.submit(agent: agent, browser: browser, owner: "test")
  try check(browser.showSettings && browser.requestedSettingsSection == "MCP connection", "MCP opens exact settings category")
  browser.showSettings = false
  for provider in Provider.allCases {
    agent.provider = provider; show("/")
    try check(commands.rows.filter { $0.driver != nil }.allSatisfy { $0.driver == provider.driver }, "catalog changes with " + provider.rawValue)
  }
  agent.provider = .codex; show("/compact")
  agent.provider = .claude
  commands.choose()
  try check(agent.draft == "/compact" && ComposerDropdown.shared.open == nil, "stale harness choice is ignored")
  show("/model")
  _ = commands.key(key(36), owner: "test")
  try check(ComposerDropdown.shared.open?.kind == .modelAndTraits && agent.draft.isEmpty, "Return opens model picker")
  agent.draft = "/new"
  let previous = agent.conversationID
  _ = commands.submit(agent: agent, browser: browser, owner: "test")
  try check(agent.conversationID != previous && agent.provider == agent.taskDefault.provider && !ComposerContext.shared.planMode, "new chat starts on the task default and resets plan")
  let editor = ComposerTextView(frame: .zero)
  var intercepted = false, sent = false
  editor.onCommandKey = { _ in intercepted = true; return true }
  editor.onReturn = { _ in sent = true }
  editor.keyDown(with: key(36))
  try check(intercepted && !sent, "native text view command handler precedes send")
  try check(agent.hub.runs.count == before && agent.flow.queue.items.isEmpty, "command tests use no provider or queue")
  print("PASS: \(count) composer command checks (synthetic, no provider usage)")
}
#endif
