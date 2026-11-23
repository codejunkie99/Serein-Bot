import CryptoKit
import Foundation

// The life of one assistant, as pure rules: its face, a new assistant from typed words, the plan
// for a delete and its Undo, the sections of the assistant list, the quick-reply chips at the end
// of a reply, and a job guess from a name. Nothing here writes a file or grants a place: the
// shell applies a plan through `changeTeam`, which journals it, and the admission rule
// (`Admission`) decides first whether the plan may apply or needs a card.

// MARK: - Face

/// The face an assistant shows when the person chose no icon: one of five blob shapes, one tint
/// and two eyes. SHA-256 of the assistant's id selects the shape and the tint, so one id always
/// gives the same face and a rename keeps it. A chosen `AssistantIcon` wins over the face, and
/// Serein (the main assistant) keeps the app icon; the shell makes those two decisions.
public struct AssistantFace: Equatable, Sendable {
  public enum Blob: String, CaseIterable, Codable, Sendable {
    case round, soft, squircle, hex, cloud
  }
  /// A point in the face's box of `box` by `box`: x goes right and y goes down, as SwiftUI draws.
  public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
      self.x = x
      self.y = y
    }
  }
  /// One step of an outline, in the order SwiftUI's `Path` takes them (`move`, `addLine`,
  /// `addCurve`, `closeSubpath`). Every outline starts with `move` and ends with `close`.
  public enum Step: Equatable, Sendable {
    case move(Point)
    case line(Point)
    case curve(to: Point, control1: Point, control2: Point)
    case close
  }

  /// The side of the box that outlines and eyes use. The shell multiplies by `size / box`.
  public static let box: Double = 24
  /// The radius of each eye in the box. The shell draws a blink as a vertical squash.
  public static let eyeRadius: Double = 1.5
  /// The tints a face can have: the assistant tints of DESIGN.md (`AssistantColour.all`) without
  /// Slate and Indigo. Indigo is the accent, the main assistant's own colour.
  public static let tints: [String] = AssistantColour.all.filter { $0 != "slate" && $0 != "indigo" }

  public private(set) var blob: Blob
  /// A key of `AssistantColour.all`. The shell gets its value per palette from `ThemeTokens.assistantTints`.
  public private(set) var tint: String

  /// The face for an assistant id. The first byte of the digest selects the shape and the second
  /// byte selects the tint.
  public init(id: String) {
    let digest: [UInt8] = Array(SHA256.hash(data: Data(id.utf8)))
    let blobs = Blob.allCases
    blob = blobs[Int(digest[0]) % blobs.count]
    tint = Self.tints[Int(digest[1]) % Self.tints.count]
  }

  /// The same shape in the tint the assistant has on its row (`RelayProfile.colour`), so the face
  /// and the row agree. A colour that no build knows keeps the tint from the id.
  public func wearing(_ stored: String?) -> AssistantFace {
    var face = self
    if let key = AssistantColour.key(stored) { face.tint = key }
    return face
  }

  public var outline: [Step] { Self.outline(blob) }
  public var eyes: (left: Point, right: Point) { Self.eyes(blob) }

  public static func outline(_ blob: Blob) -> [Step] {
    switch blob {
    case .round: return roundPath
    case .soft: return softPath
    case .squircle: return squirclePath
    case .hex: return hexPath
    case .cloud: return cloudPath
    }
  }
  /// The centres of the two eyes. They are inside the outline for each shape.
  public static func eyes(_ blob: Blob) -> (left: Point, right: Point) {
    switch blob {
    case .round, .squircle: return (Point(9, 11), Point(15, 11))
    case .soft, .hex: return (Point(9, 11.5), Point(15, 11.5))
    case .cloud: return (Point(9.5, 13.5), Point(14.5, 13.5))
    }
  }

  private static func p(_ x: Double, _ y: Double) -> Point { Point(x, y) }

  /// A circle: centre (12, 12), radius 10.
  static let roundPath: [Step] = [
    .move(p(12, 2)),
    .curve(to: p(22, 12), control1: p(17.52, 2), control2: p(22, 6.48)),
    .curve(to: p(12, 22), control1: p(22, 17.52), control2: p(17.52, 22)),
    .curve(to: p(2, 12), control1: p(6.48, 22), control2: p(2, 17.52)),
    .curve(to: p(12, 2), control1: p(2, 6.48), control2: p(6.48, 2)),
    .close,
  ]
  /// A pebble: a smooth closed curve through six points at a small range of distances from the centre.
  static let softPath: [Step] = [
    .move(p(12, 2.5)),
    .curve(to: p(20.83, 7), control1: p(15.57, 2.52), control2: p(19.21, 4.14)),
    .curve(to: p(20.14, 16.8), control1: p(22.46, 9.86), control2: p(21.91, 13.78)),
    .curve(to: p(12, 22.1), control1: p(18.37, 19.82), control2: p(15.33, 22.06)),
    .curve(to: p(3.51, 17), control1: p(8.67, 22.14), control2: p(5.31, 20.04)),
    .curve(to: p(2.99, 6.9), control1: p(1.71, 13.96), control2: p(1.3, 9.8)),
    .curve(to: p(12, 2.5), control1: p(4.69, 4), control2: p(8.43, 2.48)),
    .close,
  ]
  /// A square from 2 to 22 with continuous corners.
  static let squirclePath: [Step] = [
    .move(p(12, 2)),
    .curve(to: p(22, 12), control1: p(20.3, 2), control2: p(22, 3.7)),
    .curve(to: p(12, 22), control1: p(22, 20.3), control2: p(20.3, 22)),
    .curve(to: p(2, 12), control1: p(3.7, 22), control2: p(2, 20.3)),
    .curve(to: p(12, 2), control1: p(2, 3.7), control2: p(3.7, 2)),
    .close,
  ]
  /// A hexagon with a flat top, radius 10, with each corner rounded over 2.6 points of its edges.
  static let hexPath: [Step] = [
    .move(p(14.4, 3.34)),
    .curve(to: p(18.3, 5.59), control1: p(16.13, 3.34), control2: p(17.43, 4.09)),
    .line(p(20.7, 9.75)),
    .curve(to: p(20.7, 14.25), control1: p(21.57, 11.25), control2: p(21.57, 12.75)),
    .line(p(18.3, 18.41)),
    .curve(to: p(14.4, 20.66), control1: p(17.43, 19.91), control2: p(16.13, 20.66)),
    .line(p(9.6, 20.66)),
    .curve(to: p(5.7, 18.41), control1: p(7.87, 20.66), control2: p(6.57, 19.91)),
    .line(p(3.3, 14.25)),
    .curve(to: p(3.3, 9.75), control1: p(2.43, 12.75), control2: p(2.43, 11.25)),
    .line(p(5.7, 5.59)),
    .curve(to: p(9.6, 3.34), control1: p(6.57, 4.09), control2: p(7.87, 3.34)),
    .close,
  ]
  /// A cloud: a flat base and three lobes (left and right radius 4.5, top radius 6).
  static let cloudPath: [Step] = [
    .move(p(6, 19.5)),
    .line(p(18, 19.5)),
    .curve(to: p(22.5, 15), control1: p(20.49, 19.5), control2: p(22.5, 17.49)),
    .curve(to: p(18, 10.5), control1: p(22.5, 12.51), control2: p(20.49, 10.5)),
    .curve(to: p(12, 4.5), control1: p(18, 7.19), control2: p(15.31, 4.5)),
    .curve(to: p(6, 10.5), control1: p(8.69, 4.5), control2: p(6, 7.19)),
    .curve(to: p(1.5, 15), control1: p(3.51, 10.5), control2: p(1.5, 12.51)),
    .curve(to: p(6, 19.5), control1: p(1.5, 17.49), control2: p(3.51, 19.5)),
    .close,
  ]
}

