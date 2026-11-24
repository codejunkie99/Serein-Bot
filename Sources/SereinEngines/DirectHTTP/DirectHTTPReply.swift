import Foundation
import SereinCore

struct DirectHTTPCall {
  var id = ""
  var name = ""
  var arguments = ""
  /// What the host attached to the call and wants back with it (Gemini's thought signature).
  var extra: [String: Any]?
  var wire: [String: Any] {
    var row: [String: Any] = ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
    if let extra { row["extra_content"] = extra }
    return row
  }
}

/// Buffer fragmented tool calls until the provider supplies a terminal finish reason.
/// An EOF with no finish reason is a failure, even if some text already reached the user.
struct DirectHTTPReply {
  var text = ""
  var reasoning = ""
  /// OpenRouter's names for the same thing. Each goes back under the name it came in.
  private var openReasoning = ""
  private var details: [[String: Any]] = []
  static let echoKeys = ["reasoning_content", "reasoning", "reasoning_details"]
  var echo: [String: Any] {
    var keys: [String: Any] = [:]
    if !reasoning.isEmpty { keys["reasoning_content"] = reasoning }
    if !openReasoning.isEmpty { keys["reasoning"] = openReasoning }
    if !details.isEmpty { keys["reasoning_details"] = details }
    return keys
  }
  private var fragments: [Int: DirectHTTPCall] = [:]
  /// Hosts send no arguments at all for a tool that takes none.
  var calls: [DirectHTTPCall] {
    fragments.sorted { $0.key < $1.key }.map { call in
      var call = call.value
      if call.arguments.isEmpty { call.arguments = "{}" }
      return call
    }
  }
  var responseItems: [[String: Any]] = []
  private var finish: String?
  var cut: Bool { finish == "length" }
  var completedMessage: Bool { finish == "stop" }

