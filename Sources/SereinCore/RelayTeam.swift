import Foundation

/// The roster of Serein's assistants (one engine, several named profiles): each profile has its own
/// name, persona, Main-chat thread and notes; schedules, watches and the user's reminders are the
/// user's and stay shared. The active profile answers ⌥Space. Everything here is pure, so it is
/// checked in SereinChecks.
public struct RelayProfile: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var createdAt: Date
  /// What this assistant may use, narrower than the person's settings (`AssistantScope.effective`).
  /// nil is the person's full settings, as every assistant had before scopes. Optional, so a
  /// team.json written before it decodes.
  public var scope: AssistantScope?
  /// Its tint, a name from `AssistantColour.all`, picked automatically. Optional like `scope`.
  public var colour: String?
  /// Whether it speaks first (RelayProactive.Level). nil, as every new assistant starts, uses
  /// Settings › Check-ins (`RelayProactive.level(of:in:global:)`).
  /// Stored here so the editor and the row's menu set it; the behaviour follows the shared budget.
  public var speaksFirst: RelayProactive.Level?
  /// Its own engine (the inspector's model pill): its Main chat and the tasks it starts use it.
  /// nil, as every assistant starts, keeps Serein's engine and the person's task default. Set
  /// outside the journal (`RelayTeam.settingRoute`). Optional, so a team.json written before it decodes.
  public var route: AssistantRoute?
  /// A short label the person wrote under its name ("Bookkeeping"): one line of plain text, at
  /// most `labelLimit` characters (`cleanLabel`). Shown to the person only. Optional like `route`.
  public var label: String?
  /// What its mark shows instead of the petal (`AssistantIcon`); nil is the petal in its tint.
  /// Shown to the person only. Optional like `label`.
  public var icon: AssistantIcon?
  /// The person paused it (`assistant_change` with `pause`): it starts no schedule, watch, link,
  /// ask or hand-off, and does not speak first, until it is on again. The person's own messages
  /// still reach it. nil, as every assistant starts, is on. Journaled with the roster, so Undo
  /// turns it on again. Optional like `icon`.
  public var paused: Bool?
  /// Who made it and in which room, when an assistant made it (`Staffing.make`); nil for one the
  /// person made. Optional like `paused`.
  public var lineage: Staffing.Lineage?
  enum CodingKeys: String, CodingKey { case id, name, createdAt, scope, colour, speaksFirst, route, label, icon, paused, lineage }
  public init(
    id: String = UUID().uuidString, name: String, createdAt: Date = Date(), scope: AssistantScope? = nil,
    colour: String? = nil, speaksFirst: RelayProactive.Level? = nil, route: AssistantRoute? = nil, label: String? = nil,
    icon: AssistantIcon? = nil, paused: Bool? = nil, lineage: Staffing.Lineage? = nil
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.scope = scope
    self.colour = colour
    self.speaksFirst = speaksFirst
    self.route = route
    self.label = label
    self.icon = icon
    self.paused = paused
    self.lineage = lineage
  }
  /// The person paused it.
  public var isPaused: Bool { paused == true }
  public static func cleanName(_ name: String) -> String {
    String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
  }
}

extension RelayProfile {
  /// As the synthesized decoder reads it, except a bad icon (a future kind, a wrong shape) is
  /// dropped: it is only cosmetic, and a team.json that failed to read would start a fresh roster.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    scope = try c.decodeIfPresent(AssistantScope.self, forKey: .scope)
    colour = try c.decodeIfPresent(String.self, forKey: .colour)
    speaksFirst = try c.decodeIfPresent(RelayProactive.Level.self, forKey: .speaksFirst)
    route = try c.decodeIfPresent(AssistantRoute.self, forKey: .route)
    label = try c.decodeIfPresent(String.self, forKey: .label)
    icon = (try? c.decodeIfPresent(AssistantIcon.self, forKey: .icon)) ?? nil
    paused = try c.decodeIfPresent(Bool.self, forKey: .paused)
    lineage = try c.decodeIfPresent(Staffing.Lineage.self, forKey: .lineage)
  }
}

/// An assistant's own mark in place of the petal: one emoji, one of `symbols`, or a picture the
/// person chose. The mark draws each in the assistant's tint ring, so tints still tell assistants
/// apart. A picture lives only in the assistant's folder in the Library, which no agent reads; a
/// team file or a proposal carries an emoji or a symbol at most (`shareable`).
public enum AssistantIcon: Codable, Equatable, Sendable {
  case emoji(String)
  case symbol(String)
  /// The file's name in the assistant's folder (`pictureName`), never a path.
  case picture(String)

