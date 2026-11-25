import Foundation

// The pure rules behind the assistant tools in Serein's chat: the roster as a tool reads it,
// changing or pausing one assistant, the proposals another assistant makes, the way back from a
// change, the apps to offer after a make, and the links one assistant owns. Nothing here writes
// a file, reads Keychain or grants a place. The shell (RelayAssistantTools.swift,
// RelayAsks.swift, RelayLinks.swift) applies each plan through `changeTeam`, after the
// admission rule (`Admission`) said apply or the person pressed a card's button.

// MARK: - The roster as a tool reads it

/// What `assistant_list` gives: each assistant's name, job and places. Never its notes, its
/// chats or anything it read.
public enum AssistantRoster {
  /// The line of saved instructions that holds the job (`TeamProposal.saved` writes it).
  public static let jobPrefix = "Who you are: "

  /// The job and the other instructions, from saved instructions.
  public static func split(_ instructions: String) -> (job: String?, rest: String) {
    var lines: [String] = instructions.components(separatedBy: "\n")
    guard let first = lines.first, first.hasPrefix(jobPrefix) else { return (nil, instructions) }
    lines.removeFirst()
    let job = String(first.dropFirst(jobPrefix.count)).trimmingCharacters(in: .whitespaces)
    let rest: String = lines.joined(separator: "\n")
    return (job.isEmpty ? nil : job, rest)
  }
  /// Saved instructions from a job and the other instructions, as `TeamProposal.saved` writes them.
  public static func joined(job: String?, rest: String) -> String {
    var parts: [String] = []
    if let job, !job.isEmpty { parts.append(jobPrefix + job) }
    if !rest.isEmpty { parts.append(rest) }
    return parts.joined(separator: "\n")
  }
  /// The job an assistant was made with or given; nil when nobody said it yet.
  public static func job(of profile: RelayProfile) -> String? {
    guard let scope = profile.scope else { return nil }
    return split(scope.instructions).job
  }

  public struct Entry: Equatable, Sendable {
    public var name: String
    public var job: String?
    /// What it may use now: its places that the person also allows.
    public var places: Set<AssistantPlace>
    public var main: Bool
    public var active: Bool
    public var paused: Bool
  }
  /// The roster in roster order. `person` is the person's own settings.
  public static func entries(_ team: RelayTeam, person: AssistantScope) -> [Entry] {
    team.profiles.map { profile in
      let scope = AssistantScope.effective(profile.scope, person: person)
      return Entry(
        name: profile.name, job: job(of: profile), places: scope.destinations, main: profile.id == team.mainProfileID,
        active: profile.id == team.activeID, paused: profile.isPaused)
    }
  }
  /// The tool's result: one small object per assistant.
  public static func listing(_ entries: [Entry]) -> [[String: Any]] {
    entries.map { entry in
      var out: [String: Any] = ["name": entry.name, "can_use": AssistantPlace.words(entry.places)]
      out["job"] = entry.job ?? "not told yet"
      if entry.main { out["main"] = true }
      if entry.active { out["this_chat"] = true }
      if entry.paused { out["paused"] = true }
      return out
    }
  }
}

// MARK: - Change one assistant

/// `assistant_change`, read and checked: a new name, job, instructions, places, how often it
/// speaks first, or a pause. A change that lets it use more (`widens`) asks on a card; every other
/// change applies from the person's own turn (`Admission.Change.ownChange`).
public struct AssistantChange: Equatable, Sendable {
  public enum Problem: Error, Equatable, Sendable {
    /// No assistant has this name.
    case unknown(String)
    case nothing
    case name(AssistantDraft.Problem)
    case jobTooLong
    case instructionsTooLong
    case notOneLine
    /// The main assistant cannot be paused. It holds its name.
    case pauseMain(String)
    /// No place in `can_use` is one the person allows.
    case noPlaces
    case speaksFirst

    public var words: String {
      switch self {
      case .unknown(let name): return "No assistant is called \(name). Check the name with assistant_list."
      case .nothing: return "That is how the assistant is already. Nothing changed."
      case .name(let problem): return problem.words
      case .jobTooLong: return "Say the job in one sentence of at most \(AssistantDraft.jobLimit) characters."
      case .instructionsTooLong: return "The instructions are too long. Keep them under \(AssistantScope.instructionsLimit) characters."
      case .notOneLine: return "A name and a job are one line of plain text."
      case .pauseMain:
        // SPEC 3.2: Serein answers for everyone, so it never pauses alone.
        return "I cannot pause, because I answer for everyone. Say “stop everything” to stop all work now."
      case .noPlaces: return "An assistant needs at least one place it can use that you allow."
      case .speaksFirst: return "speaks_first is never, sometimes, often or always."
      }
    }
  }

