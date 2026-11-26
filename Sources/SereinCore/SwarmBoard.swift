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
  /// `stalled`: its turn waits on its app's usage limit or on memory to start.
  case working, waiting, stalled, done, stopped

  public var settled: Bool { self == .done || self == .stopped }
}

/// Where a swarm's board is saved: per chat (`room`, the chat's thread id), then by board id.
public struct SwarmLink: Codable, Hashable, Sendable {
  public var room: String
  public var id: String
  public init(room: String, id: String) {
    self.room = room
    self.id = id
  }
  public var path: String { "swarms/\(Self.safe(room))/\(Self.safe(id)).json" }
  private static func safe(_ part: String) -> String {
    String(part.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
  }
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
    /// The bot that started this one; nil only for the lead. The start tree comes from this.
    public var parent: String?
    /// The app it runs in, by display name ("Codex").
    public var agent: String?
    /// Its slice or ask, as briefed.
    public var task: String?
    /// Seating order on this board, so the tree reads the same after a reload.
    public var joined: Int

    public init(
      name: String, role: SwarmRole, workspace: SwarmWorkspaceMode,
      state: SwarmMemberState = .waiting, lastReadSeq: Int = 0, lastActivityAt: Date = Date(),
      parent: String? = nil, agent: String? = nil, task: String? = nil, joined: Int = 0
    ) {
      self.name = name
      self.role = role
      self.workspace = workspace
      self.state = state
      self.lastReadSeq = lastReadSeq
      self.lastActivityAt = lastActivityAt
      self.parent = parent
      self.agent = agent
      self.task = task
      self.joined = joined
    }
  }

  /// A UUID minted when the swarm opens; never a launch-local run id.
  public var id: String
  /// The chat's thread id, set by the app when it first saves the board.
  public var room: String
  public var goal: String
  /// Grows with every copy Peers sends out, so a reader keeps the newest.
  public var version: Int
  public private(set) var posts: [SwarmPost]
  public private(set) var members: [String: Member]
  public private(set) var finished: Bool

  public init(
    id: String = "", room: String = "", goal: String = "", version: Int = 0,
    posts: [SwarmPost] = [], members: [String: Member] = [:], finished: Bool = false
  ) {
    self.id = id
    self.room = room
    self.goal = goal
    self.version = version
    self.posts = posts
    self.members = members
    self.finished = finished
  }

  public var head: Int { posts.last?.seq ?? 0 }
  public var link: SwarmLink { SwarmLink(room: room, id: id) }

  public mutating func register(
    name: String, role: SwarmRole, workspace: SwarmWorkspaceMode, parent: String? = nil, agent: String? = nil,
    task: String? = nil, at now: Date = Date()
  ) {
    let joined = members[name]?.joined ?? members.count
    members[name] = Member(
      name: name, role: role, workspace: workspace,
      state: role == .coordinator ? .working : .waiting, lastReadSeq: head, lastActivityAt: now,
      parent: parent, agent: agent, task: task, joined: joined)
  }

  /// `wanted`, or `wanted-2`, `wanted-3` when a bot already has that name.
  public func unusedName(_ wanted: String) -> String {
    let base = wanted.lowercased()
    guard members[base] != nil || base == "you" || base == "all" else { return base }
    var n = 2
    while members["\(base)-\(n)"] != nil { n += 1 }
    return "\(base)-\(n)"
  }

  /// Every bot but the lead: workers, verifiers and helpers, with no cap.
  public var bots: Int { botMembers.count }
  public var settledBots: Int { botMembers.filter(\.state.settled).count }
  private var botMembers: [Member] { members.values.filter { $0.parent != nil || $0.role != .coordinator } }
  public var countLine: String { SwarmPrompts.countLine(bots: bots, done: settledBots) }
  /// The lead first, then each bot under the one that started it, in seating order.
  public var lead: Member? { members.values.filter { $0.parent == nil }.min { $0.joined < $1.joined } }
  public func children(of name: String) -> [Member] {
    members.values.filter { $0.parent == name }.sorted { $0.joined < $1.joined }
  }
  /// The newest `[done]` post `name` wrote.
  public func lastDone(by name: String) -> SwarmPost? { posts.last { $0.author == name && $0.kind == .done } }

  public mutating func finish() { finished = true }

  /// No bot outlives a relaunch: a board loaded from disk whose swarm no longer runs shows every
  /// unsettled bot as stopped. Running it twice changes nothing.
  public func closedAfterRelaunch() -> SwarmBoard {
    var board = self
    for (name, member) in members where !member.state.settled { board.members[name]?.state = .stopped }
    board.finished = true
    return board
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
