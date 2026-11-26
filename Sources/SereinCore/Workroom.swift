import Foundation

/// One task's team: `relay/rooms/<id>/room.json`. The host is its only writer; a model changes it
/// only through a tool. Seats are append-only: a seat is closed, never removed, so a seat's parent
/// always comes before it.
public struct Workroom: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var root: Root
  /// `seats[0]` is the lead, the assistant the person (or the routine) spoke to.
  public var seats: [Seat]
  /// The lead's reach when the room opened. No seat ever exceeds it.
  public private(set) var ceiling: Reach
  /// Monotonic: once true it never returns to false. Every later packet and seat thread carries it.
  public private(set) var personal: Bool
  /// Assistants this room made, newest last: the record of what the task made, so each can be
  /// shown and removed. Never a budget, and it never shrinks. A file from before keeps a
  /// `teamsMade` count, which decoding ignores.
  public private(set) var made: [RelayProfile.ID]
  /// Packets numbered in this room. Never shrinks, so a packet number is never given twice.
  public private(set) var packets: Int
  public var state: State
  public var openedAt: Date
  public var closedAt: Date?

  public enum State: String, Codable, Sendable { case open, closing, closed }

  /// What set the room going. Rooms are idempotent on it: one root, one room.
  public enum Root: Codable, Equatable, Sendable {
    /// The person's message: `message` is the id of their bubble in `thread`.
    case chat(thread: String, message: String)
    case scheduled(reminder: String)
    case watch(String)
    case hook(String)
    // A room saved before the rename keeps opening. In Swift, `.person(` stays the approval
    // door's own word (scripts/check_approval_door.py).
    enum CodingKeys: String, CodingKey { case chat = "person", scheduled, watch, hook }
  }

  public struct Seat: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var who: RelayProfile.ID
    /// This seat's own hidden thread, one engine session.
    public var thread: String
    public var reach: Reach
    /// nil for the lead.
    public var parent: String?
    /// The ledger row that seated it; nil for the lead.
    public var handoff: AssistantHandoff.ID?
    /// The highest note `seq` this seat has been shown (`RoomNotes.delta`).
    public var notesCursor: Int
    public var closedAt: Date?

    public init(id: String, who: RelayProfile.ID, thread: String, reach: Reach, parent: String?,
                handoff: AssistantHandoff.ID?, notesCursor: Int = 0, closedAt: Date? = nil) {
      self.id = id
      self.who = who
      self.thread = thread
      self.reach = reach
      self.parent = parent
      self.handoff = handoff
      self.notesCursor = notesCursor
      self.closedAt = closedAt
    }
  }

  /// A room with its lead seated at `reach`, which becomes the ceiling.
  public init(id: String = "r_" + UUID().uuidString.prefix(6).lowercased(), root: Root, lead: RelayProfile.ID,
              thread: String, reach: Reach, now: Date) {
    self.id = id
    self.root = root
    seats = [Seat(id: "s1", who: lead, thread: thread, reach: reach, parent: nil, handoff: nil)]
    ceiling = reach
    personal = false
    made = []
    packets = 0
    state = .open
    openedAt = now
  }

  /// The id the next seat takes: "s1", "s2", ...
  public var nextSeatID: String { "s\(seats.count + 1)" }

  public mutating func markPersonal() { personal = true }
  public mutating func recordMade(_ id: RelayProfile.ID) { made.append(id) }
  /// The next packet's number. `taken`: the highest one already given elsewhere (the ledger), for
  /// a room.json that a crash left behind it.
  public mutating func nextPacket(after taken: Int = 0) -> Int {
    packets = max(packets, taken) + 1
    return packets
  }

  /// Run before every seat's run, so reach holds over time: each seat is narrowed again under its
  /// parent's reach as it is now (the lead under the ceiling), top-down. Narrowing a maker later
  /// carries down to everything it seated. `now` is a profile's own reach today, where it changed.
  /// Reach only ever narrows here; widening a maker again widens nothing below it.
  public mutating func renarrow(_ now: [RelayProfile.ID: Reach]) {
    var current: [String: Reach] = [:]
    for i in seats.indices {
      let above = seats[i].parent.flatMap { current[$0] } ?? ceiling
      var reach = above.narrowed(to: seats[i].reach.scope)
      if let own = now[seats[i].who] { reach = reach.narrowed(to: own.scope) }
      seats[i].reach = reach
      current[seats[i].id] = reach
    }
  }
}

/// What a seat may use: places, Never sites and connected apps. Instructions are not reach and are
/// always empty here. Besides the person's own reach, the only way to get one is `narrowed`, so no
/// child wider than its parent can be made.
public struct Reach: Codable, Equatable, Sendable {
  public private(set) var scope: AssistantScope

  private init(_ scope: AssistantScope) {
    self.scope = AssistantScope(destinations: scope.destinations, neverSites: scope.neverSites, apps: scope.apps)
  }

  /// The person's own reach: their settings as `AssistantScope.effective` reads them.
  public static func ofPerson(_ scope: AssistantScope) -> Reach { Reach(scope) }

  /// Intersection of places and apps, union of Never sites. `wanted` nil copies.
  public func narrowed(to wanted: AssistantScope?) -> Reach { Reach(AssistantScope.effective(wanted, person: scope)) }

  /// What `wanted` asked for and did not get, in plain words, for the tool result ("left_out").
  public func dropped(from wanted: AssistantScope) -> [String] {
    let places = AssistantPlace.allCases.filter { wanted.destinations.contains($0) && !scope.destinations.contains($0) }
    let apps = (wanted.apps ?? []).filter { !scope.allowsApp($0) }
    return places.map(\.label) + apps
  }
}
