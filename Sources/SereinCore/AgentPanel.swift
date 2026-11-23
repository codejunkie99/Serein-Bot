import Foundation

/// "0:09", "12:34", "1:02:03": the running clock on At work rows and the task panel's pill.
public enum TaskClock {
  public static func short(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.isFinite ? seconds : 0))
    let h = s / 3600
    let m = s % 3600 / 60
    let sec = s % 60
    return h > 0
      ? "\(h):\(m < 10 ? "0" : "")\(m):\(sec < 10 ? "0" : "")\(sec)"
      : "\(m):\(sec < 10 ? "0" : "")\(sec)"
  }
}

/// Which runs the sidebar's At work card lists, in what order, and how finished rows fade.
public enum AtWorkList {
  public struct Item: Equatable {
    public var id: String
    public var outcome: RunRecord.Outcome
    public var startedAt: Date
    public var endedAt: Date?
    public init(id: String, outcome: RunRecord.Outcome, startedAt: Date, endedAt: Date? = nil) {
      self.id = id
      self.outcome = outcome
      self.startedAt = startedAt
      self.endedAt = endedAt
    }
  }
  /// A finished run stays this long, then leaves the card.
  public static let linger: TimeInterval = 60
  /// Over the last part of `linger` the row fades out.
  public static let fade: TimeInterval = 10

  /// Needs-you and failed runs wait for the user; they never fade.
  public static func needsUser(_ outcome: RunRecord.Outcome) -> Bool {
    outcome == .waiting || outcome == .stuck
  }
  /// Waiting rows first (oldest wait first), then running (in start order, so rows don't jump),
  /// then recently finished (newest first). Finished rows older than `linger` are dropped.
  public static func rows(_ items: [Item], now: Date) -> [Item] {
    let waiting = items.filter { needsUser($0.outcome) }
      .sorted { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }
    let running = items.filter { $0.outcome == .running }.sorted { $0.startedAt < $1.startedAt }
    let finished = items.filter {
      !needsUser($0.outcome) && $0.outcome != .running
        && now.timeIntervalSince($0.endedAt ?? $0.startedAt) < linger
    }.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
    return waiting + running + finished
  }
  /// 1 while the row should be fully visible, falling to 0 over the last `fade` seconds.
  public static func opacity(_ item: Item, now: Date) -> Double {
    guard !needsUser(item.outcome), item.outcome != .running else { return 1 }
    let age = now.timeIntervalSince(item.endedAt ?? item.startedAt)
    let start = linger - fade
    if age <= start { return 1 }
    return max(0, min(1, 1 - (age - start) / fade))
  }
}

/// The task panel's tab strip: which threads show as tabs, which fold into "N more", and how
/// closing moves the selection. Ids are thread ids (or a task id for a run with no saved thread).
public enum TaskTabStrip {
  /// Up to `capacity` tabs in their order; the selected tab is always shown, taking the last
  /// visible slot when it would otherwise fold away. The rest keep their order in `overflow`.
  public static func layout(_ ids: [String], selected: String?, capacity: Int)
    -> (shown: [String], overflow: [String])
  {
    let capacity = max(1, capacity)
    guard ids.count > capacity else { return (ids, []) }
    var shown = Array(ids.prefix(capacity))
    if let selected, ids.contains(selected), !shown.contains(selected) {
      shown[capacity - 1] = selected
    }
    return (shown, ids.filter { !shown.contains($0) })
  }
  /// How many tabs of `minimum` width fit beside the trailing controls.
  public static func capacity(width: Double, minimum: Double = 72, reserved: Double = 132) -> Int {
    max(1, Int(max(0, width - reserved) / minimum))
  }
  /// Closes a tab without touching its thread. A closed selected tab hands the selection to its
  /// right-hand neighbour, else the left one.
  public static func closing(_ ids: [String], selected: String?, _ id: String)
    -> (ids: [String], selected: String?)
  {
    guard let index = ids.firstIndex(of: id) else { return (ids, selected) }
    var out = ids
    out.remove(at: index)
    guard selected == id else { return (out, selected) }
    if out.isEmpty { return (out, nil) }
    return (out, out[min(index, out.count - 1)])
  }
}

