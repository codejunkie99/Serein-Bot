import Foundation

/// The assistants board in the sidebar: which list the sidebar shows, one state per assistant, a
/// folded team's one-line "Now" summary, and the roster edits the board's menus and sheets make.
/// Everything here is pure, so SereinChecks can test it; the views only read it.

/// Sidebar routing, including the retired Agents value for saved-window compatibility.
public enum SidebarMode: String, CaseIterable, Sendable {
  /// Serein is the visible place; old Agents state resolves there without discarding tasks.
  case serein, assistants
  /// The retired Agents place resolves to the assistant; existing saved values remain readable.
  public var place: SidebarMode { .serein }
  /// Saved with the window (user defaults; the main window is the only one with a sidebar).
  public static let key = "serein.sidebar.mode"
  public var label: String {
    switch self {
    case .serein: return "Serein"
    case .assistants: return "Agents"
    }
  }
  public var shortcut: String {
    switch self {
    case .serein: return "⌃1"
    case .assistants: return "⌃2"
    }
  }
  public var help: String { "\(label) · \(shortcut)" }
  /// Assistant and task routes belong to Serein. Other surfaces keep the current place (nil).
  public static func mode(for section: String) -> SidebarMode? {
    switch section {
    case ShellSection.serein: return .serein
    case ShellSection.agents, ShellSection.thread, ShellSection.agent: return .serein
    default: return nil
    }
  }
}

/// The attention dot on the Tabs | Assistants switch and on the header's assistant picker.
public enum AssistantBoard {
  public enum Attention: Equatable, Sendable {
    case none
    /// Assistants waiting on a card, by name.
    case needsYou([String])
    /// An assistant with a reply you have not seen.
    case unread(String)
  }
  /// Amber wins over accent: a card waiting beats an unread reply.
  public static func attention(_ states: [(name: String, status: SereinStatus)]) -> Attention {
    let waiting = states.filter { $0.status == .needsYou }.map(\.name)
    if !waiting.isEmpty { return .needsYou(waiting) }
    if let unread = states.first(where: { $0.status == .unread }) { return .unread(unread.name) }
    return .none
  }
  /// "Writer needs you", "Writer and 1 more need you", "New reply from Scout"; nil for nothing.
  public static func words(_ attention: Attention) -> String? {
    switch attention {
    case .none: return nil
    case .needsYou(let names):
      guard let first = names.first else { return nil }
      return names.count == 1 ? "\(first) needs you" : "\(first) and \(names.count - 1) more need you"
    case .unread(let name): return "New reply from \(name)"
    }
  }
  /// A folded team's one mark: the most pressing member state. Busy members fold into one
  /// spinner with their count, so the mark never claims a team is idle while someone works.
  public static func pressing(_ statuses: [SereinStatus]) -> SereinStatus {
    if statuses.contains(.needsYou) { return .needsYou }
    let busy = statuses.filter(\.spins).count
    if busy > 0 { return .working(busy) }
    if statuses.contains(.unread) { return .unread }
    if statuses.contains(.paused) { return .paused }
    return .ready
  }
  /// How a state ranks among members, most pressing first (the Now line's order).
  public static func rank(_ status: SereinStatus) -> Int {
    switch status {
    case .needsYou: return 0
    case .replying, .working: return 1
    case .unread: return 2
    case .paused: return 3
    default: return 4
    }
  }
  /// Never sites an assistant may list; the editor refuses more.
  public static let neverSitesLimit = 100
  /// The VoiceOver value of an assistant row: the state, then the idle marks that apply.
  public static func spoken(status: SereinStatus, lead: Bool, speaksFirst: Bool, answers: Bool) -> String {
    var parts = [status.spoken]
    if lead { parts.append("Lead") }
    if !speaksFirst { parts.append("Doesn't speak first") }
    if answers { parts.append("Answers ⌥Space") }
    return parts.joined(separator: ", ")
  }
}

/// A folded team header's second line: who is busy and with what, else who is in the team.
public enum TeamNowLine {
  public struct Member: Equatable, Sendable {
    public var name: String
    public var status: SereinStatus
    /// The run's short live line ("Checking flights…"), when one works.
    public var phase: String?
    public init(name: String, status: SereinStatus, phase: String? = nil) {
      self.name = name
      self.status = status
      self.phase = phase
    }
  }
  /// At most this many busy members are named; the rest are "N more busy".
  public static let namedBusy = 2
  /// Idle teams name this many members, then "and N more".
  public static let namedIdle = 3

