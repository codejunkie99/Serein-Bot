import Foundation

/// Role of a member inside a Serein swarm or autonomous team.
public enum SwarmRole: String, Codable, Sendable {
  case coordinator, worker, verifier, helper
}

/// Workspace ownership rule for a swarm member: readers/verifiers inspect without mutating,
/// while parallel writers use isolated worktrees.
public enum SwarmWorkspaceMode: String, Codable, Sendable {
  case inherit, readOnly, worktree
}

/// Live execution state of a swarm member on the shared board.
public enum SwarmMemberState: String, Codable, Sendable {
  case working, waiting, done, stopped
}

/// One append-only entry on a room's swarm board.
public struct SwarmPost: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case brief, update, done, stall
  }

  public let seq: Int
  public let author: String
  public let mentions: [String]
  public let text: String
  public let kind: Kind
  public let createdAt: Date

  public init(
    seq: Int, author: String, mentions: [String], text: String, kind: Kind, createdAt: Date = Date()
  ) {
    self.seq = seq
    self.author = author
    self.mentions = mentions
    self.text = text
    self.kind = kind
    self.createdAt = createdAt
  }
}

/// Compact overview manifest (`plan.json`) describing the swarm's goal, member tasks, and
/// outcome-oriented threads for UI rendering without needing an LLM narrator.
public struct SwarmPlan: Codable, Equatable, Sendable {
  public struct Goal: Codable, Equatable, Sendable {
    public var title: String
    public var line: String
    public init(title: String, line: String) {
      self.title = title
      self.line = line
    }
  }

  public struct Thread: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var goal: String
    public var tasks: [String]
    public init(id: String, title: String, goal: String, tasks: [String]) {
      self.id = id
      self.title = title
      self.goal = goal
      self.tasks = tasks
    }
  }

  public var goal: Goal
  public var tasks: [String: String]
  public var threads: [Thread]

  public init(goal: Goal, tasks: [String: String], threads: [Thread]) {
    self.goal = goal
    self.tasks = tasks
    self.threads = threads
  }
}

/// Append-only message board for multi-agent coordination. Workers sleep at zero token cost
/// until `@mentioned` (or `@all`), and refer to earlier results by `#seq` instead of copying
/// large outputs between prompts.
public struct SwarmBoard: Codable, Equatable, Sendable {
  public struct Member: Codable, Equatable, Sendable {
    public var name: String
    public var role: SwarmRole
    public var workspace: SwarmWorkspaceMode
    public var state: SwarmMemberState
    public var lastReadSeq: Int
    public var lastActivityAt: Date

    public init(
      name: String, role: SwarmRole, workspace: SwarmWorkspaceMode,
      state: SwarmMemberState = .waiting, lastReadSeq: Int = 0, lastActivityAt: Date = Date()
    ) {
      self.name = name
      self.role = role
      self.workspace = workspace
      self.state = state
      self.lastReadSeq = lastReadSeq
      self.lastActivityAt = lastActivityAt
    }
  }

  public private(set) var posts: [SwarmPost]
  public private(set) var members: [String: Member]
  public private(set) var finished: Bool

  public init(posts: [SwarmPost] = [], members: [String: Member] = [:], finished: Bool = false) {
    self.posts = posts
    self.members = members
    self.finished = finished
  }

  public var head: Int { posts.last?.seq ?? 0 }

  public mutating func register(
    name: String, role: SwarmRole, workspace: SwarmWorkspaceMode, at now: Date = Date()
  ) {
    members[name] = Member(
      name: name, role: role, workspace: workspace,
      state: role == .coordinator ? .working : .waiting, lastReadSeq: head, lastActivityAt: now)
  }

  public mutating func setState(_ name: String, to state: SwarmMemberState, at now: Date = Date()) {
    guard var member = members[name] else { return }
    member.state = state
    member.lastActivityAt = now
    members[name] = member
  }

  @discardableResult
  public mutating func post(
    author: String, text: String, kind: SwarmPost.Kind? = nil, at now: Date = Date()
  ) -> SwarmPost {
    let seq = head + 1
    let mentions = Self.parseMentions(in: text)
    let resolvedKind = kind ?? Self.inferKind(text: text, mentions: mentions)
    let entry = SwarmPost(
      seq: seq, author: author, mentions: mentions, text: text, kind: resolvedKind, createdAt: now)
    posts.append(entry)

    if var sender = members[author] {
      sender.lastActivityAt = now
      sender.lastReadSeq = max(sender.lastReadSeq, seq)
      if resolvedKind == .done && author != "coordinator" {
        sender.state = .done
      } else if author != "coordinator" {
        sender.state = .waiting
      }
      members[author] = sender
    }

    if author == "coordinator", resolvedKind == .done, mentions.isEmpty {
      finished = true
    }

    for target in mentions {
      if target == "all" {
        for (name, var m) in members where name != author && m.state == .waiting {
          m.lastActivityAt = now
          members[name] = m
        }
      } else if var m = members[target], m.state == .waiting || m.state == .done {
        m.state = .working
        m.lastActivityAt = now
        members[target] = m
      }
    }
    return entry
  }