// MARK: - Make

/// A new assistant read from `assistant_make` (`name`, `job`, `can_use`) and checked against the
/// roster and the person's own places. A draft makes nothing: `RelayTeam.making` turns it into a
/// plan, after `Admission` said apply or the person pressed the card's button.
public struct AssistantDraft: Equatable, Sendable {
  /// Why a draft or a make is refused, in words the model can repeat to the person.
  public enum Problem: Error, Equatable, Sendable {
    case noName
    case nameTooLong
    case notOneLine
    /// Another assistant has this name (in any case). It holds that assistant's name.
    case nameTaken(String)
    case jobTooLong
    case rosterFull

    public var words: String {
      switch self {
      case .noName: return "Give the assistant a name of 1 to \(AssistantDraft.nameLimit) characters."
      case .nameTooLong: return "That name is longer than \(AssistantDraft.nameLimit) characters. Choose a shorter one."
      case .notOneLine: return "A name and a job are one line of plain text."
      case .nameTaken(let name): return "Another assistant is called \(name). Choose another name."
      case .jobTooLong: return "Say the job in one sentence of at most \(AssistantDraft.jobLimit) characters."
      case .rosterFull: return AssistantBoard.fullRoster
      }
    }
  }

  public static let nameLimit = 40
  public static let jobLimit = TeamProposal.personaLimit