  public static func text(_ members: [Member]) -> String {
    let busy = members.filter { AssistantBoard.rank($0.status) < 4 }
      .sorted { AssistantBoard.rank($0.status) < AssistantBoard.rank($1.status) }
    guard !busy.isEmpty else {
      let names = members.map(\.name)
      if names.count <= namedIdle { return names.joined(separator: ", ") }
      return names.prefix(namedIdle).joined(separator: ", ") + " and \(names.count - namedIdle) more"
    }
    var parts = busy.prefix(namedBusy).map(line)
    if busy.count > namedBusy { parts.append("\(busy.count - namedBusy) more busy") }
    return parts.joined(separator: " · ")
  }
  /// One busy member: "Planner needs you", "Scout researching flights", "Writer replied".
  public static func line(_ member: Member) -> String {
    switch member.status {
    case .needsYou: return "\(member.name) needs you"
    case .replying, .working:
      let phase = member.phase.map(Self.phase) ?? ""
      return "\(member.name) \(phase.isEmpty ? "working" : phase)"
    case .unread: return "\(member.name) replied"
    case .paused: return "\(member.name) paused"
    default: return member.name
    }
  }
  /// A run's live line as the Now line reads it: the first letter lowercased, no ellipsis.
  public static func phase(_ live: String) -> String {
    var words = live.trimmingCharacters(in: .whitespacesAndNewlines)
    while words.hasSuffix("…") || words.hasSuffix(".") { words.removeLast() }
    words = words.trimmingCharacters(in: .whitespaces)
    guard let first = words.first else { return "" }
    return first.lowercased() + words.dropFirst()
  }
}

/// The roster edits the board makes by hand (menus, drags, the editor), each a pure rule on
/// `RelayTeam` so `changeTeam` journals it. Every one returns nil to refuse, and none widens
/// what an assistant may use past the person's own places.
extension RelayTeam {
  /// The main assistant: the first profile, which single-assistant setups migrated into.
  public var main: RelayProfile? { profiles.first { $0.id == Self.mainID } ?? profiles.first }
  public func group(_ id: String) -> AssistantGroup? { teams.first { $0.id == id } }
  /// The teams an assistant is in, in the person's order.
  public func groups(of profileID: String) -> [AssistantGroup] { teams.filter { $0.memberIDs.contains(profileID) } }
  /// Assistants in no team, in creation order.
  public var ungrouped: [RelayProfile] { profiles.filter { groups(of: $0.id).isEmpty } }