  /// The assistant that changes.
  public var id: String
  /// Its name before the change.
  public var name: String
  public var rename: String?
  /// A new job; "" clears it. nil: no change.
  public var job: String?
  /// New instructions after the job line; "" clears them. nil: no change.
  public var instructions: String?
  /// All the places it may use after the change; nil: no change.
  public var places: Set<AssistantPlace>?
  /// Words in `can_use` that name no place the person allows, as the card shows them.
  public var dropped: [String]
  public var speaksFirst: RelayProactive.Level?
  public var pause: Bool?
  /// Places it gets that it cannot use now.
  public var added: Set<AssistantPlace>
  /// It speaks first more often than now.
  public var speaksMore: Bool

  /// It may use more after the change: the person decides on a card.
  public var widens: Bool { !added.isEmpty || speaksMore }
  /// The admission rule's name for this change.
  public var admission: Admission.Change { widens ? .widen : .ownChange }
  /// It writes the words the assistant reads on every run, its unattended runs too: a new job or
  /// new instructions.
  public var rewritesWords: Bool { job != nil || instructions != nil }

  /// The admission rule's verdict for this change in `turn`. `wordsNameIt`: the person's own
  /// words name this assistant. A new job or new instructions apply at once only then; else the
  /// person decides on a card, so a page or a mail cannot write an assistant's instructions.
  public func verdict(turn: Admission.Turn, wordsNameIt: Bool) -> Admission.Verdict {
    let verdict = Admission.decide(admission, turn: turn, wordsNameIt: wordsNameIt)
    if verdict == .apply, rewritesWords, !wordsNameIt { return .ask }
    return verdict
  }

  /// Reads the tool's arguments (SPEC 5.1): `name` names who changes (`assistant` is read too);
  /// without it, the assistant that asks (`actingID`) changes. `rename` is the new name, `paused`
  /// (or `pause`) pauses or turns on. `person` is the person's own settings and `global` the level
  /// of Settings › Check-ins.
  public static func parse(
    _ a: [String: Any], actingID: String, team: RelayTeam, person: AssistantScope, global: RelayProactive.Level
  ) -> Result<AssistantChange, Problem> {
    let target: String = (a["name"] as? String) ?? (a["assistant"] as? String) ?? ""
    let named = AskPolicy.cleanName(target)
    let found: RelayProfile? = named.isEmpty
      ? team.profiles.first(where: { $0.id == actingID }) : team.profile(named: named)
    guard let profile = found else { return .failure(.unknown(String(named.prefix(40)))) }

    var rename: String?
    if let raw = a["rename"] as? String {
      let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if clean != profile.name {
        if let problem = nameProblem(clean, for: profile.id, team: team) { return .failure(.name(problem)) }
        rename = clean
      }
    }

    let parts = AssistantRoster.split(profile.scope?.instructions ?? "")
    var job: String?
    if let raw = a["job"] as? String {
      let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard clean.count <= AssistantDraft.jobLimit else { return .failure(.jobTooLong) }
      guard TeamProposal.oneLine(clean) else { return .failure(.notOneLine) }
      if clean != (parts.job ?? "") { job = clean }
    }
    var instructions: String?
    if let raw = a["instructions"] as? String {
      let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if clean != parts.rest { instructions = clean }
    }
    var newJob: String? = parts.job
    if let job { newJob = job.isEmpty ? nil : job }
    let text = AssistantRoster.joined(job: newJob, rest: instructions ?? parts.rest)
    guard text.count <= AssistantScope.instructionsLimit else { return .failure(.instructionsTooLong) }

    let current: Set<AssistantPlace> = AssistantScope.effective(profile.scope, person: person).destinations
    var places: Set<AssistantPlace>?
    var dropped: [String] = []
    if let raw = AssistantDraft.words(a["can_use"] ?? a["canUse"]) {
      var wanted = Set<AssistantPlace>()
      for word in raw {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { continue }
        let place = AssistantPlace.parse(clean)
        if let place, person.destinations.contains(place) {
          wanted.insert(place)
        } else {
          let shown = place?.label ?? String(clean.prefix(40))
          if !dropped.contains(shown) { dropped.append(shown) }
        }
      }
      guard !wanted.isEmpty else { return .failure(.noPlaces) }
      if wanted != current { places = wanted }
    }
    let after: Set<AssistantPlace> = places ?? current
    let added: Set<AssistantPlace> = after.subtracting(current)

    let level = RelayProactive.level(of: profile, in: team, global: global)
    var speaksFirst: RelayProactive.Level?
    if let raw = a["speaks_first"] as? String {
      guard let wanted = Self.level(raw) else { return .failure(.speaksFirst) }
      if wanted != level { speaksFirst = wanted }
    }
    let speaksMore: Bool = speaksFirst.map { $0.dailyTurns > level.dailyTurns } ?? false

    var pause: Bool?
    if let raw = (a["paused"] as? Bool) ?? (a["pause"] as? Bool) {
      if raw, profile.id == team.mainProfileID { return .failure(.pauseMain(profile.name)) }
      if raw != profile.isPaused { pause = raw }
    }

    let changes: [Bool] = [rename != nil, job != nil, instructions != nil, places != nil, speaksFirst != nil, pause != nil]
    guard changes.contains(true) else { return .failure(.nothing) }
    let change = AssistantChange(
      id: profile.id, name: profile.name, rename: rename, job: job, instructions: instructions, places: places,
      dropped: dropped, speaksFirst: speaksFirst, pause: pause, added: added, speaksMore: speaksMore)
    return .success(change)
  }

