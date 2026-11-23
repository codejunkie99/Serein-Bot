import Foundation

// MARK: - Install, sign-in and update commands

/// One command Serein shows in full and runs in its embedded terminal only after a click. It is
/// always the tool's own official command; Serein never types, stores or reads a credential.
public struct HarnessCommand: Equatable, Sendable {
  public enum Kind: String, Sendable { case install, signIn, update, resume }
  public var driver: HarnessDriver
  public var kind: Kind
  /// Arguments after the harness executable (sign-in, update). Empty for install commands, which
  /// run `shell` through a login shell because the harness is not there yet.
  public var arguments: [String]
  /// The exact text shown before it runs.
  public var display: String
  /// Install commands go through `/bin/zsh -lc`; the others run the executable directly.
  public var usesShell: Bool
  /// A tool that must already exist for an install command (npm, curl).
  public var requires: String?
  /// The folder it runs in; nil is the home folder. A resumed session runs where it ran before.
  public var folder: String? = nil
}

/// What the PTY actually starts: an absolute path, its argv after the path, and extra environment.
public struct PTYLaunch: Equatable, Sendable {
  public var path: String
  public var arguments: [String]
  public var environment: [String: String]
}

public enum HarnessCommands {
  /// Apps whose sign-in happens in their own terminal (no page opens): the person answers its
  /// questions there, so that terminal must be on screen while it runs.
  public static func signsInInTerminal(_ d: HarnessDriver, version: String? = nil) -> Bool {
    // OpenCode 2's `auth login` asks which provider in the terminal first.
    [.pi, .ohMyPi, .gemini].contains(d) || (d == .opencode && OpenCodeAPI(version: version) == .v2)
  }
  /// A fresh native terminal. Never resumes an isolated Serein session in a broader setup.
  public static func interactive(_ driver: HarnessDriver, folder: String? = nil) -> HarnessCommand {
    HarnessCommand(driver: driver, kind: .resume, arguments: driver.quietArguments,
      display: ([driver.binaries[0]] + driver.quietArguments).joined(separator: " "),
      usesShell: false, requires: nil, folder: folder)
  }

  /// The sign-in command from each CLI's own `--help` (checked on a development Mac). Pi and Oh
  /// My Pi sign in from their interactive start (`/login`), and Gemini CLI from its first
  /// interactive start. `version` is the CLI's probed version.
  public static func signIn(_ d: HarnessDriver, version: String? = nil) -> HarnessCommand {
    let args: [String]
    switch d {
    case .claude: args = ["auth", "login"]
    case .codex: args = ["login"]
    case .cursor: args = ["login"]
    // The word after `auth login` is a provider URL, so `auth login opencode` fails
    // ("fetch() URL is invalid"). Go has no API key: `console login` opens a page and a code.
    // OpenCode 2 dropped `console login`; its `auth login` connects any provider.
    case .opencode: args = OpenCodeAPI(version: version) == .v2 ? ["auth", "login"] : ["console", "login"]
    case .pi, .ohMyPi: args = []
    case .grok: args = ["login"]
    case .gemini: args = []
    }
    // The display is exactly what runs, including the no-update switches, so the Terminal
    // fallback behaves the same.
    let env = d.quietEnvironment.keys.sorted().map { "\($0)=\(d.quietEnvironment[$0] ?? "")" }
    let display = (env + [d.binaries[0]] + d.quietArguments + args).joined(separator: " ")
    return HarnessCommand(
      driver: d, kind: .signIn, arguments: args, display: display, usesShell: false, requires: nil)
  }

  /// Pi installed from @mariozechner/pi-coding-agent, the package it left: that one gets no new
  /// releases, so this copy is due an update whatever version it reports. `real` is the CLI's
  /// real file.
  public static func piOldPackage(_ real: String?) -> Bool {
    real?.contains("/@mariozechner/pi-coding-agent/") == true
  }