  private func replacingGroup(_ group: AssistantGroup) -> RelayTeam {
    var team = self
    team.groups = teams.map { $0.id == group.id ? group : $0 }
    return team
  }
  /// Adds an assistant to a team; nil when it is already in, or either is unknown.
  public func addingMember(_ profileID: String, to groupID: String) -> RelayTeam? {
    guard var group = group(groupID), profiles.contains(where: { $0.id == profileID }),
      !group.memberIDs.contains(profileID)
    else { return nil }
    group.memberIDs.append(profileID)
    return replacingGroup(group)
  }
  /// Takes an assistant out of one team only; the team goes when nobody is left.
  public func removingMember(_ profileID: String, from groupID: String) -> RelayTeam? {
    guard let group = group(groupID), group.memberIDs.contains(profileID) else { return nil }
    var team = self
    if let left = group.without(profileID) {
      team.groups = teams.map { $0.id == groupID ? left : $0 }
    } else {
      team.groups = teams.filter { $0.id != groupID }
    }
    return team
  }
  /// Sets or clears a team's lead; the lead must be a member.
  public func settingLead(_ profileID: String?, of groupID: String) -> RelayTeam? {
    guard var group = group(groupID), profileID.map({ group.memberIDs.contains($0) }) ?? true,
      group.leadID != profileID
    else { return nil }
    group.leadID = profileID
    return replacingGroup(group)
  }
  /// Renames a team; the name stays unique and within the limit.
  public func renamingGroup(_ groupID: String, to name: String) -> RelayTeam? {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var group = group(groupID), !clean.isEmpty, clean.count <= AssistantGroup.nameLimit,
      !teams.contains(where: { $0.id != groupID && $0.name.caseInsensitiveCompare(clean) == .orderedSame })
    else { return nil }
    group.name = clean
    return replacingGroup(group)
  }
  /// Puts a team's members in a new order (the same members, each once).
  public func orderingMembers(_ order: [String], of groupID: String) -> RelayTeam? {
    guard var group = group(groupID), Set(order) == Set(group.memberIDs), order.count == group.memberIDs.count,
      order != group.memberIDs
    else { return nil }
    group.memberIDs = order
    return replacingGroup(group)
  }
  /// Puts the teams in a new order (the same teams, each once).
  public func orderingGroups(_ order: [String]) -> RelayTeam? {
    let ids = teams.map(\.id)
    guard Set(order) == Set(ids), order.count == ids.count, order != ids else { return nil }
    var team = self
    team.groups = order.compactMap { id in teams.first { $0.id == id } }
    return team
  }
  /// A copy of a team, and on request of its assistants ("Scout copy"), who can do the same and
  /// never more. nil when the name is taken.
  public func duplicatingGroup(_ groupID: String, as name: String, copyingMembers: Bool) -> RelayTeam? {
    guard let group = group(groupID) else { return nil }
    guard copyingMembers else { return addingGroup(AssistantGroup(name: name, memberIDs: group.memberIDs, leadID: group.leadID)) }
    var team = self
    var copies: [String: String] = [:]
    for id in group.memberIDs {
      guard let source = profiles.first(where: { $0.id == id }) else { return nil }
      let copyName = RelayProfile.cleanName(Self.copyName(source.name, taken: team.profiles.map(\.name)))
      guard let next = team.adding(copyName), let made = next.profiles.last else { return nil }
      team = next
      team.profiles[team.profiles.count - 1].scope = source.scope
      copies[id] = made.id
    }
    let members = group.memberIDs.compactMap { copies[$0] }
    return team.addingGroup(AssistantGroup(name: name, memberIDs: members, leadID: group.leadID.flatMap { copies[$0] }))
  }
  /// The tints `count` new assistants would get, in order (`addingTeam` gives them so), for the
  /// sheets and cards that show them before they exist.
  public func nextTints(_ count: Int) -> [String] {
    var used = profiles.map(\.colour)
    return (0..<max(0, count)).map { _ in
      let next = AssistantColour.next(used: used)
      used.append(next)
      return next
    }
  }
  /// "Scout copy", then "Scout copy 2", within the name limit.
  public static func copyName(_ name: String, taken: [String]) -> String {
    let base = String(name.prefix(RelayProfile.nameLimit - 7)) + " copy"
    var candidate = base
    var n = 2
    while taken.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
      candidate = String(base.prefix(RelayProfile.nameLimit - 1 - String(n).count)) + " \(n)"
      n += 1
    }
    return candidate
  }
  /// "Scout" while free, else "Scout 2", "Scout 3": a starter's member next to an assistant of
  /// the same name.
  public static func freeName(_ name: String, taken: [String]) -> String {
    var candidate = name
    var n = 2
    while taken.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
      candidate = String(name.prefix(RelayProfile.nameLimit - 1 - String(n).count)) + " \(n)"
      n += 1
    }
    return candidate
  }

  /// The editor's save: name, colour, icon, what it may use, Never sites, instructions and Speaks
  /// first. It only narrows: every place must be one the person allows, at least one stays on, at
  /// most `neverSitesLimit` sites, instructions within their limit, an icon well formed. nil
  /// refuses the whole save. A nil scope keeps the person's full settings (nothing narrowed), so
  /// places the person turns on later still reach it.
  public func updatingProfile(
    _ id: String, name: String, colour: String?, icon: AssistantIcon?, scope: AssistantScope?,
    speaksFirst: RelayProactive.Level?, person: Set<AssistantPlace>
  ) -> RelayTeam? {
    guard var team = renaming(id, to: name), let i = team.profiles.firstIndex(where: { $0.id == id }) else { return nil }
    if let scope {
      guard !scope.destinations.isEmpty, scope.destinations.isSubset(of: person),
        scope.neverSites.count <= AssistantBoard.neverSitesLimit,
        scope.instructions.count <= AssistantScope.instructionsLimit
      else { return nil }
    }
    guard colour.map({ AssistantColour.all.contains($0) }) ?? true, icon?.checked == icon else { return nil }
    team.profiles[i].colour = colour
    team.profiles[i].icon = icon
    team.profiles[i].scope = scope
    team.profiles[i].speaksFirst = speaksFirst
    return team
  }
  /// Only Speaks first (a row's menu).
  public func settingSpeaksFirst(_ id: String, _ level: RelayProactive.Level) -> RelayTeam? {
    guard let i = profiles.firstIndex(where: { $0.id == id }), profiles[i].speaksFirst != level else { return nil }
    var team = self
    team.profiles[i].speaksFirst = level
    return team
  }
}

