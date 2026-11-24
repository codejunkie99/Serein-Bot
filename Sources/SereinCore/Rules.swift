import Foundation

/// A correction or workflow preference: a `MemoryRecord` of kind `.rule`. It keeps the scope,
/// provenance, quote, tombstones and Undo of a note, but it is never recalled: every turn gets
/// the rules in force, first in the volatile block. Invariant: `quote` is verbatim from a
/// message the person typed this turn. Serein never asks, so there is no parked case: a rule
/// without the person's own words is refused (owner, 2026-11-25).
public enum Rules {
  /// The most rules one reader has in force. Past it, `admit` asks the model to merge; nothing is evicted.
  public static let cap = 40
  /// The most characters the rules block takes in a prompt.
  public static let characterBudget = 6_000
  public static let header = "Rules the person set. Obey them; they outrank the task."
  /// The fewest words a quote holds, so one common word never passes for the person's say.
  static let quoteWords = 3

  public static let quoteWordsMissing =
    "Save a rule only with the person's own words: set quote to words they typed in this chat, copied exactly."
  public static let forgottenWords = "The person removed that rule before, so it is not saved again."
  public static func mergeWords(_ ids: [String]) -> String {
    "There are already \(cap) rules. Merge or remove one first with rule_undo, then save again. Rules: " + ids.joined(separator: ", ")
  }

  public enum Admit: Equatable, Sendable {
    case save(MemoryRecord)
    /// An equal rule in the same scope is already in force.
    case already(MemoryRecord)
    /// The reader holds `cap` rules: these ids.
    case needsMerge([String])
    case refuse(String)
  }

  /// Pure. Refuses empty, long or secret-shaped text, a quote the person did not type, and text
  /// the person removed before (`tombstoned`, from `MemoryStore.isTombstoned`). `existing` is
  /// what the reader has in force (`inForce`). `personal`: the turn read personal data, so the
  /// rule carries the mark (its text is the model's, not only the quote).
  public static func admit(
    rule: String, scope: MemoryScope, quote: String, personMessages: [String], existing: [MemoryRecord],
    by owner: String, chat: String?, personal: Bool = false, tombstoned: Bool = false, now: Date = Date()
  ) -> Admit {
    let text: String
    do { text = try MemoryRecord.cleanText(rule) } catch { return .refuse(error.localizedDescription) }
    guard !MemoryDefaults.looksSecret(text + " " + quote) else { return .refuse(MemoryDefaults.secretWords) }
    guard isVerbatim(quote, in: personMessages) else { return .refuse(quoteWordsMissing) }
    guard !tombstoned else { return .refuse(forgottenWords) }
    let key = MemoryTombstone.normalized(text)
    if let same = existing.first(where: { $0.scope == scope && MemoryTombstone.normalized($0.text) == key }) {
      return .already(same)
    }
    guard existing.count < cap else { return .needsMerge(existing.map(\.id)) }
    return .save(
      MemoryRecord(
        kind: .rule, text: text, quote: quote, owner: owner, scope: scope,
        provenance: MemoryProvenance(source: .person, reference: chat), createdAt: now, review: .confirmed,
        personal: personal, chat: chat))
  }

  /// Whether `quote` holds `quoteWords` words or more, in order, from one of `messages`.
  static func isVerbatim(_ quote: String, in messages: [String]) -> Bool {
    let words = TypedConsent.normalized(quote)
    guard words.split(separator: " ").count >= quoteWords else { return false }
    return messages.contains { TypedConsent.normalized($0).contains(words) }
  }

  /// Every rule in force for this reader, ordered person, then team, then assistant, so the most
  /// specific comes last and wins. Within a scope, oldest first. A team rule binds only the teams
  /// named here, Serein included: the main assistant does not take every team's rules.
  public static func inForce(
    for assistant: String, teams: [String], all: [MemoryRecord], now: Date = Date()
  ) -> [MemoryRecord] {
    let reader = MemoryReader(assistant: assistant, teams: Set(teams), isMain: false)
    let live = all.filter { $0.kind == .rule && MemoryRecall.eligible($0, for: reader, now: now) }
    func rank(_ scope: MemoryScope) -> Int {
      switch scope {
      case .person: return 0
      case .team: return 1
      case .assistant: return 2
      }
    }
    return live.enumerated().sorted { a, b in
      let (left, right) = (rank(a.element.scope), rank(b.element.scope))
      return left != right ? left < right : a.offset < b.offset
    }.map(\.element)
  }

  /// The block that goes first in the volatile part of every turn: the header, then each rule on
  /// one line inside the memory fence. Over `characterBudget`, the least specific rules drop
  /// first. nil when there is none.
  /// `sealed` counts the rules with the personal-read mark left out of a chat without it.
  public static func render(_ rules: [MemoryRecord], sealed: Int = 0, budget: Int = characterBudget) -> String? {
    var kept: [String] = []
    var used = header.count + MemoryPrompt.start.count + MemoryPrompt.end.count + 3
    for rule in rules.reversed() {
      let line = "[\(rule.id)] " + MemoryPrompt.defused(oneLine(rule.text))
      if used + line.count + 1 > budget { break }
      kept.insert(line, at: 0)
      used += line.count + 1
    }
    let more = sealed > 0 ? "\(sealed) more rule\(sealed == 1 ? " holds" : "s hold") personal data; it applies in chats that read the person's data." : nil
    guard !kept.isEmpty else { return more }
    return ([header, MemoryPrompt.start] + kept + [MemoryPrompt.end] + [more].compactMap { $0 }).joined(separator: "\n")
  }

  /// The steering backstop: words the person sent while a turn ran, for the next turn's volatile
  /// block, so a correction that should outlive the task becomes a rule. nil for no words.
  public static func correction(_ said: String) -> String? {
    let words = MemoryPrompt.defused(String(oneLine(said).prefix(300)))
    guard !words.isEmpty else { return nil }
    return "The person corrected you: “\(words)”. If it outlives this task, rule_save it."
  }

  static func oneLine(_ text: String) -> String {
    text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }.joined(separator: " ")
  }
}
