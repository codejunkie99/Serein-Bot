import Foundation

/// Bot teams: what each assistant may use, the person's teams of assistants, hand-offs between
/// them and the limits on those, all pure so SereinChecks can check them. Nothing here grants
/// anything: a scope only narrows the person's settings, and every hand-off and team change still
/// asks the person on a card (RelayToolHost).

/// A place an assistant may work, in the words the person reads ("can use: Web, This page,
/// Answers, Mac, Projects, Mail, Messages, Calendar, Contacts, Connected apps, Serein's
/// computer"). Mail, Messages, Calendar and Contacts are the connections the person turned on in
/// Settings › Connections (Connections, NativeConnection).
public enum AssistantPlace: String, Codable, CaseIterable, Sendable {
  case web, page, answer, mac, project
  case mail, messages
  /// Connections (NativeConnection), only while the person turned one on.
  case calendar, contacts
  /// Apps connected through Composio or by their MCP server's address (Settings › Connections),
  /// only while a Composio key is saved or an MCP connection is on.
  case connectedApps
  /// Serein's computer (ComputerPolicy): a separate Linux desktop an assistant works in; only
  /// while the person's switch "Let assistants use Serein's computer" is on.
  case computer

  public var label: String {
    switch self {
    case .web: return "Web"
    case .page: return "This page"
    case .answer: return "Answers"
    case .mac: return "Mac"
    case .project: return "Projects"
    case .mail: return "Mail"
    case .messages: return "Messages"
    case .calendar: return "Calendar"
    case .contacts: return "Contacts"
    case .connectedApps: return "Connected apps"
    case .computer: return "Serein's computer"
    }
  }
  /// How a refusal names it: "Writer can't use the Web."
  public var phrase: String {
    switch self {
    case .web: return "the Web"
    case .page: return "this page"
    case .answer: return "Answers"
    case .mac: return "Mac apps"
    case .project: return "projects"
    case .mail: return "Mail"
    case .messages: return "Messages"
    case .calendar: return "your calendar"
    case .contacts: return "your contacts"
    case .connectedApps: return "connected apps"
    case .computer: return "Serein's computer"
    }
  }
  private static let aliases: [String: AssistantPlace] = [
    "website": .web, "websites": .web, "browser": .web, "here": .page, "current page": .page,
    "answers": .answer, "mac apps": .mac, "projects": .project, "email": .mail, "imessage": .messages,
    "calendars": .calendar, "reminders": .calendar, "contact": .contacts,
    "serein's computer": .computer, "serein’s computer": .computer, "the computer": .computer,
    "connectedapps": .connectedApps, "connected apps": .connectedApps, "composio": .connectedApps,
    "connections": .connectedApps,
  ]
  /// A place from a model's or person's word: its id or its label, any case. nil for anything else.
  public static func parse(_ word: String) -> AssistantPlace? {
    let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return AssistantPlace(rawValue: w) ?? allCases.first { $0.label.lowercased() == w } ?? aliases[w]
  }
  /// "Web, Answers", in a fixed order; "only its own chat" for none.
  public static func words(_ places: Set<AssistantPlace>) -> String {
    let named = allCases.filter(places.contains).map(\.label)
    return named.isEmpty ? "only its own chat" : named.joined(separator: ", ")
  }
  /// The place a run of this kind works in, by its TaskMode run key. nil for routing ("auto").
  public static func of(runKey: String) -> AssistantPlace? {
    switch runKey {
    case "research": return .web
    case "page": return .page
    case "answer": return .answer
    case "anywhere": return .mac
    case "project", "library": return .project
    default: return nil
    }
  }
}

extension RelayTools.Destination {
  /// The place an agent_start destination works in.
  public var place: AssistantPlace {
    switch self {
    case .project: return .project
    case .web: return .web
    case .mac: return .mac
    case .answer: return .answer
    case .here: return .page
    }
  }
}

/// What one assistant may use. It can only remove places, add Never sites and narrow the
/// connected apps of the person's own settings (`effective`), and its instructions follow the
/// person's standing instructions, never replacing them.
public struct AssistantScope: Codable, Equatable, Sendable {
  public var destinations: Set<AssistantPlace>
  /// Sites this assistant never opens, on top of the person's own Never rules (SiteRules).
  public var neverSites: [String]
  public var instructions: String
  /// The connected apps this assistant may use, by `composioAppKey` or `connectionAppKey`: nil is every app the person
  /// connected; a list is only those, and an empty list is none. It only narrows: it never
  /// turns on Connected apps for an assistant whose places leave them out.
  public var apps: [String]?

  public static let instructionsLimit = 2_000
  public static let appsLimit = 200

  public init(
    destinations: Set<AssistantPlace>, neverSites: [String] = [], instructions: String = "", apps: [String]? = nil
  ) {
    self.destinations = destinations
    self.neverSites = Self.sites(neverSites)
    self.instructions = instructions
    self.apps = apps.map(Self.appKeys)
  }

