import Foundation

/// The finish notice: a small card in the screen's corner when a task, a bot's reply, a hand-off
/// or a swarm seat finishes. This decides which finishes show one and where a reply typed in it
/// goes (`Target`). The shell draws it and sends the reply (Serein/FinishNoticePanel.swift).
public struct FinishNotice: Identifiable, Equatable, Sendable {
  /// Where a reply typed in the notice goes. One card per target.
  public enum Target: Hashable, Sendable {
    /// A task: the reply is its next message (ComposerFlow.replyToTask).
    case task(thread: String)
    /// An assistant's Main chat: the reply is the person's next message there.
    case chat(assistant: String)
    /// A hand-off or swarm seat: the reply opens a side seat of its assistant, on its own model.
    case seat(handoff: String)
  }
  public var id: Target { target }
  public let target: Target
  /// The assistant whose face shows; nil shows the task mark.
  public var face: String?
  /// What was asked. Two lines, then truncated.
  public var title: String
  /// One line of what it did, or why it could not.
  public var summary: String
  /// The assistant or AI app that did it.
  public var who: String
  /// The folder, chat or seat it ran in.
  public var place: String?
  public var took: TimeInterval?
  public var failed: Bool
  public var at: Date
  /// The chat Open opens.
  public var opens: String

  public init(target: Target, face: String?, title: String, summary: String, who: String, place: String?,
              took: TimeInterval?, failed: Bool, at: Date, opens: String) {
    self.target = target
    self.face = face
    self.title = title
    self.summary = summary
    self.who = who
    self.place = place
    self.took = took
    self.failed = failed
    self.at = at
    self.opens = opens
  }

  /// A task that ended. Only done and stuck show; a waiting task keeps its system ask.
  public static func task(thread: String, title: String, outcome: RunRecord.Outcome, summary: String?, who: String,
                          place: String?, took: TimeInterval?, at: Date) -> FinishNotice? {
    guard outcome == .done || outcome == .stuck else { return nil }
    let failed = outcome == .stuck
    return FinishNotice(target: .task(thread: thread), face: nil, title: title,
                        summary: line(summary) ?? (failed ? "Open it to see what happened." : "Open it to see what it did."),
                        who: who, place: place, took: took, failed: failed, at: at, opens: thread)
  }

  /// A bot's reply to the bar, in its Main chat `thread`.
  public static func reply(assistant: String, thread: String, who: String, asked: String, summary: String?,
                           failed: Bool, at: Date) -> FinishNotice {
    FinishNotice(target: .chat(assistant: assistant), face: assistant, title: asked,
                 summary: line(summary) ?? (failed ? "It couldn't finish." : "Open it to see the reply."),
                 who: who, place: nil, took: nil, failed: failed, at: at, opens: thread)
  }

  /// A hand-off row that just closed. nil while it is open, when the person stopped it, and for a
  /// part of a chain (its parent reports for it). A swarm seat replies to itself, never to its
  /// lead: the two share an assistant and differ by row and model.
  public static func handoff(_ record: AssistantHandoff, who: String, place: String?, opens: String,
                             at: Date) -> FinishNotice? {
    guard record.state == .done || record.state == .failed, record.result != HandoffLedger.stoppedWords else { return nil }
    if record.parentID != nil, record.side != .swarm { return nil }
    let target: Target
    switch record.side {
    case .busy, .background, .swarmLead: target = .chat(assistant: record.to)
    case .swarm, nil: target = .seat(handoff: record.id)
    }
    let failed = record.state == .failed
    let took = record.startedAt.flatMap { start in record.finishedAt.map { $0.timeIntervalSince(start) } }
    return FinishNotice(target: target, face: record.to, title: record.task,
                        summary: line(record.result) ?? (failed ? "It couldn't finish." : "Done."),
                        who: who, place: place, took: took, failed: failed, at: at, opens: opens)
  }

  /// What a reply to a seat asks: the person's words, with what the seat answered before.
  public static func seatTask(words: String, earlier: String?) -> String {
    guard let earlier, line(earlier) != nil else { return words }
    return words + "\n\nWhat you answered before:\n" + String(earlier.suffix(1_500))
  }

  /// The first line with words on it.
  static func line(_ text: String?) -> String? {
    text?.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
  }
}

/// The cards on screen. One per target; at most `shown`, newest on top. Past that the oldest idle
/// card folds into "N more finished". A held card (hovered, focused or holding typed words) never
/// folds and never fades.
public struct FinishNoticeStack: Equatable, Sendable {
  public struct Entry: Identifiable, Equatable, Sendable {
    public var notice: FinishNotice
    public var shownAt: Date
    public var held = false
    public var id: FinishNotice.ID { notice.id }
  }
  public static let shown = 3
  /// How long an idle card stays.
  public static func life(voiceOver: Bool) -> TimeInterval { voiceOver ? 20 : 10 }
  public private(set) var notices: [Entry] = []
  /// Finishes folded into the "N more finished" line.
  public private(set) var more = 0
  public init() {}

  public mutating func add(_ notice: FinishNotice, now: Date) {
    // The same target again replaces its card where it is, so Return stays unambiguous and the
    // words typed there stay.
    if let i = notices.firstIndex(where: { $0.id == notice.id }) {
      notices[i].notice = notice
      notices[i].shownAt = now
      return
    }
    notices.insert(Entry(notice: notice, shownAt: now), at: 0)
    while notices.count > Self.shown, let i = notices.lastIndex(where: { !$0.held }) {
      notices.remove(at: i)
      more += 1
    }
  }
  /// A held card's life starts again when it is let go.
  public mutating func hold(_ id: FinishNotice.ID, _ held: Bool, now: Date) {
    guard let i = notices.firstIndex(where: { $0.id == id }) else { return }
    notices[i].held = held
    if !held { notices[i].shownAt = now }
  }
  public mutating func close(_ id: FinishNotice.ID) {
    notices.removeAll { $0.id == id }
    if notices.isEmpty { more = 0 }
  }
  /// The fold line was pressed (it opens Serein).
  public mutating func clearMore() { more = 0 }
  /// Idle cards past `life` go. True when something went.
  public mutating func expire(now: Date, life: TimeInterval) -> Bool {
    let before = notices.count
    notices.removeAll { !$0.held && now.timeIntervalSince($0.shownAt) >= life }
    if notices.isEmpty { more = 0 }
    return notices.count != before
  }
}