extension RelayProfile {
  public static let nameLimit = 40
  public static let labelLimit = 40
  public static let labelRefusal = "A label is one line of plain text, without emoji joiners or direction marks."
  /// A label as it is saved: trimmed, at most `labelLimit` characters, one line of plain text
  /// with no control, format or direction characters (`TeamProposal.oneLine`, as names are
  /// checked; emoji joined with a zero-width joiner are refused with them). ""
  /// clears it; nil refuses.
  public static func cleanLabel(_ text: String) -> String? {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clean.count <= labelLimit, TeamProposal.oneLine(clean) else { return nil }
    return clean
  }
}

/// An assistant's own engine: a harness instance id (`ModelRoute.provider`) and one of its
/// model ids ("" is the harness's own default). Never a key or a sign-in.
public struct AssistantRoute: Codable, Equatable, Sendable {
  public var provider: String
  public var model: String
  /// The effort the person picked on the composer's effort chip; nil is the model's own. Used only
  /// while the model's app lists it (`RelayToolHost.modelAndEffort`).
  public var effort: String?
  public init(provider: String, model: String, effort: String? = nil) {
    self.provider = provider
    self.model = model
    self.effort = effort
  }
}

extension RelayTeam {
  /// Sets or clears an assistant's label, for `changeTeam` to journal (Undo puts it back). nil
  /// refuses: an unknown assistant, an unchanged label, or one `cleanLabel` refuses.
  public func settingLabel(_ id: String, _ text: String) -> RelayTeam? {
    guard let clean = RelayProfile.cleanLabel(text), let i = profiles.firstIndex(where: { $0.id == id }) else { return nil }
    let label: String? = clean.isEmpty ? nil : clean
    guard profiles[i].label != label else { return nil }
    var team = self
    team.profiles[i].label = label
    return team
  }
  /// Sets or clears an assistant's icon (nil is the petal), for `changeTeam` to journal (Undo puts
  /// it back). nil refuses: an unknown assistant, an unchanged icon, or one not well formed.
  public func settingIcon(_ id: String, _ icon: AssistantIcon?) -> RelayTeam? {
    guard icon?.checked == icon, let i = profiles.firstIndex(where: { $0.id == id }), profiles[i].icon != icon else { return nil }
    var team = self
    team.profiles[i].icon = icon
    return team
  }
  /// Sets or clears an assistant's own route. Saved outside the journal, and `undoing` keeps every
  /// current route, so an undo never moves an assistant onto an engine that could change who pays.
  /// A change to Serein's first pins every other assistant with no route to the one it thinks with
  /// now (`route(of:)`, else `fallback`, Settings' default AI app), so it moves only Serein.
  public func settingRoute(_ id: String, _ route: AssistantRoute?, fallback: AssistantRoute) -> RelayTeam? {
    guard let i = profiles.firstIndex(where: { $0.id == id }), profiles[i].route != route else { return nil }
    var team = self
    if id == main?.id {
      for j in team.profiles.indices where team.profiles[j].route == nil && j != i {
        team.profiles[j].route = self.route(of: profiles[j]) ?? fallback
      }
    }
    team.profiles[i].route = route
    return team
  }
  /// "All assistants": every assistant, Serein too, thinks with `route`, and assistants made later
  /// start with it. One already on that app and model keeps its effort; the others take the
  /// model's own, as a single pick does. The starting route is set last, in the same value, so one
  /// save carries all of it. nil when nothing would change.
  public func settingEveryRoute(_ route: AssistantRoute) -> RelayTeam? {
    var team = self
    for i in team.profiles.indices {
      let now = self.route(of: profiles[i])
      let same = now?.provider == route.provider && now?.model == route.model
      team.profiles[i].route = AssistantRoute(provider: route.provider, model: route.model, effort: same ? now?.effort : nil)
    }
    team.startingRoute = AssistantRoute(provider: route.provider, model: route.model)
    return team == self ? nil : team
  }
  /// The route an assistant thinks with: its own, else the starting route ("All assistants"),
  /// else Serein's, as an assistant with none thinks as Serein does. nil is Serein's engine with no
  /// route (Settings' default AI app).
  public func route(of profile: RelayProfile) -> AssistantRoute? {
    profile.route ?? (profile.id == main?.id ? nil : startingRoute ?? main?.route)
  }
}

