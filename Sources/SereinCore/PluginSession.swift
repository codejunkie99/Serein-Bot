import Foundation

/// One stdio MCP exchange with a plugin server under sandbox-exec, in its own process group.
public enum PluginSession {
  public static func run(
    arguments: [String], folder: URL, environment: [String: String], timeout: TimeInterval,
    body: ((String, [String: Any]) throws -> [String: Any]) throws -> [String: Any]
  ) throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try ProcessGroup.configure(process)
    try process.run()
    defer {
      try? input.fileHandleForWriting.close()
      ProcessGroup.terminate(process)
    }
    let stderr = ErrorText()
    errors.fileHandleForReading.readabilityHandler = { h in
      let d = h.availableData
      if !d.isEmpty { stderr.append(String(decoding: d.prefix(8000), as: UTF8.self)) }
    }
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = Data()
    var next = 0
    let reader = output.fileHandleForReading
    func line() throws -> [String: Any] {
      while true {
        if let i = buffer.firstIndex(of: 10) {
          let raw = buffer.prefix(upTo: i)
          buffer.removeSubrange(...i)
          if let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] { return object }
          continue
        }
        guard Date() < deadline else { throw SereinError.invalid("The plugin did not answer within \(Int(timeout)) seconds.") }
        // Wait for data without blocking past the deadline.
        var pfd = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000)))
        if ready <= 0 { continue }
        let chunk = reader.availableData
        guard !chunk.isEmpty else {
          let detail = stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
          throw SereinError.invalid("The plugin stopped." + (detail.isEmpty ? "" : " " + String(detail.suffix(600))))
        }
        buffer.append(chunk)
        guard buffer.count <= 8_000_000 else { throw SereinError.invalid("The plugin's answer is too large.") }
      }
    }
    func send(_ object: [String: Any]) throws {
      try input.fileHandleForWriting.write(contentsOf: Data((jsonString(object) + "\n").utf8))
    }
    func rpc(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
      next += 1
      let id = next
      try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
      while true {
        let message = try line()
        guard (message["id"] as? Int) == id else {
          // A request from the server (sampling, elicitation): Serein offers none.
          if let other = message["id"], message["method"] != nil {
            try send(["jsonrpc": "2.0", "id": other, "error": ["code": -32601, "message": "Not supported"]])
          }
          continue
        }
        if let error = message["error"] as? [String: Any] {
          throw PluginSession.ServerError(message: String((error["message"] as? String ?? "error").prefix(400)))
        }
        return message["result"] as? [String: Any] ?? [:]
      }
    }
    _ = try rpc("initialize", [
      "protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
      "clientInfo": ["name": "Serein", "version": "1"],
    ])
    try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    return try body(rpc)
  }
}

/// One MCP exchange with a remote server over Streamable HTTP: JSON-RPC POSTs to the
/// reviewed manifest URL and nowhere else, the session id from `initialize` riding along.
public extension PluginSession {
  /// Thrown when the server answers 401: the caller refreshes or signs in, then retries once.
  struct Unauthorized: Error {}
  /// A JSON-RPC error the server answered: its own words, which a caller may need to fence.
  /// Reads as before ("The plugin answered: …").
  struct ServerError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { "The plugin answered: " + message }
  }

  static func runRemote(
    url: URL, headers: [String: String], timeout: TimeInterval,
    body: ((String, [String: Any]) throws -> [String: Any]) throws -> [String: Any]
  ) throws -> [String: Any] {
    // No redirect is followed: a 3xx comes back as an answer, so the request and its bearer token
    // never move to another address. Each request carries `timeout` too.
    let session = EphemeralHTTP.session(resourceTimeout: timeout)
    defer { session.finishTasksAndInvalidate() }
    var sessionId: String?
    var next = 0
    func post(_ object: [String: Any]) throws -> [String: Any]? {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.timeoutInterval = timeout
      for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
      if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
      request.httpBody = try JSONSerialization.data(withJSONObject: object)
      let done = DispatchSemaphore(value: 0)
      var payload: (data: Data, response: URLResponse)?
      session.dataTask(with: request) { data, response, _ in
        if let data, let response { payload = (data, response) }
        done.signal()
      }.resume()
      guard done.wait(timeout: .now() + timeout + 1) == .success, let (data, response) = payload,
        let http = response as? HTTPURLResponse
      else { throw SereinError.invalid("The plugin's server did not answer within \(Int(timeout)) seconds.") }
      if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionId = id }
      guard (200..<300).contains(http.statusCode) else {
        if http.statusCode == 401 { throw Unauthorized() }
        throw SereinError.invalid("The plugin's server answered \(http.statusCode).")
      }
      guard data.count <= 8_000_000 else { throw SereinError.invalid("The plugin's answer is too large.") }
      return transport(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
    }
    func rpc(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
      next += 1
      let id = next
      guard let message = try post(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else {
        throw SereinError.invalid("The plugin's server answered without a result.")
      }
      if let error = message["error"] as? [String: Any] {
        throw PluginSession.ServerError(message: String((error["message"] as? String ?? "error").prefix(400)))
      }
      return message["result"] as? [String: Any] ?? [:]
    }
    _ = try rpc("initialize", [
      "protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
      "clientInfo": ["name": "Serein", "version": "1"],
    ])
    // The initialized notification answers 202 with no body.
    _ = try? post(["jsonrpc": "2.0", "method": "notifications/initialized"])
    return try body(rpc)
  }

  /// Every tool a server lists, following `nextCursor` for at most 10 pages and 1,000 tools, so
  /// a long list is read whole before it is reviewed or compared with a review.
  static func listTools(_ rpc: (String, [String: Any]) throws -> [String: Any]) throws -> [[String: Any]] {
    var tools: [[String: Any]] = []
    var cursor: String?
    for _ in 0..<10 {
      let page = try rpc("tools/list", cursor.map { ["cursor": $0] } ?? [:])
      tools += (page["tools"] as? [[String: Any]] ?? []).prefix(1_000 - tools.count)
      guard tools.count < 1_000, let next = page["nextCursor"] as? String, !next.isEmpty, next != cursor else { break }
      cursor = next
    }
    return tools
  }

  /// The one JSON-RPC message in a Streamable-HTTP answer: a JSON body, or the first data
  /// line of an event stream.
  static func transport(data: Data, contentType: String) -> [String: Any]? {
    guard !data.isEmpty else { return nil }
    if contentType.lowercased().contains("text/event-stream") {
      for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { continue }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
          return object
        }
      }
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  /// Whether a host is allowed by a manifest network entry: exact, or a `*.example.com` suffix.
  static func hostMatches(_ host: String, _ entry: String) -> Bool {
    let h = host.lowercased()
    let e = entry.lowercased()
    if h == e { return true }
    guard e.hasPrefix("*.") else { return false }
    let suffix = String(e.dropFirst(1))
    return h.hasSuffix(suffix) && h.count > suffix.count
  }
}

/// The server's error output, kept short, for the message when it stops.
private final class ErrorText: @unchecked Sendable {
  private let lock = NSLock()
  private var value = ""
  func append(_ s: String) {
    lock.lock()
    defer { lock.unlock() }
    value = String((value + s).suffix(8000))
  }
  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
