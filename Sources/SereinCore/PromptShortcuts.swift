import Foundation

/// A named prompt the person saved. Choosing `/name` in a composer puts `text` in the draft,
/// exactly; nothing is sent and nothing is allowed by expanding it.
public struct PromptShortcut: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var text: String
  public var created: Date
  public init(id: String = UUID().uuidString, name: String, text: String, created: Date = Date()) {
    self.id = id
    self.name = name
    self.text = text
    self.created = created
  }
}

/// The pure rules for prompt shortcuts: names, the saved list, expansion and the words that
/// make saving one ask first. The list lives in the Library's `shortcuts.json` (0600).
public enum PromptShortcuts {
  public static let path = "shortcuts.json"
  public static let nameLimit = 40
  public static let textLimit = 8000
  public static let countLimit = 200

  /// Serein's own commands, their aliases and every harness's commands, so `/name` means one
  /// thing in every composer.
  public static var reserved: Set<String> {
    Set(SlashCommands.shared.map(\.name)).union(SlashCommands.aliases.keys).union(["terminal"])
      .union(HarnessDriver.allCases.flatMap { SlashCommands.nativeCommands($0).map { $0.0 } })
  }

  /// "Weekly Report!" becomes "weekly-report": lowercase ASCII letters, digits, `_` and `-`.
  public static func normalized(_ name: String) -> String {
    let words = name.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber) || $0 == "_") }
    var out = String(words.joined(separator: "-").prefix(nameLimit))
    while out.hasSuffix("-") { out.removeLast() }
    return out
  }

  /// The name offered when a sent message is saved: its first words.
  public static func suggestedName(_ text: String) -> String {
    let name = normalized(text.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " "))
    return name.isEmpty || reserved.contains(name) ? "shortcut" : name
  }

  /// Why `name` and `text` cannot be saved among `list` (nil when they can). `replacing` is the
  /// id of the shortcut being changed.
  public static func problem(name: String, text: String, among list: [PromptShortcut], replacing id: String? = nil)
    -> String?
  {
    if name.isEmpty || name != normalized(name) { return "Give the shortcut a name of letters or numbers." }
    if reserved.contains(name) { return "/\(name) is already a command. Choose another name." }
    if list.contains(where: { $0.id != id && $0.name == name }) { return "Another shortcut is already /\(name)." }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "A shortcut needs some words." }
    if text.count > textLimit { return "A shortcut can hold up to \(textLimit) characters." }
    if !list.contains(where: { $0.id == id }), list.count >= countLimit {
      return "You have \(countLimit) shortcuts. Delete one first."
    }
    return nil
  }

  /// A loaded file keeps only valid, distinct entries, so a hand-edited file cannot make one
  /// `/name` mean two things or shadow a command.
  public static func sanitized(_ list: [PromptShortcut]) -> [PromptShortcut] {
    var kept: [PromptShortcut] = []
    for shortcut in list where kept.count < countLimit && !kept.contains(where: { $0.id == shortcut.id })
      && problem(name: shortcut.name, text: shortcut.text, among: kept) == nil
    {
      kept.append(shortcut)
    }
    return kept.sorted { $0.name < $1.name }
  }

  /// The words a draft of exactly `/name` stands for; nil for any other draft.
  public static func expansion(of draft: String, in list: [PromptShortcut]) -> String? {
    guard let call = SlashCommands.parse(draft.trimmingCharacters(in: .whitespacesAndNewlines)),
      call.arguments.isEmpty else { return nil }
    return list.first { $0.name == call.name }?.text
  }

  /// The slash menu's rows: the name and the first line of the words.
  public static func commands(_ list: [PromptShortcut]) -> [SlashCommand] {
    list.map { shortcut in
      let line = shortcut.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
      return SlashCommand(shortcut.name, String(line.trimmingCharacters(in: .whitespaces).prefix(80)), .shortcut)
    }
  }

  /// Words that ask Serein to set up later or repeating work (a schedule, a reminder, a watch,
  /// an alert) or a five-field cron. Conservative: a false match only adds a card.
  public static func startsStandingWork(_ text: String) -> Bool {
    let lower = text.lowercased()
    let patterns = [
      #"\bevery\b"#, #"\beveryday\b"#,
      #"\beach (day|morning|afternoon|evening|night|week|weekday|weekend|month|year|hour|minute|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
      #"\b(daily|weekly|hourly|nightly|monthly|yearly|weekdays)\b"#,
      #"\bremind"#, #"\bschedul"#, #"\brecurring\b"#, #"\brepeat"#,
      #"\bwatch"#, #"\bmonitor"#, #"\bkeep an eye on\b"#,
      #"\b(alert|notify|ping|text|email) me\b"#, #"\blet me know (when|if)\b"#, #"\bcron\b"#,
      #"\b(tomorrow|tonight|later today|this (morning|afternoon|evening)|next (week|month|year|monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b"#,
      #"\b\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.|o'?clock)(?![a-z])"#,
      #"\bat (\d{1,2}(:\d{2})?|noon|midnight)\b"#,
      #"\bin (a|an|one|two|three|a few|few|\d+) (minutes?|mins?|hours?|hrs?|days?|weeks?|months?)\b"#,
      #"\b(mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays|weekends|mornings|evenings|nights)\b"#,
      #"\b(once|twice|\d+ times) (a|an|per) (minute|hour|day|week|month|year)\b"#, #"\bper (hour|day|week|month)\b"#,
      #"\b(whenever|as soon as|check back|follow up)\b"#,
    ]
    if patterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) { return true }
    let tokens = lower.split(whereSeparator: \.isWhitespace).map(String.init)
    guard tokens.count >= 5 else { return false }
    return (0...(tokens.count - 5)).contains { RelayCron(parse: tokens[$0..<$0 + 5].joined(separator: " ")) != nil }
  }
}