/// The six starter teams: names, a persona line, what each member would like to use and its
/// instructions. Never a model, a site or an app; a place the person has turned off is dropped
/// and listed before anything is added.
public struct TeamStarter: Identifiable, Equatable, Sendable {
  public struct Member: Equatable, Sendable {
    public var name: String
    public var colour: String
    public var persona: String
    public var places: Set<AssistantPlace>
    public var instructions: String
  }
  public var id: String
  public var name: String
  public var line: String
  public var members: [Member]
  /// Shown only while this place is on for Serein (Inbox and calendar needs Mac access).
  public var requires: AssistantPlace?

  public static let all: [TeamStarter] = [
    TeamStarter(id: "trip", name: "Trip planner", line: "Finds options and turns them into a day-by-day plan.", members: [
      Member(name: "Scout", colour: "sky", persona: "Finds flights, stays and things to do.", places: [.web, .answer],
             instructions: "Look for three options for each request and list prices, times and the source of each. Never book or pay; hand the options to Planner."),
      Member(name: "Planner", colour: "teal", persona: "Turns the options into a day-by-day plan.", places: [.answer],
             instructions: "Make a day-by-day plan from the options you are given, with times and travel between places. Keep everything the person mentioned; if something cannot fit, say what you left out and why."),
    ], requires: nil),
    TeamStarter(id: "research", name: "Research and write", line: "Looks things up, then writes it clearly.", members: [
      Member(name: "Researcher", colour: "violet", persona: "Looks things up and keeps the sources.", places: [.web, .answer],
             instructions: "Find what the person asks about, prefer primary sources, and keep a short list of where each fact came from. Hand the findings to Writer."),
      Member(name: "Writer", colour: "rose", persona: "Writes and edits drafts.", places: [.answer],
             instructions: "Write clearly and briefly in the person's own tone. Keep every fact you were given and never add one you cannot trace."),
    ], requires: nil),
    TeamStarter(id: "shopping", name: "Shopping compare", line: "Finds the item in a few shops and checks the details.", members: [
      Member(name: "Finder", colour: "tangerine", persona: "Finds the item in a few shops.", places: [.web, .answer],
             instructions: "Find the item in three shops and list the price, shipping and return terms of each. Never add anything to a basket."),
      Member(name: "Checker", colour: "moss", persona: "Checks the details before you buy.", places: [.web, .answer],
             instructions: "Check the exact model, the seller's reviews and the total cost of the options you are given, and say which fits best and why."),
    ], requires: nil),
    TeamStarter(id: "inbox", name: "Inbox and calendar", line: "Sorts mail and finds time on your calendar.", members: [
      Member(name: "Sorter", colour: "slate", persona: "Sorts mail into what needs you.", places: [.mac, .answer],
             instructions: "Read the inbox and say what needs an answer, what can wait and what is noise. Never send, reply, archive or delete."),
      Member(name: "Scheduler", colour: "sky", persona: "Finds time on your calendar.", places: [.mac, .answer],
             instructions: "Find free slots that fit what the person asks and list them. Never create, move or accept an event without asking."),
    ], requires: .mac),
    TeamStarter(id: "jobs", name: "Job hunt", line: "Finds openings and drafts the letters.", members: [
      Member(name: "Scout", colour: "sky", persona: "Finds openings that fit.", places: [.web, .answer],
             instructions: "Find openings that match what the person is looking for and list the role, the company, the deadline and the link. Never apply or fill a form."),
      Member(name: "Writer", colour: "rose", persona: "Drafts the letters.", places: [.answer],
             instructions: "Draft a short cover letter for each opening you are given, in the person's own words and tone, and leave every claim for them to confirm."),
    ], requires: nil),
    TeamStarter(id: "home", name: "Home admin", line: "Keeps bills, forms and dates in order.", members: [
      Member(name: "Organizer", colour: "teal", persona: "Keeps bills and forms in order.", places: [.web, .answer],
             instructions: "Keep a list of bills, forms and their due dates from what the person gives you. Never pay or submit anything."),
      Member(name: "Reminder", colour: "violet", persona: "Reminds you before dates.", places: [.answer],
             instructions: "Say what is due in the next two weeks and what is needed for each, in a few lines. Ask before setting any reminder."),
    ], requires: nil),
  ]
  /// The starters to offer: Inbox and calendar only while Mac access is on.
  public static func offered(person: Set<AssistantPlace>) -> [TeamStarter] {
    all.filter { $0.requires.map(person.contains) ?? true }
  }
  /// This starter as a proposal for the person's roster: taken names become "Scout 2", places the
  /// person has turned off are dropped and listed, as a proposal from a description is.
  public func proposal(person: Set<AssistantPlace>, team: RelayTeam) -> TeamProposal {
    var taken = team.profiles.map(\.name)
    var members: [TeamProposal.Member] = []
    for member in self.members {
      let name = RelayTeam.freeName(member.name, taken: taken)
      taken.append(name)
      let dropped = AssistantPlace.allCases.filter { member.places.contains($0) && !person.contains($0) }.map(\.label)
      members.append(TeamProposal.Member(
        name: name, persona: member.persona, places: member.places.intersection(person), dropped: dropped,
        instructions: member.instructions))
    }
    var proposalName = name
    var n = 2
    while team.teams.contains(where: { $0.name.caseInsensitiveCompare(proposalName) == .orderedSame }) {
      proposalName = "\(name) \(n)"
      n += 1
    }
    return TeamProposal(name: proposalName, members: members, lead: members.first?.name)
  }
}