  /// The tool's own update command; each knows how it was installed (Homebrew, npm, its own
  /// installer). `installedAt` is the CLI's real file: Pi from the old @mariozechner package
  /// cannot update itself into the new one, so npm swaps the package. Gemini CLI has no update
  /// command: Homebrew upgrades a copy in its Cellar, npm the rest.
  public static func update(_ d: HarnessDriver, installedAt real: String? = nil) -> HarnessCommand {
    switch d {
    case .gemini where real?.contains("/Cellar/gemini-cli/") == true:
      return HarnessCommand(
        driver: d, kind: .update, arguments: [], display: "brew upgrade gemini-cli", usesShell: true, requires: "brew")
    case .gemini:
      return HarnessCommand(
        driver: d, kind: .update, arguments: [], display: d.updateCommand, usesShell: true, requires: "npm")
    case .pi where piOldPackage(real):
      return HarnessCommand(
        driver: d, kind: .update, arguments: [],
        display: "npm uninstall -g @mariozechner/pi-coding-agent && npm install -g @earendil-works/pi-coding-agent@latest",
        usesShell: true, requires: "npm")
    default:
      let parts = d.updateCommand.split(separator: " ").map(String.init)
      return HarnessCommand(
        driver: d, kind: .update, arguments: Array(parts.dropFirst()), display: d.updateCommand,
        usesShell: false, requires: nil)
    }
  }

  /// Opens a past session in the harness's own CLI, in the folder it ran in. Session ids and
  /// files come from other apps' stores, so they are checked first: an id that could read as a
  /// flag, or a file outside a session folder, gives nil.
  public static func resume(_ d: HarnessDriver, id: String, file: String?, folder: String) -> HarnessCommand? {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
    guard !id.isEmpty, id.count <= 200, !id.hasPrefix("-"), id.unicodeScalars.allSatisfy(allowed.contains) else {
      return nil
    }
    let args: [String]
    switch d {
    case .claude, .grok, .cursor: args = ["--resume", id]
    case .codex: args = ["resume", id]
    case .opencode: args = ["--session", id]
    case .pi, .ohMyPi:
      guard let file, file.hasPrefix("/"), file.hasSuffix(".jsonl"), file.contains("/sessions/") else { return nil }
      args = ["--session", file]
    // Serein lists no Gemini CLI sessions (it does not read its store).
    case .gemini: return nil
    }
    let display = ([d.binaries[0]] + args).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    return HarnessCommand(
      driver: d, kind: .resume, arguments: args, display: display, usesShell: false, requires: nil,
      folder: folder.hasPrefix("/") ? folder : nil)
  }

  /// A copy of a chat that its own CLI answers can be made: Pi and Oh My Pi by copying the session
  /// file (`LinkedHistory.piFork`), Grok and OpenCode by their fork flag. Cursor has none.
  public static func copies(_ d: HarnessDriver) -> Bool { [.pi, .ohMyPi, .grok, .opencode].contains(d) }
  /// How many pictures one message may carry through the CLI: Pi takes `@file`, OpenCode `-f`;
  /// the others take none.
  public static func pictures(_ d: HarnessDriver) -> Int {
    switch d {
    case .pi, .ohMyPi, .opencode: return 10
    default: return 0
    }
  }

