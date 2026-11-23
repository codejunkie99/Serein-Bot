import Foundation

/// What a key press in the composer does, from whether a step is running and the modifiers held.
public enum ComposerKey: Equatable, Sendable {
  case send, addToStep, interruptAndSend, newline, ignore

  /// Return sends. While a step runs, Return adds the message to it (`RunSteering.path` says
  /// how), Option-Return stops the step and sends now. Shift-Return always adds a line.
  public static func resolve(running: Bool, hasText: Bool, shift: Bool, option: Bool) -> ComposerKey {
    if shift { return .newline }
    guard hasText else { return .ignore }
    if !running { return .send }
    return option ? .interruptAndSend : .addToStep
  }
}

/// One message waiting for the running step to end.
public struct QueuedMessage: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var threadID: String
  public var text: String
  public var queuedAt: Date
  /// Plan mode as it was when the message was queued; nil (older files) means off.
  public var plan: Bool?
  public init(
    id: String = UUID().uuidString, threadID: String, text: String, queuedAt: Date = Date(),
    plan: Bool? = nil
  ) {
    self.id = id
    self.threadID = threadID
    self.text = text
    self.queuedAt = queuedAt
    self.plan = plan
  }
}

/// Messages queued behind a running step, kept per thread and sent in order.
public struct MessageQueue: Equatable, Sendable {
  public static let maxPerThread = 10
  public private(set) var items: [QueuedMessage] = []
  public init() {}

  public func items(for threadID: String) -> [QueuedMessage] {
    items.filter { $0.threadID == threadID }
  }
  /// Returns the queued message, or nil when the text is empty or the thread's queue is full.
  @discardableResult
  public mutating func enqueue(
    _ text: String, thread: String, at date: Date = Date(), plan: Bool? = nil
  ) -> QueuedMessage? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, items(for: thread).count < Self.maxPerThread else { return nil }
    let item = QueuedMessage(threadID: thread, text: trimmed, queuedAt: date, plan: plan)
    items.append(item)
    return item
  }
  public mutating func remove(_ id: String) { items.removeAll { $0.id == id } }
  public mutating func removeAll(thread: String) { items.removeAll { $0.threadID == thread } }
  /// The next message to send for a thread: the oldest queued, in the order it was added.
  public func next(for threadID: String) -> QueuedMessage? { items(for: threadID).first }
  public mutating func pop(for threadID: String) -> QueuedMessage? {
    guard let item = next(for: threadID) else { return nil }
    remove(item.id)
    return item
  }
  /// The waiting messages that go as one turn: oldest first, through the first that carries
  /// chips (`carriesContext`), so no two messages' chips ever ride one turn.
  public mutating func popBurst(for threadID: String, carriesContext: (QueuedMessage) -> Bool) -> [QueuedMessage] {
    var burst: [QueuedMessage] = []
    while let item = pop(for: threadID) {
      burst.append(item)
      if carriesContext(item) { break }
    }
    return burst
  }
  /// A card's answer (`ComposerFlow.deliver`): kept past the cap, since the person gave it once
  /// and it is never dropped.
  public mutating func keep(_ text: String, thread: String, at date: Date = Date()) {
    items.append(QueuedMessage(threadID: thread, text: text, queuedAt: date))
  }
  /// Words an engine took and never read go back ahead of the thread's waiting messages, in
  /// order. Past the cap too: they were sent once already and are never dropped.
  public mutating func requeue(_ texts: [String], thread: String, at date: Date = Date()) {
    let back = texts.map { QueuedMessage(threadID: thread, text: $0, queuedAt: date) }
    items.insert(contentsOf: back, at: items.firstIndex { $0.threadID == thread } ?? items.count)
  }
}

public enum QueuePolicy {
  /// A queue sends when the step ends normally. A stopped or failed step holds it, so the user
  /// decides whether the next message still makes sense.
  public static func shouldDrain(after outcome: RunRecord.Outcome?) -> Bool {
    switch outcome {
    case .done?, .waiting?, nil: return true
    case .stuck?, .stopped?, .running?: return false
    }
  }
}

public enum InterruptedFeedback {
  /// Frames a message sent with Option-Return, so the agent knows its last step was cut short.
  public static func wrap(_ text: String) -> String {
    "I stopped your last step before it finished. Drop it and do this instead:\n\n"
      + text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