  /// Trimmed, 1 to `nameLimit` characters, one line, and no other assistant has it.
  public var name: String
  /// One plain sentence that says what it does. nil: neither the words nor the name tell, so the
  /// new assistant asks in its first turn (`NameReading.question`).
  public var job: String?
  /// The job is a guess from the name (`NameReading`), not words the person or model gave.
  public var jobFromName: Bool
  /// Only places the person allows, and never connected apps: apps start off.
  public var places: Set<AssistantPlace>
  /// What it asked to use and cannot have now, as the card shows it: places the person does not
  /// allow, words that name no place, and connected apps.
  public var dropped: [String]

  public init(name: String, job: String?, jobFromName: Bool = false, places: Set<AssistantPlace>, dropped: [String] = []) {
    self.name = name
    self.job = job
    self.jobFromName = jobFromName
    self.places = places
    self.dropped = dropped
  }

  /// Reads the tool's arguments. `person` is the places the person allows. Without `can_use`, the
  /// new assistant gets every place the person allows except connected apps, as New assistant does.
  public static func parse(_ a: [String: Any], person: Set<AssistantPlace>, team: RelayTeam) -> Result<AssistantDraft, Problem> {
    guard team.profiles.count < RelayTeam.maxProfiles else { return .failure(.rosterFull) }
    let name = (a["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if let problem = nameProblem(name, team: team) { return .failure(problem) }

    let typedJob = (a["job"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard typedJob.count <= jobLimit else { return .failure(.jobTooLong) }
    guard TeamProposal.oneLine(typedJob) else { return .failure(.notOneLine) }
    let guessed: String? = typedJob.isEmpty ? NameReading.job(for: name) : nil
    let job: String? = typedJob.isEmpty ? guessed : typedJob

    let raw: [String]? = words(a["can_use"] ?? a["canUse"])
    var places = Set<AssistantPlace>()
    var dropped: [String] = []
    if let raw {
      for word in raw {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { continue }
        let place = AssistantPlace.parse(clean)
        if let place, place != .connectedApps, person.contains(place) {
          places.insert(place)
        } else {
          let shown = place?.label ?? String(clean.prefix(40))
          if !dropped.contains(shown) { dropped.append(shown) }
        }
      }
    } else {
      places = person.subtracting([.connectedApps])
    }
    let draft = AssistantDraft(name: name, job: job, jobFromName: guessed != nil, places: places, dropped: dropped)
    return .success(draft)
  }

  /// nil when `name` (already trimmed) can be a new assistant's name in `team`.
  static func nameProblem(_ name: String, team: RelayTeam) -> Problem? {
    if name.isEmpty { return .noName }
    if name.count > nameLimit { return .nameTooLong }
    if !TeamProposal.oneLine(name) { return .notOneLine }
    if let other = team.profile(named: name) { return .nameTaken(other.name) }
    return nil
  }
  /// A list of words from a list or from one string with commas; nil when there is no value.
  static func words(_ value: Any?) -> [String]? {
    if let list = value as? [String] { return list }
    if let text = value as? String { return text.components(separatedBy: ",") }
    return nil
  }
}

/// One assistant to make, ready for `changeTeam`: the roster after, the new profile and its face.
public struct MakePlan: Equatable, Sendable {
  public var team: RelayTeam
  public var profile: RelayProfile
  public var face: AssistantFace
  /// The job the receipt and the first turn use; nil when the assistant must ask.
  public var job: String?

  /// The new assistant reads its name in its first turn and asks what to do (no job is known).
  public var asksFirst: Bool { job == nil }
  /// The system line in the chat: "You made Inbox Zero".
  public var line: String { "You made \(profile.name)" }

  /// "Inbox Zero is ready. It sorts your mail…", with Undo for the journal entry `entry`. A job
  /// that would make the line too long stays out of it.
  public func receipt(entry: String) -> Receipt {
    let sentence = job ?? ""
    let full = ReceiptCopy.made(name: profile.name, job: sentence, entry: entry)
    if !sentence.isEmpty, full.line.count <= Receipt.maxLine { return full }
    var short = full
    short.line = "\(profile.name) is ready."
    return short
  }
}

extension RelayTeam {
  /// The roster with one new assistant from `draft`. It checks the roster again (a card can wait
  /// while the roster changes) and clips the places to `person` again. The new assistant gets the
  /// next free tint and a face from its id; the active assistant does not change.
  public func making(
    _ draft: AssistantDraft, person: Set<AssistantPlace>, id: String = UUID().uuidString, now: Date = Date()
  ) -> Result<MakePlan, AssistantDraft.Problem> {
    guard profiles.count < Self.maxProfiles else { return .failure(.rosterFull) }
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let problem = AssistantDraft.nameProblem(name, team: self) { return .failure(problem) }
    let places = draft.places.intersection(person).subtracting([.connectedApps])
    let member = TeamProposal.Member(name: name, persona: draft.job ?? "", places: places, dropped: [], instructions: "")
    let scope = AssistantScope(destinations: places, instructions: TeamProposal.saved(member))
    let newID = profiles.contains(where: { $0.id == id }) ? UUID().uuidString : id
    let colour = AssistantColour.next(used: profiles.map(\.colour))
    let profile = RelayProfile(id: newID, name: name, createdAt: now, scope: scope, colour: colour)
    var team = self
    team.profiles.append(profile)
    let plan = MakePlan(team: team, profile: profile, face: AssistantFace(id: newID), job: draft.job)
    return .success(plan)
  }
}

// MARK: - Delete

/// What deleting one assistant ends, for its card (`sheet-destructive-confirm`), and the way back.
/// The shell pauses the routines, watches and links in `ends` (`pauseWork`), ends the open
/// hand-offs, applies `team` through `changeTeam` (its files go to relay/removed) and shows the
/// toast. Undo puts the roster back and turns on again what was on.
public struct DeletePlan: Equatable, Sendable {
  /// One thing the assistant owns that ends with it.
  public struct Item: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
      case routine, watch, link, handoff
      var one: String {
        switch self {
        case .routine: return "routine"
        case .watch: return "watch"
        case .link: return "link"
        case .handoff: return "open hand-off"
        }
      }
      var many: String {
        switch self {
        case .routine: return "routines"
        case .watch: return "watches"
        case .link: return "links"
        case .handoff: return "open hand-offs"
        }
      }
    }
    public var kind: Kind
    public var id: String
    /// The words the card shows for it, at most 80 characters.
    public var title: String
    /// It was on before the delete. Undo turns on only what was on. A hand-off is always open.
    public var on: Bool
    public init(kind: Kind, id: String, title: String, on: Bool = true) {
      self.kind = kind
      self.id = id
      self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
      self.on = on
    }
  }

  public enum Refusal: Error, Equatable, Sendable {
    case unknown
    /// The main assistant (`RelayTeam.mainProfileID`) never goes. It holds its name.
    case main(String)
    /// The assistant on screen cannot go; switch first. It holds its name.
    case active(String)

    public var words: String {
      switch self {
      case .unknown: return "There is no assistant with that name."
      case .main(let name): return "\(name) is your main assistant, so it cannot be deleted."
      case .active(let name): return "\(name) is the assistant on screen. Switch to another assistant first."
      }
    }
  }

  /// The inverse of the delete. `restoring` gives the roster back as it was before, with the names
  /// that assistants have now; nil when the roster changed since (undo newer changes first).
  public struct Undo: Equatable, Sendable {
    public var before: RelayTeam
    public var after: RelayTeam
    /// Routines, watches and links that were on: Undo turns them on again. Hand-offs do not
    /// start again, because the work they did stopped.
    public var resume: [Item]
    public func restoring(_ current: RelayTeam) -> RelayTeam? { current.undoing(before: before, after: after) }
  }

  public static let confirm = "Delete assistant"
  public static let keep = "Keep it"

  /// The assistant that goes, and where it stood in the roster.
  public var profile: RelayProfile
  public var index: Int
  /// The roster after the delete: without the assistant, and out of every team.
  public var team: RelayTeam
  /// What ends, in the card's order: routines, watches, links, then open hand-offs.
  public var ends: [Item]
  public var undo: Undo

  /// "Delete Old notes?"
  public var title: String { "Delete \(profile.name)?" }
  /// "Its chats stay in History. Its 1 routine ends. You can undo for 10 seconds."
  public var detail: String {
    let window = Int(UndoToken.removalWindow)
    let parts: [String?] = ["Its chats stay in History.", Self.endsSentence(ends), "You can undo for \(window) seconds."]
    return parts.compactMap { $0 }.joined(separator: " ")
  }
  /// The receipt after the delete: the line, the toast and a 10-second Undo for `entry`.
  public func receipt(entry: String, now: Date = Date()) -> Receipt {
    ReceiptCopy.deleted(name: profile.name, entry: entry, now: now)
  }

  /// "Its 1 routine ends." or "Its 2 routines, 1 watch and 1 open hand-off end."; nil for nothing.
  static func endsSentence(_ items: [Item]) -> String? {
    var phrases: [String] = []
    for kind in Item.Kind.allCases {
      let count = items.filter { $0.kind == kind }.count
      if count > 0 { phrases.append("\(count) \(count == 1 ? kind.one : kind.many)") }
    }
    guard let last = phrases.last else { return nil }
    var list = last
    if phrases.count > 1 {
      let head: String = phrases.dropLast().joined(separator: ", ")
      list = head + " and " + last
    }
    let verb = items.count == 1 ? "ends" : "end"
    return "Its \(list) \(verb)."
  }
}

extension RelayTeam {
  /// The plan to delete assistant `id`. `owned` lists its routines, watches, links and open
  /// hand-offs; a repeat of the same kind and id counts once. Refused for the main assistant, the
  /// assistant on screen and an id not on the roster.
  public func deleting(_ id: String, owned: [DeletePlan.Item]) -> Result<DeletePlan, DeletePlan.Refusal> {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return .failure(.unknown) }
    let profile = profiles[index]
    if id == mainProfileID { return .failure(.main(profile.name)) }
    if id == activeID { return .failure(.active(profile.name)) }
    guard let after = removing(id) else { return .failure(.unknown) }
    var seen = Set<String>()
    var unique: [DeletePlan.Item] = []
    for item in owned {
      guard seen.insert(item.kind.rawValue + "|" + item.id).inserted else { continue }
      unique.append(item)
    }
    let ends: [DeletePlan.Item] = DeletePlan.Item.Kind.allCases.flatMap { kind in unique.filter { $0.kind == kind } }
    let resume = ends.filter { $0.kind != .handoff && $0.on }
    let undo = DeletePlan.Undo(before: self, after: after, resume: resume)
    return .success(DeletePlan(profile: profile, index: index, team: after, ends: ends, undo: undo))
  }
}

// MARK: - Sections

/// The sections of the assistant list, from state only: "Needs you", "Working", then "Quiet".
/// The person never files an assistant. A drag sets a manual order, which wins inside a section.
/// While a drag is live the list holds still (`dragging` and `frozen`).
public enum AssistantSections {
  public enum Section: String, CaseIterable, Sendable {
    case needsYou, working, quiet
    public var title: String {
      switch self {
      case .needsYou: return "Needs you"
      case .working: return "Working"
      case .quiet: return "Quiet"
      }
    }
  }
  public struct Row: Equatable, Sendable {
    public var id: String
    public var status: SereinStatus
    public init(id: String, status: SereinStatus) {
      self.id = id
      self.status = status
    }
  }
  /// One section and its assistants in order. A section with nobody in it is left out.
  public struct Part: Equatable, Sendable {
    public var section: Section
    public var ids: [String]
    public init(section: Section, ids: [String]) {
      self.section = section
      self.ids = ids
    }
  }

