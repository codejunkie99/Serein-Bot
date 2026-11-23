import Foundation

// Pure rules for the face above the message bar and the composer's "+" list (board 17,
// NbQuick): the face shows the assistant whose chat runs now, and "+" opens one list of what the
// person can add to a message or go to. Here: the one running chat the face shows when several
// run, the words under the face, the filter and its order, the sections and which of them show,
// the recent chats, and the words a pick puts into the draft. Nothing here reads a file or a
// clock.

/// One chat that runs for an assistant now, or waits on the person: the active chat's turn, a
/// routine in its owner's chat, a hand-off the assistant works on, a task it started, or a card
/// that waits for an answer.
public struct RunningChat: Equatable, Sendable {
  public enum State: Equatable, Sendable { case working, needsYou }
  public var assistantID: String
  /// The assistant's name, as the person named it.
  public var name: String
  /// The chat to open; nil when there is none that may open (a hidden ask chat).
  public var chatID: String?
  /// The chat's title; nil when it must not show (`QuickFace.title`).
  public var title: String?
  public var state: State
  /// When it started, or when its card began to wait.
  public var since: Date

  public init(assistantID: String, name: String, chatID: String?, title: String?, state: State, since: Date) {
    self.assistantID = assistantID
    self.name = name
    self.chatID = chatID
    self.title = title
    self.state = state
    self.since = since
  }
}

/// The face above the message bar and its one line.
public enum QuickFace {
  /// The longest title the line keeps; a longer one ends in "…".
  public static let titleLimit = 60

  /// The one the face shows when several run: one that needs the person comes first, then the
  /// one that started last. Equal starts go by assistant id, then by chat id, so the face never
  /// changes between two on its own. nil when nothing runs.
  public static func now(_ running: [RunningChat]) -> RunningChat? {
    running.min(by: comesFirst)
  }
  /// `a` shows before `b`.
  static func comesFirst(_ a: RunningChat, _ b: RunningChat) -> Bool {
    let aWaits: Bool = a.state == .needsYou
    let bWaits: Bool = b.state == .needsYou
    if aWaits != bWaits { return aWaits }
    if a.since != b.since { return a.since > b.since }
    if a.assistantID != b.assistantID { return a.assistantID < b.assistantID }
    return (a.chatID ?? "") < (b.chatID ?? "")
  }

  /// A chat's title as the face may show it: none for a hidden ask chat, none when it is empty;
  /// one line of at most `titleLimit` characters.
  public static func title(_ raw: String?, chatID: String?, hidden: Set<String>) -> String? {
    if let chatID, hidden.contains(chatID) { return nil }
    guard let raw else { return nil }
    return AddListRules.oneLine(raw, limit: titleLimit)
  }

  /// The one line under the face: "Scout is working · Lisbon fares", "Scout is working" when no
  /// title may show, "Scout needs you"; nil at rest.
  public static func line(_ running: RunningChat?) -> String? {
    guard let running else { return nil }
    switch running.state {
    case .needsYou:
      return "\(running.name) needs you"
    case .working:
      guard let title = running.title else { return "\(running.name) is working" }
      return "\(running.name) is working · \(title)"
    }
  }

  /// What VoiceOver reads for the face, which opens the chat: "Scout is working on Lisbon fares.
  /// Open the chat." At rest it names the assistant whose chat opens.
  public static func spoken(_ running: RunningChat?, restName: String) -> String {
    guard let running else { return "\(restName). Open the chat." }
    switch running.state {
    case .needsYou:
      return "\(running.name) needs you. Open the chat."
    case .working:
      guard let title = running.title else { return "\(running.name) is working. Open the chat." }
      return "\(running.name) is working on \(title). Open the chat."
    }
  }

  /// The line shimmers only while the assistant works (and never under Reduce Motion, which the
  /// view decides).
  public static func shimmers(_ running: RunningChat?) -> Bool { running?.state == .working }

  /// The same one with its title left out: a bar that opened by itself, or a private window.
  public static func withoutTitle(_ running: RunningChat?) -> RunningChat? {
    guard var copy = running else { return nil }
    copy.title = nil
    return copy
  }
}

/// The sections of the "+" list, in the order they show.
public enum AddListSection: Int, CaseIterable, Sendable {
  /// Attach a file and Teach a skill, at the top with no heading.
  case actions
  case assistants
  case chats
  case apps
  case plugins
  /// Add an app…, at the foot with no heading.
  case more