/// A short, readable name under the harness mark on an At work row: "Opus", "Sonnet", "5.1",
/// "o3". Never cut mid-word: a name that does not fit in six characters shows no badge.
public enum ModelBadge {
  public static let maxLength = 6
  public static func short(_ model: String) -> String {
    let lower = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !lower.isEmpty else { return "" }
    for family in ["opus", "sonnet", "haiku", "mini", "nano"] where lower.contains(family) {
      return family.prefix(1).uppercased() + family.dropFirst()
    }
    // gpt-5.1-codex → 5.1; gpt-4o → 4o
    if let range = lower.range(of: "gpt-") {
      let rest = lower[range.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "o" }
      if !rest.isEmpty, rest.count <= maxLength { return String(rest) }
    }
    if lower.contains("codex") { return "Codex" }
    let words = lower.split { !($0.isLetter || $0.isNumber || $0 == ".") }
    if let short = words.first(where: { $0.count <= 3 && $0.first?.isLetter == true && $0.contains(where: \.isNumber) }) {
      return String(short)
    }
    guard let first = words.first, first.count <= maxLength else { return "" }
    return first.first?.isLetter == true ? first.prefix(1).uppercased() + first.dropFirst() : String(first)
  }
}

extension ModelBadge {
  /// "GPT 5.1 Codex", "Claude Sonnet 4.5": a readable model name for the composer's picker.
  /// An empty model shows the provider's default.
  public static func display(_ model: String, provider: String) -> String {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return provider }
    var words = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)
    // claude-sonnet-4-5 → Sonnet 4.5: join a trailing pair of single digits as a version.
    if words.count >= 2, let last = words.last, let prior = words.dropLast().last,
      last.count == 1, prior.count == 1, last.allSatisfy(\.isNumber), prior.allSatisfy(\.isNumber)
    {
      words.removeLast(2)
      words.append(prior + "." + last)
    }
    let shown = words.map { word -> String in
      let lower = word.lowercased()
      if lower == "gpt" { return "GPT" }
      if lower.first?.isNumber == true || lower.count <= 2 { return lower }
      return lower.prefix(1).uppercased() + lower.dropFirst()
    }.joined(separator: " ")
    return shown.count > 28 ? String(shown.prefix(27)) + "…" : shown
  }
}

/// What an agent is doing this second, read from one CLI event or tool call. Paths, commands and
/// queries come from the model (untrusted): they are shortened and only ever shown as plain text.
public struct RunActivity: Equatable {
  /// A short tool key: read, edit, command, test, build, search, web, browser, tool.
  public var tool: String
  /// Present tense for the panel's Now line: "Editing Sources/App.swift".
  public var now: String
  /// Past tense for the step timeline: "Edited Sources/App.swift".
  public var done: String
  /// Browser tools are already recorded by the agent tab board.
  public var browser: Bool
  public init(tool: String, now: String, done: String, browser: Bool = false) {
    self.tool = tool
    self.now = now
    self.done = done
    self.browser = browser
  }
}

public enum RunNow {
  static let browserPrefix = "mcp__serein_browser__"