  /// A card that waits is "Needs you"; a reply or a run is "Working"; all else is "Quiet".
  public static func section(for status: SereinStatus) -> Section {
    switch status {
    case .needsYou: return .needsYou
    case .replying, .working: return .working
    case .notConnected, .offline, .ready, .unread, .paused: return .quiet
    }
  }

  /// The list in sections. `rows` is in roster order (the order with no manual order). In a
  /// section, ids in `manualOrder` come first in that order, then the others in roster order.
  /// While `dragging`, `frozen` (what the list showed when the drag started) keeps every row in
  /// its section and place; a row new since goes last in its own section, and a row that left goes.
  public static func arrange(_ rows: [Row], manualOrder: [String] = [], dragging: Bool = false, frozen: [Part] = []) -> [Part] {
    var seen = Set<String>()
    let unique = rows.filter { seen.insert($0.id).inserted }
    if dragging && !frozen.isEmpty { return held(unique, frozen: frozen) }
    var manual: [String: Int] = [:]
    for (i, id) in manualOrder.enumerated() where manual[id] == nil { manual[id] = i }
    var roster: [String: Int] = [:]
    for (i, row) in unique.enumerated() { roster[row.id] = i }
    var parts: [Part] = []
    for kind in Section.allCases {
      let ids = unique.filter { Self.section(for: $0.status) == kind }.map(\.id)
      let ordered = ids.sorted { a, b in
        let ma = manual[a] ?? Int.max
        let mb = manual[b] ?? Int.max
        if ma != mb { return ma < mb }
        return (roster[a] ?? 0) < (roster[b] ?? 0)
      }
      if !ordered.isEmpty { parts.append(Part(section: kind, ids: ordered)) }
    }
    return parts
  }