  /// The host's own words for a refused request, short and with secrets removed.
  private static func detail(_ body: Data, hiding secret: String) -> String {
    var said = String(decoding: body, as: UTF8.self)
    if let frame = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
      let error = frame["error"]
      said = (error as? [String: Any])?["message"] as? String ?? error as? String ?? frame["message"] as? String
        ?? (frame["message"] as? [String: Any])?["detail"] as? String ?? frame["detail"] as? String
        ?? (frame["detail"] as? [[String: Any]])?.map { "\(($0["loc"] as? [Any] ?? []).map { "\($0)" }.joined(separator: ".")) \($0["msg"] as? String ?? "")" }
          .joined(separator: "; ") ?? ""
    } else if said.contains("<html") || said.contains("<!DOCTYPE") {
      said = ""
    }
    if !secret.isEmpty { said = said.replacingOccurrences(of: secret, with: "[key]") }
    said = said.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return AgentPrivacy.redact(said, limit: 300)
  }

  static func read(_ post: URLRequest, hiding secret: String, events: AsyncStream<WireEvent>.Continuation, responses: Bool = false) async throws -> Self {
    // The request's own timeout is the wait between chunks. This one only bounds a stream that never ends.
    let session = EphemeralHTTP.session(resourceTimeout: 1_800)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: post)
    let http = response as? HTTPURLResponse
    let status = http?.statusCode ?? 0
    let header = { (name: String) in http?.value(forHTTPHeaderField: name) }
    if let share = UsageTally.headerLeft(header) { events.yield(.usageLeft(share)) }
    guard (200..<300).contains(status) else {
      if let limit = UsageLimit.http(status: status, header: header, now: Date()) { events.yield(.limitReached(limit)) }
      var body = Data()
      for try await byte in bytes {
        body.append(byte)
        if body.count >= 4_000 { break }
      }
      let after = header("Retry-After").flatMap(Double.init)
      throw DirectHTTPError.status(status, detail(body, hiding: secret), retryAfter: after)
    }
    var reply = Self()
    if responses || response.mimeType == "application/json" {
      var data = Data()
      for try await byte in bytes {
        guard data.count < 8_000_000 else { throw DirectHTTPError.invalid("The provider response is too large.") }
        data.append(byte)
      }
      // Some compatible servers always answer with one completed message even when asked to stream.
      guard var frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DirectHTTPError.invalid("The provider returned invalid JSON.") }
      try checkEnvelope(frame, secret: secret)
      if responses {
        guard let output = frame["output"] as? [[String: Any]], let status = frame["status"] as? String,
          status == "completed" || status == "incomplete" else { throw DirectHTTPError.invalid("The provider did not complete the Responses request.") }
        reply.responseItems = output
        for item in output {
          if item["type"] as? String == "function_call" {
            guard let id = item["call_id"] as? String, !id.isEmpty, let name = item["name"] as? String,
              let args = item["arguments"] as? String else { throw DirectHTTPError.invalid("Incomplete Responses tool call.") }
            reply.fragments[reply.fragments.count] = DirectHTTPCall(id: id, name: name, arguments: args)
          } else if item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
              if let text = part["text"] as? String ?? part["refusal"] as? String { reply.text += text; events.yield(.text(text)) }
            }
          }
        }
        if let usage = frame["usage"] as? [String: Int] {
          events.yield(.usage(input: usage["input_tokens"] ?? 0, output: usage["output_tokens"] ?? 0, cachedInput: nil))
        }
        reply.finish = status == "completed" ? "stop" : "length"
        try reply.validate()
        return reply
      }
      guard
        var choice = (frame["choices"] as? [[String: Any]])?.first,
        var message = choice.removeValue(forKey: "message") as? [String: Any] else {
        throw DirectHTTPError.invalid("The provider returned an invalid chat response.")
      }
      if let calls = message["tool_calls"] as? [[String: Any]] {
        message["tool_calls"] = calls.enumerated().map { index, call in call.merging(["index": index]) { _, new in new } }
      }
      choice["delta"] = message
      frame["choices"] = [choice]
      try reply.consume(JSONSerialization.data(withJSONObject: frame), events: events)
      try reply.validate()
      return reply
    }
    var consumed = 0
    var line = Data()
    // Bound the bytes even when a failing endpoint never sends a newline.
    for try await byte in bytes {
      consumed += 1
      guard consumed <= 8_000_000, line.count <= 1_000_000 else { throw DirectHTTPError.invalid("The provider response is too large.") }
      if byte != 10 { line.append(byte); continue }
      let raw = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      line.removeAll(keepingCapacity: true)
      guard raw.hasPrefix("data:") else { continue }
      let payload = raw.dropFirst(5).trimmingCharacters(in: .whitespaces)
      if payload == "[DONE]" { break }
      try reply.consume(Data(payload.utf8), events: events, secret: secret)
    }
    try reply.validate()
    return reply
  }

  static func checkEnvelope(_ frame: [String: Any], secret: String) throws {
    if let base = frame["base_resp"] as? [String: Any], let code = base["status_code"] as? Int, code != 0 {
      let body = try JSONSerialization.data(withJSONObject: ["message": base["status_msg"] as? String ?? ""])
      throw DirectHTTPError.invalid("The provider returned error " + String(code) + ". " + detail(body, hiding: secret))
    }
    if frame["error"] != nil, !(frame["error"] is NSNull) {
      throw DirectHTTPError.invalid("The provider returned an error. " + detail(try JSONSerialization.data(withJSONObject: frame), hiding: secret))
    }
  }

  mutating func consume(_ data: Data, events: AsyncStream<WireEvent>.Continuation, secret: String = "") throws {
    guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DirectHTTPError.invalid("Invalid provider frame.") }
    try Self.checkEnvelope(frame, secret: secret)
    guard let choices = frame["choices"] as? [[String: Any]] else {
      throw DirectHTTPError.invalid("The provider returned an invalid chat stream.")
    }
    if let usage = frame["usage"] as? [String: Any] ?? (frame["x_groq"] as? [String: Any])?["usage"] as? [String: Any] {
      events.yield(.usage(input: usage["prompt_tokens"] as? Int ?? 0, output: usage["completion_tokens"] as? Int ?? 0, cachedInput: nil))
    }
    guard let choice = choices.first else { return }
    // Asked for usage, some hosts send it in one more frame after the finish.
    if finish != nil, frame["usage"] is [String: Any] { return }
    guard finish == nil, (choice["index"] as? Int ?? 0) == 0, let delta = choice["delta"] as? [String: Any] else {
      throw DirectHTTPError.invalid("The provider returned unexpected stream data.")
    }
    if let part = delta["content"] as? String, !part.isEmpty { text += part; events.yield(.text(part)) }
    if let part = delta["reasoning_content"] as? String { reasoning += part }
    if let part = delta["reasoning"] as? String { openReasoning += part }
    if let part = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String, !part.isEmpty { events.yield(.thinking(part)) }
    for piece in delta["reasoning_details"] as? [[String: Any]] ?? [] {
      // Streamed pieces of one detail share its type and index, and their text runs together.
      guard let index = piece["index"] as? Int,
        let at = details.lastIndex(where: { $0["index"] as? Int == index && $0["type"] as? String == piece["type"] as? String }) else {
        details.append(piece)
        continue
      }
      for (key, value) in piece where !(value is NSNull) {
        if ["text", "summary"].contains(key), let old = details[at][key] as? String, let more = value as? String {
          details[at][key] = old + more
        } else {
          details[at][key] = value
        }
      }
    }
    for piece in delta["tool_calls"] as? [[String: Any]] ?? [] {
      guard let index = piece["index"] as? Int, (0..<12).contains(index) else {
        throw DirectHTTPError.invalid("The provider returned an invalid tool index.")
      }
      var call = fragments[index] ?? DirectHTTPCall()
      let function = piece["function"] as? [String: Any]
      call.id += piece["id"] as? String ?? ""
      call.name += function?["name"] as? String ?? ""
      call.arguments += function?["arguments"] as? String ?? ""
      if let extra = piece["extra_content"] as? [String: Any] { call.extra = extra }
      fragments[index] = call
    }
    finish = choice["finish_reason"] as? String
  }

  func validate() throws {
    guard let finish else { throw DirectHTTPError.invalid("The provider stopped before completing its reply.") }
    if calls.isEmpty {
      // A model that has nothing to add after its tools ends with an empty message.
      guard finish == "stop" || !text.isEmpty else {
        throw DirectHTTPError.invalid("The provider stopped before completing its reply.")
      }
      return
    }
    // Hosts differ on the finish reason of a tool call. A length stop leaves the arguments cut.
    guard finish != "length" else { throw DirectHTTPError.invalid("The provider's length limit cut a tool call short.") }
    guard ["stop", "tool_calls", "function_call"].contains(finish) else { throw DirectHTTPError.invalid("The provider stopped its tool request.") }
    for call in calls {
      guard !call.name.isEmpty, (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) is [String: Any] else {
        throw DirectHTTPError.invalid("The provider returned an incomplete tool call.")
      }
    }
  }
}
