import Foundation

/// One saved key or card: what it is called and where it may go. Never the value, which lives in
/// Keychain only, one item per id. Kept in relay/secrets.json. `savedAt` is nil while the card that
/// asks for it waits.
public struct SecretRecord: Codable, Hashable, Identifiable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable { case key, card }
  public let id: String
  public let name: String
  /// The exact https hosts the key may go to, or the sites a card is for. A subdomain of one counts.
  public let hosts: [String]
  public let kind: Kind
  public var savedAt: Date?
  public init(id: String, name: String, hosts: [String], kind: Kind, savedAt: Date? = nil) {
    self.id = id
    self.name = name
    self.hosts = hosts
    self.kind = kind
    self.savedAt = savedAt
  }
}

/// What the person types into a secret card, only until Save.
public struct SecretEntry: Equatable, Sendable {
  public var key = ""
  public var number = ""
  public var holder = ""
  public var expiry = ""
  public var cvc = ""
  /// A pasted key's service and address, which the card asks for.
  public var service = ""
  public var address = ""
  public init(key: String = "") { self.key = key }
}

/// Keys and cards the model asks for and uses by placeholder: the person types the
/// value into a card in the chat, Keychain keeps it, and Serein puts it into a request it builds
/// itself, only for the secret's own hosts over https. Pure. No value enters a prompt, a tool
/// answer, a record or a file.
public enum SecretVault {
  public static let maxHosts = 4
  public static let maxBody = 65_536
  public static let answerLimit = 16_000
  public static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

  public static let notHere =
    "Only the person can add a key or a card, in their own chat. Tell them what is needed when they are back."
  public static let badName = "name is a short name such as Stripe key."
  public static let badHosts =
    "hosts are 1 to 4 plain names such as api.stripe.com, with no https://, path, port or IP address."
  public static let badKind = "kind is key or card."
  public static let notAKey = "That does not look like a key."
  public static let notACard = "Check the card number, the expiry (MM/YY) and the security code."
  public static let noPlaceholder = "service_request needs a {{secret:<id>}} placeholder from secret_ask. It is not a general web tool."
  public static let badURL = "url is one https address on the secret's own host, with no user name or port."
  public static let badMethod = "method is GET, HEAD, POST, PUT, PATCH or DELETE."
  public static let bodyOnRead = "A GET or HEAD request has no body."