  /// The roster after the change; nil when the assistant is gone, a new name is taken by now, or
  /// nothing would change. Places are checked again against `person`, since a card can wait.
  public func applied(to team: RelayTeam, person: AssistantScope) -> RelayTeam? {
    guard let i = team.profiles.firstIndex(where: { $0.id == id }) else { return nil }
    var next = team
    var profile = next.profiles[i]
    if let rename {
      if Self.nameProblem(rename, for: id, team: team) != nil { return nil }
      profile.name = rename
    }
    if job != nil || instructions != nil || places != nil {
      // An assistant with no scope of its own uses the person's settings; every place stands for
      // that, so a new job alone does not narrow it.
      let old: AssistantScope = profile.scope ?? AssistantScope(destinations: Set(AssistantPlace.allCases))
      let parts = AssistantRoster.split(old.instructions)
      var newJob: String? = parts.job
      if let job { newJob = job.isEmpty ? nil : job }
      let text = AssistantRoster.joined(job: newJob, rest: instructions ?? parts.rest)
      guard text.count <= AssistantScope.instructionsLimit else { return nil }
      var destinations: Set<AssistantPlace> = old.destinations
      if let places {
        destinations = places.intersection(person.destinations)
        if destinations.isEmpty { return nil }
      }
      profile.scope = AssistantScope(
        destinations: destinations, neverSites: old.neverSites, instructions: text, apps: old.apps)
    }
    if let speaksFirst { profile.speaksFirst = speaksFirst }
    if let pause { profile.paused = pause ? true : nil }
    next.profiles[i] = profile
    return next == team ? nil : next
  }

  /// The words after "Done. <Name> " in the receipt, without the full stop: "is paused",
  /// "has a new job and can use Web now". Several changes read as "has 3 changes".
  public var receiptPhrase: String {
    var parts: [String] = []
    if let pause { parts.append(pause ? "is paused" : "is on again") }
    if rename != nil { parts.append("is the new name for \(AskPolicy.oneLine(name))") }
    if let places { parts.append("can use \(AssistantPlace.words(places)) now") }
    if job != nil { parts.append("has a new job") }
    if instructions != nil { parts.append("has new instructions") }
    if let speaksFirst { parts.append("speaks first \(speaksFirst.title.lowercased()) now") }
    if parts.count > 2 { return "has \(parts.count) changes" }
    return parts.joined(separator: " and ")
  }
  /// The name the receipt starts with: the new name after a rename.
  public var shownName: String { rename ?? name }

  /// The card for a change that lets the assistant use more (`sheet-permission`).
  /// "Let Planner use your calendar?" (SPEC 2.7); "Let Scout speak first more often?" when only
  /// that changes.
  public var cardTitle: String {
    let who = AskPolicy.oneLine(name)
    if !widens, rewritesWords { return "Change how \(who) works?" }
    guard !added.isEmpty else { return "Let \(who) speak first more often?" }
    let phrases: [String] = AssistantPlace.allCases.filter { added.contains($0) }.map(\.phrase)
    return "Let \(who) use \(AskPolicy.list(phrases))?"
  }
  public var cardDetail: String {
    var lines: [String] = []
    if let job { lines.append(job.isEmpty ? "Its job line goes." : "New job: " + Self.flat(job, limit: 160)) }
    if let instructions {
      lines.append(instructions.isEmpty ? "Its instructions go." : "New instructions: " + Self.flat(instructions, limit: 240))
    }
    if speaksMore, let speaksFirst { lines.append("It speaks first \(speaksFirst.title.lowercased()).") }
    if let places { lines.append("After this it can use: \(AssistantPlace.words(places)).") }
    if !dropped.isEmpty { lines.append("Left out, because you do not allow it: \(dropped.joined(separator: ", ")).") }
    lines.append("Changes always ask you first.")
    return lines.joined(separator: "\n")
  }
  public static let allow = "Allow"
  public static let keep = "Not now"
  /// `text` on one line, cut to `limit` characters with "…", for the card.
  static func flat(_ text: String, limit: Int) -> String {
    let line: String = text.components(separatedBy: .newlines).joined(separator: " ")
    guard line.count > limit else { return line }
    return String(line.prefix(limit - 1)) + "…"
  }