  /// The symbols on offer, in the picker's order, suited to what assistants do.
  public static let symbols = [
    "briefcase", "airplane", "cart", "book", "chart.bar", "envelope", "calendar", "leaf", "hammer", "paintbrush",
    "music.note", "camera", "heart", "graduationcap", "globe", "magnifyingglass", "lightbulb", "doc", "terminal",
    "fork.knife", "dumbbell", "house", "gift", "sparkles",
  ]
  /// Each symbol's name for VoiceOver.
  public static let symbolLabels = [
    "briefcase": "Briefcase", "airplane": "Airplane", "cart": "Cart", "book": "Book", "chart.bar": "Chart",
    "envelope": "Envelope", "calendar": "Calendar", "leaf": "Leaf", "hammer": "Hammer", "paintbrush": "Paintbrush",
    "music.note": "Music note", "camera": "Camera", "heart": "Heart", "graduationcap": "Graduation cap", "globe": "Globe",
    "magnifyingglass": "Magnifying glass", "lightbulb": "Light bulb", "doc": "Document", "terminal": "Terminal",
    "fork.knife": "Fork and knife", "dumbbell": "Dumbbell", "house": "House", "gift": "Gift", "sparkles": "Sparkles",
  ]
  /// The side of a saved picture, in pixels.
  public static let picturePixels = 128

  /// One emoji as typed: a single grapheme that draws as an emoji (skin tones, flags, keycaps and
  /// joined sequences included, at most 16 scalars; tag characters only in a flag's tag sequence).
  /// nil for anything else, a letter or a digit too.
  public static func cleanEmoji(_ text: String) -> AssistantIcon? {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let scalars = clean.unicodeScalars
    let joiners: [UInt32] = [0x200D, 0xFE0F, 0x20E3]
    let tags: ClosedRange<UInt32> = 0xE0020...0xE007F
    guard clean.count == 1, scalars.count <= 16, let first = scalars.first, first.properties.isEmoji,
      scalars.allSatisfy({ $0.properties.isEmoji || joiners.contains($0.value) || tags.contains($0.value) }),
      scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F })
    else { return nil }
    // Tag characters only in a flag's tag sequence (a black flag, the tags, the cancel tag), so no
    // hidden text rides along in a grapheme.
    let tagged = scalars.contains { tags.contains($0.value) }
    guard !tagged || (first.value == 0x1F3F4 && scalars.last?.value == 0xE007F) else { return nil }
    return .emoji(clean)
  }
  /// A new picture's file name: a fresh one for every pick, so Undo can show the one before.
  public static func pictureName() -> String { "icon-\(UUID().uuidString).png" }
  /// Whether a name is one `pictureName` makes: no separator or dot-dot can reach past the folder.
  public static func isPictureName(_ name: String) -> Bool {
    guard name.hasPrefix("icon-"), name.hasSuffix(".png") else { return false }
    return UUID(uuidString: String(name.dropFirst(5).dropLast(4))) != nil
  }
  /// The icon when it is well formed (an emoji `cleanEmoji` accepts, a listed symbol, a picture
  /// name `pictureName` made); else nil.
  public var checked: AssistantIcon? {
    switch self {
    case .emoji(let text): return Self.cleanEmoji(text) == self ? self : nil
    case .symbol(let name): return Self.symbols.contains(name) ? self : nil
    case .picture(let name): return Self.isPictureName(name) ? self : nil
    }
  }
  /// What a team file or a proposal may carry: an emoji or a symbol, checked. A picture is never
  /// written out nor read in, so no name from a file is ever opened.
  public var shareable: AssistantIcon? {
    if case .picture = self { return nil }
    return checked
  }
  /// The picture's file name, for a picture.
  public var pictureFile: String? {
    if case .picture(let name) = self { return name }
    return nil
  }

  // One key per kind ({"emoji": "…"}), so a team file reads plainly.
  private enum CodingKeys: String, CodingKey { case emoji, symbol, picture }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let text = try container.decodeIfPresent(String.self, forKey: .emoji) {
      self = .emoji(text)
    } else if let name = try container.decodeIfPresent(String.self, forKey: .symbol) {
      self = .symbol(name)
    } else if let name = try container.decodeIfPresent(String.self, forKey: .picture) {
      self = .picture(name)
    } else {
      throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "An icon names one kind."))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .emoji(let text): try container.encode(text, forKey: .emoji)
    case .symbol(let name): try container.encode(name, forKey: .symbol)
    case .picture(let name): try container.encode(name, forKey: .picture)
    }
  }
}

public struct RelayTeam: Codable, Equatable, Sendable {
  public var profiles: [RelayProfile]
  public var activeID: String
  /// True once the default name "Relay" became "Serein" (`renamingFormerMain`). It lives in
  /// relay/team.json, not in user defaults, so a preview's own library never marks the real one.
  /// Optional, so a team.json written before it decodes.
  public var mainRenamed: Bool?
  /// The person's teams (`AssistantGroup`). nil, as written before teams, is one implicit team of
  /// every assistant. Optional, so a team.json written before it decodes.
  public var groups: [AssistantGroup]?
  /// The engine an assistant made later starts with, set by a model pick for "All assistants"
  /// (`settingEveryRoute`); nil starts it on Serein's. Read only through `route(of:)`, so every way
  /// of making an assistant gets it. Saved outside the journal like every route. Optional, so a
  /// team.json written before it decodes.
  public var startingRoute: AssistantRoute?
  public init(profiles: [RelayProfile], activeID: String, mainRenamed: Bool? = nil, groups: [AssistantGroup]? = nil) {
    self.profiles = profiles
    self.activeID = activeID
    self.mainRenamed = mainRenamed
    self.groups = groups
  }

