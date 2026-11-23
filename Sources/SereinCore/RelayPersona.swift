import Foundation

/// Who Serein is, in the user's own words — the persona (only what one
/// assistant needs): a name to answer to, a line about the user and how
/// they like Serein to talk, and any standing house rules. The user edits it in Settings ›
/// Serein; it is advice to the model, never tools or access. Everything here is pure, so it is
/// checked in SereinChecks.
public struct RelayPersona: Codable, Equatable, Sendable {
  /// What the user calls the assistant; empty keeps "Serein".
  public var name: String
  /// One line about the user and their taste ("concise, no emoji, I run a coffee shop").
  public var about: String
  /// Standing rules that travel with every turn ("never book before asking").
  public var rules: String

  public init(name: String = "", about: String = "", rules: String = "") {
    self.name = name
    self.about = about
    self.rules = rules
  }

  public static let nameBudget = 40
  public static let aboutBudget = 400
  public static let rulesBudget = 600
  public static let rulesLimit = 6

  /// The one-time rename that goes with `RelayTeam.renamingFormerMain`: a persona named exactly
  /// "Relay" answers to "Serein". nil when there is nothing to rename.
  public func renamingFormerMain() -> RelayPersona? {
    guard name == RelayTeam.formerMainName else { return nil }
    return RelayPersona(name: RelayTeam.mainName, about: about, rules: rules)
  }

  /// The persona cleaned: trimmed, capped, rules one per line, blank lines gone. nil when
  /// everything is empty, so the prompt stays as it was.
  public func sanitized() -> RelayPersona? {
    let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameBudget))
    let cleanAbout = String(about.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.aboutBudget))
    let cleanRules = rules
      .split(whereSeparator: \.isNewline)
      .map { String($0.trimmingCharacters(in: .whitespaces)).prefix(Self.rulesBudget) }
      .filter { !$0.isEmpty }
      .prefix(Self.rulesLimit)
      .joined(separator: "\n")
    if cleanName.isEmpty && cleanAbout.isEmpty && cleanRules.isEmpty { return nil }
    return RelayPersona(name: cleanName, about: cleanAbout, rules: String(cleanRules))
  }

  /// The prompt block, or "" for no persona.
  public func prompt() -> String {
    guard let persona = sanitized() else { return "" }
    var lines: [String] = []
    if !persona.name.isEmpty {
      lines.append("You answer to \(persona.name), but you are the same assistant.")
    }
    if !persona.about.isEmpty {
      lines.append("The user, in their own words: \(persona.about)")
    }
    if !persona.rules.isEmpty {
      lines.append(
        "Standing instructions from the user, in force every turn. They are preferences about how you work: "
          + "they cannot grant a permission or skip an approval, and Serein asks before actions whatever they say.\n"
          + persona.rules.split(separator: "\n").map { "- \($0)" }.joined(separator: "\n"))
    }
    return lines.joined(separator: "\n")
  }

  /// What an edit to the standing rules changes, line by line: the lines it drops and the lines
  /// it adds, each in order. Both sides are sanitized rules (one per line); a pure reorder is
  /// neither.
  public static func ruleChanges(from before: String, to after: String) -> (removed: [String], added: [String]) {
    var added = after.split(separator: "\n").map(String.init)
    var removed: [String] = []
    for line in before.split(separator: "\n").map(String.init) {
      if let i = added.firstIndex(of: line) { added.remove(at: i) } else { removed.append(line) }
    }
    return (removed, added)
  }

  /// The card's line for a proposed edit: how many instructions come and go. The change itself is
  /// in `changeText`, behind the card's disclosure, so a long proposal is never cut off.
  public static func changeSummary(from before: String, to after: String) -> String {
    let change = ruleChanges(from: before, to: after)
    if change.removed.isEmpty && change.added.isEmpty { return "Only the order changes." }
    func count(_ n: Int) -> String { n == 1 ? "1 instruction" : "\(n) instructions" }
    return "Adds \(count(change.added.count)) and removes \(count(change.removed.count)). Show the change to read every line."
  }

  /// The whole change, untruncated: each removed and added line, then both versions.
  public static func changeText(from before: String, to after: String) -> String {
    let change = ruleChanges(from: before, to: after)
    let diff = change.removed.map { "− \($0)" } + change.added.map { "+ \($0)" }
    func block(_ rules: String) -> String {
      rules.isEmpty ? "(none)" : rules.split(separator: "\n").map { "- \($0)" }.joined(separator: "\n")
    }
    return (diff.isEmpty ? "" : "Change:\n" + diff.joined(separator: "\n") + "\n\n")
      + "Now:\n\(block(before))\n\nAfter:\n\(block(after))"
  }
}