  /// One message on an existing chat, sent as the harness's own CLI would send it typed there,
  /// with no window: the CLI writes the turn to its own store. `stdin` carries the message when
  /// the CLI reads it there. Nil for Claude Code and Codex (Serein runs those itself), Gemini CLI
  /// (no linked chats: Serein does not read its store), and an id, file or picture Serein cannot
  /// pass safely, or more pictures than `pictures(d)`.
  /// `model`: another model than the chat's own, chosen in Serein; dropped when unsafe to pass.
  /// `fork`: the message goes on in a copy (`copies(d)`, not Pi, whose copy is a file); Grok's
  /// copy takes this id.
  public static func reply(
    _ d: HarnessDriver, id: String, file: String?, prompt: String, model: String? = nil, pictures files: [String] = [],
    fork: String? = nil
  ) -> (arguments: [String], stdin: String?)? {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
    func safe(_ value: String) -> Bool {
      !value.isEmpty && value.count <= 200 && !value.hasPrefix("-") && value.unicodeScalars.allSatisfy(allowed.contains)
    }
    guard safe(id), fork.map({ $0.isEmpty || safe($0) }) ?? true, files.count <= pictures(d),
      files.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\n") })
    else { return nil }
    // A message that starts with "-" would read as a flag, and for Pi one that starts with "@" as
    // a file to attach.
    let text = prompt.hasPrefix("-") || ([.pi, .ohMyPi].contains(d) && prompt.hasPrefix("@")) ? " " + prompt : prompt
    let named = model.flatMap { m in
      !m.isEmpty && m.count <= 200 && !m.hasPrefix("-")
        && m.unicodeScalars.allSatisfy(allowed.union(CharacterSet(charactersIn: "/@+")).contains) ? m : nil
    }
    switch d {
    case .pi, .ohMyPi:
      guard fork == nil, let file, file.hasPrefix("/"), file.hasSuffix(".jsonl") else { return nil }
      return (["-p", "--session", file] + (named.map { ["--model", $0] } ?? []) + files.map { "@" + $0 } + [text], nil)
    case .grok:
      let copy = fork.map { $0.isEmpty ? ["--fork-session"] : ["--fork-session", "--session-id", $0] } ?? []
      return (["-p", text, "--resume", id] + copy + (named.map { ["-m", $0] } ?? []), nil)
    case .opencode:
      // -f takes several values, so it comes after the message.
      return (["run", "--session", id] + (fork == nil ? [] : ["--fork"]) + (named.map { ["-m", $0] } ?? []) + [text]
        + files.flatMap { ["-f", $0] }, nil)
    case .cursor:
      guard fork == nil else { return nil }
      return (["--resume", id] + (named.map { ["--model", $0] } ?? []) + ["-p", text], nil)
    case .claude, .codex, .gemini: return nil
    }
  }

  /// The published install command (npm or the vendor's install script).
  public static func install(_ d: HarnessDriver, hasTool: (String) -> Bool = { _ in true }) -> HarnessCommand? {
    let options = AgentSetup.installOptions(provider: d.setupKey, hasTool: hasTool)
    guard let first = options.first else { return nil }
    return HarnessCommand(
      driver: d, kind: .install, arguments: [], display: first.shell, usesShell: true, requires: first.requires)
  }

  /// What the embedded terminal starts for `command`. `executable` is the harness's resolved path
  /// (sign-in and update); install and npm updates run through the login shell so its PATH applies.
  public static func launch(_ c: HarnessCommand, executable: String?, loginShell: String = "/bin/zsh")
    -> PTYLaunch?
  {
    var env = c.driver.quietEnvironment
    if c.kind == .update {
      // An update is what the user asked for; only the no-telemetry style switches stay.
      env = [:]
    }
    env["TERM"] = "xterm-256color"
    if c.usesShell {
      let shell = loginShell.hasPrefix("/") ? loginShell : "/bin/zsh"
      return PTYLaunch(path: shell, arguments: ["-lc", c.display], environment: env)
    }
    guard let executable, executable.hasPrefix("/") else { return nil }
    let quiet = c.kind == .signIn ? c.driver.quietArguments : []
    return PTYLaunch(path: executable, arguments: quiet + c.arguments, environment: env)
  }
}

extension HarnessDriver {
  /// The key AgentSetup knows this driver by ("claude", "codex", then raw values).
  public var setupKey: String {
    switch self {
    case .claude: return "claude"
    case .codex: return "codex"
    default: return rawValue
    }
  }
}

// MARK: - One primary action per harness

/// The single action a setup row or Settings card offers.
public enum HarnessPrimaryAction: String, Equatable, Sendable {
  case checking, install, signIn, update, ready
  public var label: String {
    switch self {
    case .checking: return "Checking…"
    case .install: return "Install"
    case .signIn: return "Sign in"
    case .update: return "Update"
    case .ready: return "Ready"
    }
  }
  /// The step in a connect menu's row: nil until the app is checked, and “Connect” for an app
  /// that needs no install, sign-in or update (one that is turned off).
  public var menuWords: String? {
    switch self {
    case .checking: return nil
    case .ready: return "Connect"
    case .install, .signIn, .update: return label
    }
  }
  /// While a sign-in job runs, Serein checks the app again this often, for `signInRecheckLimit`
  /// at most (`HarnessActions.run`): Gemini CLI, Pi and Oh My Pi sign in from their interactive
  /// start, which never exits on its own.
  public static let signInRecheckEvery: TimeInterval = 5
  public static let signInRecheckLimit: TimeInterval = 300
  /// A running sign-in is done: the app can answer now and could not when the job began. One that
  /// could already (a second OpenCode account) runs to its own end.
  public static func signedInWhileRunning(before: HarnessPrimaryAction, now: HarnessPrimaryAction) -> Bool {
    let answers: Set<HarnessPrimaryAction> = [.ready, .update]
    return !answers.contains(before) && answers.contains(now)
  }
  public static func of(_ s: HarnessSnapshot?) -> HarnessPrimaryAction {
    guard let s, s.checkedAt != nil else { return .checking }
    if !s.installed { return .install }
    if s.signedIn == false { return .signIn }
    // Too old for Serein: every request is refused, so Update is the one action even when no
    // newer release has been seen.
    if s.needsUpdate || s.tooOld { return .update }
    // The probe could not confirm a sign-in: the app's own sign-in shows why, then re-probes.
    if s.signInProblem != nil { return .signIn }
    return .ready
  }
}

