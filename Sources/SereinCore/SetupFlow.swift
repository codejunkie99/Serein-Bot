import Foundation

// MARK: First-run steps

public enum SetupStep: String, CaseIterable, Codable, Identifiable {
  case welcome, agent, macAccess, relay, importData, signIns, talking
  /// Retired with the browser. Kept so saved progress that names it still decodes (a progress
  /// that failed to decode would ask everyone to run setup again); never one of `allCases`.
  case defaultBrowser
  public static let allCases: [SetupStep] = [.welcome, .agent, .macAccess, .relay, .importData, .signIns, .talking]
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .welcome: return "Welcome"
    case .agent: return "Connect an AI app"
    case .macAccess: return "Let Serein use your Mac apps"
    case .relay: return "Meet Serein"
    case .importData: return "Bookmarks and history"
    case .signIns: return "Stay signed in"
    case .defaultBrowser: return "Default browser"
    case .talking: return "Talking"
    }
  }
  /// Every step except the welcome page can be skipped.
  public var skippable: Bool { self != .welcome }
}

/// Which steps are done or skipped, and the one the user is on. Persisted as JSON so closing the
/// window part-way resumes in place.
public struct SetupProgress: Codable, Equatable {
  public var current: SetupStep = .welcome
  public var done: Set<SetupStep> = []
  public var skipped: Set<SetupStep> = []
  public var finished = false
  public init() {}

  public static let defaultsKey = "serein.setup.progress"
  /// Written by the older import-only onboarding. Treated as "already set up".
  public static let legacyImportKey = "serein.browserImportOnboardingComplete"

  public var index: Int { SetupStep.allCases.firstIndex(of: current) ?? 0 }
  public var isLast: Bool { current == SetupStep.allCases.last }

  public mutating func complete() { advance(done: true) }
  public mutating func skip() { advance(done: false) }
  public mutating func back() {
    let all = SetupStep.allCases
    if let i = all.firstIndex(of: current), i > 0 { current = all[i - 1] }
  }
  private mutating func advance(done isDone: Bool) {
    if isDone { done.insert(current) } else { skipped.insert(current) }
    let all = SetupStep.allCases
    if let i = all.firstIndex(of: current), i + 1 < all.count {
      current = all[i + 1]
    } else {
      finished = true
    }
  }

  public static func load(_ defaults: UserDefaults = .standard) -> SetupProgress {
    guard let data = defaults.data(forKey: defaultsKey),
      var value = try? JSONDecoder().decode(SetupProgress.self, from: data)
    else { return SetupProgress() }
    // Parked on the retired step: go on to the one that followed it.
    if value.current == .defaultBrowser { value.current = .talking }
    return value
  }
  public func save(_ defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
  }
  /// First run shows the flow until it is finished, unless the older import flow was already completed.
  public static func needsFirstRun(_ defaults: UserDefaults = .standard) -> Bool {
    if defaults.bool(forKey: legacyImportKey) { return false }
    return !load(defaults).finished
  }
  /// "Run setup again": a fresh pass from the welcome page.
  public static func restart(_ defaults: UserDefaults = .standard) {
    SetupProgress().save(defaults)
    defaults.removeObject(forKey: automaticKey)
  }
  /// Set when the automatic part ended in this pass of setup: the tour then leaves its steps
  /// out also after Serein opens again.
  public static let automaticKey = "serein.setup.automatic"
}

// MARK: Agent install and sign-in commands

/// A command Serein shows in full and runs in Terminal only after a click.
public struct SetupCommand: Equatable, Identifiable {
  public enum Kind: Equatable { case install, signIn }
  public var id: String { provider + "." + label }
  public var provider: String  // "claude" or "codex"
  public var kind: Kind
  public var label: String
  public var shell: String
  public var requires: String?  // a tool that must already exist, such as npm or brew
}

