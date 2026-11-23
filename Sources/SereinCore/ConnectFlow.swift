import Foundation

/// The small link that a chat card shows to connect one app: the app, the name the person reads,
/// and the kind of sign-in. It never holds a secret. It has no key, no address and no account.
/// When the person presses the button, the host gets the real sign-in address itself.
public struct ConnectLink: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable {
    /// OAuth through Composio. The app's own sign-in opens in the person's browser, and Composio
    /// keeps the account. The person's Composio key must be in Keychain first.
    case composio
    /// The vendor's own sign-in page in Serein's browser sheet (`PluginSignIn`), where Serein's
    /// saved-password fill works. Serein has no password form of its own.
    case vendorPage
    /// One of `ConnectorCatalog`'s apps: its own MCP server, signed in to in the browser with no key.
    case mcp
    /// A cloud computer's key (`ConnectLink.keyPlaces`: E2B, Daytona), typed into the key card in
    /// the chat and kept in Keychain. The link names the place only, never the key.
    case key
    /// A saved secret's record (`SecretRecord`), asked for with `secret_ask` and typed into the
    /// secret card. The link names the record id only, never the value.
    case secret
  }
  /// The places whose key the chat may ask for.
  public static let keyPlaces: [ComputerPlace] = [.e2b, .daytona]
  public static let maxName = 40
  /// The longest plugin id (`PluginManifest` ids).
  public static let maxPluginID = 80

  /// A Composio app slug (`ConnectedApps.appSlug`) for `.composio`, or a plugin id for `.vendorPage`.
  public let app: String
  /// The name in the card ("Gmail"): one line, at most `maxName` characters.
  public let name: String
  public let kind: Kind

  /// nil when the app id is not a valid id for `kind`, or when no clean name is left. A name that
  /// looks like a key or a password (`AgentPrivacy.redact` changes it) is refused, so a link can
  /// never carry a secret into a card, a chat or a prompt. Without a name, a Composio app takes
  /// its known name (`ConnectedApps.name`); a vendor page must have one.
  public init?(app: String, name: String? = nil, kind: Kind) {
    let id: String
    switch kind {
    case .composio:
      guard let slug = ConnectedApps.appSlug(app) else { return nil }
      id = slug
    case .mcp:
      guard let connector = ConnectorCatalog.byID(app) else { return nil }
      id = connector.id
    case .vendorPage:
      let raw = app.trimmingCharacters(in: .whitespacesAndNewlines)
      let pattern = "^[a-z0-9]+([.-][a-z0-9]+)*$"
      guard raw.count <= ConnectLink.maxPluginID, raw.range(of: pattern, options: .regularExpression) != nil else { return nil }
      id = raw
    case .key:
      let raw = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard let place = ConnectLink.keyPlaces.first(where: { $0.rawValue == raw }) else { return nil }
      id = place.rawValue
    case .secret:
      let raw = app.trimmingCharacters(in: .whitespacesAndNewlines)
      guard raw.count <= ConnectLink.maxName, raw.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
      else { return nil }
      id = raw
    }
    let fallback: String?
    switch kind {
    case .composio: fallback = ConnectedApps.name(id)
    case .mcp: fallback = ConnectorCatalog.byID(id)?.name
    case .key: fallback = ComputerPlace(rawValue: id)?.label
    case .vendorPage, .secret: fallback = nil
    }
    guard let given = name ?? fallback, let clean = ConnectLink.cleanName(given) else { return nil }
    self.app = id
    self.name = clean
    self.kind = kind
  }

  /// One line without hidden characters, at most `maxName` characters; nil when nothing is left
  /// or the text looks like a secret.
  static func cleanName(_ raw: String) -> String? {
    let short = String(oneLine(raw).prefix(maxName)).trimmingCharacters(in: .whitespaces)
    guard !short.isEmpty, AgentPrivacy.redact(short) == short else { return nil }
    return short
  }
  /// Line breaks and runs of spaces become one space, then hidden characters
  /// (`SafeFileName.hidden`: controls, zero-width characters, direction marks) are dropped.
  static func oneLine(_ raw: String) -> String {
    let words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    var kept = String.UnicodeScalarView()
    kept.append(contentsOf: words.unicodeScalars.filter { !SafeFileName.hidden($0) })
    return String(kept)
  }

  enum CodingKeys: String, CodingKey { case app, name, kind }
  /// A stored link goes through the same checks as a new one.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let app = try container.decode(String.self, forKey: .app)
    let name = try container.decode(String.self, forKey: .name)
    let kind = try container.decode(Kind.self, forKey: .kind)
    guard let link = ConnectLink(app: app, name: name, kind: kind) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not a valid connect link."))
    }
    self = link
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(app, forKey: .app)
    try container.encode(name, forKey: .name)
    try container.encode(kind, forKey: .kind)
  }
}