// MARK: - Terminal text

/// A small terminal screen for the embedded sign-in pane: enough of VT100 to show line-based
/// CLIs and redrawn menus (carriage return, backspace, cursor moves, erase in line and display).
/// Colours and other attributes are dropped. Output is untrusted and only displayed.
public struct TerminalScreen: Sendable {
  public private(set) var lines: [[Character]] = [[]]
  private var row = 0
  private var col = 0
  private var pending: [UInt8] = []
  public static let maxLines = 2000
  public let width: Int
  public init(width: Int = 100) { self.width = max(20, width) }

  public var text: String { lines.map { String($0) }.joined(separator: "\n") }

  public mutating func feed(_ data: Data) { feed(Array(data)) }
  public mutating func feed(_ bytes: [UInt8]) {
    var input = pending + bytes
    pending = []
    // Keep an incomplete trailing UTF-8 sequence or escape for the next chunk.
    if let cut = Self.incompleteTail(input) {
      pending = Array(input[cut...])
      input = Array(input[..<cut])
    }
    let scalars = Array(String(decoding: input, as: UTF8.self).unicodeScalars)
    var i = 0
    while i < scalars.count {
      let c = scalars[i]
      switch c.value {
      case 0x1B:
        i = escape(scalars, from: i)
        continue
      case 0x0D: col = 0
      case 0x0A:
        // The tty turns LF into CR LF on output (ONLCR); do the same for raw text.
        newline()
        col = 0
      case 0x08: col = max(0, col - 1)
      case 0x09: col = min(width - 1, (col / 8 + 1) * 8)
      case 0x07, 0x00..<0x07, 0x0B, 0x0C, 0x0E..<0x1B, 0x1C..<0x20, 0x7F: break
      default: put(Character(c))
      }
      i += 1
    }
  }

  /// Index where an unfinished UTF-8 sequence or escape sequence starts, if the data ends in one.
  static func incompleteTail(_ b: [UInt8]) -> Int? {
    guard !b.isEmpty else { return nil }
    // An escape in the last 64 bytes without its final byte.
    if let esc = b.lastIndex(of: 0x1B), b.count - esc < 64 {
      let rest = b[(esc + 1)...]
      if rest.isEmpty { return esc }
      if rest.first == UInt8(ascii: "[") {
        if !rest.dropFirst().contains(where: { (0x40...0x7E).contains($0) }) { return esc }
      } else if rest.first == UInt8(ascii: "]") {
        if !rest.contains(0x07) && !(rest.contains(0x1B)) { return esc }
      }
    }
    var i = b.count - 1
    var back = 0
    while i >= 0, back < 4, b[i] & 0xC0 == 0x80 {
      i -= 1
      back += 1
    }
    guard i >= 0 else { return nil }
    let lead = b[i]
    let need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
    return need > back + 1 ? i : nil
  }