  public static func claudeTool(_ name: String, input: [String: Any], folder: String?) -> RunActivity? {
    if name.hasPrefix(browserPrefix) {
      let tool = String(name.dropFirst(browserPrefix.count))
      return browserTool(tool, input: input)
    }
    func path() -> String { display(input["file_path"] as? String ?? input["path"] as? String ?? input["notebook_path"] as? String, folder: folder) }
    switch name {
    case "Read":
      let p = path()
      return RunActivity(tool: "read", now: "Reading \(p)", done: "Read \(p)")
    case "Edit", "MultiEdit", "NotebookEdit":
      let p = path()
      return RunActivity(tool: "edit", now: "Editing \(p)", done: "Edited \(p)")
    case "Write":
      let p = path()
      return RunActivity(tool: "edit", now: "Writing \(p)", done: "Wrote \(p)")
    case "Glob", "Grep":
      let q = clip(input["pattern"] as? String ?? "", 32)
      return RunActivity(
        tool: "search", now: q.isEmpty ? "Searching files" : "Searching for “\(q)”",
        done: q.isEmpty ? "Searched files" : "Searched for “\(q)”")
    case "Bash": return command(input["command"] as? String ?? "")
    case "WebFetch":
      let host = (input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a page"
      return RunActivity(tool: "web", now: "Reading \(host)", done: "Read \(host)")
    case "WebSearch":
      let q = clip(input["query"] as? String ?? "", 40)
      return RunActivity(tool: "web", now: "Searching the web for “\(q)”", done: "Searched the web for “\(q)”")
    case "TodoWrite": return RunActivity(tool: "plan", now: "Updating its plan", done: "Updated its plan")
    case "Task", "Agent":
      let what = clip(input["description"] as? String ?? "", 60)
      return RunActivity(tool: "tool", now: what.isEmpty ? "Starting a helper" : "Starting a helper: \(what)",
                         done: what.isEmpty ? "Started a helper" : "Started a helper: \(what)")
    default:
      let n = toolName(name)
      return RunActivity(tool: "tool", now: "Using \(n)", done: "Used \(n)")
    }
  }

  /// A tool's name as a person reads it: `mcp__claude_ai_Notion__notion-search` is “notion-search
  /// in Notion”; any other name is clipped as it is.
  public static func toolName(_ name: String) -> String {
    let parts = name.components(separatedBy: "__")
    guard parts.count >= 3, parts[0] == "mcp" else { return clip(name, 32) }
    var server = parts[1]
    for prefix in ["claude_ai_", "plugin_"] where server.hasPrefix(prefix) { server = String(server.dropFirst(prefix.count)) }
    server = server.replacingOccurrences(of: "_", with: " ")
    let tool = parts.dropFirst(2).joined(separator: "__")
    return clip(tool, 28) + " in " + clip(server, 24)
  }

  /// "Running tests", "Building", or "Running `git status`".
  public static func command(_ raw: String) -> RunActivity {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // `bash -lc 'swift test'` and friends: show the inner command.
    for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc ", "sh -c ", "bash -c "]
    where text.hasPrefix(shell) {
      text = unquoted(String(text.dropFirst(shell.count)).trimmingCharacters(in: .whitespaces))
    }
    let words = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "&" })
      .map(String.init)
    let testers = ["pytest", "jest", "vitest", "xctest"]
    if words.contains("test") || words.contains(where: { testers.contains($0) || $0.hasPrefix("test:") })
      || words.contains("sereinchecks")
    {
      return RunActivity(tool: "test", now: "Running tests", done: "Ran tests")
    }
    if words.contains("build") || words.first == "make" || words.contains("xcodebuild") {
      return RunActivity(tool: "build", now: "Building", done: "Built the project")
    }
    let shown = clip(text.replacingOccurrences(of: "\n", with: " "), 40)
    if shown.isEmpty { return RunActivity(tool: "command", now: "Running a command", done: "Ran a command") }
    return RunActivity(tool: "command", now: "Running `\(shown)`", done: "Ran `\(shown)`")
  }

  /// One shell word's quoting undone, as the shell would read it: `'it'"'"'s'` and `'it'\\''s'`
  /// read it's, `"say \\"hi\\""` reads say "hi", and Codex's `"-g '"'!'"\\\\.git'"` reads
  /// -g '!\\.git'. A word cut short (a clipped label) reads as far as it goes. Text that does not
  /// start with a quote stays as it is.
  static func unquoted(_ word: String) -> String {
    guard let first = word.first, first == "'" || first == "\"" else { return word }
    enum Quote { case none, single, double }
    var out = ""
    var state = Quote.none
    var chars = word.makeIterator()
    while let c = chars.next() {
      switch state {
      case .none:
        if c == "'" { state = .single } else if c == "\"" { state = .double }
        else if c == "\\" { if let next = chars.next() { out.append(next) } }
        else { out.append(c) }
      case .single:
        if c == "'" { state = .none } else { out.append(c) }
      case .double:
        if c == "\"" { state = .none }
        else if c == "\\" {
          guard let next = chars.next() else { out.append(c); break }
          if "\\\"$`".contains(next) { out.append(next) } else { out.append(c); out.append(next) }
        } else { out.append(c) }
      }
    }
    return out
  }

  static func browserTool(_ tool: String, input: [String: Any] = [:]) -> RunActivity {
    let host = (input["url"] as? String).flatMap { URL(string: $0)?.host }
    switch tool {
    case "navigate", "go", "open_tab", "open":
      let h = host ?? "a page"
      return RunActivity(tool: "browser", now: "Going to \(h)", done: "Went to \(h)", browser: true)
    case "read": return RunActivity(tool: "browser", now: "Reading the page", done: "Read the page", browser: true)
    case "find": return RunActivity(tool: "browser", now: "Searching the page", done: "Searched the page", browser: true)
    case "click": return RunActivity(tool: "browser", now: "Clicking on the page", done: "Clicked on the page", browser: true)
    case "fill", "type": return RunActivity(tool: "browser", now: "Typing on the page", done: "Typed on the page", browser: true)
    case "mac_observe": return RunActivity(tool: "browser", now: "Looking at a Mac app", done: "Looked at a Mac app", browser: true)
    case "mac_act": return RunActivity(tool: "browser", now: "Working in a Mac app", done: "Worked in a Mac app", browser: true)
    case "mac_run": return RunActivity(tool: "browser", now: "Running a command on your Mac", done: "Ran a command on your Mac", browser: true)
    // Mail and Messages (Connections): what was asked, never the message.
    case "mail_search": return RunActivity(tool: "browser", now: "Searching Mail", done: "Searched Mail", browser: true)
    case "mail_read": return RunActivity(tool: "browser", now: "Reading an email", done: "Read an email", browser: true)
    case "mail_draft": return RunActivity(tool: "browser", now: "Saving a draft in Mail", done: "Saved a draft in Mail", browser: true)
    case "mail_send", "mail_reply", "messages_send":
      return RunActivity(tool: "browser", now: "Asking you before it sends", done: "Asked you before sending", browser: true)
    case "mail_move", "mail_mark", "mail_delete":
      return RunActivity(tool: "browser", now: "Asking you before it changes an email", done: "Asked you before changing an email", browser: true)
    case "messages_read": return RunActivity(tool: "browser", now: "Reading chosen Messages", done: "Read chosen Messages", browser: true)
    default:
      let done = AgentStep.label(tool: tool, arguments: input)
      return RunActivity(tool: "browser", now: present(done), done: done, browser: true)
    }
  }

  /// The board's past-tense step in present tense, for the Now line.
  public static func present(_ label: String) -> String {
    let swaps = [
      ("Opened a new tab on ", "Opening "), ("Went to ", "Going to "), ("Read part of the page", "Reading part of the page"),
      ("Read the page", "Reading the page"), ("Clicked on the page", "Clicking on the page"),
      ("Typed", "Typing"), ("Picked an option", "Picking an option"),
      ("Pointed at an element", "Pointing at an element"), ("Checked its tabs", "Checking its tabs"),
      ("Scrolled", "Scrolling"), ("Took a picture", "Taking a picture"),
      ("Clicked ", "Clicking "), ("Pressed ", "Pressing "), ("Looked at ", "Looking at "),
      ("Checked the open apps", "Checking the open apps"), ("Worked in ", "Working in "),
    ]
    for (past, now) in swaps where label.hasPrefix(past) {
      return now + label.dropFirst(past.count)
    }
    // The other board labels lead with a past-tense verb ("Looked for files", "Set a reminder").
    let verb = label.prefix { $0 != " " }
    return verbs[String(verb)].map { $0 + label.dropFirst(verb.count) } ?? label
  }
  private static let verbs: [String: String] = [
    "Looked": "Looking", "Searched": "Searching", "Read": "Reading", "Started": "Starting", "Checked": "Checking",
    "Sent": "Sending", "Stopped": "Stopping", "Waited": "Waiting", "Saved": "Saving", "Forgot": "Forgetting",
    "Shared": "Sharing", "Proposed": "Proposing", "Set": "Setting", "Changed": "Changing", "Cancelled": "Cancelling",
    "Updated": "Updating", "Undid": "Undoing", "Showed": "Showing", "Asked": "Asking", "Ran": "Running",
    "Offered": "Offering", "Paused": "Pausing", "Resumed": "Resuming", "Cross-checked": "Cross-checking",
    "Made": "Making", "Handed": "Handing", "Drafted": "Drafting", "Used": "Using", "Opened": "Opening", "Closed": "Closing",
    "Uploaded": "Uploading", "Finished": "Finishing", "Went": "Going", "Planned": "Planning", "Noted": "Noting",
  ]

  /// A path relative to the run's folder, shortened in the middle.
  static func display(_ path: String?, folder: String?) -> String {
    guard var p = path?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else {
      return "a file"
    }
    if let folder, !folder.isEmpty {
      let base = folder.hasSuffix("/") ? folder : folder + "/"
      if p.hasPrefix(base) { p = String(p.dropFirst(base.count)) }
    }
    p = p.replacingOccurrences(of: "\n", with: " ")
    guard p.count > 48 else { return p }
    return String(p.prefix(18)) + "…" + String(p.suffix(29))
  }
  /// One line for a label or a local summary: line breaks become single spaces, the ends are
  /// trimmed, and a longer text is cut so it ends in "…" at `limit` characters.
  public static func clip(_ text: String, _ limit: Int) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    guard flat.count > limit else { return flat }
    return String(flat.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
  }
}