/// A team as a file (Export Team… and Import file). The file holds names, what each member may
/// use, its Never sites, instructions, an emoji or symbol icon and the lead: never keys, chat
/// history, models, pictures or the person's grants, which the file lists as left out. What comes
/// back in is untrusted input: every member arrives able to use nothing until the person turns
/// places on.
public struct TeamFile: Codable, Equatable, Sendable {
  public struct Member: Codable, Equatable, Sendable {
    public var name: String
    public var canUse: [String]
    public var neverSites: [String]
    public var instructions: String
    /// An emoji or a symbol (`AssistantIcon.shareable`); never a picture. Optional, so a file
    /// written before icons reads.
    public var icon: AssistantIcon?
    enum CodingKeys: String, CodingKey { case name, canUse, neverSites, instructions, icon }
  }
  public static let format = "serein-team"
  public static let version = 1
  /// What an export never carries, in the words the sheet shows.
  public static let stripped = ["Keys and sign-ins", "Chat history", "Models", "Permissions and approvals", "Pictures"]
  /// The largest file Serein reads.
  public static let maxBytes = 256 * 1024

  public var format: String
  public var version: Int
  public var name: String
  public var members: [Member]
  public var lead: String?
  public var leftOut: [String]

  /// Each value is redacted on its own before encoding, so a secret that found its way into an
  /// instruction never reaches disk and the JSON stays whole.
  public init(group: AssistantGroup, profiles: [RelayProfile]) {
    format = Self.format
    version = Self.version
    name = AgentPrivacy.redact(group.name)
    let chosen = group.memberIDs.compactMap { id in profiles.first { $0.id == id } }
    let names = Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, AgentPrivacy.redact($0.name)) })
    members = chosen.map { profile in
      Member(
        name: names[profile.id] ?? "",
        canUse: AssistantPlace.allCases.filter { profile.scope?.destinations.contains($0) ?? true }.map(\.rawValue),
        neverSites: profile.scope?.neverSites ?? [],
        instructions: AgentPrivacy.redact(profile.scope?.instructions ?? "", limit: AssistantScope.instructionsLimit),
        icon: profile.icon?.shareable)
    }
    lead = group.leadID.flatMap { names[$0] }
    leftOut = Self.stripped
  }
  /// The file's text: pretty JSON with stable keys (its values were redacted in `init`).
  public func text() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
  }
  /// "Trip planner.serein-team": the name the save panel suggests.
  public static func fileName(_ name: String) -> String { SafeFileName.export(name, fallback: "Team", ext: format) }
  /// A name from a file without the hidden characters the board's own rename accepts (a joiner in
  /// an emoji, a non-joiner, a direction mark, a soft hyphen), so a team Serein exported imports
  /// again. Line breaks, control characters and direction overrides or isolates stay, so
  /// `TeamProposal.parse` still refuses them.
  static func plain(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    out.append(contentsOf: s.unicodeScalars.filter {
      !SafeFileName.hidden($0) || $0.properties.generalCategory == .control
        || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
    })
    return String(out)
  }
  /// Reads a file the person chose. Limits refuse rather than cut (`TeamProposal.parse`). Every
  /// member arrives with no place at all: "Can use" waits for the person; its Never sites stay,
  /// since they only narrow. The team's name takes a free one when the file's is taken.
  public static func proposal(from data: Data, team: RelayTeam) throws -> TeamProposal {
    guard data.count <= maxBytes, let file = try? JSONDecoder().decode(TeamFile.self, from: data),
      file.format == format, file.version <= version
    else { throw SereinError.invalid("This file isn't a team Serein can read.") }
    guard file.members.allSatisfy({ $0.neverSites.count <= AssistantBoard.neverSitesLimit }) else {
      throw SereinError.invalid("This file isn't a team Serein can read.")
    }
    var name = plain(file.name).trimmingCharacters(in: .whitespacesAndNewlines)
    var n = 2
    let base = name
    while team.teams.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
      name = String(base.prefix(AssistantGroup.nameLimit - 1 - String(n).count)) + " \(n)"
      n += 1
    }
    // A name already on the roster becomes "Scout 2", as a starter's does, so a team exported on
    // this Mac imports again; the card shows the new names before Add team.
    var taken = team.profiles.map(\.name)
    var renamed: [String: String] = [:]
    let members = file.members.map { member -> [String: Any] in
      let free = RelayTeam.freeName(plain(member.name).trimmingCharacters(in: .whitespacesAndNewlines), taken: taken)
      taken.append(free)
      renamed[member.name] = free
      return ["name": free, "canUse": [String](), "instructions": member.instructions]
    }
    var arguments: [String: Any] = ["name": name, "members": members]
    if let lead = file.lead { arguments["lead"] = renamed[lead] ?? plain(lead) }
    do {
      var proposal = try TeamProposal.parse(arguments, person: [], team: team)
      for i in proposal.members.indices {
        proposal.members[i].neverSites = AssistantScope(destinations: [], neverSites: file.members[i].neverSites).neverSites
        // An emoji or a symbol, checked; a picture's name from a file is dropped unread.
        proposal.members[i].icon = file.members[i].icon?.shareable
      }
      return proposal
    } catch {
      throw SereinError.invalid("This file isn't a team Serein can read.")
    }
  }
}