  private mutating func ensureRow() {
    while lines.count <= row { lines.append([]) }
  }
  private mutating func put(_ ch: Character) {
    ensureRow()
    if col >= width { newline(); col = 0 }
    var line = lines[row]
    while line.count < col { line.append(" ") }
    if col < line.count { line[col] = ch } else { line.append(ch) }
    lines[row] = line
    col += 1
  }
  private mutating func newline() {
    row += 1
    ensureRow()
    if lines.count > Self.maxLines {
      let drop = lines.count - Self.maxLines
      lines.removeFirst(drop)
      row -= drop
    }
  }
  /// Handles one escape sequence starting at `i`; returns the index after it.
  private mutating func escape(_ s: [Unicode.Scalar], from i: Int) -> Int {
    guard i + 1 < s.count else { return s.count }
    let kind = s[i + 1]
    if kind == "[" {
      var j = i + 2
      var params = ""
      while j < s.count, !(0x40...0x7E).contains(s[j].value) {
        params.unicodeScalars.append(s[j])
        j += 1
      }
      guard j < s.count else { return s.count }
      csi(String(s[j]), params)
      return j + 1
    }
    if kind == "]" {
      // OSC: up to BEL or ESC \.
      var j = i + 2
      while j < s.count {
        if s[j].value == 0x07 { return j + 1 }
        if s[j].value == 0x1B, j + 1 < s.count, s[j + 1] == "\\" { return j + 2 }
        j += 1
      }
      return s.count
    }
    // Two- or three-byte escapes (charset selection, keypad modes): skip.
    if kind == "(" || kind == ")" { return min(s.count, i + 3) }
    return i + 2
  }
  private mutating func csi(_ final: String, _ raw: String) {
    let params = raw.trimmingCharacters(in: CharacterSet(charactersIn: "?>=")).split(separator: ";").map { Int($0) ?? 0 }
    let n = max(1, params.first ?? 1)
    ensureRow()
    switch final {
    case "A": row = max(0, row - n)
    case "B": row += n; ensureRow()
    case "C": col = min(width - 1, col + n)
    case "D": col = max(0, col - n)
    case "G": col = min(width - 1, max(0, n - 1))
    case "E": row += n; col = 0; ensureRow()
    case "F": row = max(0, row - n); col = 0
    case "K":
      let mode = params.first ?? 0
      var line = lines[row]
      if mode == 0 { if col < line.count { line.removeSubrange(col...) } }
      else if mode == 1 { for k in 0..<min(col + 1, line.count) { line[k] = " " } }
      else { line = [] }
      lines[row] = line
    case "J":
      let mode = params.first ?? 0
      if mode == 2 || mode == 3 {
        lines = [[]]
        row = 0
        col = 0
      } else if mode == 0 {
        if col < lines[row].count { lines[row].removeSubrange(col...) }
        if row + 1 < lines.count { lines.removeSubrange((row + 1)...) }
      }
    case "H", "f":
      // Absolute positions count from the top of the last 24 rows (a typical window).
      let top = max(0, lines.count - 24)
      row = top + max(0, (params.first ?? 1) - 1)
      col = min(width - 1, max(0, (params.count > 1 ? params[1] : 1) - 1))
      ensureRow()
    default: break
    }
  }

  /// https links in the text, newest last (for "Open sign-in page").
  public static func links(_ text: String) -> [URL] {
    guard let re = try? NSRegularExpression(pattern: #"https://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
      var s = ns.substring(with: $0.range)
      while let last = s.last, ".,;:)]'".contains(last) { s.removeLast() }
      return URL(string: s)
    }
  }
}

// MARK: - Keys

/// Bytes a key press sends to a terminal program.
public enum TerminalKeys {
  public enum Key: Sendable { case up, down, right, left, enter, tab, backspace, escape, delete, home, end }
  public static func bytes(_ key: Key) -> [UInt8] {
    switch key {
    case .up: return [0x1B, 0x5B, 0x41]
    case .down: return [0x1B, 0x5B, 0x42]
    case .right: return [0x1B, 0x5B, 0x43]
    case .left: return [0x1B, 0x5B, 0x44]
    case .enter: return [0x0D]
    case .tab: return [0x09]
    case .backspace: return [0x7F]
    case .escape: return [0x1B]
    case .delete: return [0x1B, 0x5B, 0x33, 0x7E]
    case .home: return [0x1B, 0x5B, 0x48]
    case .end: return [0x1B, 0x5B, 0x46]
    }
  }
}

extension HarnessCommand {
  /// The same command as a Terminal.app script (the "Open in Terminal" fallback).
  public var setupCommand: SetupCommand {
    SetupCommand(
      provider: driver.setupKey, kind: kind == .install ? .install : .signIn, label: display, shell: display,
      requires: requires)
  }
}