/// What a run may touch, as chips in the task panel's header. Fixed when the run starts.
public enum TaskPermissions {
  public enum Kind: String, CaseIterable { case pages, act, signIns, edits, mac }
  public struct Chip: Equatable, Identifiable {
    public var kind: Kind
    public var on: Bool
    public var label: String
    /// One plain sentence for the chip's popover and VoiceOver.
    public var detail: String
    public var id: String { kind.rawValue }
  }
  public static func chips(
    readsPages: Bool, currentTab: Bool, actions: Bool, signIns: Bool, projectName: String?,
    edits: Bool, mac: Bool
  ) -> [Chip] {
    [
      chip(.pages, on: readsPages, currentTab: currentTab),
      chip(.act, on: actions),
      chip(.signIns, on: signIns),
      chip(.edits, on: edits, projectName: projectName),
      chip(.mac, on: mac),
    ]
  }
  /// One chip. `currentTab` applies to Read pages only; `projectName` to Project edits only.
  /// Project edits without a project is always off.
  public static func chip(_ kind: Kind, on: Bool, currentTab: Bool = false, projectName: String? = nil) -> Chip {
    switch kind {
    case .pages:
      return Chip(
        kind: .pages, on: on, label: "Read pages",
        detail: !on
          ? "This task does not read web pages."
          : currentTab
            ? "Reads the page you shared with it, and nothing else you have open."
            : "Reads only the pages it opens itself.")
    case .act:
      return Chip(
        kind: .act, on: on, label: "Click & type",
        detail: on
          ? "May click, type and submit forms on sites it opens."
          : "Looks only. It can't click or type on sites.")
    case .signIns:
      return Chip(
        kind: .signIns, on: on, label: "Signing in",
        detail: on
          ? "Its tabs start signed out. If you sign in there, it holds for this task only."
          : "Its tabs are isolated: no cookies, no sign-ins.")
    case .edits:
      guard let projectName else {
        return Chip(kind: .edits, on: false, label: "Project edits", detail: "Not working in a project.")
      }
      return Chip(
        kind: .edits, on: on, label: "Project edits",
        detail: on
          ? "May edit files in \(projectName). Each turn can be undone."
          : "Reads \(projectName). Edits wait for your approval.")
    case .mac:
      return Chip(
        kind: .mac, on: on, label: "Mac actions",
        detail: on
          ? "May use Mac apps. Scripts are shown to you before they run."
          : "No Mac apps or scripts.")
    }
  }
}
