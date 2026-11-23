import Foundation

/// What "Use my own setup" (HarnessInstance.ownSetup) changes in a run.
public enum OwnSetup {
  /// The user's choices (2026-10-18, "Not in web tasks", then "Read-only + connectors"): their
  /// own MCP servers, connectors and API keys are used only in answer, library and project tasks
  /// that edit nothing and run no commands, and never in a turn that carries web content (the
  /// page, tabs, a selection, pointed elements, console errors). Those turns get no web tools at
  /// all. Web, page and Mac tasks, and tasks with edits, use Serein's isolated setup. The user's
  /// MCP servers are fenced by the mode, not by an OS sandbox.
  public static let modes: Set<String> = ["answer", "project", "library"]
  public static func applies(mode: String, webContent: Bool, edits: Bool) -> Bool {
    modes.contains(mode) && !webContent && !edits
  }
  /// The last eight messages written on the same side of the own-setup line (nil: Serein's side),
  /// for history pasted into a fresh session.
  public static func sameSide<T>(_ messages: [T], own: Bool, side: KeyPath<T, Bool?>) -> [T] {
    Array(messages.filter { ($0[keyPath: side] ?? false) == own }.suffix(8))
  }
  /// What a copy of a thread ("Continue in copy") is summarized from: an own-setup thread's own
  /// messages, or else only Serein's side, so a mixed thread's summary (which lands on Serein's
  /// side) holds no result of the user's servers.
  public static func forkSide<T>(_ messages: [T], side: KeyPath<T, Bool?>) -> (messages: [T], own: Bool) {
    let own = !messages.isEmpty && messages.allSatisfy { $0[keyPath: side] == true }
    return (messages.filter { ($0[keyPath: side] == true) == own }, own)
  }
  /// Serein's own secrets, closed to an agent with its own setup as to every other: website data
  /// (every site sign-in in Serein, also other WebKit apps'), Serein's support folder and library,
  /// and its settings (which hold the CLI-reply consent).
  public static func sereinPaths(home: URL, library: URL?) -> [String] {
    ["Library/HTTPStorages", "Library/WebKit", "Library/Application Support/Serein",
      "Library/Preferences/local.serein.browser.plist"]
      .map { home.appendingPathComponent($0).standardizedFileURL.path }
      + [library?.standardizedFileURL.path].compactMap { $0 }
  }
  /// The environment of a run with the user's own setup: theirs, without names that change how a
  /// shell starts or tell the CLI that it runs inside another one.
  public static func environment(_ env: [String: String]) -> [String: String] {
    env.filter { !["ENV", "BASH_ENV", "CLAUDECODE", "CODEX_THREAD_ID", "CLAUDE_CODE_SHELL_PREFIX"].contains($0.key) }
  }
  /// Codex features off with the user's own setup: everything Serein turns off on its own runs
  /// except apps (connectors) and plugins, which can bring their MCP servers. Hooks, memories,
  /// sub-agents and the built-in browser, computer use and code runner stay off.
  public static let codexFeaturesOff = CodexParams.disabledFeatures.filter { !["apps", "plugins", "remote_plugin"].contains($0) }
}
