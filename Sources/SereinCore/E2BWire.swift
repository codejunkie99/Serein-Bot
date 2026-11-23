import CryptoKit
import Foundation

/// The wire of E2B's public API (https://docs.e2b.dev/api-reference): platform calls on
/// `api.e2b.app` authorised by the person's key, and calls into one computer's own service
/// (envd) on `sandbox.e2b.app`, routed by headers and authorised by that computer's access token.
/// Everything here is pure. A call is built without any secret: the key or the token is added as
/// its one header by `Call.urlRequest(secret:)`, so no URL, body or log line can hold it, and the
/// key never goes to the computer's host. Every answer is untrusted input, read with size caps.
public enum E2BWire {
  public static let platformHost = "api.e2b.app"
  public static let envdHost = "sandbox.e2b.app"
  public static let envdPort = 49983
  /// The template Settings names, built once by the person with E2B's own tool from Serein's recipe.
  public static let templateKey = "serein.computer.e2b.template"
  public static let defaultTemplate = "serein-computer"
  /// Bytes a platform or one-shot answer may hold; a longer one is refused.
  public static let answerLimit = 256 * 1024
  /// Bytes one streamed message may hold.
  public static let frameLimit = 8 << 20
  /// Seconds E2B keeps a computer running without a word from Serein before it pauses it (memory
  /// kept): a backstop for Serein's own idle pause if Serein quits, crashes or the Mac sleeps.
  public static let providerTimeout = Int(ComputerPolicy.idleLimit) + 5 * 60
  /// Every IPv4 address: denied on the computer's own internet in every mode.
  public static let allTraffic = "0.0.0.0/0"
  /// The tag every computer Serein makes carries (E2B metadata), so Settings can list Serein's own.
  public static let metadata = ["serein": "computer"]

