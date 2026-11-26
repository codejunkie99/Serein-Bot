import Foundation

/// Where words the person spoke from any app go (hold ⌥Space, Fn or their own key, speak, let go).
/// The person says only the task: no "@", and no name unless they want one.
/// - Words that ask for a new assistant go to the main assistant, which makes one
///   (`assistant_make`): "make me an assistant for my inbox".
/// - Words that open with an assistant's or a team's name reach it: "Scout find fares",
///   "hey Scout, find fares", "ask Scout to find fares", "tell the Trip team that dinner moved".
/// - A task that clearly fits one assistant's job goes to it (`fit`): "check my email for
///   invoices" reaches the assistant whose job is mail. Its name, its job and what it may use are
///   weighed, and only a clear winner takes the task.
/// - A stop ("stop", "stop everything": `RelayStop`) goes as said, and acts from the chat in
///   front. "Scout, stop" keeps Scout's name while a run is in Scout's own chat or is being handed
///   to it. That chat comes forward and the run ends there, unless the chats cannot change (always
///   so during a routine or a hand-over): then the stop acts from the chat in front. "Stop
///   everything" keeps no name.
/// - Anything else goes to the main assistant, which answers, hands the work to the assistant it
///   fits (`assistant_handoff`) or offers a new one. With Serein's chat in front, it stays with the
///   assistant on screen instead: the person is looking at who they talk to.
/// A route that reaches someone is the form a typed mention has ("@Name, words"), so the switch, a
/// busy assistant's refusal and a team's responder are `TeamMention`'s and `routeMention`'s,
/// unchanged. Only a stop is never refused: the bar sends it alone, from the chat in front.
/// Pure, so it is checked without a microphone.
public struct VoiceRoute: Equatable, Sendable {
  public enum Reason: String, Equatable, Sendable {
    /// The words named an assistant or a team.
    case named
    /// The task fits one assistant's job, and nobody was named.
    case fits
    /// The words asked for a new assistant.
    case newAssistant
    /// Nobody was named, from another app: the main assistant decides.
    case main
    /// Nobody was named, with the chat in front: the assistant on screen.
    case stays
  }
  /// What is sent: "@Name, words" when it reaches someone other than the assistant in front. The
  /// comma ends the name, so "@Scout, research fares" is never read as the longer "Scout Research".
  public var message: String
  /// The words alone, as the chat shows them.
  public var words: String
  /// Who gets them, by the roster's name; nil when the route changes nothing.
  public var to: String?
  /// Stable target for a named assistant, so a stop does not depend on switching chats.
  public var targetProfileID: String? = nil
  public var reason: Reason
  /// The words are a stop for the assistant they reach, so they start no turn there: the bar
  /// drops what the hold took.
  public var stop = false

  /// "Send what you say to the assistant it fits": on unless turned off.
  public static let settingKey = "serein.relay.voiceRouting"

  static let greetings: Set<String> = ["hey", "hi", "hello", "ok", "okay", "yo"]
  static let askVerbs: Set<String> = ["ask", "tell", "have", "message", "ping"]
  /// A request for a new assistant, from its first words: a verb or "I need" must lead, so
  /// "a bot keeps emailing me" is not one.
  static let newAssistantPatterns: [String] = [
    #"^(please\s+)?((can|could|would)\s+you\s+)?((make|create|set\s+up|add|build|start|hire)\s+(me\s+)?|i\s+(need|want)\s+|i['’]?d\s+like\s+)(a|an|another|one\s+more)\s+(new\s+)?(assistant|agent|bot)\b"#,
    #"^(a\s+)?new\s+(assistant|agent|bot)\b"#,
  ]

