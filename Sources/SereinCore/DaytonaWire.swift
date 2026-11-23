import Foundation

/// The wire of Daytona's public API (https://www.daytona.io/docs/en/tools/api.md): sandbox calls on
/// `app.daytona.io/api` (https://www.daytona.io/docs/openapi.json), calls into one computer's
/// toolbox on `proxy.app.daytona.io/toolbox/{id}` (https://www.daytona.io/docs/toolbox-openapi.json)
/// and its usage on `analytics.app.daytona.io` (https://www.daytona.io/docs/analytics-openapi.json).
/// Daytona authorises all three with the person's key as a Bearer header; its toolbox takes no
/// other credential (a preview token would open the whole sandbox, and Serein never asks for one),
/// and Daytona's proxy takes that header off before anything reaches the sandbox. The three hosts
/// are fixed here: a host Daytona names in an answer is checked against them, never followed.
/// Everything here is pure. A call is built without the key, which `Call.urlRequest(key:)` adds as
/// its one header, so no URL, body or log line can hold it. Every answer is untrusted, read with
/// size caps.
public enum DaytonaWire {
  public static let apiHost = "app.daytona.io"
  public static let toolboxHost = "proxy.app.daytona.io"
  public static let analyticsHost = "analytics.app.daytona.io"
  /// The snapshot Settings names: a Linux VM snapshot the person makes once in Daytona from an
  /// image built from Serein's recipe.
  public static let snapshotKey = "serein.computer.daytona.snapshot"
  public static let defaultSnapshot = "serein-computer"
  /// Bytes an answer may hold; a screenshot, a tree and a usage list have their own caps.
  public static let answerLimit = 256 * 1024
  public static let screenLimit = 12 << 20
  public static let treeLimit = 4 << 20
  public static let usageLimit = 1 << 20
  /// Minutes without activity before Daytona pauses the computer itself (memory kept): a
  /// backstop for Serein's own idle pause if Serein quits, crashes or the Mac sleeps.
  public static let idleMinutes = Int(ComputerPolicy.idleLimit) / 60 + 5
  /// The label every computer Serein makes carries, so Settings can list Serein's own.
  public static let labels = ["serein": "computer"]
  /// The first part of every command session Serein opens inside, so leftovers can be found.
  public static let sessionPrefix = "serein-"
  /// Bytes of input sent in one request (as one base64 line).
  public static let inputLimit = 256 * 1024
  /// The screen Daytona's desktop is made with (`VNC_RESOLUTION`), Serein's coordinate space.
  public static let resolution = "\(ComputerPolicy.screenWidth)x\(ComputerPolicy.screenHeight)"
  /// The one class Serein uses: a VM with its own kernel, whose pause keeps its memory.
  public static let vmClass = "linux-vm"

