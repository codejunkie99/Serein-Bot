import CryptoKit
import Foundation
import Network
import SereinCore

/// Serein's webhook receiver: an HTTP server on 127.0.0.1 that turns a delivery into one
/// unattended turn, all on this Mac. It binds loopback only — a delivery from beyond this Mac
/// needs a tunnel the user set up. It takes two kinds of delivery:
/// - **Owned links** (`/link/<id>`, RelayLinks.swift): one assistant owns each. `HookGate.admit`
///   checks the size, the signature or bearer secret (constant time), the delivery's identity,
///   the filter and 20 runs an hour; the secret comes from Keychain for each delivery and is never
///   kept here. An admitted delivery is written to the work ledger (kind `.link`, key
///   `Admitted.dedupeKey`) and only then answered 200; a repeat of the same key is answered 200
///   and starts nothing. The owner's turn reads `Admitted.prompt`.
/// - **Hooks from Settings** (`/hook/<secret>` or a bearer header), while "Accept webhooks on this
///   Mac" is on: the secret is shown once when the hook is made and only its digest is kept. A
///   delivery is written to the work ledger (kind `.link`, key `RelayHook.ledgerKey`) before the
///   200; a repeat (same Idempotency-Key, or the same body in the same ten minutes) fires no second turn.
/// One registered hook: its name for the prompt's source line, and the SHA-256 of its
/// secret (the secret itself is shown once and never kept).
public struct RelayHookEntry: Identifiable, Codable, Equatable {
  public var id = UUID().uuidString
  public var name: String
  public var secretDigest: String
  public var createdAt = Date()
}

final class RelayHookServer {
  static let switchKey = "serein.relay.hooks"
  /// The longest request head read before it must end.
  static let headLimit = 16 * 1024
  /// A connection closes this long after it was accepted, answered or not, so a slow sender
  /// cannot hold a socket and its buffer.
  static let connectionDeadline: TimeInterval = 10

  private let listener: NWListener
  private let queue = DispatchQueue(label: "serein-relay-hook")
  private let io = DispatchQueue(label: "serein-relay-hook-io")
  private let log = RelayHookLog()
  /// The registry it authenticates against; Relay owns and persists it.
  private let registry: [RelayHookEntry]
  /// Hooks from Settings answer only while that switch is on.
  private let legacy: Bool
  /// Owned links by id, as they were when the server started (a change restarts it).
  private let links: [String: OwnedLink]
  private let ledger: WorkLedger?
  private let rates: LinkRates

  static var enabled: Bool {
    get { GateSettings.shared.bool(forKey: switchKey) }
    set { GateSettings.shared.set(newValue, forKey: switchKey) }
  }