  /// Unread posts strictly after `since`. When `mentionsOnly` is true, returns only posts calling
  /// `@name` or `@all` (or everything if the reader is `coordinator`).
  public func unread(since: Int, for member: String, mentionsOnly: Bool = true) -> [SwarmPost] {
    let tail = posts.filter { $0.seq > since }
    guard mentionsOnly, member != "coordinator" else { return tail }
    return tail.filter { $0.mentions.contains(member) || $0.mentions.contains("all") }
  }

  /// Fetches specific posts referenced by `#seq` without re-reading the entire board.
  public func posts(seqs: [Int]) -> [SwarmPost] {
    let wanted = Set(seqs)
    return posts.filter { wanted.contains($0.seq) }
  }

  /// Extracts `@target` mentions in appearance order, deduplicated.
  public static func parseMentions(in text: String) -> [String] {
    let ns = text as NSString
    let regex = try! NSRegularExpression(pattern: #"(?:^|[\s(])@([a-zA-Z0-9_-]+)"#)
    var seen = Set<String>()
    var out: [String] = []
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      let name = ns.substring(with: match.range(at: 1)).lowercased()
      if seen.insert(name).inserted { out.append(name) }
    }
    return out
  }

  private static func inferKind(text: String, mentions: [String]) -> SwarmPost.Kind {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("[done]") || trimmed.hasPrefix("[done]") { return .done }
    if trimmed.contains("[stall]") { return .stall }
    if !mentions.isEmpty, postsLikelyBrief(trimmed) { return .brief }
    return .update
  }

  private static func postsLikelyBrief(_ text: String) -> Bool {
    text.hasPrefix("@") && !text.contains("[done]") && !text.contains("[stall]")
  }
}

/// Pure stall monitor: detects when every active worker has gone quiet while the swarm is still
/// open, and identifies who needs to act next so the swarm never silently freezes.
public enum SwarmMonitor {
  public static func stallTarget(
    board: SwarmBoard, now: Date, idleAfter: TimeInterval
  ) -> String? {
    guard !board.finished else { return nil }
    let workers = board.members.values.filter { $0.role != .coordinator }
    guard !workers.isEmpty else { return nil }
    // Any worker currently working means the swarm is actively making progress.
    if workers.contains(where: { $0.state == .working }) { return nil }
    let latestActivity = board.posts.last?.createdAt ?? workers.map(\.lastActivityAt).max() ?? now
    guard now.timeIntervalSince(latestActivity) >= idleAfter else { return nil }
    // If any post since the last coordinator message tagged a specific waiting/done worker that has not answered, nudge it.
    if let lastPost = board.posts.last, lastPost.kind != .stall {
      for target in lastPost.mentions where target != "all" && target != "coordinator" {
        if let m = board.members[target], m.state != .done { return target }
      }
    }
    return "coordinator"
  }
}

/// Pure admission rules for unlimited autonomous teams (#9). No artificial bot count or team
/// count cap: staffing is paced by real memory/quota, cycle prevention, duplicate-role checks,
/// provenance (`createdBy`), and zero connected apps on newly created teammates.
public enum AutoTeamPolicy {
  public struct BotRecord: Equatable, Sendable {
    public var id: String
    public var role: String
    public var createdBy: String
    public var parentTaskID: String
    public var connectedApps: [String]

    public init(
      id: String, role: String, createdBy: String, parentTaskID: String, connectedApps: [String] = []
    ) {
      self.id = id
      self.role = role
      self.createdBy = createdBy
      self.parentTaskID = parentTaskID
      self.connectedApps = connectedApps
    }
  }

  public enum Decision: Equatable, Sendable {
    case admit(BotRecord)
    case reject(String)
  }

  public static func admit(
    id: String, role: String, createdBy: String, parentTaskID: String,
    existing: [BotRecord], activeChain: [String]
  ) -> Decision {
    let cleanRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanCreator = createdBy.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanRole.isEmpty else { return .reject("Role is required for an autonomous teammate.") }
    guard !cleanCreator.isEmpty else { return .reject("Creator identity (`createdBy`) is required.") }
    if activeChain.contains(id) {
      return .reject("Cycle detected: \(id) is already in the active chain.")
    }
    if existing.contains(where: {
      $0.parentTaskID == parentTaskID && $0.role.caseInsensitiveCompare(cleanRole) == .orderedSame
    }) {
      return .reject("An active teammate already owns the role \(cleanRole) for this task.")
    }
    // Newly created autonomous teammates always start with zero connected apps.
    return .admit(BotRecord(
      id: id, role: cleanRole, createdBy: cleanCreator, parentTaskID: parentTaskID, connectedApps: []))
  }
}