  public struct Call: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
      case platform
      case computer(String)
    }
    public var method: String
    public var target: Target
    /// The path and query, percent-encoded.
    public var path: String
    public var body: Data?
    public var contentType: String?
    /// A Connect call into the computer: the protocol-version header goes with it.
    public var connect: Bool
    /// The computer's system user for the call (envd's basic-auth user, no password).
    public var user: String?
    /// Seconds without a byte before the call fails.
    public var timeout: TimeInterval
    /// Further headers the call needs (never a secret).
    public var headers: [String: String] = [:]

    public var host: String { target == .platform ? E2BWire.platformHost : E2BWire.envdHost }
    public var url: URL? { URL(string: "https://" + host + path) }
    /// What a log line or an error may say about the call: method, host and path, never the query.
    public var logLine: String {
      method + " " + host + (path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path)
    }
    /// The request, with the secret in its one header: the account key for the platform, the
    /// computer's access token for the computer's own service.
    public func urlRequest(secret: String) -> URLRequest? {
      guard let url, HostedWire.validSecret(secret) else { return nil }
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
      request.httpMethod = method
      request.httpBody = body
      request.httpShouldHandleCookies = false
      if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
      for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
      switch target {
      case .platform:
        request.setValue(secret, forHTTPHeaderField: "X-API-Key")
      case .computer(let id):
        request.setValue(id, forHTTPHeaderField: "E2b-Sandbox-Id")
        request.setValue(String(E2BWire.envdPort), forHTTPHeaderField: "E2b-Sandbox-Port")
        request.setValue(secret, forHTTPHeaderField: "X-Access-Token")
        if connect { request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version") }
        if let user {
          request.setValue("Basic " + Data((user + ":").utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
      }
      return request
    }
  }

  // MARK: checks on what goes out and comes back

  private static func validID(_ text: String) -> Bool { HostedWire.validID(text) }
  /// A template name or id: ASCII letters, digits and `- _ . : /`, at most 128.
  public static func validTemplate(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 128
      && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:/".unicodeScalars.contains($0)) }
  }

  // MARK: platform calls (https://docs.e2b.dev/api-reference/sandboxes)

  private static func json(_ object: Any) -> Data { HostedWire.json(object) }
  private static func platform(_ method: String, _ path: String, _ body: Any? = nil, timeout: TimeInterval = 60) -> Call {
    Call(method: method, target: .platform, path: path, body: body.map(json), contentType: body == nil ? nil : "application/json",
         connect: false, user: nil, timeout: timeout)
  }
  /// The egress rules of a mode: through this Mac switches the computer's own internet off;
  /// provider internet denies everything but the allowed sites. E2B always holds its internet to
  /// a list, so it is never opened without one (nil).
  private static func egress(_ network: HostedNetwork) -> [String: Any]? {
    switch network {
    case .throughThisMac: return ["allow_internet_access": false]
    case .provider(let allow): return ["allowOut": allow, "denyOut": [allTraffic]]
    case .providerOpen: return nil
    }
  }

  /// Create (POST /v2/sandboxes): Serein's template, its own internet as `network` says, no
  /// public address without the computer's token, every envd call held to that token too
  /// (`secure`, which is also what makes E2B send `envdAccessToken`), paused (memory kept) by E2B
  /// itself after `providerTimeout`, never woken by traffic, and nothing secret in its environment
  /// (none is sent).
  public static func create(template: String, network: HostedNetwork, attempt: String? = nil) -> Call? {
    guard validTemplate(template), let wanted = egress(network) else { return nil }
    var tags = metadata
    if let attempt {
      guard validAttempt(attempt) else { return nil }
      tags["serein-create"] = createTag(attempt)
      if let proof = privateVerifier(attempt) { tags["serein-recovery"] = proof }
    }
    var body: [String: Any] = [
      "templateID": template, "timeout": providerTimeout, "autoPause": true, "secure": true, "metadata": tags,
    ]
    var rules: [String: Any] = ["allowPublicTraffic": false]
    switch network {
    case .throughThisMac: body["allow_internet_access"] = false
    case .provider, .providerOpen: rules.merge(wanted) { _, new in new }
    }
    body["network"] = rules
    var call = platform("POST", "/v2/sandboxes", body, timeout: 90)
    if let attempt { call.headers["Idempotency-Key"] = createTag(attempt) }
    return call
  }
  /// Connect (POST /v2/sandboxes/{id}/connect): resumes a paused computer (memory kept), extends
  /// its time, and returns a fresh access token.
  public static func connect(_ id: String) -> Call? {
    guard validID(id) else { return nil }
    return platform("POST", "/v2/sandboxes/\(id)/connect", ["timeout": providerTimeout], timeout: 90)
  }
  /// Get (GET /sandboxes/{id}): E2B's own account of the computer, read before Serein trusts it.
  public static func info(_ id: String) -> Call? {
    guard validID(id) else { return nil }
    return platform("GET", "/sandboxes/\(id)")
  }
  /// Pause (POST /sandboxes/{id}/pause) with its memory, so its apps carry on after a resume.
  public static func pause(_ id: String) -> Call? {
    guard validID(id) else { return nil }
    return platform("POST", "/sandboxes/\(id)/pause", ["memory": true], timeout: 90)
  }
  /// Delete (DELETE /sandboxes/{id}).
  public static func kill(_ id: String) -> Call? {
    guard validID(id) else { return nil }
    return platform("DELETE", "/sandboxes/\(id)")
  }
  /// Set timeout (POST /sandboxes/{id}/timeout): still in use, so E2B does not pause it yet.
  public static func keepRunning(_ id: String) -> Call? {
    guard validID(id) else { return nil }
    return platform("POST", "/sandboxes/\(id)/timeout", ["timeout": providerTimeout])
  }
  /// Update network (PUT /sandboxes/{id}/network): the egress rules of `network`, replacing all.
  public static func setNetwork(_ id: String, _ network: HostedNetwork) -> Call? {
    guard validID(id), let wanted = egress(network) else { return nil }
    return platform("PUT", "/sandboxes/\(id)/network", wanted)
  }
  public static func createAttempt(key: String) -> String {
    let nonce = UUID().uuidString.lowercased()
    return "v2:" + nonce + "-" + accountProof(nonce, key)
  }

  // A random nonce keeps the proof specific to this operation. The original account key
  // must make the same proof before a person can clear an order after an empty lookup.
  private static func accountProof(_ nonce: String, _ key: String) -> String {
    HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(key.utf8)))
      .prefix(16).map { String(format: "%02x", $0) }.joined()
  }
  private static func receiptPayload(_ attempt: String) -> Substring {
    attempt.hasPrefix("v2:") ? attempt.dropFirst(3) : attempt[...]
  }
  /// Only this public tag is shown in Settings or sent to support. The verifier is separate.
  public static func createTag(_ attempt: String) -> String {
    attempt.hasPrefix("v2:") ? String(receiptPayload(attempt).prefix(36)) : attempt
  }
  public static func privateVerifier(_ attempt: String) -> String? {
    attempt.hasPrefix("v2:") && validAttempt(attempt) ? String(receiptPayload(attempt).suffix(32)) : nil
  }
  public static func matchesCreateKey(_ attempt: String, key: String) -> Bool {
    let payload = receiptPayload(attempt)
    let nonce = String(payload.prefix(36))
    return validAttempt(attempt) && payload == nonce + "-" + accountProof(nonce, key)
  }
  private static func validAttempt(_ value: String) -> Bool {
    let payload = receiptPayload(value)
    let nonce = String(payload.prefix(36))
    guard UUID(uuidString: nonce)?.uuidString.lowercased() == nonce else { return false }
    let suffix = payload.dropFirst(36)
    return suffix.count == 33 && suffix.first == "-" && suffix.dropFirst().allSatisfy { "0123456789abcdef".contains($0) }
  }

  /// A spent idempotency key may create again after expiry. Recover by metadata instead.
  /// The query asks for two matches, allowing duplicates to be refused without selecting one.
  public static func findCreate(_ attempt: String) -> Call? {
    guard validAttempt(attempt) else { return nil }
    let filter = "serein=computer&serein-create=" + createTag(attempt)
    guard let encoded = filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
    return platform("GET", "/v2/sandboxes?metadata=\(encoded)&state=running,paused&limit=2")
  }

  public static func recoveredID(_ data: Data, attempt: String, hasMore: Bool) -> String? {
    guard validAttempt(attempt), !hasMore, data.count <= answerLimit,
      let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], rows.count == 1,
      let row = rows.first, let id = row["sandboxID"] as? String, validID(id),
      let tags = row["metadata"] as? [String: String], tags["serein"] == "computer", tags["serein-create"] == createTag(attempt),
      privateVerifier(attempt).map({ tags["serein-recovery"] == $0 }) ?? true
    else { return nil }
    return id
  }

  /// List (GET /v2/sandboxes): Serein's own computers on the account, running or paused.
  public static func listComputers() -> Call {
    let filter = metadata.map { $0.key + "=" + $0.value }.joined(separator: "&")
    let encoded = filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    return platform("GET", "/v2/sandboxes?metadata=\(encoded)&state=running,paused")
  }

  // MARK: calls into the computer (https://docs.e2b.dev/api-reference/process, /filesystem)

  private static func envd(_ id: String, _ path: String, _ body: Data?, contentType: String?, connect: Bool, user: String?,
                           timeout: TimeInterval) -> Call {
    Call(method: "POST", target: .computer(id), path: path, body: body, contentType: contentType, connect: connect, user: user,
         timeout: timeout)
  }
  /// One Connect message in its envelope: flags 0 (not compressed), the length as four big-endian
  /// bytes, the JSON.
  public static func envelope(_ message: [String: Any]) -> Data {
    let payload = json(message)
    let n = UInt32(payload.count)
    var out = Data([0, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
    out.append(payload)
    return out
  }
  /// Process Start (server streaming): `command` as Serein's user in its home folder, with stdin
  /// open when Serein will write to it.
  public static func startProcess(_ id: String, command: [String], environment: [String: String], stdin: Bool,
                                  user: String = HostedWire.user) -> Call? {
    guard validID(id), let cmd = command.first, !cmd.isEmpty else { return nil }
    let message: [String: Any] = [
      "process": ["cmd": cmd, "args": Array(command.dropFirst()), "envs": environment, "cwd": HostedWire.home], "stdin": stdin,
    ]
    // No deadline is sent: the helper and the shim live as long as the stream; the request fails
    // only after `providerTimeout` seconds without a byte. E2B is asked for a keepalive message
    // every 50 seconds, so an idle stream is not cut by anything on the way.
    var call = envd(id, "/process.Process/Start", envelope(message), contentType: "application/connect+json", connect: true,
                    user: user, timeout: TimeInterval(providerTimeout))
    call.headers = ["Keepalive-Ping-Interval": "50"]
    return call
  }
  /// SendInput (unary): bytes for a process's stdin. Serein sends one at a time, so they arrive in order.
  public static func sendInput(_ id: String, pid: Int, data: Data) -> Call? {
    guard validID(id), pid > 0 else { return nil }
    let body: [String: Any] = ["process": ["pid": pid], "input": ["stdin": data.base64EncodedString()]]
    return envd(id, "/process.Process/SendInput", json(body), contentType: "application/json", connect: true, user: nil, timeout: 60)
  }
  /// CloseStdin (unary): the end of a process's input.
  public static func closeInput(_ id: String, pid: Int) -> Call? {
    guard validID(id), pid > 0 else { return nil }
    return envd(id, "/process.Process/CloseStdin", json(["process": ["pid": pid]]), contentType: "application/json", connect: true,
                user: nil, timeout: 30)
  }
  /// SendSignal (unary): ends a process Serein started and no longer holds.
  public static func killProcess(_ id: String, pid: Int) -> Call? {
    guard validID(id), pid > 0 else { return nil }
    let body: [String: Any] = ["process": ["pid": pid], "signal": "SIGNAL_SIGKILL"]
    return envd(id, "/process.Process/SendSignal", json(body), contentType: "application/json", connect: true, user: nil, timeout: 30)
  }
  /// List (unary): the processes running inside, to find helpers left from before a pause or quit.
  public static func listProcesses(_ id: String) -> Call? {
    guard validID(id) else { return nil }
    return envd(id, "/process.Process/List", json([String: Any]()), contentType: "application/json", connect: true, user: nil,
                timeout: 30)
  }
  /// Upload (POST /files): a file Serein made (a checkpoint going back in) at a path of its own,
  /// as raw bytes; E2B makes the folders on the way.
  public static func upload(_ id: String, path: String, checkpoint: Bool = false) -> Call? {
    if checkpoint {
      let prefix = "/root/.serein-checkpoint-"
      guard path.hasPrefix(prefix), UUID(uuidString: String(path.dropFirst(prefix.count))) != nil else { return nil }
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/")
    guard validID(id), path.hasPrefix("/"), !path.contains(".."), path.count <= 512,
      path.unicodeScalars.allSatisfy(allowed.contains), let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed)
    else { return nil }
    return Call(method: "POST", target: .computer(id), path: "/files?path=\(encoded)&username=\(checkpoint ? "root" : HostedWire.user)", body: nil,
                contentType: "application/octet-stream", connect: false, user: nil, timeout: 300)
  }

  // MARK: reading answers (untrusted, capped)

  private static func jsonObject(_ data: Data) -> [String: Any]? { HostedWire.jsonObject(data, limit: answerLimit) }
  private static func integer(_ value: Any?) -> Int? { HostedWire.integer(value) }
  private static func strings(_ value: Any?, limit: Int) -> [String]? {
    guard let value else { return [] }
    guard let list = value as? [Any], list.count <= limit else { return nil }
    var out: [String] = []
    for item in list {
      guard let text = item as? String, text.count <= 260 else { return nil }
      out.append(text)
    }
    return out
  }

  /// A computer as create and connect return it: its id and, when sent, its access token.
  public struct Sandbox: Equatable, Sendable {
    public var id: String
    public var accessToken: String?
  }
  public static func readSandbox(_ data: Data) -> Sandbox? {
    guard let object = jsonObject(data), let id = object["sandboxID"] as? String, validID(id) else { return nil }
    let token = (object["envdAccessToken"] as? String).flatMap { HostedWire.validSecret($0) ? $0 : nil }
    return Sandbox(id: id, accessToken: token)
  }

  /// E2B's own account of a computer (GET /sandboxes/{id}).
  public struct Detail: Equatable, Sendable {
    public var id: String
    public var running: Bool
    public var cpuCount: Int?
    public var memoryMB: Int?
    /// `allowInternetAccess` is false.
    public var internetOff: Bool
    /// Whether its public addresses take traffic without the computer's token; nil when not said.
    public var publicTraffic: Bool?
    public var allowOut: [String]
    public var denyOut: [String]
    public var accessToken: String?
  }
  /// nil for anything that is not a running or paused computer with a valid id, or carries lists
  /// or sizes out of bounds.
  public static func readDetail(_ data: Data) -> Detail? {
    guard let object = jsonObject(data), let id = object["sandboxID"] as? String, validID(id),
      let state = object["state"] as? String, state == "running" || state == "paused"
    else { return nil }
    let network = object["network"] as? [String: Any] ?? [:]
    guard let allow = strings(network["allowOut"], limit: 200), let deny = strings(network["denyOut"], limit: 200) else { return nil }
    let cpu = integer(object["cpuCount"]).flatMap { (1...256).contains($0) ? $0 : nil }
    let memory = integer(object["memoryMB"]).flatMap { (128...4_194_304).contains($0) ? $0 : nil }
    let token = (object["envdAccessToken"] as? String).flatMap { HostedWire.validSecret($0) ? $0 : nil }
    let internet = object["allowInternetAccess"] as? Bool
    return Detail(
      id: id, running: state == "running", cpuCount: cpu, memoryMB: memory, internetOff: internet == false,
      publicTraffic: network["allowPublicTraffic"] as? Bool, allowOut: allow, denyOut: deny, accessToken: token)
  }
  /// Whether E2B's own account shows the network Serein asked for. Always: no public address
  /// without the computer's token. Through this Mac: its own internet off and nothing allowed out.
  /// Provider internet: everything denied but exactly the allowed sites.
  public static func confirms(_ detail: Detail, _ network: HostedNetwork) -> Bool {
    guard detail.publicTraffic == false else { return false }
    let denyAll = detail.denyOut.contains(allTraffic)
    switch network {
    case .throughThisMac:
      return (detail.internetOff || denyAll) && detail.allowOut.isEmpty
    case .provider(let allow):
      return denyAll && !detail.internetOff && Set(detail.allowOut.map { $0.lowercased() }) == Set(allow)
    case .providerOpen:
      return false
    }
  }
  /// How many of Serein's computers a list answer holds; nil when it is not a list of computers.
  public static func readListCount(_ data: Data) -> Int? {
    guard data.count <= answerLimit, let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
      list.count <= 1000, list.allSatisfy({ ($0["sandboxID"] as? String).map(validID) == true })
    else { return nil }
    return list.count
  }
  /// The pids of Serein's helper and shim processes in a process list; nil when unreadable.
  public static func readHelperPIDs(_ data: Data) -> [Int]? {
    guard let object = jsonObject(data) else { return nil }
    guard let processes = object["processes"] as? [[String: Any]] else { return object.isEmpty ? [] : nil }
    guard processes.count <= 4096 else { return nil }
    return processes.compactMap { process in
      guard let pid = integer(process["pid"]), pid > 0, let config = process["config"] as? [String: Any],
        let args = config["args"] as? [String], args.contains("/opt/serein/helper.py")
      else { return nil }
      return pid
    }
  }

  // MARK: process streams

  /// The flags and length of one streamed message from its five-byte prefix. A compressed message
  /// (Serein asks for none) or one over `frameLimit` throws: the stream is out of step and ends.
  public static func frameHead(_ head: [UInt8]) throws -> (end: Bool, length: Int) {
    guard head.count == 5 else { throw SereinError.invalid("The computer's stream was cut off.") }
    guard head[0] & 0x01 == 0 else { throw SereinError.invalid("E2B sent a compressed message Serein did not ask for.") }
    let length = Int(head[1]) << 24 | Int(head[2]) << 16 | Int(head[3]) << 8 | Int(head[4])
    guard length <= frameLimit else { throw SereinError.invalid("E2B sent a message larger than Serein reads.") }
    return (head[0] & 0x02 != 0, length)
  }

  public enum ProcessEvent: Equatable, Sendable {
    case start(pid: Int)
    case stdout(Data)
    case stderr(Data)
    /// The process ended: its exit code (-1 when it did not exit on its own) and E2B's error line.
    case end(code: Int, error: String?)
    case keepalive
  }
  /// One streamed message of a process: its event, or nil for one Serein does not know (a newer
  /// field is skipped, never guessed at). A message that is not JSON, or bytes that are not
  /// base64, throw.
  public static func processEvent(_ payload: Data) throws -> ProcessEvent? {
    guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
      throw SereinError.invalid("E2B sent a process message Serein could not read.")
    }
    guard let event = object["event"] as? [String: Any] else { return nil }
    if let start = event["start"] as? [String: Any] {
      guard let pid = integer(start["pid"]), pid > 0, pid < Int(Int32.max) else {
        throw SereinError.invalid("E2B sent a process start without a process.")
      }
      return .start(pid: pid)
    }
    if let data = event["data"] as? [String: Any] {
      for (name, make) in [("stdout", ProcessEvent.stdout), ("stderr", ProcessEvent.stderr)] {
        guard let text = data[name] as? String else { continue }
        guard let bytes = Data(base64Encoded: text) else { throw SereinError.invalid("E2B sent process output that is not base64.") }
        return make(bytes)
      }
      return nil
    }
    if let end = event["end"] as? [String: Any] {
      // A zero exit code is left out of the message, and `exited` says it ended on its own.
      let code = integer(end["exitCode"]) ?? (end["exited"] as? Bool == true ? 0 : -1)
      return .end(code: code, error: (end["error"] as? String).map { HostedWire.plain($0, limit: 300) })
    }
    return event["keepalive"] != nil ? .keepalive : nil
  }
  /// The error in a stream's last message, or nil when it ended cleanly.
  public static func endError(_ payload: Data) -> String? {
    guard !payload.isEmpty else { return nil }
    guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
      return "E2B ended the stream with a message Serein could not read."
    }
    guard let error = object["error"] as? [String: Any] else { return nil }
    return HostedWire.plain(error["message"] as? String ?? error["code"] as? String ?? "E2B ended the stream with an error.", limit: 300)
  }

  // MARK: errors

  /// A plain sentence for an error answer, with every secret Serein holds taken out (HostedWire).
  public static func errorText(status: Int, body: Data, secrets: [String]) -> String {
    HostedWire.errorText(provider: "E2B", status: status, body: body, secrets: secrets, limit: answerLimit)
  }
}