  enum CodingKeys: String, CodingKey { case destinations, neverSites, instructions, apps }
  /// A place a newer build wrote is dropped, which only narrows; the file still decodes. An app
  /// list that is there but cannot be read is no apps, never every app.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try c.decodeIfPresent([String].self, forKey: .destinations) ?? []
    destinations = Set(raw.compactMap(AssistantPlace.init(rawValue:)))
    neverSites = Self.sites(try c.decodeIfPresent([String].self, forKey: .neverSites) ?? [])
    instructions = String((try c.decodeIfPresent(String.self, forKey: .instructions) ?? "").prefix(Self.instructionsLimit))
    if c.contains(.apps), (try? c.decodeNil(forKey: .apps)) != true {
      apps = (try? c.decode([String].self, forKey: .apps)).map(Self.appKeys) ?? []
    } else {
      apps = nil
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(AssistantPlace.allCases.filter(destinations.contains).map(\.rawValue), forKey: .destinations)
    try c.encode(neverSites, forKey: .neverSites)
    try c.encode(instructions, forKey: .instructions)
    try c.encodeIfPresent(apps, forKey: .apps)
  }

  /// The key of a Composio app (`gmail`) in `apps`.
  public static func composioAppKey(_ slug: String) -> String { "composio:" + slug.lowercased() }
  /// The key of an MCP server connected by address, by its plugin id (`app.notion`).
  public static func connectionAppKey(_ pluginID: String) -> String { "mcp:" + pluginID.lowercased() }
  /// Keys as `apps` stores them: lower case, a known kind, once each, in order, at most
  /// `appsLimit`. A key of an unknown kind is dropped, which only narrows.
  static func appKeys(_ list: [String]) -> [String] {
    var seen = Set<String>()
    let kept = list.compactMap { raw -> String? in
      let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard key.hasPrefix("composio:") || key.hasPrefix("mcp:"), key.count > 5, key.count <= 120,
        key.range(of: #"^[a-z0-9:._-]+$"#, options: .regularExpression) != nil
      else { return nil }
      return seen.insert(key).inserted ? key : nil
    }
    return Array(kept.prefix(appsLimit))
  }
  /// Both lists' apps: nil only when both are nil (every app).
  public static func intersect(_ a: [String]?, _ b: [String]?) -> [String]? {
    guard let a else { return b }
    guard let b else { return a }
    return a.filter(b.contains)
  }
  /// This app is one the assistant may use. Connected apps as a place is checked apart.
  public func allowsApp(_ key: String) -> Bool { apps.map { $0.contains(key.lowercased()) } ?? true }
  /// An app left out of the assistant's list, refused in plain words. Model-facing.
  public static func appRefusal(name: String, app: String) -> String {
    "\(name) can't use \(app). The person chose the connected apps \(name) may use. Do the rest without it and tell the person what was left out."
  }

  /// Hosts as Site rules store them (`SitePolicy.site`), once each; anything that names no site goes.
  /// Never cut short: dropping a Never site would widen what the assistant may open.
  static func sites(_ list: [String]) -> [String] {
    var seen = Set<String>()
    return list.compactMap(SitePolicy.site).filter { seen.insert($0).inserted }
  }

  /// What an assistant may use: the intersection of its places with the person's, and the union of
  /// Never sites. A nil scope is the person's settings unchanged. Never wider than `person`.
  public static func effective(_ scope: AssistantScope?, person: AssistantScope) -> AssistantScope {
    guard let scope else { return person }
    return AssistantScope(
      destinations: scope.destinations.intersection(person.destinations),
      neverSites: person.neverSites + scope.neverSites, instructions: scope.instructions,
      apps: intersect(scope.apps, person.apps))
  }
  public func allows(_ place: AssistantPlace) -> Bool { destinations.contains(place) }
  /// This address is on one of the Never sites (the site or any subdomain, as SiteRules match).
  public func blocks(_ address: String?) -> Bool {
    guard let address, let site = SiteRules.site(address) else { return false }
    return neverSites.contains { SitePolicy.matches(host: site, site: $0) }
  }

  /// A step outside the assistant's places, refused in plain words with what to do next.
  /// `others` are assistants who share a team with it and may use the place (none for a
  /// handed-over task or a light ask).
  public static func refusal(name: String, place: AssistantPlace, others: [String]) -> String {
    "\(name) can't use \(place.phrase)."
      + (others.first.map { " Ask \($0) instead." } ?? " Do the rest without it and tell the person what was left out.")
  }
  /// A site turned off for this assistant only. Model-facing as SiteRules' refusal is.
  public static func siteRefusal(name: String, address: String) -> String {
    "\(name) doesn’t open \(SiteRules.site(address) ?? "this site") (a site turned off for \(name)). Nothing was done. Do not try this site again; tell the person it is turned off for \(name)."
  }
}

/// The tints assistants wear (`ThemeTokens.assistantTints`, one value per appearance): each new
/// assistant takes the next one not in use. Indigo is the accent, the main assistant's own, so it
/// comes last.
public enum AssistantColour {
  public static let all = ["sky", "teal", "violet", "rose", "tangerine", "moss", "slate", "indigo"]
  /// The keys an earlier build stored, read as today's tints.
  static let legacy = [
    "blue": "sky", "green": "moss", "orange": "tangerine", "purple": "violet", "pink": "rose", "teal": "teal",
    "yellow": "tangerine", "red": "rose",
  ]
  /// A stored colour as a tint key of `all`; nil for none or one no build knows.
  public static func key(_ stored: String?) -> String? {
    stored.map { legacy[$0] ?? $0 }.flatMap { all.contains($0) ? $0 : nil }
  }
  public static func next(used: [String?]) -> String {
    let keys = used.map(key)
    return all.first { !keys.contains($0) } ?? all[used.count % all.count]
  }
}

/// One of the person's teams. An assistant may be in several; deleting a team never deletes its
/// assistants, and deleting an assistant takes it out of every team (`RelayTeam.removing`).
public struct AssistantGroup: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var memberIDs: [String]
  /// Answers a message posted to the team that names nobody.
  public var leadID: String?