  /// The heading over its rows; nil for the actions at the top and the row at the foot.
  public var heading: String? {
    switch self {
    case .actions, .more: return nil
    case .assistants: return "Assistants"
    case .chats: return "Chats"
    case .apps: return "Apps"
    case .plugins: return "Plugins"
    }
  }
}

/// One row of the "+" list: its kind, its title and one line.
public struct AddListRow: Equatable, Identifiable, Sendable {
  public enum Kind: Equatable, Sendable {
    case attach
    case teach
    /// An assistant, by profile id: picking it opens its chat.
    case assistant(String)
    /// A chat, by thread id: picking it opens it.
    case chat(String)
    /// An app by its slug. A connected one adds "with {App}" to the draft; one that is not
    /// connected offers Connect.
    case app(String, connected: Bool)
    /// A plugin by its id: picking it adds "with {Plugin}" to the draft.
    case plugin(String)
    case addApp
  }
  public var kind: Kind
  public var title: String
  /// The one line after the title.
  public var detail: String
  /// The green "Now" dot: an assistant that works, a chat that runs.
  public var now: Bool

  public init(kind: Kind, title: String, detail: String, now: Bool = false) {
    self.kind = kind
    self.title = title
    self.detail = detail
    self.now = now
  }

  public var section: AddListSection {
    switch kind {
    case .attach, .teach: return .actions
    case .assistant: return .assistants
    case .chat: return .chats
    case .app: return .apps
    case .plugin: return .plugins
    case .addApp: return .more
    }
  }

  public var id: String {
    switch kind {
    case .attach: return "attach"
    case .teach: return "teach"
    case .assistant(let profile): return "assistant:" + profile
    case .chat(let thread): return "chat:" + thread
    case .app(let slug, _): return "app:" + slug
    case .plugin(let plugin): return "plugin:" + plugin
    case .addApp: return "addApp"
    }
  }
}

/// The rows of one section that show.
public struct AddListGroup: Equatable, Sendable {
  public var section: AddListSection
  public var rows: [AddListRow]

  public init(section: AddListSection, rows: [AddListRow]) {
    self.section = section
    self.rows = rows
  }
}

/// A chat the list may offer: one of an assistant's chats, with its owner's name.
public struct AddListChat: Equatable, Sendable {
  public var id: String
  public var title: String
  public var ownerName: String
  public var date: Date
  public var running: Bool

  public init(id: String, title: String, ownerName: String, date: Date, running: Bool) {
    self.id = id
    self.title = title
    self.ownerName = ownerName
    self.date = date
    self.running = running
  }
}

public enum AddListRules {
  /// The most chats the list offers.
  public static let maxChats = 6
  /// The longest name a pick puts into the draft.
  public static let nameLimit = 40

  // MARK: opening by "@"

  /// The filter in a draft that is only "@" and one word ("@sc"): the list opens on it. nil for
  /// any other draft; an "@" later in the draft belongs to the Send to list.
  public static func atQuery(_ draft: String) -> String? {
    guard draft.first == "@" else { return nil }
    let word: Substring = draft.dropFirst()
    guard !word.contains(where: { $0.isWhitespace }), !word.contains("@") else { return nil }
    return String(word)
  }

  // MARK: the filter

  /// How well `text` matches `query`: 0 when it starts with it, 1 when one of its words does,
  /// 2 when it holds it elsewhere; nil when it does not hold it. Case and accents do not count.
  /// An empty query matches everything at 0.
  public static func rank(_ text: String, query: String) -> Int? {
    let wanted: String = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
    if wanted.isEmpty { return 0 }
    let folded: String = fold(text)
    if folded.hasPrefix(wanted) { return 0 }
    let words: [Substring] = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    if words.contains(where: { $0.hasPrefix(wanted) }) { return 1 }
    if folded.range(of: wanted) != nil { return 2 }
    return nil
  }
  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  /// The rows whose title matches `query`, in section order (Attach a file and Teach a skill,
  /// then Assistants, Chats, Apps and Plugins, then Add an app…). Inside a section the better
  /// matches come first and equal ones keep their order. A section with no row left is not shown.
  public static func groups(_ rows: [AddListRow], query: String) -> [AddListGroup] {
    var ranked: [(row: AddListRow, score: Int, order: Int)] = []
    for (order, row) in rows.enumerated() {
      guard let score = Self.rank(row.title, query: query) else { continue }
      ranked.append((row: row, score: score, order: order))
    }
    var groups: [AddListGroup] = []
    for section in AddListSection.allCases {
      let inSection = ranked.filter { $0.row.section == section }
      guard !inSection.isEmpty else { continue }
      let sorted = inSection.sorted { left, right in
        if left.score != right.score { return left.score < right.score }
        return left.order < right.order
      }
      groups.append(AddListGroup(section: section, rows: sorted.map { $0.row }))
    }
    return groups
  }