  /// nil when `name` (trimmed) can be the name of assistant `id`: one line, 1 to 40 characters,
  /// and no other assistant has it in any case.
  static func nameProblem(_ name: String, for id: String, team: RelayTeam) -> AssistantDraft.Problem? {
    if name.isEmpty { return .noName }
    if name.count > AssistantDraft.nameLimit { return .nameTooLong }
    if !TeamProposal.oneLine(name) { return .notOneLine }
    if let other = team.profile(named: name), other.id != id { return .nameTaken(other.name) }
    return nil
  }
  /// A level from a person's or model's word: never, sometimes, often, always, or the stored names.
  static func level(_ raw: String) -> RelayProactive.Level? {
    let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch word {
    case "never", "off", "none", "no": return .off
    case "sometimes", "light", "some": return .light
    case "often", "jarvis", "a lot": return .jarvis
    case "always", "all the time", "constantly": return .always
    default: return RelayProactive.Level(rawValue: word)
    }
  }
}

extension RelayTeam {
  /// An undo of one change to an assistant (`undoing`), with the names put back too: `undoing`
  /// keeps the names assistants have now, so an undo of a rename alone sets the name before the
  /// change, while nobody renamed it since and no other assistant has that name. nil when the
  /// roster changed since (undo newer changes first).
  public func undoingChange(before: RelayTeam, after: RelayTeam) -> RelayTeam? {
    guard var restored = undoing(before: before, after: after) else { return nil }
    for i in restored.profiles.indices {
      let id = restored.profiles[i].id
      guard let old = before.profiles.first(where: { $0.id == id })?.name,
        let set = after.profiles.first(where: { $0.id == id })?.name, old != set,
        restored.profiles[i].name == set
      else { continue }
      let taken = restored.profiles.contains { $0.id != id && $0.name.caseInsensitiveCompare(old) == .orderedSame }
      if !taken { restored.profiles[i].name = old }
    }
    return restored
  }
}

// MARK: - Work Serein pauses for an assistant

/// One routine, watch or link of an assistant that Serein paused when the assistant was paused
/// or deleted. Turning the assistant on again (or Undo) turns on only these, so a routine the
/// person paused by hand stays paused.
public struct HeldWork: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable { case routine, watch, link }
  public var kind: Kind
  public var id: String
  public init(kind: Kind, id: String) {
    self.kind = kind
    self.id = id
  }
  /// The items of a delete plan that were on: hand-offs are not held, since their work stopped.
  public static func from(_ items: [DeletePlan.Item]) -> [HeldWork] {
    items.compactMap { item -> HeldWork? in
      guard item.on else { return nil }
      switch item.kind {
      case .routine: return HeldWork(kind: .routine, id: item.id)
      case .watch: return HeldWork(kind: .watch, id: item.id)
      case .link: return HeldWork(kind: .link, id: item.id)
      case .handoff: return nil
      }
    }
  }
}

// MARK: - Proposals from an assistant