  public static let nameLimit = 40
  public static let maxMembers = 8

  public init(id: String = UUID().uuidString, name: String, memberIDs: [String], leadID: String? = nil) {
    self.id = id
    self.name = name
    self.memberIDs = memberIDs
    self.leadID = leadID
  }

  /// The team without one assistant; nil when nobody is left.
  func without(_ id: String) -> AssistantGroup? {
    var group = self
    group.memberIDs.removeAll { $0 == id }
    if group.leadID == id { group.leadID = nil }
    return group.memberIDs.isEmpty ? nil : group
  }

  /// Who answers a message posted to the team: the member it names with "@Name", else the lead,
  /// else the first member. It picks who replies and nothing else.
  public func responder(for text: String, profiles: [RelayProfile]) -> String? {
    let members = memberIDs.compactMap { id in profiles.first { $0.id == id } }
    let named = members.compactMap { member -> (String, String.Index)? in
      guard let at = TeamMention.find("@" + member.name, in: text) else { return nil }
      return (member.id, at)
    }.min { $0.1 < $1.1 }
    if let named { return named.0 }
    if let leadID, memberIDs.contains(leadID) { return leadID }
    return memberIDs.first
  }
}

/// "@Writer draft the reply" sends to Writer's Main chat; "@Trip …" (or "@Trip team …") posts to
/// the team, whose responder answers.
public enum TeamMention: Equatable, Sendable {
  case assistant(String)
  case team(String)

  /// The mention at the start of `text` and the words after it. The longest name wins, and an
  /// assistant wins a tie with a team. nil when the text does not open with "@" and a name.
  public static func parse(_ text: String, in team: RelayTeam) -> (mention: TeamMention, rest: String)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("@") else { return nil }
    let body = trimmed.dropFirst()
    guard let best = longest(body, in: team) else { return nil }
    let rest = String(body[best.end...]).trimmingCharacters(in: CharacterSet(charactersIn: ",:").union(.whitespacesAndNewlines))
    return (best.mention, rest)
  }

  /// The roster name `body` opens with: the longest wins, and an assistant wins a tie with a team.
  static func longest(_ body: Substring, in team: RelayTeam) -> (mention: TeamMention, end: String.Index)? {
    var candidates: [(TeamMention, String)] = team.profiles.map { (TeamMention.assistant($0.id), $0.name) }
    for group in team.groups ?? [] {
      candidates.append((.team(group.id), group.name + " team"))
      candidates.append((.team(group.id), group.name))
    }
    var best: (mention: TeamMention, length: Int, end: String.Index)?
    for (mention, name) in candidates where !name.isEmpty {
      guard let range = body.range(of: name, options: [.caseInsensitive, .anchored]), boundary(body, at: range.upperBound)
      else { continue }
      let length = body.distance(from: body.startIndex, to: range.upperBound)
      let wins = best.map { length > $0.length || (length == $0.length && $0.mention.isTeam && !mention.isTeam) } ?? true
      if wins { best = (mention, length, range.upperBound) }
    }
    return best.map { ($0.mention, $0.end) }
  }

  /// Where `name` starts in `text` as a whole word (case-insensitive), or nil.
  static func find(_ name: String, in text: String) -> String.Index? {
    var from = text.startIndex
    while let range = text.range(of: name, options: .caseInsensitive, range: from..<text.endIndex) {
      if boundary(text[...], at: range.upperBound) { return range.lowerBound }
      from = range.upperBound
    }
    return nil
  }
  private static func boundary(_ text: Substring, at index: String.Index) -> Bool {
    guard index < text.endIndex else { return true }
    let next = text[index]
    return next.isWhitespace || next.isPunctuation
  }
  private var isTeam: Bool {
    if case .team = self { return true }
    return false
  }
}

/// One channel: every "@Name" in a message, anywhere in it, names a bot who takes a turn there.
public enum GroupTurn {
  /// Each tag that names someone on the roster: an "@" at the start or after a character that is
  /// not a letter or digit, then the longest roster name. A team stands for its responder.
  /// Unknown names are plain text.
  public static func tags(in text: String, team: RelayTeam) -> [(id: String, range: Range<String.Index>)] {
    var out: [(id: String, range: Range<String.Index>)] = []
    var from = text.startIndex
    while let at = text[from...].firstIndex(of: "@") {
      let after = text.index(after: at)
      let opens = at == text.startIndex || !text[text.index(before: at)].isLetter && !text[text.index(before: at)].isNumber
      guard opens, let hit = TeamMention.longest(text[after...], in: team) else {
        from = after
        continue
      }
      let id: String?
      switch hit.mention {
      case .assistant(let profile): id = profile
      case .team(let group): id = team.teams.first { $0.id == group }?.responder(for: text, profiles: team.profiles)
      }
      if let id { out.append((id, at..<hit.end)) }
      from = hit.end
    }
    return out
  }