  /// `showing`: the hold took something from the screen. `running`: something runs or is starting
  /// in the chat in front or behind it, or a task its assistant started still works. `busy`: the
  /// other assistants with a run in their own chat now, or one being handed to it, by id. They say
  /// whether the words are a stop (`RelayStop.stops`), and whose.
  public static func plan(
    _ spoken: String, team: RelayTeam, chatInFront: Bool, showing: Bool, running: Bool, busy: Set<String>
  ) -> VoiceRoute {
    let text = oneLine(spoken)
    let stays = VoiceRoute(message: text, words: text, to: nil, reason: .stays)
    /// A stop with no name on it: it acts from the chat in front.
    func bare(_ words: String) -> VoiceRoute {
      VoiceRoute(message: words, words: words, to: nil, reason: .stays, stop: true)
    }
    // Nothing heard, or already a mention: `ask` reads it as typed.
    guard !text.isEmpty, !text.hasPrefix("@") else { return stays }
    if RelayStop.stops(text, overShown: showing, running: running) { return bare(text) }
    if asksForNewAssistant(text) { return toMain(text, team: team, reason: .newAssistant) }
    if let hit = addressed(text, team: team) {
      // A named reply-stop keeps its target even when that assistant is idle; a stop to an idle
      // assistant must never fall through to the reply in front. “Stop everything” stays global.
      let other = team.profiles.first { $0.name == hit.name && $0.id != team.activeID }
      let theirs = other.map { busy.contains($0.id) } ?? false
      let stop = RelayStop.stops(hit.words, overShown: showing, running: other == nil ? running : theirs)
      if stop, RelayStop.kind(hit.words) == .everything { return bare(hit.words) }
      if stop, other == nil { return bare(hit.words) }
      let message = hit.words.isEmpty ? "@" + hit.name : "@" + hit.name + ", " + hit.words
      return VoiceRoute(message: message, words: hit.words, to: hit.name, targetProfileID: other?.id,
                        reason: .named, stop: stop)
    }
    if let best = fit(text, team: team) {
      // Already in front: the words go as they are.
      guard best.id != team.activeID else { return VoiceRoute(message: text, words: text, to: best.name, reason: .fits) }
      return VoiceRoute(message: "@" + best.name + ", " + text, words: text, to: best.name, reason: .fits)
    }
    return chatInFront ? stays : toMain(text, team: team, reason: .main)
  }

  // MARK: which assistant a task fits

  /// Words that carry no task.
  static let stopWords: Set<String> = [
    "the", "and", "for", "with", "that", "this", "these", "those", "from", "into", "about", "what", "when", "where", "which",
    "who", "why", "how", "can", "could", "would", "should", "please", "you", "your", "mine", "our", "have", "has", "had",
    "are", "was", "were", "will", "its", "any", "all", "some", "just", "now", "then", "them", "they", "there", "here",
    "need", "want", "like", "get", "give", "make", "tell", "show", "let", "does", "did", "not", "but", "out", "one",
    "you're", "it's", "assistant", "serein",
  ]
  /// Words that mean the same kind of work, so "email" fits a job that says "mail".
  static let concepts: [String: String] = {
    let groups: [String: [String]] = [
      "mail": ["mail", "email", "e-mail", "inbox", "gmail", "outlook", "newsletter", "unread", "reply"],
      "calendar": ["calendar", "meeting", "schedule", "event", "appointment", "agenda", "availability", "invite"],
      "code": ["code", "repo", "repository", "bug", "commit", "branch", "deploy", "merge", "test", "build", "compile", "refactor"],
      "travel": ["flight", "fare", "hotel", "trip", "travel", "airline", "itinerary", "booking", "train"],
      "money": ["money", "budget", "expense", "invoice", "finance", "spending", "payment", "receipt", "tax", "bill"],
      "research": ["research", "investigate", "compare", "study", "paper", "source", "report"],
      "writing": ["write", "writing", "draft", "blog", "essay", "copy", "article", "edit", "proofread", "rewrite"],
      "social": ["social", "tweet", "twitter", "linkedin", "instagram", "post", "thread"],
      "shopping": ["shop", "shopping", "buy", "order", "price", "cart", "purchase"],
      "news": ["news", "headline", "briefing", "digest"],
      "notes": ["note", "notion", "doc", "document", "wiki"],
      "sales": ["lead", "prospect", "crm", "deal", "pipeline", "outreach", "customer"],
      "texts": ["imessage", "sms", "texts"],
      "contacts": ["contact", "phone", "address"],
    ]
    var map: [String: String] = [:]
    for (concept, words) in groups { for word in words { map[word] = concept } }
    return map
  }()
  /// What a place an assistant may use says about its work.
  static let placeConcepts: [AssistantPlace: String] = [
    .mail: "mail", .calendar: "calendar", .project: "code", .messages: "texts", .contacts: "contacts",
  ]

