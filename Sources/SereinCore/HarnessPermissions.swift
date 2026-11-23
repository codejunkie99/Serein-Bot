import Foundation

/// What one run grants, in the terms the permission mappings need.
public struct HarnessGrant: Equatable, Sendable {
  /// TaskMode.runKey.
  public var mode: String
  /// Project edits allowed for this run.
  public var edits: Bool
  public var permission: RunPermissionMode
  /// The agent runs with its own setup (OwnSetup.applies). Serein still answers no to every ask
  /// outside the grant: only what the user's own config allows without asking runs.
  public var ownSetup: Bool
  /// The chat's level; only Allow all widens the grant (`opensHome`).
  public var level: ApprovalLevel
  public init(
    mode: String, edits: Bool, permission: RunPermissionMode, ownSetup: Bool = false, level: ApprovalLevel = .everyStep
  ) {
    self.mode = mode
    self.edits = edits
    self.permission = permission
    self.ownSetup = ownSetup
    self.level = level
  }
  /// Edits are possible only in a project with edits granted.
  public var mayEdit: Bool { mode == "project" && edits }
  /// Shell commands run only in Auto or Full access, in a project with edits granted.
  public var mayRunCommands: Bool { mayEdit && permission.needsProjectEdits }
  /// File reads: everywhere except Answer (no tools) and the web modes, which use the browser.
  public var mayRead: Bool { ["project", "library"].contains(mode) }
  /// Full access asks for nothing (still inside the project and Serein's browser capability).
  public var unattended: Bool { mayEdit && permission == .fullAccess }
  /// Allow all on a run that asks nothing: home is open past the task folder, except the
  /// protected folders and Serein's own data, and so is everything the CLI asks about (R7).
  public var opensHome: Bool { level == .proactive && unattended }
}

/// Each harness's native permission flags for Serein's four run modes. Nothing here ever turns
/// off Serein's browser capability scoping; dangerous flags appear only for Full access in a
/// project with edits granted.
public enum HarnessPermissions {
  /// cursor-agent launch flags. `--force` only for Full access in a project with edits. Cursor
  /// has no flag for Auto, so Serein answers its permission requests from the grant instead.
  public static func cursorFlags(_ g: HarnessGrant) -> [String] {
    guard g.mayEdit else { return [] }
    switch g.permission {
    case .supervised, .autoAcceptEdits, .auto: return []
    case .fullAccess: return ["--force"]
    }
  }
  /// Grok's flags. Never its `auto`: there Grok answers its own shell asks and Serein never sees
  /// them, so Commands asks like Edits and Serein's rule allows the shell.
  public static func grokFlags(_ g: HarnessGrant) -> [String] {
    guard g.mayEdit else { return ["--permission-mode", "default"] }
    switch g.permission {
    case .supervised: return ["--permission-mode", "default"]
    case .autoAcceptEdits, .auto: return ["--permission-mode", "acceptEdits"]
    case .fullAccess: return ["--always-approve"]
    }
  }
  /// OpenCode's `permission` config object for `grant`, for OPENCODE_CONFIG_CONTENT.
  public static func openCodeConfigPermission(_ g: HarnessGrant) -> [String: String] {
    var p: [String: String] = [
      "read": g.mayRead ? "allow" : "ask", "glob": g.mayRead ? "allow" : "deny",
      "grep": g.mayRead ? "allow" : "deny", "list": g.mayRead ? "allow" : "deny",
      "lsp": g.mayRead ? "allow" : "deny",
      "edit": g.mayEdit ? (g.permission == .supervised ? "ask" : "allow") : (g.mode == "project" ? "ask" : "deny"),
      "bash": openCodeBash(g),
      "task": "deny", "skill": "deny", "webfetch": "deny", "websearch": "deny",
      "external_directory": "deny", "question": "deny", "doom_loop": "deny",
      "todowrite": g.mayEdit ? "allow" : "deny",
    ]
    if !g.mayEdit { p["todowrite"] = "deny" }
    return p
  }
  /// Never "deny" bash or read: OpenCode then drops the tool, and OpenCode Zen's free tier refuses
  /// a request without both ("can only be used from within OpenCode"). Without the grant every
  /// call is asked and `HarnessApprovals.decide` rejects it.
  static func openCodeBash(_ g: HarnessGrant) -> String {
    g.mayRunCommands && g.permission == .fullAccess ? "allow" : "ask"
  }
}

// MARK: - Answering a harness's permission request

