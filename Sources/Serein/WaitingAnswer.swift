import AppKit
import ApplicationServices
import SereinCore

/// Answers a question an app outside Serein is waiting on, from Serein's card: reads that app's
/// own window through Accessibility (`WaitingPromptReader`), and presses the answer the person chose
/// in the same window. Never on its own: only the person's press on the card answers, and only when
/// the window still asks exactly what the card showed. What it reads stays on the card: it is never
/// sent to a model.
@MainActor enum WaitingAnswer {
  /// Where a prompt was found: the app, its window, the text area or the controls by ref.
  struct Found {
    let prompt: WaitingPrompt
    let app: NSRunningApplication
    let window: AXUIElement
    /// Terminal prompts: the text area that was read, the only place keys may go.
    let textArea: AXUIElement?
    let table: [String: AXUIElement]
  }
  enum Read: Equatable {
    case found(WaitingPrompt)
    /// Serein cannot read other apps' windows until the person turns on Accessibility for it.
    case needsAccessibility
    /// No window reads as a question Serein can answer for this session (or more than one does).
    case unreadable
  }
  enum Outcome: Equatable { case answered, changed, unverified, failed(String) }

  /// Terminals whose screen is read as text. Other apps (editors included, whose buffers could end
  /// in a numbered list) are read only for answer buttons.
  static let terminals: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.cmuxterm.app",
    "dev.warp.Warp-Stable", "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty", "co.zeit.hyper",
  ]
  /// The longest one Accessibility call may take: a hung app can't stall Serein.
  static let messagingTimeout: Float = 0.5

  /// The app holding a session: the first regular app above its process (Terminal, Claude, Cursor…).
  static func app(for session: ExternalSession) -> NSRunningApplication? {
    guard let pid = session.pid else { return nil }
    for ancestor in [pid] + HarnessProcessDiscovery.ancestors(pid) {
      if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular { return app }
    }
    return nil
  }

  static func read(_ session: ExternalSession) -> (Read, Found?) {
    guard MacControl.accessibilityGranted(prompt: false) else { return (.needsAccessibility, nil) }
    guard let app = app(for: session), app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      (try? MacControl.refuseSecrets(app, appName: app.localizedName ?? "")) != nil
    else { return (.unreadable, nil) }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(root, messagingTimeout)
    let terminal = terminals.contains(app.bundleIdentifier ?? "")
    // A terminal can hold several waiting sessions: then only a window titled for this one's folder
    // or title counts. With one waiting session there, its one asking window is this session's.
    let sharing = ExternalSessionStore.shared.sessions.filter {
      $0.state == .needsUser && Self.app(for: $0)?.processIdentifier == app.processIdentifier
    }.count > 1
    let windows = (MacControl.value(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    var found: [Found] = []
    for window in windows.prefix(12) {
      if terminal, sharing, !titled(window, for: session) { continue }
      if let one = prompt(in: window, app: app, terminal: terminal) { found.append(one) }
    }
    guard found.count == 1, let only = found.first else { return (.unreadable, nil) }
    return (.found(only.prompt), only)
  }

  static func titled(_ window: AXUIElement, for session: ExternalSession) -> Bool {
    let title = MacControl.string(window, kAXTitleAttribute) ?? ""
    let folder = session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
    return (!folder.isEmpty && title.contains(folder)) || (!session.title.isEmpty && title.contains(session.title))
  }

  private static func prompt(in window: AXUIElement, app: NSRunningApplication, terminal: Bool) -> Found? {
    if terminal {
      // A terminal shows its prompt as text: its biggest text area, last screenful.
      guard let (area, text) = terminalText(window), let prompt = WaitingPromptReader.terminal(text) else { return nil }
      return Found(prompt: prompt, app: app, window: window, textArea: area, table: [:])
    }
    var rows: [[String: Any]] = []
    var table: [String: AXUIElement] = [:]
    var truncated = false
    MacControl.walk(window, depth: 0, rows: &rows, table: &table, truncated: &truncated)
    let controls = rows.compactMap { row -> WaitingPromptReader.Control? in
      guard let role = row["role"] as? String, let label = row["label"] as? String else { return nil }
      if row["enabled"] as? Bool == false { return nil }
      return WaitingPromptReader.Control(role: "AX" + role, label: label, ref: row["ref"] as? String)
    }
    guard let prompt = WaitingPromptReader.window(controls) else { return nil }
    return Found(prompt: prompt, app: app, window: window, textArea: nil, table: table)
  }

  /// The largest text area in the window and the last part of its text: a terminal's screen.
  private static func terminalText(_ window: AXUIElement) -> (AXUIElement, String)? {
    var best: (AXUIElement, String)?
    func visit(_ element: AXUIElement, depth: Int) {
      guard depth < 8 else { return }
      if MacControl.role(element) == "AXTextArea", !MacControl.isSecure(element),
        let text = MacControl.string(element, kAXValueAttribute), text.count > (best?.1.count ?? 0)
      {
        best = (element, text)
      }
      for child in (MacControl.value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        visit(child, depth: depth + 1)
      }
    }
    visit(window, depth: 0)
    return best.map { ($0.0, String($0.1.suffix(6_000))) }
  }

  /// The prompt in a text area as it reads now.
  private static func reread(_ area: AXUIElement) -> WaitingPrompt? {
    MacControl.string(area, kAXValueAttribute).flatMap { WaitingPromptReader.terminal(String($0.suffix(6_000))) }
  }

  /// Presses `choice` in the app, after reading the window again: if it no longer asks what the card
  /// showed, nothing is pressed and the card shows the new question.
  static func answer(_ choice: WaitingPrompt.Choice, shown: WaitingPrompt, session: ExternalSession) async -> Outcome {
    let (read, found) = read(session)
    guard case .found(let now) = read, let found else {
      return read == .needsAccessibility ? .failed(accessibilityNote) : .changed
    }
    guard now.sameAsked(shown),
      let live = now.choices.first(where: { $0.label == choice.label && $0.index == choice.index && $0.ref == choice.ref })
    else { return .changed }
    switch now.kind {
    case .window:
      guard let ref = live.ref, let element = found.table[ref], !MacControl.isSecure(element),
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
      else { return .failed("\(found.app.localizedName ?? "The app") did not take the press. Open it to answer.") }
    case .terminal:
      if let outcome = await typeAnswer(live, shown: shown, found: found) { return outcome }
    case .transcript:
      return .changed  // A window read never gives one; transcript questions are answered in the app.
    }
    // Answered when the window no longer asks the same thing; unread is not proof either way.
    try? await Task.sleep(nanoseconds: 700_000_000)
    switch WaitingAnswer.read(session) {
    case (.found(let after), _) where after.sameAsked(shown): return .failed("It is still asking. Open it to answer.")
    case (.found, _): return .answered
    default: return .unverified
    }
  }

  /// A terminal answer: the window comes forward, the text area it was read from must have the
  /// keyboard and still ask the same thing, the arrows move the marker, the marker must be seen on
  /// the choice, and only then Return. Any doubt stops before Return. Nil when it was sent.
  private static func typeAnswer(_ live: WaitingPrompt.Choice, shown: WaitingPrompt, found: Found) async -> Outcome? {
    guard let area = found.textArea, let target = live.index else { return .changed }
    let pid = found.app.processIdentifier
    let root = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(root, messagingTimeout)
    func back(_ outcome: Outcome) -> Outcome { NSApp.activate(ignoringOtherApps: true); return outcome }
    found.app.activate()
    AXUIElementPerformAction(found.window, kAXRaiseAction as CFString)
    try? await Task.sleep(nanoseconds: 250_000_000)
    guard let focused = MacControl.value(root, kAXFocusedUIElementAttribute), CFEqual(focused, area) else {
      return back(.failed("Serein could not put the keyboard in that window. Open it to answer."))
    }
    guard let before = reread(area), before.sameAsked(shown) else { return back(.changed) }
    guard let moves = before.moves(to: live) else {
      return back(.failed("Serein can't tell which answer is selected there. Open it to answer."))
    }
    for key in moves {
      MacControl.post(MacKey(code: keyCodes[key] ?? 125), to: pid)
      try? await Task.sleep(nanoseconds: 70_000_000)
    }
    try? await Task.sleep(nanoseconds: 150_000_000)
    guard let moved = reread(area), moved.sameAsked(shown), moved.selected == target,
      let still = MacControl.value(root, kAXFocusedUIElementAttribute), CFEqual(still, area)
    else {
      return back(.failed("The selection didn't land on “\(live.label)”, so Serein didn't confirm. Open it to answer."))
    }
    MacControl.post(MacKey(code: keyCodes["Return"]!), to: pid)
    try? await Task.sleep(nanoseconds: 150_000_000)
    _ = back(.answered)
    return nil
  }

  static let keyCodes: [String: Int] = ["Down": 125, "Up": 126, "Return": 36]
  static let accessibilityNote =
    "Drag Serein into Accessibility to answer here."
}
