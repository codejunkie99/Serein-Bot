import Foundation

// Pure rules for the person's own marks on the assistant list (SPEC.md 2.2, board 12): the pinned
// rows in pin order, the hidden rows, and the rows with a reply that is not read yet. The shell
// keeps the marks in relay/sidebar.json (read through `RelayStateFile`, so an unreadable file is
// never written over) and draws the list from `AssistantRowRules.layout`. Nothing here reads a
// file or a clock.

/// What the person set on the assistant list by hand.
public struct AssistantRowMarks: Codable, Equatable, Sendable {
  /// Profile ids, in pin order. Each id once.
  public var pinned: [String]
  public var hidden: Set<String>
  /// Assistants with a reply or a routine's result that the person has not seen.
  public var unread: Set<String>

  public init(pinned: [String] = [], hidden: Set<String> = [], unread: Set<String> = []) {
    self.pinned = pinned
    self.hidden = hidden
    self.unread = unread
  }

  enum CodingKeys: String, CodingKey { case pinned, hidden, unread }

  /// A key that is not there reads as empty, so an older file still loads.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pinned = try container.decodeIfPresent([String].self, forKey: .pinned) ?? []
    hidden = try container.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
    unread = try container.decodeIfPresent(Set<String>.self, forKey: .unread) ?? []
  }
}

public enum AssistantRowRules {
  /// Where the shell keeps the marks.
  public static let path = "relay/sidebar.json"

  // MARK: changes

  /// Pin: the row goes last in the pin order, and it shows again if it was hidden.
  public static func pinning(_ id: String, in marks: AssistantRowMarks) -> AssistantRowMarks {
    var next = marks
    if !next.pinned.contains(id) { next.pinned.append(id) }
    next.hidden.remove(id)
    return next
  }
  public static func unpinning(_ id: String, in marks: AssistantRowMarks) -> AssistantRowMarks {
    var next = marks
    next.pinned.removeAll { $0 == id }
    return next
  }
  /// The pins in a new order (a drag, or Move up and Move down). Ids that are not pinned are
  /// left out; pins that `order` does not name keep their place after the others.
  public static func ordering(pins order: [String], in marks: AssistantRowMarks) -> AssistantRowMarks {
    var seen = Set<String>()
    var pins: [String] = []
    for id in order where marks.pinned.contains(id) && seen.insert(id).inserted { pins.append(id) }
    for id in marks.pinned where seen.insert(id).inserted { pins.append(id) }
    var next = marks
    next.pinned = pins
    return next
  }
  /// The pin order after `id` moves one place up (−1) or down (+1); unchanged at either end.
  public static func movingPin(_ id: String, step: Int, in pins: [String]) -> [String] {
    guard step != 0, let index = pins.firstIndex(of: id) else { return pins }
    let target: Int = index + (step < 0 ? -1 : 1)
    guard pins.indices.contains(target) else { return pins }
    var next = pins
    next.swapAt(index, target)
    return next
  }
  /// Hide: the row leaves the list and its pin. The main assistant never hides.
  public static func hiding(_ id: String, main: String?, in marks: AssistantRowMarks) -> AssistantRowMarks {
    guard id != main else { return marks }
    var next = marks
    next.hidden.insert(id)
    next.pinned.removeAll { $0 == id }
    return next
  }
  public static func showing(_ id: String, in marks: AssistantRowMarks) -> AssistantRowMarks {
    var next = marks
    next.hidden.remove(id)
    return next
  }
  /// Mark as unread, or Mark as read (opening a chat marks it read).
  public static func marking(_ id: String, unread: Bool, in marks: AssistantRowMarks) -> AssistantRowMarks {
    var next = marks
    if unread { next.unread.insert(id) } else { next.unread.remove(id) }
    return next
  }
  /// A reply or a routine's result landed in `id`'s chat. It is unread only when that chat is not
  /// on screen; the chat on screen is read.
  public static func replyLanded(_ id: String, chatOnScreen: Bool, in marks: AssistantRowMarks) -> AssistantRowMarks {
    marking(id, unread: !chatOnScreen, in: marks)
  }
  /// Ids that are no longer on the roster leave every mark.
  public static func pruned(_ marks: AssistantRowMarks, roster: [String]) -> AssistantRowMarks {
    let live = Set(roster)
    return AssistantRowMarks(
      pinned: pinnedOrder(marks.pinned, roster: roster), hidden: marks.hidden.intersection(live),
      unread: marks.unread.intersection(live))
  }
  /// Marks set before the file was read, put on the marks in the file: the file's pins first.
  public static func merged(_ saved: AssistantRowMarks, _ early: AssistantRowMarks) -> AssistantRowMarks {
    var pins = saved.pinned
    for id in early.pinned where !pins.contains(id) { pins.append(id) }
    var hidden = saved.hidden.union(early.hidden)
    for id in pins { hidden.remove(id) }
    return AssistantRowMarks(pinned: pins, hidden: hidden, unread: saved.unread.union(early.unread))
  }