  /// The manual order after a drop: `id` moves to `index` in its own section (counted without
  /// it), and the full order on screen becomes the manual order. A row never moves to another
  /// section, because state sets the section.
  public static func moving(_ id: String, to index: Int, in parts: [Part]) -> [String] {
    var parts = parts
    if let p = parts.firstIndex(where: { $0.ids.contains(id) }), let from = parts[p].ids.firstIndex(of: id) {
      parts[p].ids.remove(at: from)
      let at = min(max(index, 0), parts[p].ids.count)
      parts[p].ids.insert(id, at: at)
    }
    return parts.flatMap(\.ids)
  }

  static func held(_ rows: [Row], frozen: [Part]) -> [Part] {
    let live = Set(rows.map(\.id))
    var placed = Set<String>()
    var parts: [Part] = []
    for kind in Section.allCases {
      var ids: [String] = []
      for part in frozen where part.section == kind {
        for id in part.ids {
          guard live.contains(id), !placed.contains(id) else { continue }
          placed.insert(id)
          ids.append(id)
        }
      }
      parts.append(Part(section: kind, ids: ids))
    }
    for row in rows where !placed.contains(row.id) {
      let kind = Self.section(for: row.status)
      if let i = parts.firstIndex(where: { $0.section == kind }) { parts[i].ids.append(row.id) }
      placed.insert(row.id)
    }
    return parts.filter { !$0.ids.isEmpty }
  }
}

// MARK: - Quick replies

/// Tap-to-send replies at the end of an assistant's reply. The model ends a reply with one line
/// `CHIPS: a | b | c`; the shell shows the reply without that line and the chips under it. A chip
/// is model text: it shows as plain text, and a tap sends its words as the person's message.
public enum QuickReplies {
  public static let marker = "CHIPS:"
  public static let maxChips = 3
  public static let chipLimit = 24
  /// What the model reads about chips, for a turn that offers them.
  public static let instruction =
    "If short replies would help, end with one line: \(marker) first | second | third. At most \(maxChips), each at most \(chipLimit) characters of plain text."