  /// Who takes a turn, in the order they are tagged, each once. `addressed` keeps only tags with
  /// words after them, so "thanks @Writer" in a bot's reply sends nothing but "@Writer can you…" does.
  public static func speakers(of text: String, in team: RelayTeam, addressed: Bool = false) -> [String] {
    var seen: [String] = []
    for tag in tags(in: text, team: team) where !seen.contains(tag.id) {
      if addressed, !words(of: String(text[tag.range.upperBound...]), in: team).contains(where: \.isLetter) { continue }
      seen.append(tag.id)
    }
    return seen
  }

  /// The message without its tags; empty for a bare "@Writer".
  public static func words(of text: String, in team: RelayTeam) -> String {
    var rest = text
    for tag in tags(in: text, team: team).reversed() { rest.removeSubrange(tag.range) }
    return rest.trimmingCharacters(in: CharacterSet(charactersIn: ",:").union(.whitespacesAndNewlines))
  }
}

extension RelayTeam {
  /// The teams that exist; empty means one implicit team of everyone.
  public var teams: [AssistantGroup] { groups ?? [] }

  public func profile(named name: String) -> RelayProfile? {
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return profiles.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
  }
  /// A team both assistants are in (the first, in the person's order), or nil.
  public func sharedGroup(_ a: String, _ b: String) -> AssistantGroup? {
    teams.first { $0.memberIDs.contains(a) && $0.memberIDs.contains(b) }
  }
  /// Who `from` may hand work to: members of a team it shares, or anyone when there are no teams.
  /// Never itself.
  public func handoffTargets(from id: String) -> [RelayProfile] {
    profiles.filter { $0.id != id && (teams.isEmpty || sharedGroup(id, $0.id) != nil) }
  }

  /// A new team. nil when its name is empty, too long or taken, or its members are not 1 to 8
  /// distinct assistants of this roster, or its lead is not one of them.
  public func addingGroup(_ group: AssistantGroup) -> RelayTeam? {
    let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= AssistantGroup.nameLimit,
      !teams.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
      (1...AssistantGroup.maxMembers).contains(group.memberIDs.count), Set(group.memberIDs).count == group.memberIDs.count,
      group.memberIDs.allSatisfy({ id in profiles.contains { $0.id == id } }),
      group.leadID.map({ group.memberIDs.contains($0) }) ?? true
    else { return nil }
    var team = self
    var clean = group
    clean.name = name
    team.groups = teams + [clean]
    return team
  }
  /// Deletes a team; its assistants stay. nil when there is no such team.
  public func removingGroup(_ id: String) -> RelayTeam? {
    guard teams.contains(where: { $0.id == id }) else { return nil }
    var team = self
    team.groups = teams.filter { $0.id != id }
    return team
  }

  /// A proposed team made real after "Create team": each member a new assistant with its scope and
  /// the next free colour, and one team with its lead. nil when the roster changed so that it no
  /// longer fits (a name taken, too many assistants, the team's name taken).
  public func addingTeam(_ proposal: TeamProposal) -> (team: RelayTeam, created: [RelayProfile])? {
    guard profiles.count + proposal.members.count <= Self.maxProfiles else { return nil }
    var team = self
    var created: [RelayProfile] = []
    for member in proposal.members {
      guard team.profile(named: member.name) == nil else { return nil }
      let profile = RelayProfile(
        name: RelayProfile.cleanName(member.name), scope: proposal.scope(of: member),
        colour: AssistantColour.next(used: team.profiles.map(\.colour)), icon: member.icon?.shareable)
      team.profiles.append(profile)
      created.append(profile)
    }
    let lead = proposal.lead.flatMap { lead in created.first { $0.name.caseInsensitiveCompare(lead) == .orderedSame }?.id }
    guard let grouped = team.addingGroup(AssistantGroup(name: proposal.name, memberIDs: created.map(\.id), leadID: lead))
    else { return nil }
    return (grouped, created)
  }

