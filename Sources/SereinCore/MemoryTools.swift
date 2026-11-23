import Foundation

/// The host's side of the memory tools (`remember`, `recall`, `forget`, `memory_share`): who a
/// share names, where a remembered fact came from, and who else knows something. Pure, so
/// `--verify-assistant-core` checks it. Record text stays data: nothing here reads it as an
/// instruction.
public enum MemoryTools {
  /// The words a share may use for every assistant.
  static let everyone: Set<String> = [
    "everyone", "everybody", "all", "all assistants", "every assistant", "all my assistants", "all of them",
  ]

  /// The words that keep a note to the assistant itself ("keep that to yourself").
  static let onlyYou: Set<String> = ["only you", "me", "you", "yourself", "only me", "just you", "private"]

  /// The scope `with` names: every assistant, one of the person's teams by its name ("Trip",
  /// "the Trip team"), or only `assistant` ("only you"). nil when it names none of them.
  public static func scope(with raw: String, in team: RelayTeam, assistant: String) -> MemoryScope? {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !key.isEmpty else { return nil }
    if everyone.contains(key) { return .person }
    if onlyYou.contains(key) { return .assistant(assistant) }
    let bare = key.hasPrefix("the ") ? String(key.dropFirst(4)) : key
    let name = bare.hasSuffix(" team") ? String(bare.dropLast(5)) : bare
    let group = team.teams.first { group in
      let own = group.name.lowercased()
      return own == name || own == bare
    }
    return group.map { MemoryScope.team($0.id) }
  }

  /// Who a scope reaches, for the receipt: "Every assistant", "The Trip team" or an assistant's
  /// name.
  public static func whom(_ scope: MemoryScope, in team: RelayTeam) -> String {
    switch scope {
    case .person: return "Every assistant"
    case .team(let id): return team.group(id).map { "The \($0.name) team" } ?? "That team"
    case .assistant(let id): return team.profiles.first { $0.id == id }?.name ?? "That assistant"
    }
  }

  /// Phrases by which the person's own message asks to keep something (SPEC 4.3). A `remember`
  /// in a turn whose message has none of them is the assistant's own idea: it waits, unreviewed,
  /// until the person keeps it. Seeing a note is not consent.
  static let rememberPhrases: [String] = [
    "remember", "note that", "make a note", "take a note", "keep in mind", "bear in mind", "don t forget",
    "do not forget", "never forget", "save that", "save this", "keep that", "keep this", "memorize", "write that down",
    "for future reference", "from now on",
  ]

  /// Whether the person's own words ask Serein to keep something.
  public static func asksToRemember(_ message: String) -> Bool {
    TypedConsent.contains(TypedConsent.normalized(message), any: rememberPhrases)
  }

  /// Words by which the person says yes to keeping an idea Serein offered (SPEC 4.3: the chip
  /// "Keep it" or a typed yes).
  static let keepPhrases: [String] = [
    "yes", "yeah", "yep", "keep it", "keep that", "keep this", "keep them", "keep both", "save it", "save that",
  ]
  /// Whether the person's own words say yes to keeping an idea: a yes or "keep it". Seeing an idea
  /// is not consent, and neither is the idea's own text; "what do you remember?" only shows ideas.
  public static func saysKeep(_ message: String) -> Bool {
    TypedConsent.contains(TypedConsent.normalized(message), any: keepPhrases)
  }
  /// The refusal when `remember` with `keep` comes without the person's yes.
  public static let keepNeedsYes = "Keep an idea only after the person says yes to it in their own words. Ask them first."

  /// Phrases by which the person's own message asks to see the memory journal. Tight on purpose:
  /// only a plain show, see or open. "What do you remember about Lisbon" is a question for recall,
  /// and a window that opens on a question would be a surprise.
  static let journalPhrases: [String] = [
    "memory journal", "open your memory", "open my memory", "open the memory", "show your memory", "show me your memory",
    "show my memory", "see your memory", "show me what you remember", "show what you remember", "see what you remember",
    "show me what you learned", "show me what you have learned", "see what you learned", "see what you have learned",
  ]
  /// Whether the person's own words ask to see what Serein remembers, as a list they can undo.
  public static func asksToSeeMemory(_ message: String) -> Bool {
    TypedConsent.contains(TypedConsent.normalized(message), any: journalPhrases)
  }

