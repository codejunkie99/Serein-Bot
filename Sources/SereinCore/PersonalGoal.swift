import Foundation

public struct PersonalGoal: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    case general, saving, training, learning
    public var symbol: String {
      switch self { case .general: return "flag"; case .saving: return "banknote"; case .training: return "figure.run"; case .learning: return "book" }
    }
  }
  public struct Step: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var done: Bool
    public init(title: String, id: String = UUID().uuidString, done: Bool = false) {
      self.id = id; self.title = TodoBoard.cleanTitle(title); self.done = done
    }
  }
  public struct Entry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var at: Date
    public var value: Double
    public var note: String?
  }
  public var kind: Kind
  public var steps: [Step]
  public var target: Double?
  public var current: Double
  public var unit: String
  public var entries: [Entry]
  public init(kind: Kind = .general, steps: [Step] = [], target: Double? = nil, current: Double = 0, unit: String = "") {
    self.kind = kind; self.steps = steps; self.target = target; self.current = current; self.unit = unit; entries = []
  }
  public var fraction: Double? {
    if let target, target > 0 { return min(1, max(0, current / target)) }
    return steps.isEmpty ? nil : Double(steps.filter(\.done).count) / Double(steps.count)
  }
  public var next: Step? { steps.first { !$0.done } }
  /// How far the recorded total is from the target. A goal with no target has none.
  public var remaining: Double? { target.map { max(0, $0 - current) } }
  /// The steps after the person edits them as text, one per line. A line that names an existing
  /// step keeps that step, so a finished step stays finished when the goal is edited. With the same
  /// number of lines as before, a reworded line keeps the step at its place.
  public func steps(editedTo text: String) -> [Step] {
    var old = steps
    // `isNewline` and not "\n": a pasted "\r\n" is one character and would join every step.
    let lines = text.split(whereSeparator: \.isNewline).map { Step(title: String($0)) }.filter { !$0.title.isEmpty }
    let kept = lines.map { line in old.firstIndex { $0.title == line.title }.map { old.remove(at: $0) } }
    return lines.indices.map { index in
      if let step = kept[index] { return step }
      guard lines.count == steps.count, old.contains(steps[index]) else { return lines[index] }
      return Step(title: lines[index].title, id: steps[index].id, done: steps[index].done)
    }
  }
  public var valid: Bool {
    current.isFinite && current >= 0 && (target.map { $0.isFinite && $0 > 0 } ?? true)
      && steps.count <= 30 && steps.allSatisfy { !$0.title.isEmpty && $0.title.count <= 200 }
      && Set(steps.map(\.id)).count == steps.count && unit.count <= 24
  }
  /// Absolute readings, rather than deltas: retrying the same observation cannot double-count it.
  public mutating func record(value: Double, note: String?, now: Date = Date()) -> Bool {
    guard value.isFinite, value >= 0 else { return false }
    let clean = TodoBoard.cleanNotes(note).map { String($0.prefix(300)) }
    if current == value, entries.last?.note == clean { return true }
    current = value
    entries.append(Entry(id: UUID().uuidString, at: now, value: value, note: clean))
    entries = Array(entries.suffix(200))
    return true
  }
}

public struct SavedSite: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var url: String?
  public var dashboard: DashboardSpec?
  public var goalID: String?
  public var updatedAt: Date
  public var personal: Bool?
  public init(id: String = UUID().uuidString, title: String, url: String? = nil, dashboard: DashboardSpec? = nil,
              goalID: String? = nil, updatedAt: Date = Date(), personal: Bool? = nil) {
    self.id = id; self.title = title; self.url = url; self.dashboard = dashboard
    self.goalID = goalID; self.updatedAt = updatedAt; self.personal = personal
  }
  public static func safeURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
    return url
  }
}

public enum MessageTimeline {
  /// Grok's dividers: before the first message, then after a pause of more than an hour.
  public static func startsGroup(_ date: Date?, after previous: Date?, calendar: Calendar = .current) -> Bool {
    guard let date else { return false }
    guard let previous else { return true }
    return !calendar.isDate(date, inSameDayAs: previous) || date.timeIntervalSince(previous) > 3600
  }
  /// "Today 9:02 AM", "Yesterday 11:24 PM", "Fri, Nov 6 3:56 PM", with the year when it is not this one.
  public static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    var time = Date.FormatStyle(date: .omitted, time: .shortened); time.timeZone = calendar.timeZone
    let clock = date.formatted(time)
    if calendar.isDate(date, inSameDayAs: now) { return "Today " + clock }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
      return "Yesterday " + clock
    }
    var day = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day(); day.timeZone = calendar.timeZone
    if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
    return date.formatted(day) + " " + clock
  }
}