  // MARK: the list

  /// The pins that show, in pin order: on the roster, each once.
  public static func pinnedOrder(_ pinned: [String], roster: [String]) -> [String] {
    let live = Set(roster)
    var seen = Set<String>()
    return pinned.filter { live.contains($0) && seen.insert($0).inserted }
  }

  /// A hidden row still shows while it needs the person, while its chat is the one open, and
  /// while the person asked to see the hidden rows (`revealed`).
  public static func shows(_ id: String, hidden: Set<String>, needsYou: Bool, active: Bool, revealed: Bool) -> Bool {
    !hidden.contains(id) || needsYou || active || revealed
  }

  /// What the list shows, before the sections are made.
  public struct Layout: Equatable, Sendable {
    /// The main assistant's row, first and outside the sections; nil while it is pinned.
    public var main: String?
    /// The pinned rows, in pin order, under "Pinned".
    public var pinned: [String]
    /// Every other row that shows, in roster order, for `AssistantSections.arrange`.
    public var rest: [AssistantSections.Row]
    /// Hidden rows that are left out now (the "{N} hidden · Show" row counts them). Rows that
    /// show only because the person asked to see them still count.
    public var hiddenCount: Int

    public init(main: String?, pinned: [String], rest: [AssistantSections.Row], hiddenCount: Int) {
      self.main = main
      self.pinned = pinned
      self.rest = rest
      self.hiddenCount = hiddenCount
    }
  }

  /// The list from the roster and the marks. `rows` is every assistant but the main one, in roster
  /// order, with its state. The main assistant can be pinned, never hidden.
  public static func layout(
    main: String?, rows: [AssistantSections.Row], marks: AssistantRowMarks, active: String?, revealed: Bool
  ) -> Layout {
    var roster: [String] = rows.map(\.id)
    if let main { roster.insert(main, at: 0) }
    let pins: [String] = pinnedOrder(marks.pinned, roster: roster)
    let pinSet = Set(pins)
    var rest: [AssistantSections.Row] = []
    var leftOut = 0
    for row in rows where !pinSet.contains(row.id) {
      let needsYou: Bool = row.status == .needsYou
      let isActive: Bool = row.id == active
      let hiddenNow: Bool = marks.hidden.contains(row.id) && !needsYou && !isActive
      if hiddenNow { leftOut += 1 }
      if shows(row.id, hidden: marks.hidden, needsYou: needsYou, active: isActive, revealed: revealed) { rest.append(row) }
    }
    let mainRow: String? = main.flatMap { pinSet.contains($0) ? nil : $0 }
    return Layout(main: mainRow, pinned: pins, rest: rest, hiddenCount: leftOut)
  }

  /// The order ↑ ↓ and ⌥⌘↑ ⌥⌘↓ follow: the main row while it is not pinned, the pins, then the
  /// sections, each id once.
  public static func order(_ layout: Layout, parts: [AssistantSections.Part]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    let all: [String] = [layout.main].compactMap { $0 } + layout.pinned + parts.flatMap(\.ids)
    for id in all where seen.insert(id).inserted { out.append(id) }
    return out
  }

  /// The quiet last row: "2 hidden · Show".
  public static func hiddenWords(_ count: Int) -> String { "\(count) hidden · Show" }

  // MARK: Copy chat

  /// One message of a chat as Copy chat writes it.
  public struct ChatLine: Equatable, Sendable {
    /// Who said it ("You", the assistant's name); nil for a system line ("Asked Planner").
    public var who: String?
    public var words: String
    public init(who: String?, words: String) {
      self.who = who
      self.words = words
    }
  }
  /// The chat as plain text: "Name: words" for each message, a blank line between them. Empty
  /// messages are left out.
  public static func plainChat(_ lines: [ChatLine]) -> String {
    var parts: [String] = []
    for line in lines {
      let words: String = line.words.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !words.isEmpty else { continue }
      if let who = line.who, !who.isEmpty {
        parts.append(who + ": " + words)
      } else {
        parts.append(words)
      }
    }
    return parts.joined(separator: "\n\n")
  }

  // MARK: the name card

  /// "Use a name of 40 characters or fewer."
  public static let nameTooLong = "Use a name of \(RelayProfile.nameLimit) characters or fewer."
  /// What the name card says under the field, or nil: too long, then taken (the whole roster, in
  /// any case).
  public static func nameProblem(_ clean: String, roster: [String]) -> String? {
    if clean.count > RelayProfile.nameLimit { return nameTooLong }
    guard !clean.isEmpty, roster.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return nil }
    return "Another assistant is called \(clean)."
  }
}