  public struct Parsed: Equatable, Sendable {
    /// The reply without the chips line.
    public var text: String
    /// At most `maxChips`, each 1 to `chipLimit` characters of plain text, each once.
    public var chips: [String]
    public init(text: String, chips: [String]) {
      self.text = text
      self.chips = chips
    }
  }

  /// The reply and its chips. Only the last line that is not blank can be the chips line. A reply
  /// without one comes back unchanged with no chips. The chips line always goes, also when no
  /// chip in it is valid.
  public static func parse(_ reply: String) -> Parsed {
    let body = trimmedEnd(reply)
    let lineBreak = body.lastIndex(where: { $0.isNewline })
    let lineStart = lineBreak.map { body.index(after: $0) } ?? body.startIndex
    let line = body[lineStart...].trimmingCharacters(in: .whitespaces)
    guard line.lowercased().hasPrefix(marker.lowercased()) else { return Parsed(text: reply, chips: []) }
    let text = lineBreak.map { trimmedEnd(String(body[..<$0])) } ?? ""
    var chips: [String] = []
    var seen = Set<String>()
    for part in line.dropFirst(marker.count).split(separator: "|", omittingEmptySubsequences: false) {
      guard chips.count < maxChips else { break }
      let chip = unquoted(String(part))
      guard (1...chipLimit).contains(chip.count), plain(chip), seen.insert(chip.lowercased()).inserted else { continue }
      chips.append(chip)
    }
    return Parsed(text: text, chips: chips)
  }