  /// Every row that shows, in the order the arrow keys move through them.
  public static func flat(_ groups: [AddListGroup]) -> [AddListRow] {
    groups.flatMap { $0.rows }
  }

  /// The line when nothing matches.
  public static func nothing(_ query: String) -> String { "Nothing called “\(query)”" }

  /// The row ↑ (-1) or ↓ (+1) moves to; it wraps at both ends.
  public static func moving(_ index: Int, by step: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let next: Int = (index + step) % count
    return next < 0 ? next + count : next
  }

  // MARK: what the list offers

  /// A hidden assistant is left out of the list unless it works or needs the person now.
  public static func listsAssistant(hidden: Bool, busy: Bool) -> Bool { !hidden || busy }

  /// The chats to offer: a running chat first, then the newest; each once; never a hidden ask
  /// chat or the chat on screen; at most `limit`.
  public static func recentChats(_ chats: [AddListChat], hidden: Set<String>, current: String?, limit: Int = maxChats)
    -> [AddListChat]
  {
    let sorted: [AddListChat] = chats.sorted { left, right in
      if left.running != right.running { return left.running }
      if left.date != right.date { return left.date > right.date }
      return left.id < right.id
    }
    var seen = Set<String>()
    var out: [AddListChat] = []
    for chat in sorted where !hidden.contains(chat.id) && chat.id != current {
      guard seen.insert(chat.id).inserted else { continue }
      out.append(chat)
      if out.count >= limit { break }
    }
    return out
  }

  /// When a chat last moved, for its line.
  public enum When: Equatable, Sendable { case today, yesterday, earlier }
  public static func when(_ date: Date, now: Date, calendar: Calendar) -> When {
    if calendar.isDate(date, inSameDayAs: now) { return .today }
    if let before = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: before) {
      return .yesterday
    }
    return .earlier
  }
  /// A chat row's line: "Scout · working", else "Inbox Zero · 8:02 AM" today, "Writer ·
  /// Yesterday", or "Writer · Oct 28". `time` and `day` are the date in the Mac's own format.
  public static func chatDetail(owner: String, running: Bool, when: When, time: String, day: String) -> String {
    if running { return owner + " · working" }
    switch when {
    case .today: return owner + " · " + time
    case .yesterday: return owner + " · Yesterday"
    case .earlier: return owner + " · " + day
    }
  }

  // MARK: what a pick does to the draft

  /// "with Gmail", "with Visualize": what picking an app or a plugin adds. It grants nothing.
  public static func withWords(_ name: String) -> String {
    let clean: String = oneLine(name, limit: nameLimit) ?? ""
    return "with " + clean
  }

  /// The draft after a pick that adds words: the "@word" that opened the list goes, the words go
  /// at the end after one space, and words already there are not added again. A space follows,
  /// so the person can type on.
  public static func adding(_ words: String, to draft: String) -> String {
    var base: String = clearing(draft)
    while base.last?.isWhitespace == true { base.removeLast() }
    if base.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return base + " " }
    return base.isEmpty ? words + " " : base + " " + words + " "
  }

  /// The draft after any other pick (a file, an assistant, a chat): only the "@word" that opened
  /// the list goes; other words stay in the bar.
  public static func clearing(_ draft: String) -> String { atQuery(draft) == nil ? draft : "" }

  /// One line without hidden characters, at most `limit` characters ("…" at the end when cut);
  /// empty text gives nil.
  public static func oneLine(_ raw: String, limit: Int) -> String? {
    let words: String = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    var kept = String.UnicodeScalarView()
    kept.append(contentsOf: words.unicodeScalars.filter { !SafeFileName.hidden($0) })
    let line: String = String(kept).trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty else { return nil }
    guard line.count > limit else { return line }
    return String(line.prefix(max(1, limit - 1))) + "…"
  }
}