  /// Everything an undo compares: who is on the roster with what scope, colour, label, icon and
  /// pause, and the teams. Names are left out: a rename is not journaled, so it never blocks an
  /// undo; routes too. The main assistant's Speaks first is left out: Settings › Check-ins writes
  /// it outside the journal.
  private func sameShape(_ other: RelayTeam) -> Bool {
    guard profiles.map(\.label) == other.profiles.map(\.label), profiles.map(\.icon) == other.profiles.map(\.icon) else {
      return false
    }
    guard profiles.map(\.isPaused) == other.profiles.map(\.isPaused) else { return false }
    return profiles.map(\.id) == other.profiles.map(\.id) && profiles.map(\.scope) == other.profiles.map(\.scope)
      && profiles.map(\.colour) == other.profiles.map(\.colour)
      && profiles.map { $0.id == mainProfileID ? nil : $0.speaksFirst }
        == other.profiles.map { $0.id == other.mainProfileID ? nil : $0.speaksFirst }
      && teams == other.teams
  }
  /// The roster put back to `before`, undoing a change that produced `after`. nil when the roster
  /// changed since (undo newer changes first), when the active assistant would go, or when a name
  /// would clash. Assistants that stay keep their current names; the active one stays active.
  public func undoing(before: RelayTeam, after: RelayTeam) -> RelayTeam? {
    guard sameShape(after), before.profiles.contains(where: { $0.id == activeID }) else { return nil }
    var restored = before
    restored.activeID = activeID
    restored.mainRenamed = mainRenamed
    restored.startingRoute = startingRoute
    for i in restored.profiles.indices {
      if let current = profiles.first(where: { $0.id == restored.profiles[i].id }) {
        restored.profiles[i].name = current.name
        // A route is never journaled: an undo keeps the engine each assistant has now.
        restored.profiles[i].route = current.route
      } else {
        // An assistant an undo brings back starts on the default engine; a new pick asks again.
        restored.profiles[i].route = nil
      }
      /// Speaks first is also set outside the journal (Settings › Check-ins writes the main assistant's): undo reverts it only when this entry changed it and nothing has changed it since.
      let id = restored.profiles[i].id
      let then = after.profiles.first(where: { $0.id == id })?.speaksFirst
      if let current = profiles.first(where: { $0.id == id }),
        before.profiles.first(where: { $0.id == id })?.speaksFirst == then || current.speaksFirst != then
      {
        restored.profiles[i].speaksFirst = current.speaksFirst
      }
    }
    let names = restored.profiles.map { $0.name.lowercased() }
    guard Set(names).count == names.count else { return nil }
    return restored
  }
}

/// A team proposed from the person's description or an imported file. Nothing is saved until
/// the person presses "Create team"; anything wider than what the person allows is dropped here
/// and the card lists it.
public struct TeamProposal: Equatable, Sendable {
  public struct Member: Equatable, Sendable {
    public var name: String
    /// One line on who the assistant is ("Finds flights and hotels").
    public var persona: String
    public var places: Set<AssistantPlace>
    /// What it asked to use that the person does not allow, or that names no place: dropped.
    public var dropped: [String]
    public var instructions: String
    /// Sites it never opens (an imported team keeps its own; a proposal has none).
    public var neverSites: [String] = []
    /// Its icon: an emoji or a symbol from an imported file, never a picture (`AssistantIcon.shareable`).
    public var icon: AssistantIcon?
    public init(name: String, persona: String, places: Set<AssistantPlace>, dropped: [String], instructions: String,
                neverSites: [String] = [], icon: AssistantIcon? = nil) {
      self.name = name
      self.persona = persona
      self.places = places
      self.dropped = dropped
      self.instructions = instructions
      self.neverSites = neverSites
      self.icon = icon?.shareable
    }
  }
  public var name: String
  public var members: [Member]
  public var lead: String?
  public init(name: String, members: [Member], lead: String?) {
    self.name = name
    self.members = members
    self.lead = lead
  }

  public static let personaLimit = 160