  /// Characters that format or link in Markdown or HTML.
  static let markup = CharacterSet(charactersIn: "*_`[]<>#~\\|")
  /// One line, no hidden characters, no markup and no link.
  static func plain(_ chip: String) -> Bool {
    TeamProposal.oneLine(chip) && chip.rangeOfCharacter(from: markup) == nil && !chip.contains("://")
  }
  static func unquoted(_ raw: String) -> String {
    var chip = raw.trimmingCharacters(in: .whitespaces)
    let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]
    for (opening, closing) in pairs {
      if chip.count >= 2, chip.first == opening, chip.last == closing {
        chip = String(chip.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
      }
    }
    return chip
  }
  static func trimmedEnd(_ s: String) -> String {
    var end = s.endIndex
    while end > s.startIndex {
      let previous = s.index(before: end)
      guard s[previous].isWhitespace else { break }
      end = previous
    }
    return String(s[..<end])
  }
}

// MARK: - Name reading

/// A job guess from the name the person typed for a new assistant. A name with a common word
/// ("Inbox Zero", "Trip planner") gives one plain sentence; a name that says nothing ("Bob 3000")
/// gives nil, and the new assistant asks (`question`).
public enum NameReading {
  /// The first words of an assistant that cannot tell its job from its name.
  public static let question = "I cannot tell my job from my name. What should I do for you?"

  static let groups: [(words: [String], job: String)] = [
    (["inbox", "inboxes", "mail", "mails", "email", "emails", "mailbox"], "It sorts your mail and asks before it sends anything."),
    (["calendar", "calendars", "schedule", "schedules", "scheduler"], "It keeps your calendar and asks before it changes an event."),
    (["travel", "traveler", "traveller", "trip", "trips", "flight", "flights"], "It plans your trips and finds flights and places to stay."),
    (["fare", "fares"], "It watches fares and tells you when a price drops."),
    (["writer", "writers", "writing"], "It writes and edits drafts with you."),
    (["note", "notes", "notebook"], "It keeps your notes and finds them when you ask."),
    (["research", "researcher"], "It finds sources, reads them and gives you a short summary."),
    (["news"], "It reads the news and tells you the important parts."),
    (["finance", "finances", "budget", "budgets", "budgeting"], "It tracks your spending and budget and never moves money."),
    (["fitness"], "It plans your workouts and tracks your progress."),
    (["recipe", "recipes"], "It finds recipes and makes your shopping lists."),
    (["shopping", "shopper"], "It compares prices and asks before it buys anything."),
  ]
  static let table: [String: String] = {
    var table: [String: String] = [:]
    for group in groups {
      for word in group.words { table[word] = group.job }
    }
    return table
  }()

  /// The job for the first word of `name` that tells one, or nil.
  public static func job(for name: String) -> String? {
    for word in words(name) {
      if let job = table[word] { return job }
    }
    return nil
  }

  /// Lowercased words: letters only, split at other characters and where a capital follows a
  /// small letter ("InboxZero" is "inbox", "zero").
  static func words(_ name: String) -> [String] {
    var words: [String] = []
    var current = ""
    var previousLower = false
    for character in name {
      if character.isLetter {
        if character.isUppercase && previousLower && !current.isEmpty {
          words.append(current)
          current = ""
        }
        current.append(character)
        previousLower = character.isLowercase
      } else {
        if !current.isEmpty { words.append(current) }
        current = ""
        previousLower = false
      }
    }
    if !current.isEmpty { words.append(current) }
    return words.map { $0.lowercased() }
  }
}