/// New assistants that another assistant proposed (`assistant_make` in a turn the person did not
/// start). Each waits for the person's card in the root chat: Make it, or Not now. Not now blocks
/// that name for `blockDays` days. Each assistant has at most `maxOpenPerAssistant` open.
/// Kept in relay/make-proposals.json.
public struct MakeProposals: Codable, Equatable, Sendable {
  public struct Proposal: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// The assistant that proposed it.
    public var by: String
    public var name: String
    public var job: String?
    public var places: [AssistantPlace]
    public var createdAt: Date
    public init(id: String = UUID().uuidString, by: String, draft: AssistantDraft, createdAt: Date = Date()) {
      self.id = id
      self.by = by
      name = draft.name
      job = draft.job
      places = AssistantPlace.allCases.filter { draft.places.contains($0) }
      self.createdAt = createdAt
    }
    /// The draft the card makes on Make it. `RelayTeam.making` checks it again.
    public var draft: AssistantDraft { AssistantDraft(name: name, job: job, places: Set(places)) }
  }

  public enum Refusal: Error, Equatable, Sendable {
    /// The proposer has two open already. It holds the proposer's name.
    case tooMany(String)
    /// The person said Not now to this name. It holds the name and the days left.
    case blocked(String, days: Int)
    /// A proposal for this name waits already.
    case waiting(String)

    public var words: String {
      switch self {
      case .tooMany(let name):
        return "\(name) already waits for the person to decide on \(MakeProposals.maxOpenPerAssistant) new assistants. Wait until they decide."
      case .blocked(let name, let days):
        return "The person said not now to \(name). Do not propose it again for \(days) day\(days == 1 ? "" : "s")."
      case .waiting(let name): return "A proposal for \(name) already waits for the person."
      }
    }
  }

  public static let maxOpenPerAssistant = 2
  public static let blockDays = 7
  public static let confirm = "Make it"
  public static let notNow = "Not now"

  public var open: [Proposal]
  /// Names the person turned down, by `key`, with the time they may come back.
  public var blocked: [String: Date]

  public init(open: [Proposal] = [], blocked: [String: Date] = [:]) {
    self.open = open
    self.blocked = blocked
  }

  /// Why `by` cannot propose `name` now, or nil.
  public func refusal(by: String, byName: String, name: String, now: Date) -> Refusal? {
    let key = Self.key(name)
    // Not now blocks the name for the assistant that asked (SPEC 2.5).
    if let until = blocked[Self.blockKey(by: by, name: name)], until > now {
      let days = max(1, Int((until.timeIntervalSince(now) / 86_400).rounded(.up)))
      return .blocked(String(name.prefix(40)), days: days)
    }
    if open.contains(where: { Self.key($0.name) == key }) { return .waiting(String(name.prefix(40))) }
    if open.filter({ $0.by == by }).count >= Self.maxOpenPerAssistant { return .tooMany(String(byName.prefix(40))) }
    return nil
  }
  /// Adds a proposal; the refusal when it cannot wait now.
  public mutating func add(_ proposal: Proposal, byName: String, now: Date) -> Refusal? {
    trim(now: now)
    if let refusal = refusal(by: proposal.by, byName: byName, name: proposal.name, now: now) { return refusal }
    open.append(proposal)
    return nil
  }
  /// Not now: the proposal goes and its name is blocked for `blockDays` days.
  @discardableResult public mutating func decline(_ id: String, now: Date) -> Proposal? {
    guard let i = open.firstIndex(where: { $0.id == id }) else { return nil }
    let proposal = open.remove(at: i)
    blocked[Self.blockKey(by: proposal.by, name: proposal.name)] = now.addingTimeInterval(TimeInterval(Self.blockDays) * 86_400)
    return proposal
  }
  /// Make it, or the card went away: the proposal leaves the list.
  @discardableResult public mutating func take(_ id: String) -> Proposal? {
    guard let i = open.firstIndex(where: { $0.id == id }) else { return nil }
    return open.remove(at: i)
  }
  /// Forgets blocks that ended.
  public mutating func trim(now: Date) {
    blocked = blocked.filter { $0.value > now }
  }
  static func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

  /// The key of a block: the asker and the name.
  static func blockKey(by: String, name: String) -> String { by + "|" + key(name) }

  /// The person's own make card, when their words did not name it (SPEC 2.7).
  public static let personConfirm = "Make assistant"
  /// The card's words (SPEC 2.5 and 2.7). `byName` is nil for the person's own make.
  public static func title(_ draft: AssistantDraft) -> String { "Make \(AskPolicy.oneLine(draft.name))?" }
  public static func detail(_ draft: AssistantDraft, byName: String?) -> String {
    var lines: [String] = []
    if let byName {
      lines.append(helper(byName, job: draft.job))
    } else {
      lines.append(draft.job ?? "It will ask what to do.")
    }
    lines.append("It starts with no apps.")
    return lines.joined(separator: "\n")
  }
  /// What "Show what it will do" opens: the job, the places and what was left out, uncut.
  public static func more(_ draft: AssistantDraft) -> String {
    var lines: [String] = [draft.job ?? "It will ask what to do."]
    lines.append("It can use: \(AssistantPlace.words(draft.places)).")
    if !draft.dropped.isEmpty {
      lines.append("Left out, because you do not allow it: \(draft.dropped.joined(separator: ", ")).")
    }
    return lines.joined(separator: "\n")
  }
  /// The line after Not now.
  public static func declined(_ name: String) -> String { "You said no to \(AskPolicy.oneLine(name))." }
  /// "Scout wants a helper that watches fares and tells you when a price drops." A job that does
  /// not start with "It " keeps its own words after "Scout wants a new assistant."
  static func helper(_ byName: String, job: String?) -> String {
    let who = AskPolicy.oneLine(byName)
    guard let job, job.hasPrefix("It ") else {
      return "\(who) wants a new assistant." + (job.map { " " + $0 } ?? "")
    }
    var clause = String(job.dropFirst(3))
    while clause.hasSuffix(".") { clause.removeLast() }
    return "\(who) wants a helper that \(clause)."
  }
}