/// The steps of one connect card in the chat: primer, needs key, opening, waiting, ready, failed.
/// Pure. The host sends each event and does the one effect that `next` returns. The flow holds
/// no secret: it knows only whether a key is kept, never the key.
///
/// Rules:
/// - While it waits, the host reads the status every `pollInterval` seconds, for at most
///   `maxWait` seconds after the sign-in opened. Then the card fails with `timeoutReason`.
/// - When a sign-in that this card started becomes ready, the effect is `.carryOn` with the card
///   id: the person's paused words go on by themselves. When the app becomes ready in another
///   way (in Settings, or after the time ran out), the card shows Continue and only a press
///   carries on. Either way a card carries on one time at most, never twice.
/// - Ready is the last step. No later event changes it.
public struct ConnectFlow: Equatable, Sendable {
  public enum State: Equatable, Sendable {
    /// The first card: what the app does and a Connect button.
    case primer
    /// A Composio app and no Composio key yet: the host shows its secure key field.
    case needsKey
    /// The host is opening the app's own sign-in.
    case opening
    /// The sign-in is open. The host reads the status until `deadline`.
    case waiting
    case ready
    /// It stopped, with a plain reason the person can read.
    case failed(reason: String)
  }
  public enum Event: Equatable, Sendable {
    /// The person pressed Connect (on the primer) or Try again (after a failure). `keyKept`:
    /// a Composio key is in Keychain (`ComposioApps.available`). The flow never sees the key.
    case connect(keyKept: Bool)
    /// The host saved the key from its secure field to Keychain and cleared the field.
    case keySaved
    /// The app's own sign-in is open in the browser or the browser sheet.
    case linkOpened
    /// One status read said: not ready yet.
    case statusWaiting
    case statusReady
    /// The host's own plain words for why it failed, or nil for `failedReason`.
    case statusFailed(reason: String?)
    case timedOut
    /// The person stopped it ("Not now", or closed the sign-in).
    case cancelled
    /// The person pressed Continue on a ready card.
    case continued
  }
  /// The one thing the host does after an event.
  public enum Effect: Equatable, Sendable {
    case nothing
    /// Start the app's own sign-in: Composio's link in the browser, or the vendor page in the sheet.
    case openSignIn(ConnectLink)
    /// Read the status again after this many seconds, then send the result.
    case poll(after: TimeInterval)
    /// Send the person's paused words again, for this card. It comes one time per card.
    case carryOn(card: String)
  }

  public static let pollInterval: TimeInterval = 2
  public static let maxWait: TimeInterval = 180
  public static let timeoutReason = "It did not finish. Try again."
  public static let failedReason = "The sign-in did not work. Try again."
  public static let maxReason = 140
  /// The line under the key field.
  public static let keyNote = "Kept in this Mac's Keychain only."

  /// The card's id. One card carries on one time at most.
  public let card: String
  public let link: ConnectLink
  public private(set) var state: State = .primer
  /// When waiting must stop. Set when the sign-in opens; nil in every other step.
  public private(set) var deadline: Date?
  /// True after the flow returned `.carryOn` for this card.
  public private(set) var carriedOn = false

  public init(card: String, link: ConnectLink) {
    self.card = card
    self.link = link
  }

  /// Moves to the next step and returns the one effect for the host. An event that does not fit
  /// the current step changes nothing and returns `.nothing` (a late status read, a second press).
  public mutating func next(_ event: Event, now: Date = Date()) -> Effect {
    if state == .ready {
      return event == .continued ? carryOnOnce() : .nothing
    }
    switch event {
    case .connect(let keyKept):
      guard isStart else { return .nothing }
      deadline = nil
      if link.kind == .composio && !keyKept {
        state = .needsKey
        return .nothing
      }
      state = .opening
      return .openSignIn(link)
    case .keySaved:
      guard state == .needsKey else { return .nothing }
      state = .opening
      return .openSignIn(link)
    case .linkOpened:
      guard state == .opening else { return .nothing }
      state = .waiting
      deadline = now.addingTimeInterval(Self.maxWait)
      return .poll(after: Self.pollInterval)
    case .statusWaiting:
      guard state == .waiting, let end = deadline else { return .nothing }
      let left: TimeInterval = end.timeIntervalSince(now)
      if left <= 0 {
        fail(Self.timeoutReason)
        return .nothing
      }
      return .poll(after: min(Self.pollInterval, left))
    case .statusReady:
      let startedHere = state == .opening || state == .waiting
      state = .ready
      deadline = nil
      return startedHere ? carryOnOnce() : .nothing
    case .statusFailed(let reason):
      guard isInFlight else { return .nothing }
      fail(Self.plainReason(reason))
      return .nothing
    case .timedOut:
      guard isInFlight else { return .nothing }
      fail(Self.timeoutReason)
      return .nothing
    case .cancelled:
      state = .primer
      deadline = nil
      return .nothing
    case .continued:
      return .nothing
    }
  }