  /// The task's words as the scoring reads them: lower case, three letters or more, no stop
  /// words, plurals and "-ing" cut, each as its kind of work when it has one.
  public static func terms(_ text: String) -> Set<String> {
    var found = Set<String>()
    for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" }) {
      var word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "-'"))
      guard word.count >= 3, !stopWords.contains(word) else { continue }
      // A word that names its kind of work as it stands is read first: cutting "shopping" to
      // "shopp" or "news" to "new" would lose it.
      if let concept = concepts[word] {
        found.insert(concept)
        continue
      }
      if word.count > 6, word.hasSuffix("ing") { word = String(word.dropLast(3)) }
      if word.count > 4, word.hasSuffix("ies") { word = String(word.dropLast(3)) + "y" }
      else if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { word = String(word.dropLast()) }
      guard word.count >= 3, !stopWords.contains(word) else { continue }
      found.insert(concepts[word] ?? word)
    }
    return found
  }

  /// The kinds of work `concepts` names.
  static let kinds = Set(concepts.values)

  /// How well a task fits an assistant: 3 for each of the task's terms in its name; in its job, 2
  /// for a kind of work and 1 for any other word, so one plain word a job shares with the task
  /// ("find", "sort") is not a fit; 1 in its other instructions or in what it may use.
  static func score(_ task: Set<String>, _ profile: RelayProfile) -> Int {
    let parts = AssistantRoster.split(profile.scope?.instructions ?? "")
    let name = terms(profile.name), job = terms(parts.job ?? ""), rest = terms(parts.rest)
    let places = Set((profile.scope?.destinations ?? []).compactMap { placeConcepts[$0] })
    var total = 0
    for term in task {
      if name.contains(term) { total += 3 } else if job.contains(term) { total += kinds.contains(term) ? 2 : 1 } else if rest.contains(term) { total += 1 }
      if places.contains(term) { total += 1 }
    }
    return total
  }

  /// The one assistant the task clearly fits: not the main assistant (it takes everything else),
  /// not a paused one, with at least `fitFloor` and `fitLead` more than the next. nil is nobody.
  static let fitFloor = 2
  static let fitLead = 2
  public static func fit(_ text: String, team: RelayTeam) -> RelayProfile? {
    let task = terms(text)
    guard !task.isEmpty else { return nil }
    let main = team.mainProfileID
    let scored = team.profiles.filter { $0.id != main && !$0.isPaused }
      .map { (profile: $0, score: score(task, $0)) }
      .sorted { $0.score > $1.score }
    guard let best = scored.first, best.score >= fitFloor else { return nil }
    let next = scored.dropFirst().first?.score ?? 0
    return best.score - next >= fitLead ? best.profile : nil
  }

  /// To the main assistant: as a mention when another assistant is in front, else as it is.
  static func toMain(_ text: String, team: RelayTeam, reason: Reason) -> VoiceRoute {
    guard let id = team.mainProfileID, id != team.activeID, let main = team.profiles.first(where: { $0.id == id }),
      !main.name.isEmpty
    else { return VoiceRoute(message: text, words: text, to: nil, reason: reason) }
    return VoiceRoute(message: "@" + main.name + ", " + text, words: text, to: main.name, reason: reason)
  }

  static func asksForNewAssistant(_ text: String) -> Bool {
    newAssistantPatterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
  }

  /// The assistant or team the words open with, and the words after it.
  static func addressed(_ text: String, team: RelayTeam) -> (name: String, words: String)? {
    var rest = Substring(text)
    if let after = dropWord(rest, from: greetings) { rest = after }
    if let hit = leadingName(rest, team: team) { return (hit.name, tidy(hit.rest)) }
    guard let after = dropWord(rest, from: askVerbs) else { return nil }
    let named = dropWord(after, from: ["the"]) ?? after
    guard let hit = leadingName(named, team: team) else { return nil }
    let words = tidy(hit.rest)
    // "ask Scout to find fares" is "find fares"; "tell Scout that it moved" is "it moved".
    let cut = dropWord(Substring(words), from: ["to", "that"]).map { String($0) } ?? words
    return (hit.name, cut)
  }

  /// The longest roster name `text` opens with as whole words; an assistant wins a tie with a
  /// team, as in `TeamMention`. "Scout's report" names nobody.
  static func leadingName(_ text: Substring, team: RelayTeam) -> (name: String, rest: Substring)? {
    var candidates: [(name: String, team: Bool)] = team.profiles.map { ($0.name, false) }
    for group in team.groups ?? [] {
      candidates.append((group.name + " team", true))
      candidates.append((group.name, true))
    }
    let ordered = candidates.filter { !$0.name.isEmpty }.sorted { a, b in
      a.name.count != b.name.count ? a.name.count > b.name.count : (!a.team && b.team)
    }
    for candidate in ordered {
      guard let range = text.range(of: candidate.name, options: [.caseInsensitive, .anchored]) else { continue }
      if range.upperBound < text.endIndex {
        let next = text[range.upperBound]
        guard next.isWhitespace || next.isPunctuation, next != "'", next != "’" else { continue }
      }
      return (candidate.name, text[range.upperBound...])
    }
    return nil
  }

  /// `text` without its first word, when that word (commas aside) is one of `words`.
  static func dropWord(_ text: Substring, from words: Set<String>) -> Substring? {
    let trimmed = text.drop { $0.isWhitespace }
    let first = trimmed.prefix { !$0.isWhitespace }
    let bare = first.trimmingCharacters(in: .punctuationCharacters).lowercased()
    guard !bare.isEmpty, words.contains(bare) else { return nil }
    return trimmed.dropFirst(first.count).drop { $0.isWhitespace || $0 == "," }
  }

  static func tidy(_ text: Substring) -> String {
    String(text).trimmingCharacters(in: CharacterSet(charactersIn: ",:;.-–—").union(.whitespacesAndNewlines))
  }
  static func oneLine(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
  }
}