// MARK: - The way back

/// The changes of this launch that Undo can reverse, newest last, each with the chat its
/// receipt is in. `undo` without a token reverses the newest one of the chat. The journal holds
/// the change itself; this only finds it.
public struct UndoStack: Equatable, Sendable {
  public struct Item: Equatable, Sendable {
    public var token: UndoToken
    public var thread: String
    public var at: Date
  }
  public static let kept = 30
  public private(set) var items: [Item] = []
  public init() {}

  public mutating func push(_ token: UndoToken, thread: String, now: Date = Date()) {
    items.removeAll { $0.token.entry == token.entry }
    items.append(Item(token: token, thread: thread, at: now))
    if items.count > Self.kept { items.removeFirst(items.count - Self.kept) }
  }
  /// The token for `entry`; with no entry, the newest one made in `thread`.
  public func find(entry: String?, thread: String) -> UndoToken? {
    if let entry { return items.last { $0.token.entry == entry }?.token }
    return items.last { $0.thread == thread }?.token
  }
  public mutating func remove(_ entry: String) {
    items.removeAll { $0.token.entry == entry }
  }
}

// MARK: - Apps to offer after a make

/// The connected apps that fit a new assistant, from words in its name and job: offered after a
/// make as connect chips while Composio is set up, else as one connect card. A guess only: a
/// tap starts the app's own sign-in, and the assistant still asks before it may use an app.
public enum AppSuggestions {
  static let table: [(slug: String, words: [String])] = [
    ("gmail", ["inbox", "inboxes", "mail", "mails", "email", "emails", "mailbox", "gmail"]),
    ("outlook", ["inbox", "mail", "email", "emails", "outlook"]),
    ("googlecalendar", ["calendar", "calendars", "schedule", "meeting", "meetings", "planner", "week"]),
    ("slack", ["slack", "chat", "chats", "standup"]),
    ("notion", ["notion", "notes", "note", "docs", "wiki", "notebook"]),
    ("github", ["github", "code", "release", "releases", "pull", "issues", "repo", "repos", "developer"]),
  ]
  public static let maxChips = 3

  /// App slugs in the table's order, at most `limit`.
  public static func apps(name: String, job: String?, limit: Int = maxChips) -> [String] {
    let words = Set(NameReading.words(name) + NameReading.words(job ?? ""))
    var out: [String] = []
    for entry in table where out.count < limit {
      if !words.isDisjoint(with: entry.words) { out.append(entry.slug) }
    }
    return out
  }
  /// The connect offers: up to `maxChips` links while a Composio key is kept (the chat shows
  /// them as chips), else the first one only (the chat shows the connect card, which asks for
  /// the key first). Empty when no app fits.
  public static func offers(name: String, job: String?, composioReady: Bool) -> [ConnectLink] {
    let slugs = apps(name: name, job: job, limit: composioReady ? maxChips : 1)
    return slugs.compactMap { ConnectLink(app: $0, kind: .composio) }
  }
}

// MARK: - Lines of working together

/// The system lines of a light ask and a hand-off (SPEC 2.5). Names are cut to one line of 40
/// characters, as `AskPolicy` cuts them.
public enum AskLines {
  /// "Asked Planner", "Asked Planner and Scout", "Asked 3 assistants".
  public static func asked(_ names: [String]) -> String {
    let clean = names.map(AskPolicy.oneLine)
    if clean.count >= 3 { return "Asked \(clean.count) assistants" }
    return "Asked " + AskPolicy.list(clean)
  }
  /// The tool returned before this answer: it lands later in the same chat.
  public static func stillAnswering(_ name: String) -> String {
    "\(AskPolicy.oneLine(name)) is still answering. I will add it here."
  }
  /// The run reached the time cap.
  public static func noAnswer(_ name: String) -> String { "\(AskPolicy.oneLine(name)) did not answer." }
  /// The folded line in the asked assistant's own chat; it opens to the question and the answer.
  public static func askedYou(_ asker: String) -> String { "\(AskPolicy.oneLine(asker)) asked you" }
  /// The asked assistant's row while it answers.
  public static func answering(_ asker: String) -> String { "Answering \(AskPolicy.oneLine(asker))" }
  /// What the folded line opens to when personal data took part: no words travel.
  public static let personalFold = "The question or the answer used personal data, so the words stay in the chat that asked."
}

// MARK: - Words of the host