  /// The first profile's fixed id, which single-assistant setups migrate into.
  public static let mainID = "main"
  public static let mainName = "Serein"
  /// The default name before the assistant took the app's name.
  public static let formerMainName = "Relay"

  /// The one-time rename: a profile named exactly "Relay" becomes "Serein", custom names stay,
  /// and nothing is renamed when another profile is already named "Serein" (names are unique).
  /// `personas` lists the profiles whose persona may be renamed the same way. The result is
  /// marked, so it runs once.
  public func renamingFormerMain() -> (team: RelayTeam, personas: [String]) {
    var team = self
    team.mainRenamed = true
    guard mainRenamed != true else { return (team, []) }
    let renames = profiles.contains { $0.name == Self.formerMainName }
    let taken = profiles.contains { $0.name.caseInsensitiveCompare(Self.mainName) == .orderedSame }
    guard !(renames && taken) else { return (team, []) }
    for i in team.profiles.indices where team.profiles[i].name == Self.formerMainName {
      team.profiles[i].name = Self.mainName
    }
    return (team, profiles.map(\.id))
  }

  /// What launch does with relay/team.json (nil when it is missing or does not decode).
  /// `personas` lists the profiles whose persona.json to rename once; `rewrite` says the team
  /// itself changed and must be saved. A missing team becomes a fresh, marked team, but its main
  /// persona is still checked: Settings › Serein › Personality saves a persona without a team.
  /// The caller saves that marked team once a persona.json was there to check, so it runs once.
  public static func launching(_ decoded: RelayTeam?) -> (team: RelayTeam, personas: [String], rewrite: Bool) {
    guard let decoded else {
      var team = fresh()
      team.mainRenamed = true
      return (team, [mainID], false)
    }
    guard decoded.mainRenamed != true else { return (decoded, [], false) }
    let renamed = decoded.renamingFormerMain()
    return (renamed.team, renamed.personas, true)
  }

  /// A one-profile team for a fresh library.
  public static func fresh() -> RelayTeam {
    RelayTeam(profiles: [RelayProfile(id: mainID, name: mainName)], activeID: mainID)
  }

  public var active: RelayProfile? {
    profiles.first { $0.id == activeID }
  }
  public var activeName: String {
    active?.name ?? Self.mainName
  }
  /// The assistant that holds Settings' "Speaks first": the main profile, else the first one (a roster whose main was deleted).
  public var mainProfileID: String? { main?.id }
  /// The folder a profile's own files live in.
  public func folder(_ id: String) -> String {
    "relay/profiles/\(id)"
  }

  /// Adds a profile with a unique cleaned name, the next free colour and every place but
  /// connected apps; nil when the name is empty or taken.
  public func adding(_ name: String) -> RelayTeam? {
    let clean = RelayProfile.cleanName(name)
    guard !clean.isEmpty else { return nil }
    guard !profiles.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else {
      return nil
    }
    var team = self
    // Every place but connected apps, which a new assistant starts without (narrowing only).
    team.profiles.append(RelayProfile(
      name: clean, scope: AssistantScope(destinations: Set(AssistantPlace.allCases).subtracting([.connectedApps])),
      colour: AssistantColour.next(used: profiles.map(\.colour))))
    return team
  }

  /// Renames; the name must stay unique. nil when it cannot.
  public func renaming(_ id: String, to name: String) -> RelayTeam? {
    let clean = RelayProfile.cleanName(name)
    guard !clean.isEmpty else { return nil }
    guard profiles.contains(where: { $0.id == id }) else { return nil }
    guard !profiles.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else {
      return nil
    }
    var team = self
    if let i = team.profiles.firstIndex(where: { $0.id == id }) {
      team.profiles[i].name = clean
    }
    return team
  }

  /// Removes a profile and anything it was, and takes it out of every team (a team left with
  /// nobody goes too); the last profile and the active one cannot go. Returns nil when the
  /// removal is refused.
  public func removing(_ id: String) -> RelayTeam? {
    guard id != activeID, profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else {
      return nil
    }
    var team = self
    team.profiles.remove(at: index)
    team.groups = groups?.compactMap { $0.without(id) }
    return team
  }

  public func switching(to id: String) -> RelayTeam? {
    guard profiles.contains(where: { $0.id == id }) else { return nil }
    var team = self
    team.activeID = id
    return team
  }
}
