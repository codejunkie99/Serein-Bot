import Foundation

/// R9: every value Serein filled from a secure card, kept in memory for the task's life, so that
/// `AgentPrivacy.redact` replaces exact matches in every tool result, transcript and log. Never
/// written anywhere: password values live only in the Keychain vault.
public final class FilledValues: @unchecked Sendable {
  public static let shared = FilledValues()
  /// Shorter values are kept only when all digits (a CVC), and scrubbed only where no digit touches
  /// them, so longer numbers stay.
  static let shortest = 4
  private let lock = NSLock()
  private var byTask: [String: Set<String>] = [:]

  public func add(_ value: String, task: String) {
    guard value.count >= Self.shortest || (!value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }) else { return }
    lock.withLock { _ = byTask[task, default: []].insert(value) }
  }
  public func scrub(_ text: String, task: String) -> String {
    Self.replace(text, lock.withLock { byTask[task] ?? [] })
  }
  /// Every task's values: the redactor does not know which task a text belongs to.
  public func scrubAll(_ text: String) -> String {
    Self.replace(text, lock.withLock { byTask.values.reduce(into: Set<String>()) { $0.formUnion($1) } })
  }
  /// Match registered values across consecutive numeric labels. Short all-digit values
  /// require label boundaries so a code can be split into fields without matching every
  /// longer number containing it. Longer values use the same substring rule as scrubAll.
  public func containsAcross(labels: [String], digits: [String]) -> Bool {
    let values = lock.withLock { byTask.values.reduce(into: Set<String>()) { $0.formUnion($1) } }
    guard !values.isEmpty else { return false }
    let forms = [labels.joined(), labels.joined(separator: " "), digits.joined()]
    if values.contains(where: { value in value.count >= Self.shortest && forms.contains(where: { $0.contains(value) }) }) {
      return true
    }
    let codes = values.filter { $0.count < Self.shortest }
    guard !codes.isEmpty else { return false }
    for start in digits.indices {
      var candidate = ""
      for fragment in digits[start...] {
        candidate.append(contentsOf: fragment)
        if candidate.count >= Self.shortest { break }
        if codes.contains(candidate) { return true }
      }
    }
    return false
  }

  public var hasValues: Bool { lock.withLock { !byTask.isEmpty } }
  /// Whether Serein filled any value in this task.
  public func has(task: String) -> Bool { lock.withLock { byTask[task]?.isEmpty == false } }
  public func forget(task: String) {
    lock.withLock {
      byTask[task] = nil
      for box in filledIn.keys { filledIn[box]?.remove(task) }
    }
  }
  /// Each box's last task Serein filled a value in: what was copied there may be that value, so
  /// another task pastes nothing in that box until its clipboard is cleared (ComputerHost.boxStep).
  private var boxes: [String: String] = [:]
  /// Each box's tasks that filled a value there.
  private var filledIn: [String: Set<String>] = [:]
  public func filled(box: String, task: String) {
    lock.withLock {
      boxes[box] = task
      filledIn[box, default: []].insert(task)
    }
  }
  /// Whether a picture of this box may show a value Serein filled: a task that filled one there
  /// still has its values, or the box's clipboard is owed a clear.
  public func shows(box: String) -> Bool {
    lock.withLock { boxes[box] != nil || (filledIn[box] ?? []).contains { byTask[$0]?.isEmpty == false } }
  }
  public func clipboardOwed(box: String, task: String) -> Bool { lock.withLock { boxes[box].map { $0 != task } ?? false } }
  public func clipboardCleared(box: String) { lock.withLock { boxes[box] = nil } }

  private static func replace(_ text: String, _ values: Set<String>) -> String {
    // Longest first, so a value inside another is not left as a stub.
    values.sorted { $0.count > $1.count }.reduce(text) { text, value in
      guard value.count < shortest else { return text.replacingOccurrences(of: value, with: AgentPrivacy.replacement) }
      let pattern = "(?<![0-9])" + NSRegularExpression.escapedPattern(for: value) + "(?![0-9])"
      return text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: AgentPrivacy.replacement),
                                       options: .regularExpression)
    }
  }
}