public enum AgentSetup {
  public static func commands(provider: String) -> [SetupCommand] {
    switch provider {
    case "claude":
      return [
        SetupCommand(
          provider: "claude", kind: .install, label: "Install Claude Code",
          shell: "curl -fsSL https://claude.ai/install.sh | bash", requires: "curl"),
        SetupCommand(
          provider: "claude", kind: .signIn, label: "Sign in to Claude Code", shell: "claude auth login",
          requires: nil),
      ]
    case "codex":
      return [
        SetupCommand(
          provider: "codex", kind: .install, label: "Install Codex with npm",
          shell: "npm install -g @openai/codex", requires: "npm"),
        SetupCommand(
          provider: "codex", kind: .install, label: "Install Codex with Homebrew",
          shell: "brew install --cask codex", requires: "brew"),
        SetupCommand(
          provider: "codex", kind: .signIn, label: "Sign in to Codex", shell: "codex login",
          requires: nil),
      ]
    default:
      // Other harnesses: their published install command and their own sign-in command.
      guard let driver = HarnessDriver(rawValue: provider) else { return [] }
      let name = driver.displayName
      var out: [SetupCommand] = []
      switch driver {
      case .cursor:
        out.append(SetupCommand(provider: provider, kind: .install, label: "Install \(name)", shell: "curl https://cursor.com/install -fsS | bash", requires: "curl"))
      case .opencode:
        out.append(SetupCommand(provider: provider, kind: .install, label: "Install \(name) with npm", shell: "npm install -g opencode-ai", requires: "npm"))
        out.append(SetupCommand(provider: provider, kind: .install, label: "Install \(name) with Homebrew", shell: "brew install sst/tap/opencode", requires: "brew"))
      case .pi:
        out.append(SetupCommand(provider: provider, kind: .install, label: "Install \(name) with npm", shell: "npm install -g @earendil-works/pi-coding-agent", requires: "npm"))
      case .ohMyPi:
        out.append(SetupCommand(provider: provider, kind: .install, label: "Install \(name) with npm", shell: "npm install -g @oh-my-pi/pi-coding-agent", requires: "npm"))
      case .grok:
        out.append(SetupCommand(provider: provider, kind: .install, label: "Install \(name) with npm", shell: "npm install -g @xai-official/grok", requires: "npm"))
      case .gemini:
        out.append(SetupCommand(provider: provider, kind: .install, label: "Install \(name) with npm", shell: "npm install -g @google/gemini-cli", requires: "npm"))
        out.append(SetupCommand(provider: provider, kind: .install, label: "Install \(name) with Homebrew", shell: "brew install gemini-cli", requires: "brew"))
      case .claude, .codex: break
      }
      if let signIn = driver.signInCommand {
        out.append(SetupCommand(provider: provider, kind: .signIn, label: "Sign in to \(name)", shell: signIn, requires: nil))
      }
      return out
    }
  }

  /// The install options whose tool exists, falling back to all of them so the command is still visible.
  public static func installOptions(provider: String, hasTool: (String) -> Bool) -> [SetupCommand] {
    let all = commands(provider: provider).filter { $0.kind == .install }
    let usable = all.filter { $0.requires.map(hasTool) ?? true }
    return usable.isEmpty ? all : usable
  }

  /// The tools an install needs when none of its options can run on this Mac (npm and Homebrew
  /// for Codex on a new Mac); empty when one can. Running one anyway only fails in the terminal.
  public static func missingInstallTools(provider: String, hasTool: (String) -> Bool) -> [String] {
    let all = commands(provider: provider).filter { $0.kind == .install }
    guard !all.contains(where: { $0.requires.map(hasTool) ?? true }) else { return [] }
    return all.compactMap(\.requires).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
  }

  /// “npm or Homebrew”: install tools by the names people know them by.
  public static func toolList(_ tools: [String]) -> String {
    let names = tools.map { $0 == "brew" ? "Homebrew" : $0 }
    guard let last = names.last else { return "" }
    return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " or " + last
  }