/// One request a harness sends before a tool runs (ACP `session/request_permission`), reduced to what Serein decides on.
public struct HarnessPermissionRequest: Equatable, Sendable {
  /// `mode`: a request to change the harness's own permission mode (ACP `switch_mode`), never allowed.
  public enum Kind: String, Sendable { case read, edit, execute, fetch, browser, mcp, mode, other }
  public var id: String
  public var kind: Kind
  /// Untrusted, display only.
  public var title: String
  public var paths: [String]
  public init(id: String, kind: Kind, title: String, paths: [String] = []) {
    self.id = id
    self.kind = kind
    self.title = title
    self.paths = paths
  }
  /// ACP `toolCall.kind` (read, edit, delete, move, search, execute, think, fetch, other).
  public static func acpKind(_ kind: String?, title: String) -> Kind {
    switch kind ?? "" {
    case "read", "search", "think": return .read
    case "edit", "delete", "move": return .edit
    case "execute": return .execute
    case "fetch": return .fetch
    case "switch_mode": return .mode
    default:
      // "<server>__<tool>" (Grok: "serein_browser__read_page"; Claude's "mcp__<server>__<tool>"):
      // only Serein's own server counts, never a server of the user's whose tool names it.
      if let split = title.range(of: "__") {
        let server = title[..<split.lowerBound]
        if server == "serein_browser" || (server == "mcp" && title[split.upperBound...].hasPrefix("serein_browser__")) {
          return .browser
        }
        return server.lowercased() == "mcp" ? .mcp : .other
      }
      return title.lowercased().hasPrefix("mcp") ? .mcp : .other
    }
  }
  /// Gemini CLI: whether a request is for one of Serein's browser tools. Newer versions (0.68.0
  /// does) name the MCP server themselves, and that name decides either way. Older ones give only
  /// a title built from the model's arguments, so there only a title that starts with Serein's
  /// server counts. Anything else is declined like any other tool.
  public static func geminiKind(_ kind: Kind, title: String, server: String?) -> Kind {
    if let server { return server == "serein_browser" ? .browser : kind == .browser ? .other : kind }
    guard kind == .browser else { return kind }
    return title.hasPrefix("serein_browser__") || title.hasPrefix("mcp__serein_browser__") ? .browser : .other
  }
}

public struct HarnessPermissionAnswer: Equatable, Sendable {
  public var allow: Bool
  /// An approval card for the user when an edit was declined.
  public var approval: PendingApproval?
}

public enum HarnessApprovals {
  public static func decide(_ r: HarnessPermissionRequest, grant g: HarnessGrant, folder: String?)
    -> HarnessPermissionAnswer
  {
    let allow: Bool
    switch r.kind {
    case .read:
      allow = g.mayRead && (AgentFileGuard.allowsRead(r.paths, folder: folder) || g.opensHome && AgentFileGuard.allowsHome(r.paths))
    case .edit:
      allow = g.mayEdit
        && (AgentFileGuard.allowsRead(r.paths, folder: folder) && inside(r.paths, folder: folder)
          || g.opensHome && AgentFileGuard.allowsHome(r.paths))
    case .execute: allow = g.mayRunCommands
    case .browser: allow = g.mode != "answer" && g.mode != "library"
    // At Auto and Manual nobody can be asked here, so what the CLI asks about is declined (the
    // user's choice, 2026-10-18); Allow all runs it (R7).
    case .fetch, .mcp, .mode, .other: allow = g.opensHome
    }
    var approval: PendingApproval?
    if !allow, r.kind == .edit, g.mode == "project" {
      // Compare resolved paths: /var and /tmp are symlinks into /private on macOS.
      let target = ApprovalEvents.display(
        r.paths.first.map { resolved($0, folder: folder) }, folder: folder.map { resolved($0, folder: nil) })
      approval = PendingApproval(id: r.id, tool: "Edit", target: target.isEmpty ? String(r.title.prefix(80)) : target)
    }
    return HarnessPermissionAnswer(allow: allow, approval: approval)
  }
  /// Every path must be inside the project; an edit with no path is allowed only when granted.
  static func inside(_ paths: [String], folder: String?) -> Bool {
    guard let folder, !paths.isEmpty else { return true }
    let root = resolved(folder, folder: nil)
    return paths.allSatisfy {
      let full = resolved($0, folder: folder)
      return full == root || full.hasPrefix(root + "/")
    }
  }
  /// Absolute, with symlinks resolved as the file is opened (`AgentFileGuard.physicalPath`: a
  /// file that does not exist yet still compares correctly, and `link/..` climbs from the link's
  /// target, so it cannot pass for a path inside the folder).
  static func resolved(_ path: String, folder: String?) -> String {
    AgentFileGuard.physicalPath(path.hasPrefix("/") ? path : (folder ?? "") + "/" + path)
  }
  /// The ACP option to answer with: allow_once or reject_once, never an `_always` one, so nothing
  /// persists in the harness (R8). nil means answer `cancelled`.
  public static func acpOption(_ options: [[String: Any]], allow: Bool) -> String? {
    let kind = allow ? "allow_once" : "reject_once"
    return options.first(where: { $0["kind"] as? String == kind })?["optionId"] as? String
  }
}