  /// Reads the tool's arguments. Limits refuse rather than cut: a name, persona or instructions
  /// that is too long, a name already on the roster, or a team too big is an error that says so.
  public static func parse(_ a: [String: Any], person: Set<AssistantPlace>, team: RelayTeam) throws -> TeamProposal {
    let name = (a["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= AssistantGroup.nameLimit else {
      throw SereinError.invalid("name is the team's name, 1 to \(AssistantGroup.nameLimit) characters.")
    }
    guard oneLine(name) else { throw SereinError.invalid(oneLineRefusal) }
    guard !team.teams.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
      throw SereinError.invalid("The person already has a team called that. Choose another name.")
    }
    let raw = a["members"] as? [[String: Any]] ?? []
    guard (1...AssistantGroup.maxMembers).contains(raw.count) else {
      throw SereinError.invalid("members lists 1 to \(AssistantGroup.maxMembers) assistants.")
    }
    guard team.profiles.count + raw.count <= RelayTeam.maxProfiles else {
      throw SereinError.invalid(
        "The person has \(team.profiles.count) assistants and the most is \(RelayTeam.maxProfiles). Propose at most \(RelayTeam.maxProfiles - team.profiles.count).")
    }
    var members: [Member] = []
    for entry in raw {
      let memberName = (entry["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !memberName.isEmpty, memberName.count <= 40 else {
        throw SereinError.invalid("Each member needs a name of 1 to 40 characters.")
      }
      guard oneLine(memberName) else { throw SereinError.invalid(oneLineRefusal) }
      guard team.profile(named: memberName) == nil,
        !members.contains(where: { $0.name.caseInsensitiveCompare(memberName) == .orderedSame })
      else { throw SereinError.invalid("\(memberName) is already an assistant's name. Give each new member its own name.") }
      let persona = (entry["persona"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard persona.count <= personaLimit else {
        throw SereinError.invalid("\(memberName)'s persona is one line of at most \(personaLimit) characters.")
      }
      guard oneLine(persona) else { throw SereinError.invalid(oneLineRefusal) }
      let instructions = (entry["instructions"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let words = (entry["canUse"] as? [String]) ?? (entry["canUse"] as? String)?.components(separatedBy: ",") ?? []
      var places = Set<AssistantPlace>()
      var dropped: [String] = []
      for word in words where !word.trimmingCharacters(in: .whitespaces).isEmpty {
        // Connected apps start off: the person turns them on for an assistant themselves.
        if let place = AssistantPlace.parse(word), place != .connectedApps, person.contains(place) {
          places.insert(place)
        } else {
          let shown = AssistantPlace.parse(word)?.label ?? String(word.trimmingCharacters(in: .whitespaces).prefix(40))
          if !dropped.contains(shown) { dropped.append(shown) }
        }
      }
      let member = Member(name: memberName, persona: persona, places: places, dropped: dropped, instructions: instructions)
      members.append(member)
      guard Self.saved(member).count <= AssistantScope.instructionsLimit else {
        throw SereinError.invalid("\(memberName)'s instructions are longer than \(AssistantScope.instructionsLimit) characters. Shorten them.")
      }
    }
    let leadName = (a["lead"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard leadName.isEmpty || members.contains(where: { $0.name.caseInsensitiveCompare(leadName) == .orderedSame }) else {
      throw SereinError.invalid("lead is one of the members' names.")
    }
    return TeamProposal(name: name, members: members, lead: leadName.isEmpty ? nil : leadName)
  }

  /// Names and personas reach prompts and one-line rows: no line breaks and no hidden characters
  /// (controls, zero-width characters, direction marks; `SafeFileName.hidden`).
  static func oneLine(_ s: String) -> Bool {
    !s.unicodeScalars.contains { CharacterSet.newlines.contains($0) || SafeFileName.hidden($0) }
  }
  static let oneLineRefusal = "Names and personas are one line of plain text."
  /// The instructions a member is saved with: its persona line ahead of its instructions.
  static func saved(_ member: Member) -> String {
    [member.persona.isEmpty ? nil : "Who you are: " + member.persona, member.instructions.isEmpty ? nil : member.instructions]
      .compactMap { $0 }.joined(separator: "\n")
  }
  /// The scope a member is created with: only the places that survived, and its Never sites.
  public func scope(of member: Member) -> AssistantScope {
    AssistantScope(destinations: member.places, neverSites: member.neverSites, instructions: Self.saved(member))
  }
  /// The card's lines: every member, its persona, what it can use and what was dropped, the lead.
  public var summary: String {
    var lines = members.map { member -> String in
      var line = "\(member.name)" + (member.persona.isEmpty ? "" : ": \(member.persona)")
        + "\n  can use: \(AssistantPlace.words(member.places))"
      let apps = AssistantPlace.connectedApps.label
      let others = member.dropped.filter { $0 != apps }
      if !others.isEmpty { line += "\n  dropped (you don't allow it): " + others.joined(separator: ", ") }
      if member.dropped.contains(apps) {
        line += "\n  dropped: \(apps) start off for a new assistant; you can turn them on for it yourself"
      }
      return line
    }
    lines.append("Lead: \(lead ?? "none")")
    return lines.joined(separator: "\n")
  }
  /// Every member's full instructions, shown open on the card.
  public var instructionsText: String {
    members.map { "\($0.name):\n" + ($0.instructions.isEmpty ? "(no instructions)" : $0.instructions) }
      .joined(separator: "\n\n")
  }
}

/// One task an assistant handed to another. The target works on its own Main chat with only its
/// own scope; nothing of the sender's carries over. The target may hand part of it on, which
/// makes a chain: each link is its own hand-off, tied to the one above by `parentID`.
public struct AssistantHandoff: Codable, Equatable, Identifiable, Sendable {
  public enum State: String, Codable, Sendable { case waiting, running, done, failed, declined, expired }
  public var id: String
  public var from: String
  public var to: String
  public var task: String
  /// The seat's hidden chat, where the task runs (`seat-<id>`; its target's Main chat in older ledgers).
  public var threadID: String
  /// The chat it was asked in, where its status line and result show.
  public var askedIn: String
  /// The team it counts against: its id, or "" for the implicit team of everyone.
  public var team: String
  public var teamName: String
  public var createdAt: Date
  public var startedAt: Date?
  /// The last time the target's run showed progress (a step or a message).
  public var progressAt: Date?
  public var finishedAt: Date?
  public var state: State
  /// The target's final reply, or why it failed. Untrusted: it may quote web pages.
  public var result: String?
  /// The stall notice went (once).
  public var stalled: Bool?
  /// The result reached the asking assistant's chat (once). Only `HandoffLedger.claimReport` sets it.
  public fileprivate(set) var reported: Bool?
  /// Asked from a chat that read the person's mail, messages or Mac apps: the target is not
  /// offered Serein's computer, and its chat is marked too. nil in older ledgers.
  public var personal: Bool? = nil
  /// The first hand-off of this chain. nil: this one is the root (and in older ledgers).
  public var rootID: String? = nil
  /// The hand-off whose target sent this one as part of its own task.
  public var parentID: String? = nil
  /// The assistants that already hold this work, from the root's sender to `from`, in order.
  /// nil for a root, where it is `from` alone.
  public var chain: [String]? = nil
  /// The room its packet is in (`Workroom`), and the packet's number there. nil in older ledgers,
  /// and `packet` nil when its packet could not be sealed, so nothing trusts a missing file.
  public var room: String? = nil
  public var packet: Int? = nil
  /// Started by an @tag in the channel, not a hand-off: the tagging message stands for its post,
  /// its reply answers that message, and it never wakes its sender. nil for a hand-off.
  public var mention: Mention? = nil
  public enum Mention: Codable, Equatable, Sendable {
    case byPerson(message: String)
    case byBot(post: String)
    /// The channel message that tagged it.
    public var post: String {
      switch self {
      case .byPerson(let message): message
      case .byBot(let post): post
      }
    }
  }

  /// A side seat (`SideSeat`): the person's own message to its chat's assistant, answered in a
  /// hidden seat beside a busy turn (`busy`) or carried on from a turn that ran long
  /// (`background`). `from` and `to` are that assistant, and the seat holds it once. nil for a hand-off.
  public var side: Side? = nil
  public enum Side: String, Codable, Sendable { case busy, background }
  /// Its report post is owed to the origin chat (false) or is there (true). nil in older ledgers
  /// and while it is open; only a row that closes owes one, so an old row is never posted again.
  public var posted: Bool? = nil

  /// `parent`: the hand-off whose target sends this one as part of its own task.
  public init(
    id: String = UUID().uuidString, from: String, to: String, task: String, threadID: String, askedIn: String,
    team: String, teamName: String, createdAt: Date = Date(), state: State = .waiting, parent: AssistantHandoff? = nil
  ) {
    self.id = id
    self.from = from
    self.to = to
    self.task = task
    self.threadID = threadID
    self.askedIn = askedIn
    self.team = team
    self.teamName = teamName
    self.createdAt = createdAt
    self.state = state
    if let parent {
      rootID = parent.rootID ?? parent.id
      parentID = parent.id
      chain = parent.holders
    }
  }
  public var isOpen: Bool { state == .waiting || state == .running }
  /// Everyone who holds this work once its target has it, in order. None of them is asked again.
  public var holders: [String] { side != nil ? [to] : (chain ?? [from]) + [to] }
  /// "Serein asked Writer, who asked you": the chain as the target's prompt says it, from the
  /// names of `chain`.
  public static func chainWords(_ names: [String]) -> String {
    guard let first = names.first else { return "" }
    return ([first + " asked"] + names.dropFirst().map { "\($0), who asked" }).joined(separator: " ") + " you"
  }
}

/// The hand-offs and their counters, saved in relay/handoffs.json (0600) so a relaunch never
/// resets a limit. Limits refuse with a reason; they never cut a task short.
public struct HandoffLedger: Codable, Equatable, Sendable {
  public var records: [AssistantHandoff]
  /// Hand-offs taken per reader per day, keyed "assistant id|yyyy-MM-dd". Keys from before were a
  /// team id, which no assistant shares, so they only age out.
  public var daily: [String: Int]

  public static let maxOpenPerAssistant = 3
  /// Hand-offs one assistant may be sent in a day, from anyone.
  public static let maxPerReaderPerDay = 20
  public static let queueExpiry: TimeInterval = 24 * 60 * 60
  public static let stallAfter: TimeInterval = 30 * 60
  /// Closed hand-offs kept for the status lines; open ones are always kept.
  public static let kept = 50
  public static let taskLimit = 2_000
  /// The most of a closed hand-off's result kept, and of a side seat's answer posted.
  public static let resultLimit = 4_000
  /// The most assistants one task passes through, its first sender included.
  public static let maxChain = 4
  /// The most hand-offs that share one root, the root included.
  public static let maxPerRoot = 8

  public init(records: [AssistantHandoff] = [], daily: [String: Int] = [:]) {
    self.records = records
    self.daily = daily
  }

  static func key(_ reader: String, _ now: Date) -> String { reader + "|" + RelayProactive.dayKey(now) }

  /// The open hand-off whose target works in `thread`, if any.
  public func open(thread: String) -> AssistantHandoff? {
    records.first { $0.isOpen && $0.threadID == thread }
  }
  /// The hand-off that holds `thread` now: its target works there, or waits there for what it
  /// handed on. At most one per chat. What that chat hands on is part of it.
  public func running(thread: String) -> AssistantHandoff? {
    records.first { $0.state == .running && $0.threadID == thread }
  }
  /// Whether `id` may close: nothing its target handed on is still open, and every result of
  /// those has reached its chat.
  public func closable(_ id: String) -> Bool {
    !records.contains { $0.parentID == id && ($0.isOpen || $0.reported != true) }
  }
  /// Whether `a` holds its chat for `b`: part of a task `a` was handed is open with `b`, or with
  /// someone who holds theirs for `b`. A hand-off back the other way would never start.
  func waits(_ a: String, on b: String, seen: Set<String> = []) -> Bool {
    guard !seen.contains(a) else { return false }
    return records.contains {
      $0.isOpen && $0.parentID != nil && $0.from == a && ($0.to == b || waits($0.to, on: b, seen: seen.union([a])))
    }
  }

  /// Why `parent`'s target (`fromName`) cannot hand part of its task to `to`, or nil: no loop, at
  /// most `maxChain` assistants on one task, at most `maxPerRoot` hand-offs under one root.
  public func chainRefusal(parent: AssistantHandoff, fromName: String, to: String, toName: String) -> String? {
    if parent.holders.contains(to) {
      return "\(toName) already holds this task further up the chain, so it can't go back there. Reply with what you have instead."
    }
    if waits(to, on: parent.to) {
      return "\(toName) is waiting on \(fromName) for another task, so it can't take this one now. Reply with what you have instead."
    }
    if parent.holders.count >= Self.maxChain {
      return "This task has already passed through \(Self.maxChain) assistants, the most for one task. Finish it yourself, or reply with what you have."
    }
    let root = parent.rootID ?? parent.id
    if records.filter({ $0.id == root || $0.rootID == root }).count >= Self.maxPerRoot {
      return "This task has been handed on \(Self.maxPerRoot) times, the most for one task. Finish it yourself, or reply with what you have."
    }
    return nil
  }

  /// Why a new hand-off from `from` to `to` cannot be sent now, or nil. The day's cap is the
  /// reader's: hand-offs no longer need a shared team, and a root already stops at `maxPerRoot`,
  /// so the one flood left to bound is many tasks into one assistant. `to` is "" for an assistant
  /// not made yet, which has had nothing.
  public func refusal(from: String, fromName: String, to: String, toName: String, now: Date) -> String? {
    // A side seat is the person's message, not a hand-off the assistant sent.
    if records.filter({ $0.from == from && $0.isOpen && $0.side == nil }).count >= Self.maxOpenPerAssistant {
      return "\(fromName) already has \(Self.maxOpenPerAssistant) hand-offs open. Wait for one to finish, or do this part yourself."
    }
    if !to.isEmpty, (daily[Self.key(to, now)] ?? 0) >= Self.maxPerReaderPerDay {
      return "\(toName) has been handed \(Self.maxPerReaderPerDay) tasks today, the most in a day. Hand this to another assistant, or do this part yourself."
    }
    return nil
  }
  /// A hand-off: recorded and counted toward its reader's day. A side seat is recorded only.
  public mutating func admit(_ handoff: AssistantHandoff, now: Date) {
    records.append(handoff)
    if handoff.side == nil { daily[Self.key(handoff.to, now), default: 0] += 1 }
    trim(now: now)
  }
  /// Hand-offs that waited in the queue longer than a day expire; returns them, each once.
  public mutating func expire(now: Date) -> [AssistantHandoff] {
    var gone: [AssistantHandoff] = []
    for i in records.indices where records[i].state == .waiting && now.timeIntervalSince(records[i].createdAt) > Self.queueExpiry {
      records[i].state = .expired
      records[i].finishedAt = now
      gone.append(records[i])
    }
    return gone
  }
  /// Running hand-offs with no progress for 30 minutes whose notice has not gone; marks them.
  /// One that only waits on what its target handed on is not stuck. `live`: the chats with a
  /// run now, where a hand-off works itself.
  public mutating func stall(now: Date, live: Set<String>) -> [AssistantHandoff] {
    var stuck: [AssistantHandoff] = []
    for i in records.indices
    where records[i].state == .running && records[i].stalled != true && (live.contains(records[i].threadID) || closable(records[i].id)) {
      let since = records[i].progressAt ?? records[i].startedAt ?? records[i].createdAt
      if now.timeIntervalSince(since) > Self.stallAfter {
        records[i].stalled = true
        stuck.append(records[i])
      }
    }
    return stuck
  }
  /// Stop Everything: every hand-off that holds a chat ends as failed, and with it each part
  /// still queued under one. None is told to anyone, so no result is left to start its parent
  /// again. Hand-offs queued on their own keep waiting. Returns what ended.
  public mutating func stop(now: Date) -> [AssistantHandoff] {
    var ended: [AssistantHandoff] = []
    for i in records.indices where records[i].state == .running || (records[i].state == .waiting && records[i].parentID != nil) {
      records[i].state = .failed
      records[i].finishedAt = now
      records[i].result = Self.stoppedWords
      _ = claimReport(records[i].id)
      ended.append(records[i])
    }
    return ended
  }
  public static let stoppedWords = "It was stopped."
  /// The only writer of `reported` (TEAMS-V2 §4.8): a closed hand-off's report is claimed once.
  /// nil while it is open or once it was claimed, so a replayed delivery or the launch sweep
  /// (`sweepHandoffs`, first run at launch) delivers nothing twice.
  public mutating func claimReport(_ id: AssistantHandoff.ID) -> AssistantHandoff? {
    guard let i = records.firstIndex(where: { $0.id == id }), !records[i].isOpen, records[i].reported != true else { return nil }
    records[i].reported = true
    return records[i]
  }
  /// Open hand-offs kept whole, and every closed one of a task that still has one open (its
  /// count is the limit per root, and its result may be owed to its parent); then the newest
  /// closed ones. Counters only for today.
  public mutating func trim(now: Date) {
    let live = Set(records.filter(\.isOpen).map { $0.rootID ?? $0.id })
    let closed = records.filter { !$0.isOpen && !live.contains($0.rootID ?? $0.id) }.suffix(Self.kept)
    let keep = Set(closed.map(\.id))
    records = records.filter { live.contains($0.rootID ?? $0.id) || keep.contains($0.id) }
    let today = "|" + RelayProactive.dayKey(now)
    daily = daily.filter { $0.key.hasSuffix(today) }
  }
}