  public static func placeholder(_ id: String) -> String { "{{secret:\(id)}}" }
  public static func marker(_ id: String) -> String { "[secret:\(id)]" }
  static let placeholderPattern = try! NSRegularExpression(pattern: #"\{\{secret:([a-z0-9]+(?:-[a-z0-9]+)*)\}\}"#)

  // MARK: hosts

  /// A plain domain name in lower case: at least two labels of letters, digits and hyphens, and a
  /// last label that is not all digits. nil for a scheme, a path, a port, user info, an IP literal
  /// or a trailing dot.
  public static func host(_ raw: String) -> String? {
    let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard name.count <= 253 else { return nil }
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, let last = labels.last, last.contains(where: \.isLetter) else { return nil }
    let label = #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#
    return labels.allSatisfy { $0.range(of: label, options: .regularExpression) != nil } ? name : nil
  }

  public static func allows(_ record: SecretRecord, host: String) -> Bool {
    record.hosts.contains { host == $0 || host.hasSuffix("." + $0) }
  }

  /// A short id from a name ("Stripe key" gives stripe-key), unique among `taken`.
  static func slug(_ name: String, taken: Set<String>) -> String {
    let words = name.lowercased().split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
    let base = String(words.joined(separator: "-").prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let stem = base.isEmpty ? "secret" : base
    var id = stem
    var n = 2
    while taken.contains(id) {
      id = "\(stem)-\(n)"
      n += 1
    }
    return id
  }

  // MARK: secret_ask

  public enum Asked: Equatable, Sendable {
    case refused(String)
    /// Saved already: the model gets the placeholder (a key) or the fact that it is saved (a card).
    case saved(SecretRecord)
    /// The card to show, waiting for the person. The caller keeps the record so the card can find it.
    case show(SecretRecord)
  }

  /// `secret_ask {name, hosts, kind}`: a saved secret for one of the hosts wins, then a waiting one
  /// for the same hosts, then a new one.
  public static func ask(_ a: [String: Any], personStarted: Bool, records: [SecretRecord]) -> Asked {
    guard personStarted else { return .refused(notHere) }
    guard let kind = SecretRecord.Kind(rawValue: (a["kind"] as? String) ?? "key") else { return .refused(badKind) }
    switch record(name: a["name"] as? String ?? "", hosts: a["hosts"] as? [String] ?? [], kind: kind, records: records) {
    case .failure(let refusal): return .refused(refusal.words)
    case .success(let asked):
      if let saved = records.first(where: { saved in
        saved.savedAt != nil && saved.kind == kind && asked.hosts.contains { allows(saved, host: $0) }
      }) {
        return .saved(saved)
      }
      if let waiting = records.first(where: { $0.savedAt == nil && $0.kind == kind && Set($0.hosts) == Set(asked.hosts) }) {
        return .show(waiting)
      }
      return .show(asked)
    }
  }

  /// A new record from a name and hosts, by the same rules whether the model or the person names
  /// them (a pasted key's card).
  public static func record(name: String, hosts: [String], kind: SecretRecord.Kind, records: [SecretRecord])
    -> Result<SecretRecord, Refusal>
  {
    guard let clean = ConnectLink.cleanName(name) else { return .failure(Refusal(badName)) }
    let plain = hosts.compactMap(host)
    guard !hosts.isEmpty, hosts.count <= maxHosts, plain.count == hosts.count else { return .failure(Refusal(badHosts)) }
    var unique: [String] = []
    for host in plain where !unique.contains(host) { unique.append(host) }
    let id = slug(clean, taken: Set(records.map(\.id)))
    return .success(SecretRecord(id: id, name: clean, hosts: unique, kind: kind))
  }

  /// What the model reads back from `secret_ask`. A card's never holds a digit.
  public static func answer(_ asked: SecretRecord, saved: Bool) -> [String: Any] {
    switch (asked.kind, saved) {
    case (.key, true):
      return [
        "placeholder": placeholder(asked.id), "hosts": asked.hosts,
        "note": "\(asked.name) is saved. Call service_request and write \(placeholder(asked.id)) where the key goes. It only goes to \(asked.hosts.joined(separator: ", ")).",
      ]
    case (.card, true):
      return ["note": "A card called \(asked.name) is saved. You never see it, and paying always waits for the person."]
    case (.key, false):
      return ["note": "The person sees a field for their \(asked.name). You never see it. Tell them in one short sentence, then stop."]
    case (.card, false):
      return ["note": "The person sees a form for their card. You never see it. Tell them in one short sentence, then stop."]
    }
  }

  /// The card's one line of explanation.
  public static func line(_ record: SecretRecord) -> String {
    let places = record.hosts.joined(separator: ", ")
    switch record.kind {
    case .key: return "Only sent to \(places). Serein's AI never sees it."
    case .card: return "Only for \(places). Serein's AI never sees it."
    }
  }

  // MARK: values

  /// The value Keychain keeps for one entry, or nil when it is not one. A key is one line of 8 to
  /// 4096 visible characters. A card is its number, expiry, code and name on four lines.
  public static func value(_ kind: SecretRecord.Kind, _ entry: SecretEntry) -> String? {
    switch kind {
    case .key:
      let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (8...4096).contains(key.count), !key.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
      return key
    case .card:
      let digits = entry.number.filter { !$0.isWhitespace && $0 != "-" }
      let cvc = entry.cvc.trimmingCharacters(in: .whitespaces)
      let holder = ConnectLink.oneLine(entry.holder).trimmingCharacters(in: .whitespaces)
      guard (13...19).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }), HandBack.containsCardNumber(digits),
        let expiry = expiry(entry.expiry), (3...4).contains(cvc.count), cvc.allSatisfy({ $0.isASCII && $0.isNumber }),
        holder.count <= 80, !holder.contains("\n")
      else { return nil }
      return [digits, expiry, cvc, holder].joined(separator: "\n")
    }
  }