  public struct Call: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
      case api
      case toolbox(String)
      case analytics
    }
    public var method: String
    public var target: Target
    /// The path after the target's own prefix, with its query, percent-encoded.
    public var path: String
    public var body: Data?
    public var contentType: String?
    /// Seconds without a byte before the call fails.
    public var timeout: TimeInterval
    /// Bytes the answer may hold.
    public var limit: Int

    public var host: String {
      switch target {
      case .api: return DaytonaWire.apiHost
      case .toolbox: return DaytonaWire.toolboxHost
      case .analytics: return DaytonaWire.analyticsHost
      }
    }
    private var prefix: String {
      switch target {
      case .api: return "/api"
      case .toolbox(let id): return "/toolbox/" + id
      case .analytics: return ""
      }
    }
    public var url: URL? { URL(string: "https://" + host + prefix + path) }
    /// The request, with the key in its one header.
    public func urlRequest(key: String) -> URLRequest? {
      guard let url, HostedWire.validSecret(key) else { return nil }
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
      request.httpMethod = method
      request.httpBody = body
      request.httpShouldHandleCookies = false
      if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
      request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
      return request
    }
    /// The same request as a WebSocket upgrade (`wss`), for a command's log stream.
    public func webSocketRequest(key: String) -> URLRequest? {
      guard var request = urlRequest(key: key), let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
      else { return nil }
      parts.scheme = "wss"
      request.url = parts.url
      request.httpBody = nil
      return request.url == nil ? nil : request
    }
  }

  // MARK: checks on what goes out

  /// A snapshot name: ASCII letters, digits and `- _ . : /`, at most 128.
  public static func validSnapshot(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 128
      && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:/".unicodeScalars.contains($0)) }
  }
  private static func encoded(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
  }
  private static func api(_ method: String, _ path: String, _ body: Any? = nil, timeout: TimeInterval = 60,
                          limit: Int = answerLimit) -> Call {
    Call(method: method, target: .api, path: path, body: body.map(HostedWire.json), contentType: body == nil ? nil : "application/json",
         timeout: timeout, limit: limit)
  }
  private static func toolbox(_ id: String, _ method: String, _ path: String, _ body: Any? = nil, timeout: TimeInterval = 60,
                              limit: Int = answerLimit) -> Call? {
    guard HostedWire.validID(id) else { return nil }
    return Call(method: method, target: .toolbox(id), path: path, body: body.map(HostedWire.json),
                contentType: body == nil ? nil : "application/json", timeout: timeout, limit: limit)
  }

  // MARK: sandbox calls (https://www.daytona.io/docs/openapi.json, tag "sandbox")

  /// Create (POST /sandbox): from the person's snapshot, run as Serein's own user, its preview
  /// closed (`public: false`), labelled as Serein's, at Serein's screen size, paused by Daytona
  /// itself after `idleMinutes` without activity (never stopped instead), and nothing secret in its
  /// environment (no secrets, no proxy URL). Through this Mac blocks all of its own internet
  /// (`networkBlockAll`); Daytona's own internet held to the person's list sends that list alone
  /// (`domainAllowList`: the network fields are exclusive at create); left open, it sends no
  /// network field, so the organization's policy applies
  /// (https://www.daytona.io/docs/en/network-limits.md).
  public static func create(snapshot: String, network: HostedNetwork) -> Call? {
    guard validSnapshot(snapshot) else { return nil }
    var body: [String: Any] = [
      "snapshot": snapshot, "user": HostedWire.user, "public": false, "labels": labels, "env": ["VNC_RESOLUTION": resolution],
      "autoPauseInterval": idleMinutes, "autoStopInterval": 0,
    ]
    switch network {
    case .throughThisMac: body["networkBlockAll"] = true
    case .providerOpen: break
    case .provider(let allow):
      guard let list = domainList(allow) else { return nil }
      body["domainAllowList"] = list
    }
    return api("POST", "/sandbox", body, timeout: 120)
  }
  /// Get (GET /sandbox/{id}): Daytona's own record of the computer, read before Serein trusts it.
  public static func info(_ id: String) -> Call? {
    guard HostedWire.validID(id) else { return nil }
    return api("GET", "/sandbox/\(id)")
  }
  /// Start (POST /sandbox/{id}/start): starts a stopped or archived computer, resumes a paused one.
  public static func start(_ id: String) -> Call? {
    guard HostedWire.validID(id) else { return nil }
    return api("POST", "/sandbox/\(id)/start", timeout: 120)
  }
  /// Pause (POST /sandbox/{id}/pause): a VM keeps its memory, so its apps carry on after a resume.
  public static func pause(_ id: String) -> Call? {
    guard HostedWire.validID(id) else { return nil }
    return api("POST", "/sandbox/\(id)/pause", timeout: 90)
  }
  /// Delete (DELETE /sandbox/{id}); Daytona finishes it on its own, so Serein reads back until it is gone.
  public static func delete(_ id: String) -> Call? {
    guard HostedWire.validID(id) else { return nil }
    return api("DELETE", "/sandbox/\(id)")
  }
  /// Network settings (POST /sandbox/{id}/network-settings): block all of its own internet, lift
  /// the block (which also clears any list), or hold it to the person's list (which, Daytona's
  /// page does not say, may leave a block in place: the record read back decides). Refused by
  /// Daytona on Tiers 1 and 2.
  public static func setNetwork(_ id: String, _ network: HostedNetwork) -> Call? {
    guard HostedWire.validID(id) else { return nil }
    switch network {
    case .throughThisMac: return api("POST", "/sandbox/\(id)/network-settings", ["networkBlockAll": true])
    case .providerOpen: return api("POST", "/sandbox/\(id)/network-settings", ["networkBlockAll": false])
    case .provider(let allow):
      guard let list = domainList(allow) else { return nil }
      return api("POST", "/sandbox/\(id)/network-settings", ["domainAllowList": list])
    }
  }
  /// The list as Daytona takes it, comma-separated, at most `HostedNetwork.maxAllow` (Daytona's
  /// limit); nil for an empty, oversized or unclean list.
  static func domainList(_ allow: [String]) -> String? {
    guard !allow.isEmpty, allow.count <= HostedNetwork.maxAllow, HostedNetwork.clean(allow) == allow else { return nil }
    return allow.joined(separator: ",")
  }
  /// Last activity (POST /sandbox/{id}/last-activity): still in use, so Daytona does not pause it yet.
  public static func keepRunning(_ id: String) -> Call? {
    guard HostedWire.validID(id) else { return nil }
    return api("POST", "/sandbox/\(id)/last-activity")
  }
  /// List (GET /sandbox): Serein's own computers on the organization, by label.
  public static func listComputers() -> Call {
    let filter = String(decoding: HostedWire.json(labels), as: UTF8.self)
    return api("GET", "/sandbox?labels=\(encoded(filter))&limit=200")
  }
  /// Usage periods of one computer (GET /organization/{org}/sandbox/{id}/usage on the analytics
  /// host), each with Daytona's price.
  public static func usage(organization: String, sandbox: String, from: Date, to: Date) -> Call? {
    guard HostedWire.validID(organization), HostedWire.validID(sandbox), from <= to else { return nil }
    let stamp = ISO8601DateFormatter()
    let path = "/organization/\(organization)/sandbox/\(sandbox)/usage?from=\(encoded(stamp.string(from: from)))&to=\(encoded(stamp.string(from: to)))"
    return Call(method: "GET", target: .analytics, path: path, body: nil, contentType: nil, timeout: 60, limit: usageLimit)
  }

  // MARK: toolbox calls (https://www.daytona.io/docs/toolbox-openapi.json)

  /// Computer use start (POST /computeruse/start): the desktop's processes Daytona runs itself.
  public static func startDesktop(_ id: String) -> Call? { toolbox(id, "POST", "/computeruse/start", timeout: 90) }
  /// Screenshot (GET /computeruse/screenshot): the whole screen as a base64 PNG.
  public static func screenshot(_ id: String) -> Call? { toolbox(id, "GET", "/computeruse/screenshot", limit: screenLimit) }
  /// Click (POST /computeruse/mouse/click) at a point inside Serein's screen.
  public static func click(_ id: String, x: Int, y: Int, button: String, double: Bool) -> Call? {
    guard onScreen(x, y), ["left", "middle", "right"].contains(button) else { return nil }
    return toolbox(id, "POST", "/computeruse/mouse/click", ["x": x, "y": y, "button": button, "double": double])
  }
  /// Scroll (POST /computeruse/mouse/scroll) up or down, 1 to 30 notches.
  public static func scroll(_ id: String, x: Int, y: Int, direction: String, amount: Int) -> Call? {
    guard onScreen(x, y), ["up", "down"].contains(direction) else { return nil }
    return toolbox(id, "POST", "/computeruse/mouse/scroll", ["x": x, "y": y, "direction": direction, "amount": max(1, min(30, amount))])
  }
  /// Type (POST /computeruse/keyboard/type), 12 ms a character as the helper types.
  public static func type(_ id: String, text: String) -> Call? {
    guard !text.isEmpty else { return nil }
    return toolbox(id, "POST", "/computeruse/keyboard/type", ["text": text, "delay": 12], timeout: 150)
  }
  /// One key (POST /computeruse/keyboard/key) or chord (POST /computeruse/keyboard/hotkey).
  public static func press(_ id: String, _ press: KeyPress) -> Call? {
    switch press {
    case .key(let name): return toolbox(id, "POST", "/computeruse/keyboard/key", ["key": name])
    case .hotkey(let keys): return toolbox(id, "POST", "/computeruse/keyboard/hotkey", ["keys": keys])
    }
  }
  /// Accessibility tree (GET /computeruse/a11y/tree) of every application, to `depth` levels below
  /// its windows.
  public static func tree(_ id: String, depth: Int) -> Call? {
    toolbox(id, "GET", "/computeruse/a11y/tree?scope=all&maxDepth=\(max(1, min(12, depth)) + 2)", timeout: 40, limit: treeLimit)
  }
  /// Windows (GET /computeruse/display/windows).
  public static func windows(_ id: String) -> Call? { toolbox(id, "GET", "/computeruse/display/windows") }
  /// Execute (POST /process/execute): one short shell line of Serein's own, to its end. The
  /// daemon splits its command into arguments and runs no shell, so the line goes to `sh -c`.
  public static func execute(_ id: String, command: String, seconds: Int) -> Call? {
    guard !command.isEmpty else { return nil }
    return toolbox(id, "POST", "/process/execute", ["command": "/bin/sh -c " + quoted(command), "timeout": seconds],
                   timeout: TimeInterval(seconds + 15))
  }
  /// Session create (POST /process/session): one per stream, named by Serein.
  public static func openSession(_ id: String, session: String) -> Call? {
    guard session.hasPrefix(sessionPrefix), HostedWire.validID(session) else { return nil }
    return toolbox(id, "POST", "/process/session", ["sessionId": session])
  }
  /// Session exec (POST /process/session/{sid}/exec), asynchronous: answers the command's id.
  /// Daytona copies a command's input into its log unless told not to: Serein's own requests
  /// would come back as the command's output.
  public static func run(_ id: String, session: String, line: String) -> Call? {
    guard HostedWire.validID(session), !line.isEmpty else { return nil }
    return toolbox(id, "POST", "/process/session/\(session)/exec", ["command": line, "runAsync": true, "suppressInputEcho": true])
  }
  /// Send input (POST /process/session/{sid}/command/{cid}/input): one base64 line of stdin.
  public static func input(_ id: String, session: String, command: String, data: Data) -> Call? {
    guard HostedWire.validID(session), HostedWire.validID(command), !data.isEmpty, data.count <= inputLimit else { return nil }
    return toolbox(id, "POST", "/process/session/\(session)/command/\(command)/input", ["data": armored(data)])
  }
  /// The end of a command's stdin: one line the helper's armor takes as end of input.
  public static func endInput(_ id: String, session: String, command: String) -> Call? {
    guard HostedWire.validID(session), HostedWire.validID(command) else { return nil }
    return toolbox(id, "POST", "/process/session/\(session)/command/\(command)/input", ["data": endLine])
  }
  /// Logs (GET /process/session/{sid}/command/{cid}/logs?follow=true), followed over a WebSocket.
  public static func logs(_ id: String, session: String, command: String) -> Call? {
    guard HostedWire.validID(session), HostedWire.validID(command) else { return nil }
    return toolbox(id, "GET", "/process/session/\(session)/command/\(command)/logs?follow=true",
                   timeout: TimeInterval(idleMinutes * 60))
  }
  /// Session delete (DELETE /process/session/{sid}).
  public static func closeSession(_ id: String, session: String) -> Call? {
    guard HostedWire.validID(session) else { return nil }
    return toolbox(id, "DELETE", "/process/session/\(session)", timeout: 30)
  }
  /// Session list (GET /process/session), to find Serein's leftovers.
  public static func sessions(_ id: String) -> Call? { toolbox(id, "GET", "/process/session", timeout: 30) }
  /// Upload (POST /files/upload-v2): a file Serein made (a checkpoint going back in) at a path of
  /// its own, as raw bytes; Daytona makes the folders on the way.
  public static func upload(_ id: String, path: String) -> Call? {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/")
    guard path.hasPrefix("/"), !path.contains(".."), path.count <= 512, path.unicodeScalars.allSatisfy(allowed.contains),
      let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed),
      var call = toolbox(id, "POST", "/files/upload-v2?path=\(encoded)", timeout: 300)
    else { return nil }
    call.contentType = "application/octet-stream"
    return call
  }
  private static func onScreen(_ x: Int, _ y: Int) -> Bool {
    (0..<ComputerPolicy.screenWidth).contains(x) && (0..<ComputerPolicy.screenHeight).contains(y)
  }

  // MARK: keys

  public enum KeyPress: Equatable, Sendable {
    case key(String)
    case hotkey(String)
  }
  /// Serein's key words (xdotool's names, as the agent and Take over send them) in Daytona's own.
  static let keyNames = [
    "return": "enter", "kp_enter": "enter", "control": "ctrl", "prior": "pageup", "page_up": "pageup", "next": "pagedown",
    "page_down": "pagedown", "esc": "escape", "super": "cmd",
  ]
  /// A key or a space-separated sequence of keys and chords (`Return`, `ctrl+l`, `Tab Tab`), each
  /// one press; nil for anything else, with the helper's rule on what a key may hold.
  public static func keyPresses(_ raw: String) -> [KeyPress]? {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+ ")
    let text = raw.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, text.count <= 40, text.allSatisfy(allowed.contains) else { return nil }
    var presses: [KeyPress] = []
    for chord in text.split(separator: " ") {
      let names = chord.split(separator: "+", omittingEmptySubsequences: false).map { part -> String in
        let name = part.lowercased()
        return keyNames[name] ?? name
      }
      guard names.allSatisfy({ !$0.isEmpty }) else { return nil }
      presses.append(names.count == 1 ? .key(names[0]) : .hotkey(names.joined(separator: "+")))
    }
    return presses.isEmpty ? nil : presses
  }

  // MARK: the command stream

  /// One argument for the session's shell, in single quotes.
  static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
  /// The line a session runs for `command`: in Serein's home, with `environment`, under the
  /// helper's armor (`serein-helper.py --armor`), which carries the command's stdin as base64
  /// lines and its stdout as `:`-led base64 lines, so bytes survive a text stream and an input line
  /// can never read as output, and ends with its exit code. Its stderr is
  /// dropped. nil for an empty command or an argument or name that could not be passed whole.
  public static func armoredLine(_ command: [String], environment: [String: String]) -> String? {
    let nameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    guard !command.isEmpty, command.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && !$0.contains("\n") }),
      environment.allSatisfy({ !$0.key.isEmpty && $0.key.unicodeScalars.allSatisfy(nameCharacters.contains)
        && !$0.value.contains("\0") && !$0.value.contains("\n") })
    else { return nil }
    let env = environment.sorted { $0.key < $1.key }.map { quoted($0.key + "=" + $0.value) }
    // No `exec`: the session's own shell stays, whatever Daytona wraps around the command.
    return "cd " + quoted(HostedWire.home) + " && env " + env.joined(separator: " ")
      + " python3 -I /opt/serein/helper.py --armor -- " + command.map(quoted).joined(separator: " ") + " 2>/dev/null"
  }
  /// Bytes for the command's stdin as one armored line.
  public static func armored(_ data: Data) -> String { data.base64EncodedString() + "\n" }
  /// The armor's end of input.
  public static let endLine = ".\n"

  /// One piece of an armored command's output.
  public enum Armored: Equatable, Sendable {
    case data(Data)
    case exit(Int)
  }
  /// Bytes an unfinished line may hold before the stream is out of step: an armor line is at
  /// most 65,537 bytes (`:` and the base64 of 48 KiB).
  public static let lineLimit = 1 << 17
  /// What the armor writes: `:`-led base64 lines, and one `!<code>` line at the end.
  private static let armorBytes = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=!:".utf8))
  /// The whole lines in what a command's log stream sent so far, taken out of `buffer`. Any byte
  /// the armor never writes (the markers Daytona's stream puts around output) is dropped. Only a
  /// `:` line is output and only a `!` line the end; any other line, or an unfinished line over
  /// `lineLimit`, throws: the stream is out of step and ends. The buffer is cut once, after the
  /// last whole line, so a flood of empty lines costs one pass.
  public static func unarmor(_ buffer: inout Data) throws -> [Armored] {
    var out: [Armored] = []
    var cursor = buffer.startIndex
    defer { buffer.removeSubrange(buffer.startIndex..<cursor) }
    while let newline = buffer[cursor...].firstIndex(of: 10) {
      let line = Data(buffer[cursor..<newline].filter { armorBytes.contains($0) })
      cursor = buffer.index(after: newline)
      guard let first = line.first else { continue }
      let rest = Data(line.dropFirst())
      switch first {
      case UInt8(ascii: ":"):
        guard let bytes = Data(base64Encoded: rest) else { throw SereinError.invalid("Daytona sent output Serein could not read.") }
        out.append(.data(bytes))
      case UInt8(ascii: "!"):
        let digits = String(decoding: rest, as: UTF8.self)
        guard digits.count <= 6, digits.allSatisfy(\.isNumber), let code = Int(digits) else {
          throw SereinError.invalid("Daytona sent an end Serein could not read.")
        }
        out.append(.exit(code))
      default:
        throw SereinError.invalid("Daytona sent output Serein could not read.")
      }
    }
    guard buffer.distance(from: cursor, to: buffer.endIndex) <= lineLimit else {
      throw SereinError.invalid("Daytona sent a line longer than Serein reads.")
    }
    return out
  }

  // MARK: reading answers (untrusted, capped)

  /// Daytona's record of a computer (the Sandbox object of GET /sandbox/{id}).
  public struct Detail: Equatable, Sendable {
    public var id: String
    public var organization: String?
    /// One of Daytona's sandbox states, or "unknown".
    public var state: String
    public var sandboxClass: String?
    public var isPublic: Bool?
    public var blockAll: Bool?
    public var cidrAllow: String
    public var domainAllow: String
    /// An outbound proxy is set (its address, which can hold a password, is never kept).
    public var outboundProxy: Bool
    /// Why the network settings asked for are not what Daytona enforces; nil when they are.
    public var policyError: String?
    public var errorReason: String?
    public var cpu: Int?
    public var memoryGB: Int?
    public var createdAt: Date?
    /// The toolbox address Daytona gives is the one Serein sends the key to.
    public var toolboxKnown: Bool
    public var running: Bool { state == "started" }
  }
  static let states: Set<String> = [
    "creating", "restoring", "destroyed", "destroying", "started", "stopped", "starting", "stopping", "error", "build_failed",
    "pending_build", "building_snapshot", "unknown", "pulling_snapshot", "archived", "archiving", "resizing", "snapshotting",
    "forking", "pausing", "paused", "resuming",
  ]
  static func date(_ value: Any?) -> Date? {
    guard let text = value as? String, text.count <= 40 else { return nil }
    let stamp = ISO8601DateFormatter()
    if let plain = stamp.date(from: text) { return plain }
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return stamp.date(from: text)
  }
  private static func listText(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return "" }
    // A full domain list: 100 names of up to 253 characters, and their commas.
    guard let text = value as? String, text.count <= 32_768 else { return nil }
    return text.trimmingCharacters(in: .whitespaces)
  }
  /// nil for anything that is not a computer with a valid id, or carries fields out of bounds.
  public static func readDetail(_ data: Data) -> Detail? {
    guard let object = HostedWire.jsonObject(data, limit: answerLimit), let id = object["id"] as? String, HostedWire.validID(id),
      let cidr = listText(object["networkAllowList"]), let domains = listText(object["domainAllowList"])
    else { return nil }
    let state = (object["state"] as? String).flatMap { states.contains($0) ? $0 : nil } ?? "unknown"
    let proxy = (object["outboundProxyUrl"] as? String).map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
    let policy = (object["networkPolicyError"] as? String).map { HostedWire.plain($0, limit: 300) }.flatMap { $0.isEmpty ? nil : $0 }
    let toolbox = (object["toolboxProxyUrl"] as? String).flatMap { URL(string: $0) }
    let known = toolbox.map {
      $0.scheme == "https" && $0.host == toolboxHost && $0.port == nil && $0.user == nil && $0.query == nil
        && ["/toolbox", "/toolbox/"].contains($0.path)
    } ?? false
    return Detail(
      id: id, organization: (object["organizationId"] as? String).flatMap { HostedWire.validID($0) ? $0 : nil }, state: state,
      sandboxClass: (object["sandboxClass"] as? String).map { HostedWire.plain($0, limit: 40) }, isPublic: object["public"] as? Bool,
      blockAll: object["networkBlockAll"] as? Bool, cidrAllow: cidr, domainAllow: domains, outboundProxy: proxy, policyError: policy,
      errorReason: (object["errorReason"] as? String).map { HostedWire.plain($0, limit: 300) },
      cpu: HostedWire.integer(object["cpu"]).flatMap { (1...256).contains($0) ? $0 : nil },
      memoryGB: HostedWire.integer(object["memory"]).flatMap { (1...4096).contains($0) ? $0 : nil },
      createdAt: date(object["createdAt"]), toolboxKnown: known)
  }
  /// Whether Daytona's own record shows what Serein needs before it uses the computer. Always: its
  /// preview closed and its toolbox at the host Serein sends the key to. Through this Mac: all of
  /// its own internet blocked, no list or proxy beside it, and no word from Daytona that the block
  /// is not in force (Tiers 1 and 2 cannot block it). Daytona's own internet held to a list:
  /// exactly that list, no block or address list beside it, and no word that it is not in force.
  /// Left open: no block or list. None of them with an outbound proxy.
  public static func confirms(_ detail: Detail, _ network: HostedNetwork) -> Bool {
    guard detail.isPublic == false, detail.toolboxKnown, !detail.outboundProxy else { return false }
    switch network {
    case .throughThisMac:
      return detail.blockAll == true && detail.cidrAllow.isEmpty && detail.domainAllow.isEmpty && detail.policyError == nil
    case .providerOpen:
      // No list left either, so a computer leaving its list is sent the lift that clears it.
      return detail.blockAll != true && detail.cidrAllow.isEmpty && detail.domainAllow.isEmpty
    case .provider(let allow):
      return !allow.isEmpty && detail.blockAll != true && detail.cidrAllow.isEmpty && detail.policyError == nil
        && domains(detail.domainAllow) == Set(allow)
    }
  }
  /// The names of a `domainAllowList` Daytona reports, in lower case, without the spaces it trims.
  static func domains(_ list: String) -> Set<String> {
    Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
  }
  /// How many of Serein's computers a list answer holds; nil when it is not a list of computers.
  public static func readListCount(_ data: Data) -> Int? {
    guard let object = HostedWire.jsonObject(data, limit: answerLimit), let items = object["items"] as? [[String: Any]],
      items.count <= 1000, items.allSatisfy({ ($0["id"] as? String).map(HostedWire.validID) == true })
    else { return nil }
    return items.count
  }
  /// The command id a session exec answers; nil when there is none.
  public static func readCommandID(_ data: Data) -> String? {
    guard let object = HostedWire.jsonObject(data, limit: answerLimit), let id = object["cmdId"] as? String, HostedWire.validID(id)
    else { return nil }
    return id
  }
  /// The ids of Serein's own sessions in a session list; nil when unreadable.
  public static func readSessions(_ data: Data) -> [String]? {
    guard data.count <= answerLimit, let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
      list.count <= 4096
    else { return nil }
    return list.compactMap { session in
      guard let id = session["sessionId"] as? String, id.hasPrefix(sessionPrefix), HostedWire.validID(id) else { return nil }
      return id
    }
  }
  /// The screenshot's base64 PNG; nil when there is none.
  public static func readScreenshot(_ data: Data) -> String? {
    guard let object = HostedWire.jsonObject(data, limit: screenLimit), let png = object["screenshot"] as? String, !png.isEmpty
    else { return nil }
    return png
  }
  /// The windows as the helper lists them: an id and a title of at most 200 characters.
  public static func readWindows(_ data: Data) -> [[String: String]]? {
    guard let object = HostedWire.jsonObject(data, limit: answerLimit), let list = object["windows"] as? [[String: Any]],
      list.count <= 500
    else { return nil }
    return list.map { window in
      ["id": HostedWire.integer(window["id"]).map(String.init) ?? "", "title": HostedWire.plain(window["title"] as? String ?? "", limit: 200)]
    }
  }
  /// The accessibility tree in the helper's lines (`role "name" x,y wxh [focused]`, indented by
  /// level), only the windows whose title holds `window` when one is named, at most `depth` levels
  /// below each window, 2,000 lines and `ComputerPolicy.outputLimit` characters.
  public static func renderTree(_ data: Data, window: String?, depth: Int) -> (text: String, cut: Bool)? {
    guard let object = HostedWire.jsonObject(data, limit: treeLimit), let root = object["root"] as? [String: Any] else { return nil }
    let wanted = (window ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    let deepest = max(1, min(12, depth)) + 2
    let windowRoles: Set<String> = ["frame", "window", "dialog"]
    var lines: [String] = []
    var cut = object["truncated"] as? Bool == true
    func walk(_ node: [String: Any], _ level: Int, _ shown: Bool) {
      // The server itself stops at maxDepth, so a boundary node cannot prove a complete walk.
      if level >= deepest { cut = true }
      guard level <= deepest else { return }
      guard lines.count < 2000 else {
        cut = true
        return
      }
      let role = HostedWire.plain(node["role"] as? String ?? "?", limit: 40)
      let name = HostedWire.plain(node["name"] as? String ?? "", limit: 80)
      let show = shown || wanted.isEmpty || (windowRoles.contains(role.lowercased()) && name.lowercased().contains(wanted))
      if show {
        var line = String(repeating: "  ", count: level) + role + " \"" + name + "\""
        if let box = node["bounds"] as? [String: Any], let x = HostedWire.integer(box["x"]), let y = HostedWire.integer(box["y"]),
          let w = HostedWire.integer(box["width"]), let h = HostedWire.integer(box["height"])
        {
          line += " \(x),\(y) \(w)x\(h)"
        }
        if (node["states"] as? [Any])?.contains(where: { ($0 as? String)?.lowercased() == "focused" }) == true { line += " [focused]" }
        lines.append(line)
      }
      let children = node["children"] as? [Any] ?? []
      if children.count > 200 || (node["name"] as? String ?? "").count > 80 { cut = true }
      for child in children.prefix(200) {
        if let child = child as? [String: Any] { walk(child, level + 1, show) } else { cut = true }
      }
    }
    walk(root, 0, false)
    let text = lines.joined(separator: "\n")
    return (String(text.prefix(ComputerPolicy.outputLimit)), cut || text.count > ComputerPolicy.outputLimit)
  }
  /// What Daytona's usage periods for a computer cost in all, in dollars; nil when unreadable.
  public static func readUsage(_ data: Data) -> Double? {
    guard data.count <= usageLimit, let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any], list.count <= 100_000
    else { return nil }
    var total = 0.0
    for item in list {
      guard let period = item as? [String: Any] else { return nil }
      guard let price = (period["price"] as? NSNumber)?.doubleValue, price.isFinite, (0...1_000_000).contains(price) else { continue }
      total += price
    }
    return total
  }

  // MARK: errors

  /// A plain sentence for an error answer, with every secret Serein holds taken out (HostedWire).
  public static func errorText(status: Int, body: Data, secrets: [String]) -> String {
    HostedWire.errorText(provider: "Daytona", status: status, body: body, secrets: secrets, limit: answerLimit)
  }
}