extension TeamFile.Member {
  /// A bad icon is dropped, not the file: it is only cosmetic.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    canUse = try c.decode([String].self, forKey: .canUse)
    neverSites = try c.decode([String].self, forKey: .neverSites)
    instructions = try c.decode(String.self, forKey: .instructions)
    icon = (try? c.decodeIfPresent(AssistantIcon.self, forKey: .icon)) ?? nil
  }
}

extension AssistantScope {
  /// The persona line's mark at the top of an assistant's instructions, as `TeamProposal.saved`
  /// writes it: "Who you are: Writes and edits drafts". The editor's "What it does" field reads
  /// and writes that line; the rest is its extra instructions.
  public static let personaMark = "Who you are: "
  public var personaLine: String {
    guard instructions.hasPrefix(Self.personaMark) else { return "" }
    return String(instructions.dropFirst(Self.personaMark.count).prefix { !$0.isNewline })
  }
  public var extraInstructions: String {
    guard instructions.hasPrefix(Self.personaMark) else { return instructions }
    let rest = instructions.drop { !$0.isNewline }
    return String(rest.dropFirst())
  }
  /// The saved text for a persona line and extra instructions (either may be empty).
  public static func instructions(persona: String, extra: String) -> String {
    let line = persona.trimmingCharacters(in: .whitespacesAndNewlines)
    let rest = extra.trimmingCharacters(in: .whitespacesAndNewlines)
    var parts: [String] = []
    if !line.isEmpty { parts.append(personaMark + line) }
    if !rest.isEmpty { parts.append(rest) }
    return parts.joined(separator: "\n")
  }
}

extension TeamProposal {
  /// A proposal as `parse` reads it, so an edited one (Change… on the card) is checked by the
  /// same rules before it is created.
  public var arguments: [String: Any] {
    var out: [String: Any] = [
      "name": name,
      "members": members.map { member -> [String: Any] in
        ["name": member.name, "persona": member.persona, "canUse": AssistantPlace.allCases.filter(member.places.contains).map(\.rawValue),
         "instructions": member.instructions]
      },
    ]
    if let lead { out["lead"] = lead }
    return out
  }
}