  /// MM/YY from "4/29", "04 / 29" or "04/2029"; nil for any other shape.
  static func expiry(_ raw: String) -> String? {
    let parts = raw.split(whereSeparator: { $0 == "/" || $0.isWhitespace }).map(String.init)
    guard parts.count == 2, let month = Int(parts[0]), (1...12).contains(month), let year = Int(parts[1]),
      parts[1].count == 2 || parts[1].count == 4
    else { return nil }
    return String(format: "%02d/%02d", month, year % 100)
  }

  // MARK: service_request

  public struct Refusal: Error, Equatable, Sendable {
    public let words: String
    public init(_ words: String) { self.words = words }
  }

  /// A checked request with its placeholders still in, for the approval card and then `fill`.
  public struct Plan: Equatable, Sendable {
    public let method: String
    public let url: String
    public let headers: [String: String]
    public let body: String?
    public let host: String
    public let secrets: [SecretRecord]
    public let effect: ApprovalGate.Effect
    /// The request as the approval card shows it, placeholders and all.
    public var shown: String {
      ([method + " " + url] + headers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }
        + (body.map { ["", $0] } ?? [])).joined(separator: "\n")
    }
  }

  /// Checks `service_request {method, url, headers, body}` before any value is read: at least one
  /// placeholder, every one a saved key whose hosts include the destination, an https address on
  /// a plain host with no placeholder before its path. Its effect comes from the approval gate.
  public static func plan(_ a: [String: Any], records: [SecretRecord]) -> Result<Plan, Refusal> {
    let method = ((a["method"] as? String) ?? "GET").uppercased()
    guard methods.contains(method) else { return .failure(Refusal(badMethod)) }
    let url = ((a["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var headers: [String: String] = [:]
    for (name, value) in (a["headers"] as? [String: Any]) ?? [:] {
      guard let text = value as? String, name.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil,
        !text.contains("\n"), !text.contains("\r")
      else { return .failure(Refusal("Each header is a name and one line of text.")) }
      headers[name] = text
    }
    let body = (a["body"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    if let body, body.utf8.count > maxBody { return .failure(Refusal("body is at most \(maxBody) bytes.")) }
    if body != nil, method == "GET" || method == "HEAD" { return .failure(Refusal(bodyOnRead)) }
    let ids = ([url, body ?? ""] + Array(headers.values)).flatMap(placeholderIDs)
    guard !ids.isEmpty else { return .failure(Refusal(noPlaceholder)) }
    guard let place = destination(url, template: true) else { return .failure(Refusal(badURL)) }
    var used: [SecretRecord] = []
    for id in ids where !used.contains(where: { $0.id == id }) {
      guard let record = records.first(where: { $0.id == id && $0.savedAt != nil }) else {
        return .failure(Refusal("No key is saved as \(placeholder(id)). Call secret_ask first."))
      }
      guard record.kind == .key else { return .failure(Refusal("A card never goes into a request. Nothing was sent.")) }
      guard allows(record, host: place.host) else {
        return .failure(Refusal("\(record.name) only goes to \(record.hosts.joined(separator: ", ")), so nothing was sent."))
      }
      used.append(record)
    }
    let effect = ApprovalGate.requestEffect(method: method, host: place.host, path: place.path)
    return .success(Plan(method: method, url: url, headers: headers, body: body, host: place.host, secrets: used, effect: effect))
  }

  /// The door's answer for a checked request: it follows the person's level, and a payment is
  /// the person's yes on the exact request (`RelaySecrets.serviceRequest` shows that card).
  public static func decision(_ effect: ApprovalGate.Effect, _ standing: ApprovalDoor.Standing) -> ApprovalDoor.Answer {
    ApprovalDoor.answer(
      .init(.effect(effect), standing),
      facts: .init(
        secureField: false, botCheck: false, pays: .no, covered: false, path: nil,
        hostKeyChanged: nil, runsAnything: false, ref: ""))
  }

  /// The request with each value in, by id. The destination is checked again on the filled
  /// address, so a value can never move the request to another host.
  public static func fill(_ plan: Plan, values: [String: String]) -> Result<URLRequest, Refusal> {
    for record in plan.secrets where (values[record.id] ?? "").isEmpty {
      return .failure(Refusal("Keychain did not give \(record.name). Nothing was sent."))
    }
    func put(_ text: String) -> String {
      plan.secrets.reduce(text) { $0.replacingOccurrences(of: placeholder($1.id), with: values[$1.id] ?? "") }
    }
    let filled = put(plan.url)
    guard let place = destination(filled, template: false), place.host == plan.host,
      plan.secrets.allSatisfy({ allows($0, host: place.host) }), let url = URL(string: filled)
    else { return .failure(Refusal(badURL)) }
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = plan.method
    for (name, value) in plan.headers { request.setValue(put(value), forHTTPHeaderField: name) }
    if let body = plan.body { request.httpBody = Data(put(body).utf8) }
    return .success(request)
  }

  /// The host and path of an https address with no user info and no port but 443. With
  /// `template`, a placeholder in the scheme or host refuses it.
  static func destination(_ raw: String, template: Bool) -> (host: String, path: String)? {
    guard raw.lowercased().hasPrefix("https://") else { return nil }
    let afterScheme = raw.dropFirst("https://".count)
    let authority = afterScheme.prefix { !"/?#".contains($0) }
    if template, authority.contains("{") { return nil }
    let probe = template
      ? placeholderPattern.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "x")
      : raw
    guard let parts = URLComponents(string: probe), parts.scheme?.lowercased() == "https", parts.user == nil,
      parts.password == nil, parts.port == nil || parts.port == 443,
      let named = parts.percentEncodedHost, named.lowercased() == authority.lowercased().split(separator: ":").first.map(String.init),
      let host = host(named)
    else { return nil }
    return (host, parts.percentEncodedPath)
  }

  static func placeholderIDs(_ text: String) -> [String] {
    placeholderPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
      Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
  }

  // MARK: what comes back

  /// What the model reads back: the status, the content type and the body as text, each saved
  /// value replaced by its marker, then clipped.
  public static func answer(status: Int, contentType: String?, body: Data, values: [String: String]) -> [String: Any] {
    let text = String(data: body, encoding: .utf8).map { scrub($0, values: values) }
    var out: [String: Any] = ["status": status, "body": text.map { AgentPrivacy.clipped($0, limit: answerLimit) } ?? "(\(body.count) bytes that are not text)"]
    if let contentType { out["content_type"] = scrub(contentType, values: values) }
    return out
  }

  /// `text` with every value replaced by `[secret:<id>]`, plain and in its base64, hex, URL-encoded
  /// and JSON-escaped forms. A value shown in any other form is not caught.
  public static func scrub(_ text: String, values: [String: String]) -> String {
    let forms: [(String, String)] = values.flatMap { id, value in encodings(value).map { ($0, marker(id)) } }
    return forms.sorted { $0.0.count > $1.0.count }.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
  }

  static func encodings(_ value: String) -> [String] {
    guard !value.isEmpty else { return [] }
    let data = Data(value.utf8)
    let base64 = data.base64EncodedString()
    let unpadded = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    let urlSafe = unpadded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    let hex = data.map { String(format: "%02x", $0) }.joined()
    let encoded = [CharacterSet.alphanumerics, .urlQueryAllowed, .urlPathAllowed].compactMap { value.addingPercentEncoding(withAllowedCharacters: $0) }
    let forms = [value, base64, unpadded, urlSafe, hex, hex.uppercased(), value.replacingOccurrences(of: "/", with: "\\/")] + encoded
    var unique: [String] = []
    for form in forms where !form.isEmpty && !unique.contains(form) { unique.append(form) }
    return unique
  }
}