  /// The quote a note the person asked for keeps: `quote` when the person's message `said`
  /// holds those words (case and punctuation aside), else the message itself, so a personal fact
  /// always carries what the person really typed and never words a model made up. nil when the
  /// message is empty or secret-shaped.
  public static func verbatim(_ quote: String?, said: String) -> String? {
    let heard = TypedConsent.normalized(said)
    if let quote {
      let words = TypedConsent.normalized(quote)
      if words.count > 2, heard.contains(words) { return quote }
    }
    let own = said.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !own.isEmpty, AgentPrivacy.redact(own) == own else { return nil }
    return own
  }

  /// Other assistants with matching notes the reader cannot read (`MemoryStore.whoKnows`), by
  /// name, the most first: never the text. An owner that is no longer on the roster is left out.
  public static func whoKnows(_ counts: [String: Int], in team: RelayTeam) -> [(name: String, count: Int)] {
    var out: [(name: String, count: Int)] = []
    for profile in team.profiles {
      guard let count = counts[profile.id], count > 0 else { continue }
      out.append((name: profile.name, count: count))
    }
    return out.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
  }

  /// The records one turn's prompt carries (SPEC 4.7): those that match the request, best first.
  /// With fewer than `fillBelow` matches, at most `fillCount` of the newest notes shared with
  /// every assistant that the person said or kept fill the block. Each record once, at most
  /// `limit`.
  public static let fillBelow = 4
  public static let fillCount = 3
  public static func forTurn(topical: [MemoryRecord], newest: [MemoryRecord], limit: Int = MemoryPrompt.maxRecords)
    -> [MemoryRecord]
  {
    var seen = Set<String>()
    var out: [MemoryRecord] = []
    for record in topical where out.count < limit {
      guard seen.insert(record.id).inserted else { continue }
      out.append(record)
    }
    guard topical.count < fillBelow else { return out }
    var filled = 0
    for record in newest where out.count < limit && filled < fillCount {
      guard record.scope == .person, record.review != .unreviewed, !record.provenance.source.isLearned else { continue }
      guard seen.insert(record.id).inserted else { continue }
      out.append(record)
      filled += 1
    }
    return out
  }

  /// Whether any of `records` came from outside content: learned from a chat, or saved in a turn
  /// that read a page, a file or another app's result. A turn that reads one is outside too, so a
  /// note saved from it stays private (SPEC 4.4). Recall and the memory block both use this rule.
  public static func carriesOutside(_ records: [MemoryRecord]) -> Bool {
    records.contains { $0.provenance.source.isLearned || $0.outside }
  }
}

extension MemoryPrompt {
  /// The sentence after the header (SPEC G15).
  public static let notProof = "Say when an answer comes from memory. Memory is not proof of how things are now."
  /// A record the host has not used for this long is shown as possibly out of date (memory unit 6b).
  public static let staleAfter: TimeInterval = 90 * 86_400

  /// `render`, with the ids of the records that went in (for `MemoryStore.markRendered`): the
  /// header and `notProof`, each record after its label between the markers, a label suffix for a
  /// record unused for `staleAfter`, and, when `sealed` is above 0, one line in place of the
  /// records that hold personal data (SPEC G14). nil when nothing goes in.
  public static func renderKept(
    _ records: [MemoryRecord], names: [String: String] = [:], sealed: Int = 0, now: Date = Date(),
    budget: Int = MemoryPrompt.characterBudget
  ) -> (text: String, ids: [String])? {
    let lead = header + " " + notProof
    var blocks: [String] = []
    var ids: [String] = []
    var used = lead.count
    for record in records where record.enabled {
      if blocks.count == maxRecords { break }
      var heading = "[\(blocks.count + 1)] " + label(record, names: names)
      if now.timeIntervalSince(record.lastUsed ?? record.createdAt) >= staleAfter { heading += " It may be out of date." }
      let block = heading + "\n" + start + "\n" + defused(record.text) + "\n" + end
      let cost = block.count + 1
      if used + cost > budget { continue }
      blocks.append(block)
      ids.append(record.id)
      used += cost
    }
    var lines: [String] = []
    if !blocks.isEmpty { lines = [lead] + blocks }
    if sealed > 0 {
      lines.append("\(sealed) more note\(sealed == 1 ? " holds" : "s hold") personal data. Use recall to read them.")
    }
    guard !lines.isEmpty else { return nil }
    return (lines.joined(separator: "\n"), ids)
  }
}
