import Foundation
import SereinCore

/// Rules in the app (harness v2 unit 1): `rule_save` keeps a correction the person typed, and
/// every turn of every kind gets the rules in force first in its context. A rule is a memory
/// record of kind `.rule`, so `forget` (and `rule_undo`) and the receipt's Undo remove it.
extension RelayOrchestrator {
  static let ruleTeamless =
    "This assistant is in no team the person has open. Save the rule for this assistant or for everyone."
  static let ruleScopeWords = "scope is assistant, team or everyone."

  /// The teams whose rules bind `profileID`: the ones it is in. Serein reads every team's notes,
  /// but it obeys only the teams it is in.
  func ruleTeams(_ profileID: String) -> [String] { team.groups(of: profileID).map(\.id) }

  /// The rules block for a turn of `profileID` in `thread` (`Rules.render`): first in
  /// `RelayPrompt.volatile` (`turnRules`), and at the top of a hand-off's or a speak-first prompt.
  /// A rule with the personal-read mark goes in only when `thread` has the mark too.
  func rulesBlock(profileID: String, thread: String) async -> String? {
    guard let memory = await memoryStore() else { return nil }
    let reader = memoryReader(profileID)
    guard let all = try? await memory.run({ (store: MemoryStore) -> [MemoryRecord] in try store.rules(reader: reader) })
    else { return nil }
    let rules = Rules.inForce(for: profileID, teams: ruleTeams(profileID), all: all)
    let marked = agent.readsPersonal(thread: thread)
    let shown = marked ? rules : rules.filter { !$0.personal }
    return Rules.render(shown, sealed: rules.count - shown.count)
  }

  /// `prompt` with the rules of `profileID` first, for a run that has no Relay volatile block.
  func withRules(_ prompt: String, profileID: String, thread: String) async -> String {
    guard let block = await rulesBlock(profileID: profileID, thread: thread) else { return prompt }
    return block + "\n\n" + prompt
  }

  /// What `rule_save` keeps: `text` in `scope` ("assistant", the default; "team", the team the
  /// person has open or this assistant's only team; "everyone"), saved at once when `quote` is
  /// the person's own words from this turn (`Rules.admit`). An equal rule is not saved twice.
  func saveRule(_ text: String, scope raw: String?, quote: String) async throws -> (record: MemoryRecord, receipt: Receipt?) {
    guard let memory = await memoryStore() else { throw SereinError.invalid(Self.memoryClosed) }
    if let why = SavedText.problem(text) { throw SereinError.invalid(why) }
    let owner = turnProfileID
    let scope: MemoryScope
    switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "", "assistant": scope = .assistant(owner)
    case "team":
      guard let group = ruleTeam(owner) else { throw SereinError.invalid(Self.ruleTeamless) }
      scope = .team(group.id)
    case "everyone": scope = .person
    default: throw SereinError.invalid(Self.ruleScopeWords)
    }
    let reader = memoryReader(owner)
    let teams = ruleTeams(owner)
    let said = [typedWords]
    let chat = turnThread
    let personal = memoryTurn(thread: chat).readPersonal
    let result = try await memory.run { (store: MemoryStore) -> (verdict: Rules.Admit, write: MemoryWrite?) in
      let existing = Rules.inForce(for: owner, teams: teams, all: try store.rules(reader: reader))
      let verdict = Rules.admit(
        rule: text, scope: scope, quote: quote, personMessages: said, existing: existing, by: owner, chat: chat,
        personal: personal, tombstoned: try store.isTombstoned(text))
      guard case .save(let record) = verdict else { return (verdict: verdict, write: nil) }
      return (verdict: verdict, write: try store.insert(record))
    }
    switch result.verdict {
    case .refuse(let why): throw SereinError.invalid(why)
    case .needsMerge(let ids): throw SereinError.invalid(Rules.mergeWords(ids))
    case .already(let same): return (record: same, receipt: nil)
    case .save(let record):
      guard case .done(let entry)? = result.write else {
        throw SereinError.invalid(result.write?.words ?? "I could not save that rule.")
      }
      let receipt = ReceiptCopy.ruleSet(whom: MemoryTools.whom(scope, in: team), entry: Self.memoryUndoPrefix + entry)
      noteReceipt(receipt)
      return (record: record, receipt: receipt)
    }
  }

  /// The team a team rule binds: the team the person has open when this assistant is in it, else
  /// its only team.
  private func ruleTeam(_ profileID: String) -> AssistantGroup? {
    let mine = team.groups(of: profileID)
    if let open = activeTeam, mine.contains(where: { $0.id == open.id }) { return open }
    return mine.count == 1 ? mine[0] : nil
  }

  /// Words the person sent while a turn ran in `thread`: the next turn there carries them as a
  /// correction (`Rules.correction`), once.
  func noteCorrection(_ words: String, thread: String) {
    guard let line = Rules.correction(words) else { return }
    corrections[thread] = line
  }
}