  init(registry: [RelayHookEntry], legacy: Bool, links: [OwnedLink], ledger: WorkLedger?, rates: LinkRates) throws {
    self.registry = registry
    self.legacy = legacy
    var byID: [String: OwnedLink] = [:]
    for link in links { byID[link.id] = link }
    self.links = byID
    self.ledger = ledger
    self.rates = rates
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: RelayHook.port)!)
    listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      connection.start(queue: self.io)
      // Closed after the deadline whatever its state; a cancel after the answer does nothing.
      self.io.asyncAfter(deadline: .now() + Self.connectionDeadline) { connection.cancel() }
      self.read(connection, buffer: Data())
    }
  }

  func start() { listener.start(queue: queue) }
  func stop() { listener.cancel() }

  /// 192 random bits, URL-safe; nil when the system generator fails, so a hook never gets a
  /// predictable (all-zero) secret.
  static func newSecret() -> String? {
    var bytes = [UInt8](repeating: 0, count: 24)
    guard SecRandomCopyBytes(nil, bytes.count, &bytes) == errSecSuccess else { return nil }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func digest(_ secret: String) -> String {
    let d = SHA256.hash(data: Data(secret.utf8))
    return d.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: deliveries

  /// One request, as read: the head's parts and the whole body (by Content-Length).
  struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
  }
  enum Parsed {
    case incomplete
    /// The declared body is larger than `HookGate.bodyLimit`: answered 413 before it is read.
    case tooLarge
    case malformed
    case request(Request)
  }

  /// One delivery, on the IO queue.
  private func handle(_ request: Request) -> (Int, String) {
    guard request.method == "POST" else { return (405, Self.error("POST only")) }
    if let id = LinkAddress.id(fromPath: request.path) { return handleLink(id, request) }
    guard legacy else { return (404, Self.error("unknown address")) }
    return handleHook(request)
  }

  /// An owned link: admitted by `HookGate`, then written to the ledger before the 200.
  private func handleLink(_ id: String, _ request: Request) -> (Int, String) {
    guard let link = links[id] else { return (404, Self.error("unknown link")) }
    if link.isPaused { return (200, "{\"ok\":true,\"paused\":true}") }
    guard let ledger else { return (503, Self.error("Serein is not ready yet. Try again later.")) }
    guard let text = LinkSecrets.read(id) else {
      return (503, Self.error("Serein cannot check deliveries right now. Try again later."))
    }
    let secret: Data
    switch link.spec.auth {
    case .standard: secret = HookGate.standardKey(from: text) ?? Data()
    case .bearer, .github: secret = Data(text.utf8)
    }
    let now = Date()
    let delivery = HookGate.Delivery(headers: request.headers, body: request.body)
    let outcome = HookGate.admit(delivery, spec: link.spec, secret: secret, rate: rates.rate(id), now: now)
    switch outcome {
    case .refuse(let refusal):
      return (refusal.status, Self.error(refusal.words))
    case .skip(let skip):
      return (200, "{\"ok\":true,\"skipped\":\"\(skip.rawValue)\"}")
    case .run(let admitted):
      let enqueued: WorkLedger.Enqueued
      do {
        enqueued = try ledger.enqueue(
          .link, owner: admitted.owner, dedupeKey: admitted.dedupeKey, payload: admitted.prompt, now: now)
      } catch {
        return (503, Self.error("Serein could not save the delivery. Try again later."))
      }
      guard enqueued.isNew else { return (200, "{\"ok\":true,\"duplicate\":true}") }
      rates.record(id, at: now)
      let row = enqueued.row
      Task { @MainActor in RelayOrchestrator.shared?.linkArrived(row, link: id) }
      return (200, "{\"ok\":true}")
    }
  }

  /// A hook made in Settings: authenticate, dedupe, wake Relay.
  private func handleHook(_ request: Request) -> (Int, String) {
    guard let token = RelayHook.token(fromURL: request.path, authorization: request.headers["authorization"]) else {
      return (401, Self.error("unknown hook secret"))
    }
    // Every hook is compared in constant time, with no early exit on a match.
    let presented = Self.digest(token)
    var matched: RelayHookEntry?
    for hook in registry where AgentAccess.tokensEqual(presented, hook.secretDigest) { matched = hook }
    guard let entry = matched else { return (401, Self.error("unknown hook secret")) }
    let text = String(decoding: request.body, as: UTF8.self)
    let body: String? = text.isEmpty ? nil : String(text.prefix(RelayHook.bodyBudget))
    let header = request.headers["idempotency-key"]
    // On disk before the 200, as an owned link's delivery is: a crash or Stop Everything's pause
    // keeps it queued, and a redelivery writes nothing. Before the ledger opens, as before.
    if let ledger {
      guard let enqueued = try? RelayHook.enqueue(ledger, hook: entry.id, source: entry.name, header: header, body: body)
      else { return (503, Self.error("Serein could not save the delivery. Try again later.")) }
      guard enqueued.isNew else { return (202, "{\"ok\":true,\"duplicate\":true}") }
      let row = enqueued.row
      Task { @MainActor in RelayOrchestrator.shared?.hookArrived(row) }
      return (200, "{\"ok\":true}")
    }
    let key = RelayHook.deliveryKey(header: header, body: body)
    guard log.insert(key) else { return (202, "{\"ok\":true,\"duplicate\":true}") }
    let prompt = RelayHook.prompt(source: entry.name, body: body, key: nil)
    Task { @MainActor in
      guard let relay = RelayOrchestrator.shared, RelayOrchestrator.enabled else { return }
      relay.enqueueWebhook(prompt)
    }
    return (200, "{\"ok\":true}")
  }

  static func error(_ words: String) -> String {
    let safe = words.replacingOccurrences(of: "\"", with: "'")
    return "{\"error\":\"\(safe)\"}"
  }

  private func read(_ connection: NWConnection, buffer: Data) {
    switch Self.parse(buffer) {
    case .request(let request):
      respond(connection, handle(request))
      return
    case .tooLarge:
      respond(connection, (413, Self.error(HookGate.Refusal.tooLarge.words)))
      return
    case .malformed:
      respond(connection, (400, Self.error("The request could not be read.")))
      return
    case .incomplete:
      break
    }
    guard buffer.count < Self.headLimit + HookGate.bodyLimit + 1 else { connection.cancel(); return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
      guard let self, let data, !data.isEmpty else { connection.cancel(); return }
      var next = buffer
      next.append(data)
      self.read(connection, buffer: next)
    }
  }

  private func respond(_ connection: NWConnection, _ answer: (Int, String)) {
    let (status, payload) = answer
    let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n"
    connection.send(content: Data((head + payload).utf8), completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  /// The request once its head and its whole body are in; `.incomplete` while more is coming.
  /// A body sent in parts (Transfer-Encoding) and a repeated Content-Length are not taken.
  static func parse(_ buffer: Data) -> Parsed {
    let separator = Data("\r\n\r\n".utf8)
    guard let end = buffer.range(of: separator) else {
      return buffer.count > headLimit ? .malformed : .incomplete
    }
    guard end.lowerBound - buffer.startIndex <= headLimit else { return .malformed }
    let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return .malformed }
    let requestLine = lines.removeFirst()
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else { return .malformed }
    var headers: [String: String] = [:]
    var lengths = 0
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = String(line[..<colon]).lowercased()
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      if name == "content-length" { lengths += 1 }
      headers[name] = value
    }
    // Two Content-Length headers can be read two ways by a proxy in front: refused.
    guard lengths <= 1 else { return .malformed }
    if headers["transfer-encoding"] != nil { return .malformed }
    let declared: Int = Int(headers["content-length"] ?? "0") ?? -1
    guard declared >= 0 else { return .malformed }
    guard declared <= HookGate.bodyLimit else { return .tooLarge }
    let start = end.upperBound
    let available = buffer.endIndex - start
    guard available >= declared else { return .incomplete }
    let body = Data(buffer[start..<(start + declared)])
    return .request(Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body))
  }
}
