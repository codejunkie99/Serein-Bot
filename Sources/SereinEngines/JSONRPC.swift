import Foundation

/// A JSON value that can cross actors.
public enum JSON: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([JSON].self) { self = .array(value) }
    else { self = .object(try container.decode([String: JSON].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  public subscript(key: String) -> JSON? {
    if case .object(let object) = self { return object[key] }
    return nil
  }
  public var string: String? { if case .string(let value) = self { return value }; return nil }
  public var number: Double? { if case .number(let value) = self { return value }; return nil }
  public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
  public var array: [JSON]? { if case .array(let value) = self { return value }; return nil }
}

public enum JSONRPCError: Error, Sendable, Equatable {
  /// The CLI exited or closed stdout with the request in flight.
  case closed
  case timedOut(method: String)
  case remote(code: Int, message: String)
}

/// JSON-RPC 2.0 over a CLI's lines (Codex app-server, ACP). Every request has a deadline, and the
/// CLI exiting fails every request in flight at once, so no caller waits on a dead process.
public actor JSONRPC {
  /// What the CLI sends unasked: notifications, and requests Serein must answer.
  public enum Incoming: Sendable {
    case notification(method: String, params: JSON)
    case request(id: JSON, method: String, params: JSON)
  }

  public nonisolated let incoming: AsyncStream<Incoming>
  /// Messages put on `incoming` so far. A reader that has handled this many has seen everything
  /// the CLI sent before a response that just arrived.
  public private(set) var yielded = 0
  private let process: EngineProcess
  private let sleep: Sleep
  private let incomingContinuation: AsyncStream<Incoming>.Continuation
  private var nextID = 1
  private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
  private var closed = false

  public init(_ process: EngineProcess) {
    self.init(process, sleep: { try? await Task.sleep(for: $0) })
  }

  init(_ process: EngineProcess, sleep: @escaping Sleep) {
    self.process = process
    self.sleep = sleep
    (incoming, incomingContinuation) = AsyncStream<Incoming>.makeStream()
    Task { await self.read() }
  }

  public func request(_ method: String, _ params: JSON, deadline: Duration) async throws -> JSON {
    if closed { throw JSONRPCError.closed }
    let id = nextID
    nextID += 1
    try write(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
    Task { [sleep] in
      await sleep(deadline)
      self.fail(id, JSONRPCError.timedOut(method: method))
    }
    return try await withCheckedThrowingContinuation { pending[id] = $0 }
  }

  public func notify(_ method: String, _ params: JSON) throws {
    try write(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
  }

  public func respond(to id: JSON, result: JSON) throws {
    try write(["jsonrpc": .string("2.0"), "id": id, "result": result])
  }

  public func respond(to id: JSON, errorCode: Int, message: String) throws {
    try write([
      "jsonrpc": .string("2.0"), "id": id,
      "error": .object(["code": .number(Double(errorCode)), "message": .string(message)]),
    ])
  }

  private func write(_ object: [String: JSON]) throws {
    try process.send(line: JSONEncoder().encode(JSON.object(object)))
  }

  private func read() async {
    for await line in process.lines {
      guard let message = try? JSONDecoder().decode(JSON.self, from: line) else { continue }
      receive(message)
    }
    closed = true
    for (id, _) in pending { fail(id, JSONRPCError.closed) }
    incomingContinuation.finish()
  }

  private func receive(_ message: JSON) {
    let method = message["method"]?.string
    let id = message["id"]
    switch (method, id) {
    case (let method?, let id?) where id != .null:
      yielded += 1
      incomingContinuation.yield(.request(id: id, method: method, params: message["params"] ?? .null))
    case (let method?, _):
      yielded += 1
      incomingContinuation.yield(.notification(method: method, params: message["params"] ?? .null))
    case (nil, let id?):
      guard let key = id.number.map(Int.init), let continuation = pending.removeValue(forKey: key) else { return }
      if let error = message["error"] {
        continuation.resume(throwing: JSONRPCError.remote(
          code: Int(error["code"]?.number ?? 0), message: error["message"]?.string ?? ""))
      } else {
        continuation.resume(returning: message["result"] ?? .null)
      }
    default:
      return
    }
  }

  private func fail(_ id: Int, _ error: JSONRPCError) {
    pending.removeValue(forKey: id)?.resume(throwing: error)
  }
}
