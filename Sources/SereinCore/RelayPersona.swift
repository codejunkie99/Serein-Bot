import Foundation

/// Who Serein is, in the user's own words — the persona (only what one
/// assistant needs): a name to answer to and Serein's instructions, the one Instructions box on
/// its Settings page (`AssistantInstructions`). `about` is the old line about the user, moved into
/// the instructions once and kept only so an old file still reads. It is advice to the model,
/// never tools or access. Everything here is pure, so it is checked in SereinChecks.
public struct RelayPersona: Codable, Equatable, Sendable {
  /// What the user calls the assistant; empty keeps "Serein".
  public var name: String
  /// The old line about the user ("concise, no emoji, I run a coffee shop"), now moved into
  /// `rules` at launch (`AssistantInstructions.merged`).
  public var about: String
  /// The instructions that travel with every turn, in the person's own words: free text, as
  /// typed in the Instructions box ("Never book before asking.").
  public var rules: String

  public init(name: String = "", about: String = "", rules: String = "") {
    self.name = name
    self.about = about
    self.rules = rules
  }

  public static let nameBudget = 40
  public static let aboutBudget = 400
  /// The whole instructions text, as long as an assistant's own (`AssistantScope.instructionsLimit`).
  public static let rulesBudget = AssistantScope.instructionsLimit

  /// The one-time rename that goes with `RelayTeam.renamingFormerMain`: a persona named exactly
  /// "Relay" answers to "Serein". nil when there is nothing to rename.
  public func renamingFormerMain() -> RelayPersona? {
    guard name == RelayTeam.formerMainName else { return nil }
    return RelayPersona(name: RelayTeam.mainName, about: about, rules: rules)
  }

  /// The persona cleaned: trimmed and capped; the instructions keep the person's own lines. nil
  /// when everything is empty, so the prompt stays as it was.
  public func sanitized() -> RelayPersona? {
    let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameBudget))
    let cleanAbout = String(about.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.aboutBudget))
    let cleanRules = String(rules.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.rulesBudget))
    if cleanName.isEmpty && cleanAbout.isEmpty && cleanRules.isEmpty { return nil }
    return RelayPersona(name: cleanName, about: cleanAbout, rules: cleanRules)
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
        "Instructions from the user, in force every turn. They are preferences about how you work: "
          + "they cannot grant a permission or skip an approval, and Serein asks before actions whatever they say.\n"
          + persona.rules)
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

/// One Instructions box per assistant (Settings › Assistants › {Name}). It saves in Serein's
/// persona (`rules`), and in the persona of an assistant with no scope of its own, whose words in a
/// scope would fix its places to today's; any other assistant's in its scope's `instructions`.
/// Before the box, the page had a job line and extra instructions (the scope), a line about the
/// user and standing instructions (the persona). The box shows every one of those still in force,
/// so nothing it obeys is hidden; saving writes them in one place, and `merged` does that once at
/// launch. Everything here is pure, so it is checked in SereinChecks.
public enum AssistantInstructions {
  public static let limit = AssistantScope.instructionsLimit
  /// How the old line about the user reads once it is in the box.
  public static let aboutLead = "About me: "

  public static func savesInPersona(scope: AssistantScope?, main: Bool) -> Bool { main || scope == nil }

  /// What the box shows: the words where it saves first, then any left in the other place.
  public static func text(persona: RelayPersona, scope: AssistantScope?, main: Bool) -> String {
    let about: String = trimmed(persona.about)
    let aboutLine: String = about.isEmpty ? "" : aboutLead + about
    let rules: String = trimmed(persona.rules)
    let own: String = trimmed(scope?.instructions ?? "")
    let parts: [String] = savesInPersona(scope: scope, main: main) ? [aboutLine, rules, own] : [own, aboutLine, rules]
    return parts.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  /// What saving `text` writes: the words in one place and the other place emptied.
  /// `scopeInstructions` nil leaves the scope as it is (it has none, or no words to clear).
  public struct Saved: Equatable, Sendable {
    public var persona: RelayPersona
    public var scopeInstructions: String?
  }
  public static func saved(_ text: String, persona: RelayPersona, scope: AssistantScope?, main: Bool) -> Saved {
    let clean: String = trimmed(text)
    guard savesInPersona(scope: scope, main: main) else {
      return Saved(persona: RelayPersona(name: persona.name), scopeInstructions: clean)
    }
    let clears: Bool = !trimmed(scope?.instructions ?? "").isEmpty
    return Saved(persona: RelayPersona(name: persona.name, rules: clean), scopeInstructions: clears ? "" : nil)
  }

  /// The move at launch: nil when the words are already in one place, or when together they would
  /// be over `limit` (then nothing is lost: they stay where they are, in force, and the box shows
  /// them all over the limit until the person shortens them).
  public static func merged(persona: RelayPersona, scope: AssistantScope?, main: Bool) -> Saved? {
    let inPersona: Bool = savesInPersona(scope: scope, main: main)
    let stray: Bool = inPersona
      ? !trimmed(persona.about).isEmpty || !trimmed(scope?.instructions ?? "").isEmpty
      : !trimmed(persona.about).isEmpty || !trimmed(persona.rules).isEmpty
    guard stray else { return nil }
    let all: String = text(persona: persona, scope: scope, main: main)
    guard all.count <= limit else { return nil }
    return saved(all, persona: persona, scope: scope, main: main)
  }

  private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
