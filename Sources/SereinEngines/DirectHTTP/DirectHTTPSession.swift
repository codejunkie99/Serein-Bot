import Foundation
import SereinCore

/// A single selected, OpenAI-compatible endpoint. Credentials never enter the CLI environment.
public struct DirectHTTPRoute: Sendable {
  public let connection: ProviderConnection
  let key: String
  let isCurrent: @Sendable () async -> Bool
  public init(connection: ProviderConnection, key: String, isCurrent: @escaping @Sendable () async -> Bool) {
    self.isCurrent = isCurrent
    self.connection = connection
    self.key = key
  }
}

enum DirectHTTPError: LocalizedError {
  case invalid(String)
  /// A refused request, with what the host said about it.
  case status(Int, String, retryAfter: Double? = nil)
  var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    case .status(let status, let said, _):
      let line: String
      switch status {
      case 401, 403: line = "The provider refused access. Check the key and model permissions (HTTP \(status))."
      case 404: line = "The provider could not find this endpoint or model (HTTP 404)."
      case 429: line = "The provider rate or usage limit was reached (HTTP 429)."
      default: line = "The provider refused the request (HTTP \(status))."
      }
      return said.isEmpty ? line : line + " The provider said: " + said
    }
  }
}

/// A turn owns its network task. The app supplies conversation history on each new turn.
/// Words sent mid-turn wait for the next model request, and go back unread if none follows.
/// Only the already-authorized task tools are available; no shell is spawned by this session.
actor DirectHTTPSession: EngineSession {
  nonisolated let mode: VerifiedMode
  nonisolated let reusable = false
  nonisolated let steers = true
  nonisolated let wire: AsyncStream<WireEvent>
  private let events: AsyncStream<WireEvent>.Continuation
  private let route: DirectHTTPRoute
  private let beginTool: @Sendable (String, String, String) async -> Bool
  private var work: Task<Void, Never>?
  private var stopped = false
  private var ended = false
  private var waiting: [(text: String, taken: CheckedContinuation<SteerOutcome, Never>)] = []
  /// Words in a request that has not come back yet. A request that fails hands them back.
  private var inFlight: [(text: String, taken: CheckedContinuation<SteerOutcome, Never>)] = []

  init(route: DirectHTTPRoute, beginTool: @escaping @Sendable (String, String, String) async -> Bool) {
    self.route = route
    self.beginTool = beginTool
    mode = ModeCheck.hostedToolsOnly()
    (wire, events) = AsyncStream.makeStream()
  }

  func steer(_ text: String) async -> SteerOutcome {
    guard work != nil, !ended else { return .handedBack(text) }
    return await withCheckedContinuation { waiting.append((text, $0)) }
  }

  private func handBackWords() {
    ended = true
    for words in inFlight + waiting { words.taken.resume(returning: .handedBack(words.text)) }
    inFlight = []
    waiting = []
  }

  func cancel() {
    stopped = true
    work?.cancel()
    handBackWords()
    events.finish()
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    guard !stopped, work == nil else { return }
    work = Task {
      events.yield(.accepted)
      do {
        let end = try await run(prompt, request: request)
        if !Task.isCancelled { events.yield(.turnDone(end)) }
      } catch {
        if !Task.isCancelled {
          let silent = (error as? URLError)?.code == .timedOut
          let message = (error as? DirectHTTPError)?.errorDescription
            ?? (silent ? "The provider sent nothing for \(Self.idle) seconds." : "The provider connection was interrupted.")
          events.yield(.failed(message))
        }
      }
      handBackWords()
      events.finish()
    }
  }

  private func checkConnection() async throws {
    guard await route.isCurrent() else { throw DirectHTTPError.invalid("The provider connection changed. Send a new turn.") }
    try Task.checkCancellation()
  }

  private static let idle = 120

  private func run(_ prompt: TurnPrompt, request: TurnRequest) async throws -> StopReason {
    guard let model = request.model, !model.isEmpty, prompt.command == nil else {
      throw DirectHTTPError.invalid("Select a provider model and send a message.")
    }
    let tools = try DirectHTTPTools(request: request, enabled: route.connection.tools != false)
    var messages: [[String: Any]] = []
    if !prompt.stable.isEmpty { messages.append(["role": "system", "content": prompt.stable]) }
    let text = [prompt.volatile, prompt.recovery ?? prompt.message].filter { !$0.isEmpty }.joined(separator: "\n\n")
    var parts: [[String: Any]] = [["type": "text", "text": text]]
    if !request.images.isEmpty {
      guard route.connection.images != false, request.images.count <= 3 else {
        throw DirectHTTPError.invalid("This connection cannot take these images.")
      }
      for image in request.images {
        let data = try Data(contentsOf: image, options: .mappedIfSafe)
        guard data.count <= 8_000_000 else { throw DirectHTTPError.invalid("The attached image is too large.") }
        let mime = data.starts(with: [0xff, 0xd8]) ? "image/jpeg" : "image/png"
        parts.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64," + data.base64EncodedString()]])
      }
    }
    messages.append(["role": "user", "content": parts.count == 1 ? text as Any : parts])
    let host = URL(string: route.connection.baseURL)?.host?.lowercased() ?? ""
    let definitions = try DirectHTTPCompatibility.fittedTools(
      tools.definitions, sizeLimited: DirectHTTPCompatibility.schemaLimited(host: host, model: model))
    var offerTools = !definitions.isEmpty
    var responses = false
    var responseInput = messages.map { message -> [String: Any] in
      var copy = message
      if let parts = message["content"] as? [[String: Any]] {
        copy["content"] = parts.map { part -> [String: Any] in
          if let image = part["image_url"] as? [String: String] { return ["type": "input_image", "image_url": image["url"] ?? ""] }
          return ["type": "input_text", "text": part["text"] ?? ""]
        }
      }
      return copy
    }
    var handled = Set<String>()
    var toolCount = 0
    var echoReasoning = host != "api.groq.com"
    var askUsage = true
    var shortened = false
    var busyTries = 0
    for round in 0..<64 {
      try Task.checkCancellation()
      try await checkConnection()
      for words in waiting {
        messages.append(["role": "user", "content": words.text])
        responseInput.append(["role": "user", "content": words.text])
      }
      inFlight = waiting
      waiting = []
      let c = route.connection
      if let reason = ProviderAddress.check(c.baseURL, place: .thisMac, keyless: c.keyless) {
        throw DirectHTTPError.invalid(reason)
      }
      guard let base = URL(string: c.baseURL) else {
        throw DirectHTTPError.invalid("The provider address is invalid.")
      }
      func ask() async throws -> DirectHTTPReply {
        while true {
          try await checkConnection()
          let url = base.appendingPathComponent(responses ? "responses" : "chat/completions")
          var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
          if askUsage { body["stream_options"] = ["include_usage": true] }
          if offerTools { body["tools"] = definitions }
          if let schema = request.schema {
            let shape = try JSONSerialization.jsonObject(with: Data(schema.utf8))
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "response", "schema": shape]]
          }
          if responses {
            body = ["model": model, "input": responseInput, "stream": false, "store": false, "include": ["reasoning.encrypted_content"]]
            if offerTools {
              body["tools"] = definitions.compactMap { ($0["function"] as? [String: Any])?.merging(["type": "function"]) { _, new in new } }
            }
            if let schema = request.schema {
              body["text"] = ["format": ["type": "json_schema", "name": "response", "schema": try JSONSerialization.jsonObject(with: Data(schema.utf8))]]
            }
          }
          var post = URLRequest(url: url, timeoutInterval: TimeInterval(Self.idle))
          post.httpMethod = "POST"
          post.httpBody = try JSONSerialization.data(withJSONObject: body)
          guard (post.httpBody?.count ?? 0) <= 32_000_000 else { throw DirectHTTPError.invalid("The conversation exceeds the provider request limit.") }
          post.setValue("application/json", forHTTPHeaderField: "Content-Type")
          post.setValue(responses ? "application/json" : "text/event-stream", forHTTPHeaderField: "Accept")
          if !c.keyless { post.setValue("Bearer " + route.key, forHTTPHeaderField: "Authorization") }
          do {
            return try await DirectHTTPReply.read(post, hiding: route.key, events: events, responses: responses)
          } catch DirectHTTPError.status(let status, _, let after)
            where round == 0 && busyTries < 3 && (status == 429 || status >= 500) && (after ?? 0) <= 30 {
            // Nothing has run or reached the person yet, so the same request can go again.
            // A host that asks for a longer wait than this is not asked again.
            let wait = max(0, after ?? [1, 3, 8][busyTries])
            busyTries += 1
            events.yield(.notice("The provider is busy (HTTP \(status)). Serein is asking again."))
            try await Task.sleep(for: .seconds(wait))
          } catch DirectHTTPError.status(let status, let said, _) where [400, 404, 405, 413, 422].contains(status) {
            // Nothing ran on a refused request, so one changed resend is safe.
            let words = said.lowercased()
            let toolsRefused = words.contains("tool") && ["not support", "unsupported", "not supported"].contains(where: words.contains)
            let tooLong = status == 413 || ["context length", "context_length", "context window", "maximum context",
              "too many tokens", "token limit", "prompt is too long"].contains(where: words.contains)
            if !responses, round == 0, (words.contains("responses") && (words.contains("endpoint") || words.contains("/responses"))
                || host == "api.openai.com" && toolsRefused) {
              responses = true
            } else if [400, 422].contains(status), round == 0, offerTools, toolsRefused {
              offerTools = false
              events.yield(.notice("This model does not take tools, so Serein asked it without them."))
            } else if askUsage, !responses, words.contains("stream_options") {
              askUsage = false
            } else if tooLong {
              guard !shortened else {
                throw DirectHTTPError.invalid("The conversation is too long for this model, even with tool results cut down. "
                  + "Start a new chat or choose a model that takes more.")
              }
              shortened = true
              messages = Self.shortened(messages, key: "content")
              responseInput = Self.shortened(responseInput, key: "output")
              events.yield(.notice("The conversation was too long for this model, so Serein cut earlier tool results down."))
            } else if echoReasoning, words.contains("reasoning") || words.contains("extra_content"), messages.contains(where: Self.echoes) {
              echoReasoning = false
              messages = Self.withoutEchoes(messages)
            } else if askUsage, !responses, round == 0, [400, 422].contains(status) {
              // A strict host can refuse the usage field without naming it, so it goes first.
              askUsage = false
            } else if echoReasoning, [400, 422].contains(status), messages.contains(where: Self.echoes) {
              echoReasoning = false
              messages = Self.withoutEchoes(messages)
            } else {
              throw DirectHTTPError.status(status, said)
            }
            try Task.checkCancellation()
          }
        }
      }
      let reply = try await ask()
      for words in inFlight { words.taken.resume(returning: .steered) }
      inFlight = []
      try Task.checkCancellation()
      var calls = reply.calls
      if calls.isEmpty, request.schema == nil, offerTools, !responses, reply.completedMessage, ProviderAddress.isHere(c.baseURL),
        let local = DirectHTTPCompatibility.localCall(reply.text) {
        calls = [local]
      }
      if calls.isEmpty { return reply.cut ? .maxTokens : .endTurn }
      toolCount += calls.count
      guard toolCount <= 200 else { throw DirectHTTPError.invalid("The provider reached the limit of 200 tool calls in this turn.") }
      guard offerTools else { throw DirectHTTPError.invalid("The provider called a tool after tools were disabled.") }
      if responses { responseInput += reply.responseItems }
      // Validate the whole batch before allowing its first side effect.
      var inReply = Set<String>()
      for index in calls.indices {
        let call = calls[index]
        guard tools.names.contains(call.name) else {
          throw DirectHTTPError.invalid("The provider requested an unavailable tool.")
        }
        // One reply naming an id twice cannot be answered. The same call in a later round is the
        // model's choice, and the round, call and loop limits end a model that never stops.
        guard call.id.isEmpty || inReply.insert(call.id).inserted else { throw DirectHTTPError.invalid("The provider repeated a tool call.") }
        if responses, handled.contains(call.id) { throw DirectHTTPError.invalid("The Responses endpoint reused a call ID.") }
        // Some hosts send no id, or the same id every round.
        if call.id.isEmpty || handled.contains(call.id) { calls[index].id = "call_" + UUID().uuidString.lowercased() }
        handled.insert(calls[index].id)
      }
      if !echoReasoning { for index in calls.indices { calls[index].extra = nil } }
      var assistant: [String: Any] = ["role": "assistant", "content": reply.text, "tool_calls": calls.map(\.wire)]
      // Some hosts need their reasoning back with a tool call and others refuse it, so it goes until one refuses.
      if echoReasoning { assistant.merge(reply.echo) { _, new in new } }
      messages.append(assistant)
      for offered in calls {
        let call = try tools.resolved(offered)
        try Task.checkCancellation()
        try await checkConnection()
        guard await beginTool(call.id, call.name, call.arguments) else { throw CancellationError() }
        try Task.checkCancellation()
        let result = try await tools.call(call)
        try Task.checkCancellation()
        events.yield(.toolEnded(id: call.id, result: result.failed ? .failed : .ok))
        if responses { responseInput.append(["type": "function_call_output", "call_id": call.id, "output": result.text]) }
        messages.append(["role": "tool", "tool_call_id": call.id, "content": result.text])
        if Machine.isFinish(call.name), !result.failed { return .endTurn }
      }
      if round < 63 { events.yield(.newMessage) }
    }
    throw DirectHTTPError.invalid("The provider reached the limit of 64 model rounds in this turn.")
  }

  private static func withoutEchoes(_ messages: [[String: Any]]) -> [[String: Any]] {
    messages.map { message in
      var message = message.filter { !DirectHTTPReply.echoKeys.contains($0.key) }
      if let calls = message["tool_calls"] as? [[String: Any]] {
        message["tool_calls"] = calls.map { $0.filter { $0.key != "extra_content" } }
      }
      return message
    }
  }
  private static func echoes(_ message: [String: Any]) -> Bool {
    DirectHTTPReply.echoKeys.contains { message[$0] != nil }
      || (message["tool_calls"] as? [[String: Any]])?.contains { $0["extra_content"] != nil } == true
  }

  /// Tool results cut down for one resend: the newest keeps 16 KB, each earlier one 2 KB.
  private static func shortened(_ rows: [[String: Any]], key: String) -> [[String: Any]] {
    func result(_ row: [String: Any]) -> String? {
      row["role"] as? String == "tool" || row["type"] as? String == "function_call_output" ? row[key] as? String : nil
    }
    let newest = rows.lastIndex { result($0) != nil }
    return rows.enumerated().map { index, row in
      guard let text = result(row) else { return row }
      var row = row
      row[key] = DirectHTTPTools.capped(text, to: index == newest ? 16_000 : 2_000)
      return row
    }
  }
}
