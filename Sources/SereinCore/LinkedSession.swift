import Foundation

/// A Serein thread that shows a chat from another app (the Codex CLI, the ChatGPT app, an
/// editor) and follows it while that app writes. The other app's own store stays the record:
/// Serein reads it and never writes to it, except through the harness when the user continues.
public struct SessionLink: Codable, Equatable, Sendable {
  /// The harness's raw value (HarnessDriver).
  public var driver: String
  /// The harness's own id for the chat.
  public var nativeID: String
  /// Where the chat is kept: the transcript or session file (Claude Code, Pi, Oh My Pi) or Grok's
  /// `chat_history.jsonl`. Codex names its file itself (`thread/read`).
  public var file: String?
  /// "Continue in a copy" on a chat whose CLI forks it with the next message: until then the
  /// thread shows the chat as it was, and the first message makes the copy.
  public var forkNext: Bool?
  public init(driver: String, nativeID: String, file: String? = nil, forkNext: Bool? = nil) {
    self.driver = driver
    self.nativeID = nativeID
    self.file = file
    self.forkNext = forkNext
  }
  /// The link after the chat went on under `id` (a copy, or a resume with a new id). A Claude Code
  /// transcript is `<id>.jsonl` in the same project folder; other harnesses keep the file.
  public func moved(to id: String, file newFile: String? = nil) -> SessionLink {
    guard newFile == nil, driver == "claude" else { return SessionLink(driver: driver, nativeID: id, file: newFile ?? file) }
    return SessionLink(
      driver: driver, nativeID: id,
      file: file.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent(id + ".jsonl").path })
  }
}

/// A chat as another app recorded it, in the shape of a Serein thread.
public struct LinkedHistory: Equatable, Sendable {
  public struct Message: Equatable, Sendable {
    public var role: String  // "you" or "assistant", as in a Serein thread
    public var text: String
    public var activities: [TranscriptActivity]
    public init(role: String, text: String, activities: [TranscriptActivity] = []) {
      self.role = role
      self.text = text
      self.activities = activities
    }
  }
  public var messages: [Message]
  /// The last turn has not ended: the other app is still working on it.
  public var working: Bool
  /// The file the harness appends to while the chat runs.
  public var path: String?
  public var cwd: String?
  public var model: String?
  public var effort: String?
  /// Only the newest part of a long chat was read.
  public var omitsEarlier = false
  public init(
    messages: [Message], working: Bool, path: String?, cwd: String?, model: String?, effort: String?,
    omitsEarlier: Bool = false
  ) {
    self.messages = messages
    self.working = working
    self.path = path
    self.cwd = cwd
    self.model = model
    self.effort = effort
    self.omitsEarlier = omitsEarlier
  }