/// What the host adds to a turn's words.
public enum HostFacts {
  /// A closing reply of exactly this stays hidden when the turn has a receipt, as NOTHING is.
  public static let done = "DONE"
  public static func hides(_ reply: String) -> Bool { RelayMarks.isExactly(done, reply) }
  /// The chips under the first question of an assistant that cannot tell its job from its name.
  public static let firstChips = ["Watch prices", "Plan my week", "Sum up Slack"]
  /// What a tool's result tells the model after a receipt.
  public static let receiptNote =
    "The person sees the result as a receipt under your reply. Add one short sentence only if it helps, or reply exactly DONE."
}

// MARK: - A new assistant's first message

/// The host's first message in a new assistant's own chat (SPEC 2.2), with no model turn. A name
/// that tells a job gets the job in the first person and asks if it is right; a name that tells
/// nothing asks `NameReading.question`. A job the person gave needs no question.
public enum FirstWords {
  /// Each `NameReading` job in the first person, after "I think I".
  static let firstPerson: [String: String] = [
    "It sorts your mail and asks before it sends anything.": "sort your mail and ask before I send anything",
    "It keeps your calendar and asks before it changes an event.": "keep your calendar and ask before I change an event",
    "It plans your trips and finds flights and places to stay.": "plan your trips and find flights and places to stay",
    "It watches fares and tells you when a price drops.": "watch fares and tell you when a price drops",
    "It writes and edits drafts with you.": "write and edit drafts with you",
    "It keeps your notes and finds them when you ask.": "keep your notes and find them when you ask",
    "It finds sources, reads them and gives you a short summary.": "find sources, read them and give you a short summary",
    "It reads the news and tells you the important parts.": "read the news and tell you the important parts",
    "It tracks your spending and budget and never moves money.": "track your spending and budget and never move money",
    "It plans your workouts and tracks your progress.": "plan your workouts and track your progress",
    "It finds recipes and makes your shopping lists.": "find recipes and make your shopping lists",
    "It compares prices and asks before it buys anything.": "compare prices and ask before I buy anything",
  ]
  public static let yes = "Yes"
  public static let somethingElse = "Something else"

  /// The words and chips, or nil when the person gave the job.
  public static func message(name: String, job: String?, jobFromName: Bool) -> (text: String, chips: [String])? {
    let who = AskPolicy.oneLine(name)
    guard let job else { return ("Hi, I am \(who). " + NameReading.question, HostFacts.firstChips) }
    guard jobFromName, let phrase = firstPerson[job] else { return nil }
    return ("Hi, I am \(who). From my name, I think I \(phrase). Right?", [yes, somethingElse])
  }
}

// MARK: - Links with an owner

/// A link one assistant owns, as Serein keeps it (relay/links.json): its spec, never its secret,
/// and whether it is paused. The secret is in Keychain under `LinkAddress.keychainService`.
public struct OwnedLink: Codable, Equatable, Identifiable, Sendable {
  public var spec: HookSpec
  public var paused: Bool?
  /// When the last delivery that started a run came (`hook_list`).
  public var lastDelivery: Date?
  public var id: String { spec.id }
  public init(spec: HookSpec, paused: Bool? = nil, lastDelivery: Date? = nil) {
    self.spec = spec
    self.paused = paused
    self.lastDelivery = lastDelivery
  }
  public var isPaused: Bool { paused == true }
}

/// Where an owned link listens, and what Copy link puts on the clipboard.
public enum LinkAddress {
  public static let path = "/link/"
  /// The Keychain service of link secrets (account: the link's id).
  public static let keychainService = "serein.hook"
  public static func url(_ id: String) -> String { "http://127.0.0.1:\(RelayHook.port)\(path)\(id)" }
  /// The link id in a request path ("/link/<id>"; a query after it is ignored); nil for any
  /// other path or an id that is not letters, digits, "-" and "_".
  public static func id(fromPath raw: String) -> String? {
    guard raw.hasPrefix(path) else { return nil }
    var rest = String(raw.dropFirst(path.count))
    if let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<end]) }
    guard HookGate.isToken(rest, limit: HookSpec.maxID) else { return nil }
    return rest
  }
  /// A new link id: "link-" and 16 lowercase letters and digits.
  public static func newID() -> String {
    let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    return "link-" + String(random.prefix(16))
  }
  /// The text Copy link puts on the clipboard (marked concealed), worded for the sender's form.
  public static func copyText(id: String, auth: HookSpec.Auth, secret: String) -> String {
    let address = url(id)
    switch auth {
    case .github:
      return "Payload URL: \(address)\nContent type: application/json\nSecret: \(secret)"
    case .standard:
      return "Address: \(address)\nSigning secret: \(secret)"
    case .bearer:
      return "Address: \(address)\nHeader: Authorization: Bearer \(secret)"
    }
  }
}