  /// The button's words for the current step.
  public var button: String {
    switch state {
    case .primer: return "Connect"
    case .needsKey: return "Save"
    case .opening, .waiting: return "Waiting for \(link.name)…"
    case .ready: return "Continue"
    case .failed: return "Try again"
    }
  }
  /// False while the host works (the button shows the wait) and after the card carried on.
  public var buttonEnabled: Bool {
    switch state {
    case .primer, .needsKey, .failed: return true
    case .opening, .waiting: return false
    case .ready: return !carriedOn
    }
  }
  /// The card's first line for the current step.
  public var title: String {
    switch state {
    case .primer: return "Connect \(link.name)"
    case .needsKey: return "Composio key"
    case .opening, .waiting: return "Sign in to \(link.name) on the page that opened."
    case .ready: return "\(link.name) is connected"
    case .failed(let reason): return reason
    }
  }

  var isStart: Bool {
    switch state {
    case .primer, .failed: return true
    case .needsKey, .opening, .waiting, .ready: return false
    }
  }
  var isInFlight: Bool { state == .opening || state == .waiting }

  mutating func fail(_ reason: String) {
    state = .failed(reason: reason)
    deadline = nil
  }
  mutating func carryOnOnce() -> Effect {
    guard !carriedOn else { return .nothing }
    carriedOn = true
    return .carryOn(card: card)
  }

  /// The host's reason as one plain line of at most `maxReason` characters, without hidden
  /// characters or anything that looks like a secret; `failedReason` when nothing is left.
  static func plainReason(_ raw: String?) -> String {
    guard let raw = raw else { return failedReason }
    let line = ConnectLink.oneLine(raw)
    let short = AgentPrivacy.redact(line, limit: maxReason).trimmingCharacters(in: .whitespaces)
    return short.isEmpty ? failedReason : short
  }
}

/// The app a request names, for `connect_app` and for a routine's receipt: an app on this Mac
/// (its switch is in Settings) or an app Composio connects.
public enum AppResolution: Equatable, Sendable {
  /// Mail, Messages, Calendar, Reminders, Contacts or Notes on this Mac, by its id.
  case mac(String)
  case composio(ConnectLink)
}

/// The connection catalogue by the names people use: the apps on this Mac, the Composio apps
/// Serein knows by name, and any other Composio app by a name that can be its id. Pure. It never
/// holds a key, an address or an account.
public enum ConnectCatalog {
  /// One Composio app: its id, the name the person reads, the words that name it, and whether
  /// those words name the app inside a routine's words too (a word like "linear" or "zoom" alone
  /// is too common for that).
  struct App {
    let slug: String
    let name: String
    let words: [String]
    let inText: Bool
  }
  static let apps: [App] = [
    App(slug: "gmail", name: "Gmail", words: ["gmail", "google mail"], inText: true),
    App(slug: "googlecalendar", name: "Google Calendar", words: ["google calendar", "gcal", "googlecalendar"], inText: true),
    App(slug: "slack", name: "Slack", words: ["slack"], inText: true),
    App(slug: "notion", name: "Notion", words: ["notion"], inText: true),
    App(slug: "github", name: "GitHub", words: ["github", "git hub"], inText: true),
    App(slug: "outlook", name: "Outlook", words: ["outlook", "microsoft outlook", "hotmail"], inText: true),
    App(slug: "googledrive", name: "Google Drive", words: ["google drive", "gdrive", "googledrive"], inText: true),
    App(slug: "googlesheets", name: "Google Sheets", words: ["google sheets", "googlesheets"], inText: true),
    App(slug: "googledocs", name: "Google Docs", words: ["google docs", "googledocs"], inText: true),
    App(slug: "jira", name: "Jira", words: ["jira"], inText: true),
    App(slug: "trello", name: "Trello", words: ["trello"], inText: true),
    App(slug: "todoist", name: "Todoist", words: ["todoist"], inText: true),
    App(slug: "dropbox", name: "Dropbox", words: ["dropbox"], inText: true),
    App(slug: "hubspot", name: "HubSpot", words: ["hubspot"], inText: true),
    App(slug: "airtable", name: "Airtable", words: ["airtable"], inText: true),
    App(slug: "linear", name: "Linear", words: ["linear"], inText: false),
    App(slug: "asana", name: "Asana", words: ["asana"], inText: false),
    App(slug: "zoom", name: "Zoom", words: ["zoom"], inText: false),
  ]
  /// The apps on this Mac, by the ids of their switches (`Connection`, `NativeConnection`).
  static let macApps: [(id: String, words: [String])] = [
    (id: "mail", words: ["mail", "apple mail", "email", "e mail"]),
    (id: "messages", words: ["messages", "imessage", "imessages", "text messages", "texts", "sms"]),
    (id: "calendar", words: ["calendar", "apple calendar", "ical"]),
    (id: "reminders", words: ["reminders", "apple reminders"]),
    (id: "contacts", words: ["contacts", "address book"]),
    (id: "notes", words: ["notes", "apple notes"]),
  ]
  /// Words around a name that do not change it ("my Gmail account").
  static let fillers: Set<String> = ["the", "my", "app", "account"]