  /// “Codex installs with npm or Homebrew, and this Mac has neither.”
  public static func missingToolsLine(name: String, tools: [String]) -> String {
    switch tools.count {
    case 0: return "\(name) did not install."
    case 1: return "\(name) installs with \(toolList(tools)), which this Mac does not have."
    case 2: return "\(name) installs with \(toolList(tools)), and this Mac has neither."
    default: return "\(name) installs with \(toolList(tools)), and this Mac has none of them."
    }
  }

  /// The `.command` file Terminal opens. It holds the one visible command and nothing else that runs.
  public static func script(for command: SetupCommand) -> String {
    """
    #!/bin/zsh -l
    clear
    echo "Serein is running this command for you:"
    echo
    echo "  \(command.shell)"
    echo
    \(command.shell)
    echo
    echo "Finished. Go back to Serein and choose Check again."
    """
  }

  /// What the user can still do with no agent connected.
  public static let withoutAgent =
    "Browsing, tabs, history, saved pages, passwords, imports and search all work without an agent. Tasks, Ask, page questions and summaries need a coding agent on this Mac."
}

// MARK: Version comparison

public struct AppVersion: Comparable, Equatable, CustomStringConvertible {
  public var parts: [Int]
  public var prerelease: String?
  public init?(_ text: String) {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
    if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
    var pre: String?
    if let dash = s.firstIndex(of: "-") {
      pre = String(s[s.index(after: dash)...])
      s = String(s[..<dash])
    }
    let pieces = s.split(separator: ".", omittingEmptySubsequences: false)
    guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
    var numbers: [Int] = []
    for piece in pieces {
      guard let n = Int(piece), n >= 0, piece.allSatisfy(\.isNumber) else { return nil }
      numbers.append(n)
    }
    while numbers.count < 3 { numbers.append(0) }
    parts = numbers
    prerelease = (pre?.isEmpty ?? true) ? nil : pre
  }
  public var description: String {
    parts.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "")
  }
  public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
  public static func < (a: AppVersion, b: AppVersion) -> Bool {
    let n = max(a.parts.count, b.parts.count)
    for i in 0..<n {
      let x = i < a.parts.count ? a.parts[i] : 0
      let y = i < b.parts.count ? b.parts[i] : 0
      if x != y { return x < y }
    }
    switch (a.prerelease, b.prerelease) {
    case (nil, nil): return false
    case (.some, nil): return true  // 1.0.0-beta is older than 1.0.0
    case (nil, .some): return false
    case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
    }
  }
}

// MARK: One-click setup

/// What the automatic part of setup brings from, and what it keeps of a list of open tabs.
public enum SetupSource {
  /// The profiles to bring from: those of the default browser when one of the found profiles is
  /// its own, else those of the first browser found. `defaultBrowser` is the name of the app
  /// that opens web links ("Arc", "Brave Browser"); nil when that app is Serein.
  public static func profiles(defaultBrowser: String?, found: [BrowserImportProfile])
    -> [BrowserImportProfile]
  {
    if let name = defaultBrowser?.lowercased() {
      let own = found.filter {
        let browser = $0.browser.lowercased()
        return name == browser || name.hasPrefix(browser + " ")
      }
      if !own.isEmpty { return own }
    }
    guard let first = found.first else { return [] }
    return found.filter { $0.browser == first.browser }
  }

  /// The profile the person used last comes first, so one browser gives its bookmarks, sign-ins
  /// and passwords from the same profile. `lastUsed` is the folder name in the browser's
  /// `Local State` ("Default", "Profile 2"); with none, the order stays.
  public static func lastUsedFirst(_ profiles: [BrowserImportProfile], lastUsed: String?) -> [BrowserImportProfile] {
    guard let lastUsed, let index = profiles.firstIndex(where: { $0.directory.lastPathComponent == lastUsed })
    else { return profiles }
    var out = profiles
    out.insert(out.remove(at: index), at: 0)
    return out
  }
  /// `profile.last_used` of a Chromium browser's `Local State` file.
  public static func lastUsed(localState: Data?) -> String? {
    guard let localState, let json = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
      let name = (json["profile"] as? [String: Any])?["last_used"] as? String, !name.isEmpty
    else { return nil }
    return name
  }
  /// A browser of the Chromium family: it says which of its windows are private, so Serein can
  /// leave those out. `name` is the app's name ("Google Chrome", "Brave Browser").
  public static func tellsPrivateWindows(_ name: String) -> Bool {
    let lower = name.lowercased()
    return ChromiumCookies.safeStorageServices.keys.contains {
      lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + " ")
    }
  }

  /// The addresses a browser gave for its open tabs, one on each line: web pages only, each
  /// one time, in their order, at most `limit`.
  public static func tabs(_ text: String, limit: Int = 40) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let address = line.trimmingCharacters(in: .whitespaces)
      guard out.count < limit, let url = URL(string: address),
        let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
        url.host?.isEmpty == false, seen.insert(address).inserted
      else { continue }
      out.append(address)
    }
    return out
  }
}