/// `hook_make`'s arguments, read into a spec. The model never gives or sees a secret.
public enum LinkDraft {
  public enum Problem: Error, Equatable, Sendable {
    case spec(HookSpec.Problem)
    case unknownOwner(String)
    case ownerPaused(String)
    case tooMany

    public var words: String {
      switch self {
      case .spec(let problem): return problem.words
      case .unknownOwner(let name): return "No assistant is called \(name). Check the name with assistant_list."
      case .ownerPaused(let name): return "\(name) is paused. Turn it on first, or choose another assistant."
      case .tooMany: return "\(LinkDraft.maxLinks) links are the most. Remove one first."
      }
    }
  }
  public static let maxLinks = 20
  /// The card when the person's words did not name the link (SPEC 2.7).
  public static let confirm = "Make link"
  public static let decline = "Not now"
  public static func cardTitle(owner: String) -> String { "Make a link that wakes \(AskPolicy.oneLine(owner))?" }
  public static func cardDetail(owner: String, instruction: String) -> String {
    let name = AskPolicy.oneLine(owner)
    let what: String = instruction.isEmpty ? "reads what came" : "does this: “\(instruction)”"
    return "Another app calls the link, and \(name) \(what). The link works on this Mac."
  }

  /// name, assistant (the one it wakes; the asking one when not given), instruction, auth
  /// (bearer, github or standard; `from` is read too), event, field and equals (which deliveries
  /// it takes).
  public static func parse(
    _ a: [String: Any], actingID: String, team: RelayTeam, existing: Int, id: String, now: Date
  ) -> Result<HookSpec, Problem> {
    guard existing < maxLinks else { return .failure(.tooMany) }
    let named = AskPolicy.cleanName(a["assistant"] as? String ?? "")
    let found: RelayProfile? = named.isEmpty
      ? team.profiles.first(where: { $0.id == actingID }) : team.profile(named: named)
    guard let owner = found else { return .failure(.unknownOwner(String(named.prefix(40)))) }
    if owner.isPaused { return .failure(.ownerPaused(owner.name)) }
    let name = (a["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard TeamProposal.oneLine(name) else { return .failure(.spec(.badName)) }
    let instruction = a["instruction"] as? String ?? ""
    let authWord: String? = (a["auth"] as? String) ?? (a["from"] as? String)
    let auth = Self.auth(authWord)
    let filter = Self.filter(a)
    do {
      let spec = try HookSpec(
        id: id, name: name, owner: owner.id, instruction: instruction, auth: auth, filter: filter, createdAt: now)
      return .success(spec)
    } catch let problem as HookSpec.Problem {
      return .failure(.spec(problem))
    } catch {
      return .failure(.spec(.badFilter))
    }
  }

  /// "github" proves deliveries with GitHub's signature, "standard" with Standard Webhooks; any
  /// other sender sends the secret as a bearer header.
  static func auth(_ raw: String?) -> HookSpec.Auth {
    let word = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if word.contains("github") { return .github }
    if word.contains("standard") || word.contains("svix") { return .standard }
    return .bearer
  }
  /// The filter from event, field and equals; nil when none is given.
  static func filter(_ a: [String: Any]) -> HookSpec.Filter? {
    let event = (a["event"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let field = (a["field"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let equals = (a["equals"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanEvent: String? = (event?.isEmpty ?? true) ? nil : event
    let cleanField: String? = (field?.isEmpty ?? true) ? nil : field
    let cleanEquals: String? = (equals?.isEmpty ?? true) ? nil : equals
    if cleanEvent == nil && cleanField == nil && cleanEquals == nil { return nil }
    return HookSpec.Filter(eventPrefix: cleanEvent, field: cleanField, equals: cleanEquals)
  }

  /// What the link takes, in plain words for `hook_list`.
  public static func takes(_ filter: HookSpec.Filter?) -> String {
    guard let filter else { return "every delivery" }
    var parts: [String] = []
    if let event = filter.eventPrefix { parts.append("events starting \(event)") }
    if let field = filter.field, let value = filter.equals { parts.append("\(field) is \(value)") }
    return parts.isEmpty ? "every delivery" : parts.joined(separator: ", ")
  }
}

/// Whether the person's own message names removing a link. Like `TypedConsent`, it reads only
/// words it knows: a miss gives a card.
public enum LinkConsent {
  public static func namesRemoval(_ message: String) -> Bool {
    let words = TypedConsent.normalized(message)
    return TypedConsent.contains(words, any: ["remove", "delete", "stop", "turn off", "get rid of"])
      && TypedConsent.contains(words, any: ["link", "links", "hook", "address"])
  }
}