  /// The app `raw` names: an app on this Mac, a known Composio app, or another Composio app whose
  /// name of one to three plain words can be its id ("Google Tasks" → googletasks). nil for an
  /// address, a name that looks like a secret, or words that name nothing.
  public static func resolve(_ raw: String) -> AppResolution? {
    let trimmed: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= ConnectLink.maxName, AgentPrivacy.redact(trimmed) == trimmed else { return nil }
    guard !trimmed.contains("://"), !trimmed.contains("."), !trimmed.contains("/") else { return nil }
    let all: [String] = TypedConsent.normalized(trimmed).split(separator: " ").map(String.init)
    let parts: [String] = all.filter { !fillers.contains($0) }
    guard !parts.isEmpty, parts.count <= 3 else { return nil }
    let key: String = parts.joined(separator: " ")
    if let mac = macApps.first(where: { $0.words.contains(key) }) { return .mac(mac.id) }
    if let app = apps.first(where: { $0.words.contains(key) || $0.slug == key }) {
      return ConnectLink(app: app.slug, name: app.name, kind: .composio).map { AppResolution.composio($0) }
    }
    if let known = ConnectedApps.suggested.first(where: { $0.name.lowercased() == key || $0.slug == key }) {
      return ConnectLink(app: known.slug, name: known.name, kind: .composio).map { AppResolution.composio($0) }
    }
    // Another app: plain words only (no digits, at most 20 letters each), so a key or a code
    // never becomes an app's name.
    guard parts.allSatisfy({ word in word.count <= 20 && word.allSatisfy({ $0.isLetter }) }) else { return nil }
    let slug: String = parts.joined()
    guard ConnectedApps.appSlug(slug) == slug else { return nil }
    let name: String = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    return ConnectLink(app: slug, name: name, kind: .composio).map { AppResolution.composio($0) }
  }

  /// The known Composio apps a routine's words name, each once, in the catalogue's order. Only
  /// names clear enough inside other words count (`App.inText`); Mac apps never do.
  public static func named(in text: String) -> [ConnectLink] {
    let words: String = TypedConsent.normalized(text)
    var out: [ConnectLink] = []
    for app in apps where app.inText && TypedConsent.contains(words, any: app.words) {
      if let link = ConnectLink(app: app.slug, name: app.name, kind: .composio) { out.append(link) }
    }
    return out
  }

  /// What `connect_app` tells the model once the person sees the button.
  public static func shown(_ app: String) -> String {
    "The person sees a button to connect \(app). Tell them in one short sentence, then stop."
  }
  /// What `connect_app` tells the model once the person sees the key field.
  public static func keyShown(_ place: String) -> String {
    "The person sees a field for their \(place) key. You never see it. Tell them in one short sentence, then stop."
  }
  /// What `connect_app` tells the model when the app is connected already.
  public static func ready(_ app: String) -> String {
    "\(app) is connected already. Go on with the request."
  }
  /// The refusal for a name the catalogue does not know.
  public static let unknown =
    "Serein cannot find that app to connect. Ask the person which app they mean, or tell them to add it in Settings › Connections."
  /// The refusal in a turn the person did not start.
  public static let notHere = "Only the person can connect an app, in their own chat. Tell them what is needed when they are back."
}