  /// From a Claude Code transcript (JSON lines; `data` may start part way through a long file,
  /// `omitsEarlier` true). Each request the person typed is shown with the last text Claude wrote
  /// before the next one. Tool results, notes Claude Code adds (`isMeta`), helper agents'
  /// lines (`isSidechain`) and thinking are left out; typed calls become bounded labels. One answer can span several
  /// lines with the same message id; their text is joined. `helper`: this is a helper agent's own
  /// transcript, whose lines are all `isSidechain`, so they count.
  public static func claude(_ data: Data, omitsEarlier: Bool = false, helper: Bool = false) -> LinkedHistory {
    var messages: [Message] = []
    var latest: (id: String, text: String)?
    var activities: [TranscriptActivity] = []
    var cwd: String?
    var model: String?
    func close() {
      if latest != nil || !activities.isEmpty {
        messages.append(Message(role: "assistant", text: latest?.text ?? "", activities: activities))
      }
      latest = nil
      activities = []
    }
    for line in data.split(separator: 10) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
      // A chat with no messages yet still names its folder on its other lines.
      if let value = object["cwd"] as? String, !value.isEmpty { cwd = value }
      guard helper || object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
        object["isCompactSummary"] as? Bool != true, let message = object["message"] as? [String: Any]
      else { continue }
      let content = message["content"]
      let blocks = content as? [[String: Any]] ?? []
      let text = (content as? String)
        ?? blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
      switch object["type"] as? String {
      case "user":
        for block in blocks where block["type"] as? String == "tool_result" && block["is_error"] as? Bool == true {
          if let index = activities.firstIndex(where: { $0.id == block["tool_use_id"] as? String }) { activities[index].failed = true }
        }
        // A tool result comes back as a user line; only words the person typed count.
        guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }),
          let request = SessionIndex.userRequest(text)
        else { continue }
        close()
        messages.append(Message(role: "you", text: request))
      case "assistant":
        TranscriptActivity.merge(TranscriptActivity.blocks(content, folder: cwd), into: &activities)
        if let value = message["model"] as? String, !value.isEmpty, value != "<synthetic>" { model = value }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { continue }
        let id = message["id"] as? String ?? UUID().uuidString
        if let current = latest, current.id == id {
          latest = (id, current.text + "\n\n" + words)
        } else {
          latest = (id, words)
        }
      default: continue
      }
    }
    close()
    return LinkedHistory(
      messages: messages, working: false, path: nil, cwd: cwd, model: model, effort: nil, omitsEarlier: omitsEarlier)
  }

  /// Each request the person typed, with the last words the agent wrote before the next one.
  /// `lines` are ("user" or "assistant", text) in the order the harness wrote them.
  static func turns(_ lines: [(role: String, text: String, activities: [TranscriptActivity])]) -> [Message] {
    var messages: [Message] = []
    var latest: String?
    var activities: [TranscriptActivity] = []
    func close() {
      if latest != nil || !activities.isEmpty { messages.append(Message(role: "assistant", text: latest ?? "", activities: activities)) }
      latest = nil
      activities = []
    }
    for (role, text, actions) in lines {
      if role == "user" {
        guard let request = SessionIndex.userRequest(text) else { continue }
        close()
        messages.append(Message(role: "you", text: request))
      } else {
        TranscriptActivity.merge(actions, into: &activities)
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { latest = words }
      }
    }
    close()
    return messages
  }
  static func text(_ content: Any?) -> String {
    (content as? String)
      ?? (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
      .joined(separator: "\n")
  }

  /// From a Pi or Oh My Pi session file (JSON lines: a `session` header, then
  /// entries). A session is a tree (`parentId`); the chat shown is the branch that ends at the
  /// newest entry. Tool results, compaction and branch summaries and extension entries are left out.
  public static func pi(_ data: Data, omitsEarlier: Bool = false) -> LinkedHistory {
    var entries: [[String: Any]] = []
    var cwd: String?
    var model: String?
    var effort: String?
    for line in data.split(separator: 10) {
      guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
      // Every entry but the header is a node of the tree, settings changes too.
      switch json["type"] as? String {
      case "session": cwd = json["cwd"] as? String
      case "model_change": model = json["modelId"] as? String ?? model
      case "thinking_level_change": effort = json["thinkingLevel"] as? String ?? effort
      default: break
      }
      if json["type"] as? String != "session" { entries.append(json) }
    }
    var branch = entries
    if let last = entries.last?["id"] as? String {
      let byID = Dictionary(entries.compactMap { e in (e["id"] as? String).map { ($0, e) } }) { _, latest in latest }
      var chain: [[String: Any]] = []
      var next: String? = last
      var seen: Set<String> = []
      while let id = next, !seen.contains(id), let entry = byID[id] {
        seen.insert(id)
        chain.append(entry)
        next = entry["parentId"] as? String
      }
      branch = chain.reversed()
    }
    let lines: [(role: String, text: String, activities: [TranscriptActivity])] = branch.compactMap { entry in
      guard entry["type"] as? String == "message", let message = entry["message"] as? [String: Any],
        let role = message["role"] as? String, role == "user" || role == "assistant"
      else { return nil }
      if role == "assistant", let value = message["model"] as? String, !value.isEmpty { model = value }
      return (role, text(message["content"]), role == "assistant" ? TranscriptActivity.blocks(message["content"]) : [])
    }
    return LinkedHistory(
      messages: turns(lines), working: false, path: nil, cwd: cwd, model: model, effort: effort, omitsEarlier: omitsEarlier)
  }

  /// The words the person typed when a harness wrapped them with context (`<user_query>`).
  static func typed(_ text: String) -> String {
    guard let start = text.range(of: "<user_query>"),
      let end = text.range(of: "</user_query>", range: start.upperBound..<text.endIndex)
    else { return text }
    return String(text[start.upperBound..<end.lowerBound])
  }

  /// One chat from OpenCode's database, opened read-only: each message's text parts, in order.
  /// Parts OpenCode adds itself (`synthetic`, `ignored`) and reasoning are left out; tool parts become labels.
  /// The last turn is still running while its answer has no completion time.
  public static func opencode(db: String, id: String) -> LinkedHistory? {
    guard let session = SQLiteRows.read(db, "SELECT directory FROM session WHERE id = ?", [id])?.first else { return nil }
    let rows = SQLiteRows.read(db, "SELECT id, data FROM message WHERE session_id = ? ORDER BY time_created, id", [id]) ?? []
    let parts = SQLiteRows.read(db, "SELECT message_id, data FROM part WHERE session_id = ? ORDER BY time_created, id", [id]) ?? []
    func json(_ text: String?) -> [String: Any] {
      text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
    }
    var texts: [String: [String]] = [:]
    var actions: [String: [TranscriptActivity]] = [:]
    for part in parts {
      let data = json(part[1])
      guard let message = part[0], data["synthetic"] as? Bool != true, data["ignored"] as? Bool != true
      else { continue }
      if data["type"] as? String == "text", let text = data["text"] as? String { texts[message, default: []].append(text) }
      if data["type"] as? String == "tool", let name = data["tool"] as? String {
        let state = data["state"] as? [String: Any] ?? [:]
        var action = TranscriptActivity.call(name: name, input: state["input"], id: data["callID"] as? String ?? data["id"] as? String ?? "tool")
        action.failed = state["status"] as? String == "error"
        TranscriptActivity.merge([action], into: &actions[message, default: []])
      }
    }
    var model: String?
    var working = false
    let lines: [(role: String, text: String, activities: [TranscriptActivity])] = rows.compactMap { row in
      let data = json(row[1])
      guard let id = row[0], let role = data["role"] as? String, role == "user" || role == "assistant" else { return nil }
      if role == "assistant" {
        if let provider = data["providerID"] as? String, let name = data["modelID"] as? String { model = provider + "/" + name }
        working = (data["time"] as? [String: Any])?["completed"] == nil
      } else {
        working = false
      }
      return (role, (texts[id] ?? []).joined(separator: "\n"), role == "assistant" ? actions[id] ?? [] : [])
    }
    return LinkedHistory(
      messages: turns(lines), working: working, path: nil, cwd: session[0].flatMap { $0.isEmpty ? nil : $0 },
      model: model, effort: nil)
  }

  /// From a Cursor agent transcript (`agent-transcripts/<id>/<id>.jsonl`): `role` and a message
  /// whose text blocks and typed tool labels are kept.
  public static func cursor(_ data: Data, omitsEarlier: Bool = false) -> LinkedHistory {
    var lines: [(role: String, text: String, activities: [TranscriptActivity])] = []
    for line in data.split(separator: 10) {
      guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        let role = json["role"] as? String, role == "user" || role == "assistant"
      else { continue }
      let content = (json["message"] as? [String: Any])?["content"]
      let words = text(content)
      lines.append((role, role == "user" ? typed(words) : words, role == "assistant" ? TranscriptActivity.blocks(content) : []))
    }
    return LinkedHistory(messages: turns(lines), working: false, path: nil, cwd: nil, model: nil, effort: nil, omitsEarlier: omitsEarlier)
  }

  /// From Grok's `chat_history.jsonl`. Lines Grok adds itself carry `synthetic_reason`; a typed
  /// request is the text inside `<user_query>` when Grok wrapped it with context.
  public static func grok(_ data: Data, omitsEarlier: Bool = false) -> LinkedHistory {
    var lines: [(role: String, text: String, activities: [TranscriptActivity])] = []
    var model: String?
    var effort: String?
    for line in data.split(separator: 10) {
      guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
      switch json["type"] as? String {
      case "user":
        if json["synthetic_reason"] is String { continue }
        lines.append(("user", typed(text(json["content"])), []))
      case "assistant":
        if let value = json["model_id"] as? String, !value.isEmpty { model = value }
        if let value = json["reasoning_effort"] as? String, !value.isEmpty { effort = value }
        lines.append(("assistant", text(json["content"]), TranscriptActivity.blocks(json["content"]) + TranscriptActivity.functions(json["tool_calls"])))
      default: continue
      }
    }
    return LinkedHistory(
      messages: turns(lines), working: false, path: nil, cwd: nil, model: model, effort: effort, omitsEarlier: omitsEarlier)
  }
  /// Grok keeps each chat in `sessions/<folder, percent-encoded>/<id>/`.
  public static func grokFolder(_ file: String) -> String? {
    let url = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
    return url.lastPathComponent.removingPercentEncoding.flatMap { $0.hasPrefix("/") ? $0 : nil }
  }

  /// The copy OpenCode made of chat `id` with `--fork`: the newest other chat in the same folder
  /// made since `since`.
  public static func opencodeCopy(db: String, of id: String, since: Date) -> String? {
    SQLiteRows.read(db, """
      SELECT id FROM session WHERE id != ?1 AND parent_id IS NULL AND time_created >= ?2
        AND directory = (SELECT directory FROM session WHERE id = ?1) ORDER BY time_created DESC LIMIT 1
      """, [id, String(Int64(since.timeIntervalSince1970 * 1000))])?.first?[0] ?? nil
  }
  /// A copy of a Pi or Oh My Pi session under `id`, as Pi's own fork writes one: a new header
  /// that names the original file, then the same entries. Nil when the file has no header.
  public static func piFork(_ data: Data, id: String, original: String, now: Date) -> Data? {
    let end = data.firstIndex(of: 10) ?? data.endIndex
    guard var header = try? JSONSerialization.jsonObject(with: data[data.startIndex..<end]) as? [String: Any],
      header["type"] as? String == "session"
    else { return nil }
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    header["id"] = id
    header["timestamp"] = stamp.string(from: now)
    header["parentSession"] = original
    guard let line = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes]) else {
      return nil
    }
    return line + data[end...]
  }

  /// From the `thread` of a Codex app server `thread/read` with `includeTurns`. Codex reads every
  /// version of its own store, so Serein does not parse rollout files here.
  /// Each user message is shown with the answer that follows it: the final answer, or, for the
  /// part of a turn still running or cut off, the agent's latest words. Progress notes that an
  /// answer replaced and reasoning are left out; tool steps become bounded labels.
  public static func codex(_ thread: [String: Any]) -> LinkedHistory {
    let folder = (thread["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    var messages: [Message] = []
    let turns = thread["turns"] as? [[String: Any]] ?? []
    for turn in turns {
      var answer: String?
      var latest: String?
      var activities: [TranscriptActivity] = []
      // A request the user sent during the turn ends the part before it; only a final answer
      // stands for that part. At the end of the turn the latest words stand in for a missing one.
      func close(endOfTurn: Bool = false) {
        let text = answer ?? (endOfTurn ? latest : nil)
        if text != nil || !activities.isEmpty { messages.append(Message(role: "assistant", text: text ?? "", activities: activities)) }
        answer = nil
        latest = nil
        activities = []
      }
      for item in turn["items"] as? [[String: Any]] ?? [] {
        switch item["type"] as? String {
        case "userMessage":
          let parts = item["content"] as? [[String: Any]] ?? []
          let raw = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
          guard let text = SessionIndex.userRequest(raw) else { continue }
          close()
          messages.append(Message(role: "you", text: text))
        case "agentMessage":
          guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
          else { continue }
          if item["phase"] as? String == "final_answer" { answer = text } else { latest = text }
        default:
          if let action = TranscriptActivity.codex(item, folder: folder) { TranscriptActivity.merge([action], into: &activities) }
        }
      }
      close(endOfTurn: true)
    }
    func text(_ key: String) -> String? { (thread[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    return LinkedHistory(
      messages: messages, working: turns.last?["status"] as? String == "inProgress",
      path: text("path"), cwd: text("cwd"), model: text("model"), effort: text("reasoningEffort"))
  }

  /// A Codex chat from its own session file (`rollout-…-<id>.jsonl`), read without Codex: a long
  /// chat Codex takes too long to send whole (`thread/read`) still opens. Each turn (task_started
  /// to task_complete or turn_aborted) gives what the person asked and the turn's answer, its
  /// final words, or its latest at the end of the turn, with its steps. Codex's own messages to
  /// itself (a goal's continuation, a spawned helper's brief) are left out as `userRequest` does.
  public static func codexRollout(_ data: Data, omitsEarlier: Bool = false) -> LinkedHistory {
    var messages: [Message] = []
    var answer: String?
    var latest: String?
    var activities: [TranscriptActivity] = []
    var working = false
    var cwd: String?
    var model: String?
    var effort: String?
    func close(endOfTurn: Bool = false) {
      let text = answer ?? (endOfTurn ? latest : nil)
      if text != nil || !activities.isEmpty { messages.append(Message(role: "assistant", text: text ?? "", activities: activities)) }
      answer = nil
      latest = nil
      activities = []
    }
    func words(_ content: Any?, _ kind: String) -> String {
      ((content as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String == kind ? $0["text"] as? String : nil }
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    for line in data.split(separator: 10) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        let payload = object["payload"] as? [String: Any] else { continue }
      switch (object["type"] as? String, payload["type"] as? String) {
      case ("session_meta", _):
        cwd = (payload["cwd"] as? String) ?? cwd
      case ("turn_context", _):
        cwd = (payload["cwd"] as? String) ?? cwd
        model = (payload["model"] as? String) ?? model
        effort = (payload["effort"] as? String) ?? (payload["reasoning_effort"] as? String) ?? effort
      case ("event_msg", "task_started"?):
        close(endOfTurn: true)
        working = true
      case ("event_msg", "task_complete"?), ("event_msg", "turn_aborted"?):
        close(endOfTurn: true)
        working = false
      case ("response_item", "message"?):
        switch payload["role"] as? String {
        case "user":
          guard let text = SessionIndex.userRequest(words(payload["content"], "input_text")) else { continue }
          close()
          messages.append(Message(role: "you", text: text))
        case "assistant":
          let text = words(payload["content"], "output_text")
          guard !text.isEmpty else { continue }
          if payload["phase"] as? String == "final_answer" { answer = text } else { latest = text }
        default: continue
        }
      case ("response_item", "function_call"?):
        let name = payload["name"] as? String ?? "tool"
        TranscriptActivity.merge([TranscriptActivity.call(name: name, input: payload["arguments"], id: payload["call_id"] as? String ?? "", folder: cwd)],
          into: &activities)
      case ("response_item", "custom_tool_call"?):
        if let action = codexCustomCall(payload, folder: cwd) { TranscriptActivity.merge([action], into: &activities) }
      default: continue
      }
    }
    close(endOfTurn: true)
    return LinkedHistory(messages: messages, working: working, path: nil, cwd: cwd, model: model, effort: effort,
                         omitsEarlier: omitsEarlier)
  }

  /// A custom tool call's step: a patch names its first file, and a script that runs a command
  /// (`tools.exec_command({cmd: "…"})`) names that command.
  static func codexCustomCall(_ payload: [String: Any], folder: String?) -> TranscriptActivity? {
    let id = payload["call_id"] as? String ?? ""
    let input = payload["input"] as? String ?? ""
    switch payload["name"] as? String {
    case "apply_patch"?:
      let files = input.split(separator: "\n").compactMap { line -> String? in
        for mark in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(mark) {
          return String(line.dropFirst(mark.count))
        }
        return nil
      }
      var action = TranscriptActivity.call(name: "edit", input: ["path": files.first ?? ""], id: id, folder: folder)
      if files.count > 1 { action.label += " and \(files.count - 1) more" }
      return action
    case "exec"?:
      guard let range = input.range(of: #"cmd:\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) else {
        return TranscriptActivity.call(name: "tool", input: nil, id: id, folder: folder)
      }
      let quoted = String(input[range]).drop { $0 != "\"" }.dropFirst().dropLast()
      let command = quoted.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
      return TranscriptActivity.call(name: "exec_command", input: ["cmd": command], id: id, folder: folder)
    case let name?:
      return TranscriptActivity.call(name: name, input: nil, id: id, folder: folder)
    case nil:
      return nil
    }
  }
}