// MARK: Keyboard pane

public struct ShortcutEntry: Equatable, Identifiable {
  public var id: String { group + "/" + title + "/" + keys }
  public var group: String
  public var title: String
  public var keys: String
  public init(group: String, title: String, keys: String) {
    self.group = group
    self.title = title
    self.keys = keys
  }
}

public enum ShortcutCatalog {
  // Raw NSEvent.ModifierFlags bits.
  public static let cmd: UInt = 1 << 20
  public static let shift: UInt = 1 << 17
  public static let option: UInt = 1 << 19
  public static let control: UInt = 1 << 18

  /// Menu key equivalents as shown on a Mac: control, option, shift, command, then the key.
  public static func display(key: String, flags: UInt) -> String {
    guard !key.isEmpty else { return "" }
    var out = ""
    if flags & control != 0 { out += "⌃" }
    if flags & option != 0 { out += "⌥" }
    if flags & shift != 0 { out += "⇧" }
    if flags & cmd != 0 { out += "⌘" }
    return out + glyph(key)
  }
  static func glyph(_ key: String) -> String {
    switch key {
    case "\r", "\u{3}": return "Return"
    case "\u{8}", "\u{7f}": return "⌫"
    case "\u{1b}": return "Esc"
    case "\t": return "Tab"
    case " ": return "Space"
    case "\u{F700}": return "↑"
    case "\u{F701}": return "↓"
    case "\u{F702}": return "←"
    case "\u{F703}": return "→"
    default: return key.count == 1 ? key.uppercased() : key
    }
  }

  /// Entries that are not menu items.
  public static func extras(talkKeyTitle: String) -> [ShortcutEntry] {
    let tabShortcuts = (1...8).map {
      ShortcutEntry(group: "Tabs", title: "Select tab \($0)", keys: "⌘\($0)")
    } + [ShortcutEntry(group: "Tabs", title: "Select last tab", keys: "⌘9")]
    return [
      ShortcutEntry(group: "Browser", title: "Stop loading the page", keys: "Esc"),
      ShortcutEntry(group: "Talking", title: "Hold to talk", keys: "Hold \(talkKeyTitle)"),
      ShortcutEntry(group: "Composer", title: "Stop and send", keys: "⌥Return"),
      ShortcutEntry(group: "Omnibox", title: "Remove the highlighted suggestion", keys: "⇧⌫"),
    ] + tabShortcuts
  }

  public static func group(_ entries: [ShortcutEntry]) -> [(name: String, entries: [ShortcutEntry])] {
    var order: [String] = []
    var buckets: [String: [ShortcutEntry]] = [:]
    for entry in entries {
      if buckets[entry.group] == nil { order.append(entry.group) }
      buckets[entry.group, default: []].append(entry)
    }
    return order.map { ($0, buckets[$0] ?? []) }
  }

  /// Case-insensitive match on the title, group or the keys.
  public static func filter(_ entries: [ShortcutEntry], query: String) -> [ShortcutEntry] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return entries }
    return entries.filter { entry in
      let hay = (entry.title + " " + entry.group + " " + entry.keys).lowercased()
      return words.allSatisfy { hay.contains($0) }
    }
  }
}
