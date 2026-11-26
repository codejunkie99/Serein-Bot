#if DEBUG
import Darwin
import Foundation
import SereinCore
@testable import SereinEngines

/// The ACP behaviours every ACP driver must keep, run through `Engines`, the real process host
/// under the file guard against a fake CLI that speaks ACP as Grok 1.0.88 and OpenCode 2.2.4 do.
/// Each driver's own file calls this with its driver, then checks its launch contract.
struct ACPCheckRig {
  let dir: URL
  let executable: URL
  let driver: any Driver
  let engines: Engines
  let records: RunRecords

  init(_ driver: any Driver, name: String, noLoad: Bool = false) throws {
    let manager = FileManager.default
    dir = manager.temporaryDirectory.appendingPathComponent("acp-checks-\(UUID().uuidString)")
    try manager.createDirectory(at: dir, withIntermediateDirectories: true)
    executable = dir.appendingPathComponent(name)
    try Self.fake(dir, noLoad: noLoad).write(to: executable, atomically: true, encoding: .utf8)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    self.driver = driver
    records = RunRecords(root: dir.appendingPathComponent("runs"))
    engines = Engines(
      drivers: [driver], host: SereinProcessHost(records: records), records: records,
      sleep: { try? await Task.sleep(for: min($0, .milliseconds(100))) }, tickEvery: .seconds(3_600))
  }

  func request(
    _ message: String, thread: String, level: ProjectLevel = .commands, resume: String? = nil, recovery: String? = nil,
    model: String? = nil
  ) -> TurnRequest {
    TurnRequest(
      thread: ThreadKey(thread), cli: driver.cli, executable: executable, access: .project(folder: dir, level: level),
      prompt: TurnPrompt(stable: "STABLE-RULES", volatile: "now: 9:00", message: message, recovery: recovery), model: model,
      effort: nil, resume: resume, browser: nil, taskID: "task")
  }

  /// The turn's events, and the steer outcome when `steer` went in at the first tool.
  func turn(_ request: TurnRequest, steer: String? = nil, stop: Bool = false) throws -> ([EngineEvent], SteerOutcome?) {
    let engines = engines
    return try AssistantCoreChecks.acpBlocking {
      let handle = try await engines.send(request)
      var seen: [EngineEvent] = []
      var outcome: SteerOutcome?
      for await event in handle.events {
        seen.append(event)
        guard case .toolStarted = event else { continue }
        if let steer, outcome == nil { outcome = await engines.steer(request.thread, steer) }
        if stop { await engines.stop(request.thread) }
      }
      return (seen, outcome)
    }
  }

  func log(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
  func lines(_ name: String) -> [String] { log(name).split(separator: "\n").map(String.init) }

  func finish() throws {
    let engines = engines
    try AssistantCoreChecks.acpBlocking { await engines.shutdown() }
    try? FileManager.default.removeItem(at: dir)
  }

  /// A fake ACP agent: answers the handshake, and plays the turn its prompt names.
  private static func fake(_ dir: URL, noLoad: Bool) -> String {
    #"""
    #!/usr/bin/env python3
    import json, os, subprocess, sys, time
    DIR = "\#(dir.path)"
    NOLOAD = \#(noLoad ? "True" : "False")
    NAME = os.path.basename(sys.argv[0])
    def append(name, text):
        with open(os.path.join(DIR, name), "a") as f: f.write(text + "\n")
    append("starts", " ".join(sys.argv[1:]))
    append("env", json.dumps({k: os.environ.get(k) for k in ["XAI_API_KEY", "OPENCODE_CONFIG_CONTENT", "OPENCODE_CONFIG_DIR", "HTTPS_PROXY"]}))
    pending = []
    asked = [1000]
    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
    def read():
        line = sys.stdin.readline()
        if not line: sys.exit(0)
        return json.loads(line)
    def ok(i, result): send({"jsonrpc": "2.0", "id": i, "result": result})
    def err(i, code, message): send({"jsonrpc": "2.0", "id": i, "error": {"code": code, "message": message}})
    def update(sid, u, meta=None):
        params = {"sessionId": sid, "update": u}
        if meta: params["_meta"] = meta
        send({"jsonrpc": "2.0", "method": "session/update", "params": params})
    def text(sid, t): update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}})
    def commands(sid):
        update(sid, {"sessionUpdate": "available_commands_update", "availableCommands": [
            {"name": "compact", "description": "Compact the conversation"}, {"name": "review", "description": "Review"}]})
    def ask(method, params):
        asked[0] += 1
        send({"jsonrpc": "2.0", "id": asked[0], "method": method, "params": params})
        while True:
            m = read()
            if m.get("id") == asked[0] and "method" not in m: return m
            pending.append(m)
    def tool(sid, tid, status, command="ls"):
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": tid, "title": "Run " + command, "kind": "execute",
            "status": status, "rawInput": {"command": command, "b": 1}})
    def play(i, sid, body):
        if "CRASH" in body and not os.path.exists(os.path.join(DIR, "crashed")):
            open(os.path.join(DIR, "crashed"), "w").close()
            sys.stderr.write("Error: read ECONNRESET\n"); sys.stderr.flush(); sys.exit(1)
        if "LATE" in body:
            text(sid, "partial"); time.sleep(0.2)
            sys.stderr.write("Error: read ECONNRESET\n"); sys.stderr.flush(); sys.exit(1)
        if "LIMIT" in body:
            err(i, -32603, "You have hit your usage limit. It resets at 5pm."); return
        if "HANG" in body:
            child = subprocess.Popen(["/bin/sleep", "300"])
            append("child", str(child.pid))
            tool(sid, "t-hang", "in_progress", "sleep 300")
            time.sleep(300); return
        if "SHELLCALL" in body:
            # As OpenCode 2.2.4 sends it: `name` is the tool, `title` the call.
            r = ask("session/request_permission", {"sessionId": sid,
                "toolCall": {"toolCallId": "t-sh", "title": "ls", "kind": "execute", "rawInput": {"command": "ls"}},
                "options": [{"optionId": "yes", "kind": "allow_once", "name": "Yes"}, {"optionId": "no", "kind": "reject_once", "name": "No"}]})
            append("answers", json.dumps(r.get("result"), sort_keys=True))
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": "t-sh", "name": "shell", "title": "ls", "kind": "execute",
                "status": "completed", "rawInput": {"command": "ls"}})
            ok(i, {"stopReason": "end_turn"}); return
        if "ASK" in body:
            r = ask("session/request_permission", {"sessionId": sid,
                "toolCall": {"toolCallId": "t-ask", "title": "Edit /etc/hosts", "kind": "edit", "locations": [{"path": "/etc/hosts"}]},
                "options": [{"optionId": "yes-always", "kind": "allow_always", "name": "Always"},
                    {"optionId": "yes", "kind": "allow_once", "name": "Yes"}, {"optionId": "no", "kind": "reject_once", "name": "No"}]})
            append("answers", json.dumps(r.get("result"), sort_keys=True))
            ok(i, {"stopReason": "end_turn"}); return
        if "CARD" in body:
            parked = json.dumps({"result": "card still open", "next": "End your turn."})
            # FAKECARD: a shell prints the reply word for word, and a page's text quotes it.
            calls = [("t-card", "execute", parked), ("t-page", "other", json.dumps({"page": "card still open"}))] \
                if "FAKECARD" in body else [("t-card", "other", parked)]
            for tid, kind, answer in calls:
                update(sid, {"sessionUpdate": "tool_call", "toolCallId": tid, "title": "secure_card", "kind": kind, "status": "pending"})
                update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "completed",
                    "content": [{"type": "content", "content": {"type": "text", "text": answer}}]})
            text(sid, "Waiting for the card.")
            ok(i, {"stopReason": "end_turn"}); return
        if "BIG" in body:
            text(sid, "x" * 9000000); ok(i, {"stopReason": "end_turn"}); return
        if body == "/compact":
            text(sid, "compacted"); ok(i, {"stopReason": "end_turn"}); return
        update(sid, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "thinking"}})
        text(sid, "hello ")
        tool(sid, "t1", "pending")
        if "STEER" in body: time.sleep(0.5)
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"})
        text(sid, "again")
        if "CONTEXT" in body: update(sid, {"sessionUpdate": "usage_update", "used": 5000, "size": 200000})
        ok(i, {"stopReason": "max_tokens" if "LONG" in body else "end_turn",
            "_meta": {"inputTokens": 20, "outputTokens": 10, "cachedReadTokens": 6}})
    count = [0]
    OPTIONS = [{"id": "model", "currentValue": "default-model"}, {"id": "mode", "currentValue": "build"}]
    while True:
        m = pending.pop(0) if pending else read()
        method, i, p = m.get("method"), m.get("id"), m.get("params") or {}
        if method: append("methods", method)
        if method == "initialize":
            append("init", json.dumps(p, sort_keys=True))
            ok(i, {"protocolVersion": 1, "agentCapabilities": {"loadSession": not NOLOAD, "promptCapabilities": {"image": True, "embeddedContext": True}}, "authMethods": []})
        elif method == "session/new":
            count[0] += 1
            sid = "s-%d-%d" % (os.getpid(), count[0])
            append("mcp", json.dumps(p.get("mcpServers")))
            commands(sid)
            ok(i, {"sessionId": sid, "configOptions": OPTIONS})
        elif method == "session/load":
            sid = p["sessionId"]
            if sid != "known-session":
                err(i, -32002, 'Session "%s" not found' % sid); continue
            update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "OLD"}}, {"isReplay": True})
            commands(sid)
            ok(i, {"configOptions": OPTIONS})
        elif method in ("session/set_model", "session/set_config_option"):
            value = p.get("modelId") or p.get("value")
            append("config", "%s %s %s" % (method, p.get("configId", "-"), value))
            if value == "SIGNEDOUT": err(i, -32000, "Authentication required")
            elif value == "bad-model": err(i, -32602, "Model bad-model is not available")
            else: ok(i, None)
        elif method == "session/prompt":
            sid = p["sessionId"]
            blocks = p["prompt"]
            body = "".join(b.get("text", "") for b in blocks if b.get("type") == "text")
            append("prompts", json.dumps(body))
            for b in blocks:
                if b.get("type") == "resource": append("resources", json.dumps(b.get("resource"), sort_keys=True))
            if any(b.get("type") == "image" and b.get("data") for b in blocks): append("images", "1")
            play(i, sid, body)
        elif i is not None and method:
            err(i, -32601, "Method not found")
    """#
  }
}

extension AssistantCoreChecks {
  /// What every ACP driver must do, through Engines. `prefix` names the CLI in each label.
  static func acpBehaviour(_ check: Check, rig: ACPCheckRig, setsModel: Bool, modelRefusalEnds: Bool, stableInPrompt: Bool) throws {
    let name = rig.driver.cli.displayName
    func text(_ events: [EngineEvent]) -> String {
      events.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
    }
    func reason(_ events: [EngineEvent]) -> StopReason? {
      for case .ended(let end) in events { return end.stopReason }
      return nil
    }
    func session(_ events: [EngineEvent]) -> (String, Bool)? {
      for case .session(let id, let rebuilt) in events { return (id, rebuilt) }
      return nil
    }
    func prompt(_ index: Int) -> String {
      let all = rig.lines("prompts")
      guard all.indices.contains(index), let data = all[index].data(using: .utf8) else { return "" }
      return (try? JSONDecoder().decode(String.self, from: data)) ?? ""
    }

    // Start, handshake, a streamed turn, warm reuse.
    let (first, _) = try rig.turn(rig.request("hello", thread: "warm"))
    try check(text(first) == "hello again" && reason(first) == .endTurn, "\(name): a turn streams to end_turn")
    try check(first.contains(.thinking("thinking")) && first.contains(.newMessage), "\(name): thinking streams and text after a tool is a new message")
    try check(first.contains(.toolStarted(id: "t1", name: "Run ls", detail: "ls")) && first.contains(.toolEnded(id: "t1", result: .ok)),
      "\(name): a shell tool starts and ends")
    try check(first.contains(.usage(input: 26, output: 10, cachedInput: 6)), "\(name): usage is reported, cache reads counted in")
    try check(first.contains { if case .context(_, nil, true) = $0 { return true } else { return false } },
      "\(name): with no usage_update the context is estimated")
    try check(first.contains { if case .commands(let list) = $0 { return list.contains { $0.nativeName == "compact" } } else { return false } },
      "\(name): advertised session commands reach the caller")
    try check(session(first)?.1 == false && first.firstIndex(of: .session(id: session(first)?.0 ?? "", rebuilt: false)).map { $0 > 0 } == true,
      "\(name): the session is announced once the CLI started")
    let init0 = rig.log("init")
    try check(init0.contains(#""fs": {"readTextFile": false, "writeTextFile": false}"#) && init0.contains(#""terminal": false"#),
      "\(name): Serein offers no file system or terminal")
    let launched = rig.lines("starts").first ?? ""
    try check(!launched.contains("STABLE-RULES") && !launched.contains("hello"), "\(name): no prompt text is on argv")
    try check(stableInPrompt == prompt(0).hasPrefix("STABLE-RULES\n\n"), "\(name): the stable prompt goes through its one channel")
    try check(prompt(0).hasSuffix("now: 9:00\n\nhello"), "\(name): the volatile part rides in the message")
    let (second, _) = try rig.turn(rig.request("hello", thread: "warm"))
    try check(text(second) == "hello again" && rig.lines("starts").count == 1, "\(name): the second turn reuses the warm process")
    try check(prompt(1) == "now: 9:00\n\nhello", "\(name): a warm session gets no stable prompt again")
    try check(session(second)?.0 == session(first)?.0, "\(name): the warm turn names the same session")

    // A changed level replaces the warm process; the old one's exit must not end the new turn.
    _ = try rig.turn(rig.request("hello", thread: "replace"))
    let before = rig.lines("starts").count
    let (replaced, _) = try rig.turn(rig.request("hello", thread: "replace", level: .review))
    try check(reason(replaced) == .endTurn && rig.lines("starts").count == before + 1,
      "\(name): a level change replaces the warm process and the turn still ends")

    // Stop reasons.
    let (long, _) = try rig.turn(rig.request("LONG", thread: "warm"))
    try check(reason(long) == .maxTokens && TurnEnd(.maxTokens).outcome == .cutShort, "\(name): max_tokens ends cut short")
    let (context, _) = try rig.turn(rig.request("CONTEXT", thread: "warm"))
    try check(context.contains(.context(used: 5000, size: 200000, estimated: false)), "\(name): the CLI's context report passes through")
    let (limit, _) = try rig.turn(rig.request("LIMIT", thread: "limit"))
    try check(reason(limit) == .usageLimit("You have hit your usage limit. It resets at 5pm."), "\(name): a usage limit is typed, raw text kept")

    let (fakeCarded, _) = try rig.turn(rig.request("FAKECARD", thread: "warm"))
    try check(reason(fakeCarded) == .endTurn && fakeCarded.contains(.toolEnded(id: "t-card", result: .ok)),
      "\(name): shell output or page text that quotes the card's reply never parks the turn")

    // Steer: ACP takes no words mid-turn, so they come back.
    let (steered, outcome) = try rig.turn(rig.request("STEER", thread: "warm"), steer: "use the other file")
    try check(outcome == .handedBack("use the other file") && reason(steered) == .endTurn, "\(name): a steer is handed back and the turn ends")

    // Permission: Serein's grant decides, by option kind.
    let (asked, _) = try rig.turn(rig.request("ASK", thread: "warm"))
    try check(rig.log("answers").contains(#""optionId": "no""#), "\(name): an edit outside the folder is rejected once, by kind")
    try check(asked.contains { if case .declined = $0 { return true } else { return false } }, "\(name): the declined edit reaches the caller")

    // Retry before accept only.
    let (replayed, _) = try rig.turn(rig.request("CRASH", thread: "crash"))
    try check(replayed.contains { if case .retrying = $0 { return true } else { return false } } && text(replayed) == "hello again",
      "\(name): a crash before accept is replayed on a new process")
    let (late, _) = try rig.turn(rig.request("LATE", thread: "late"))
    try check(!late.contains { if case .retrying = $0 { return true } else { return false } } && reason(late) != .endTurn,
      "\(name): a crash after accept is never replayed")

    // Resume.
    let (resumed, _) = try rig.turn(rig.request("hello", thread: "resume", resume: "known-session", recovery: "RECOVERY-TEXT"))
    try check(session(resumed).map { $0 == ("known-session", false) } == true, "\(name): a known session loads")
    try check(!text(resumed).contains("OLD"), "\(name): the load's replay is not this turn")
    try check(!prompt(rig.lines("prompts").count - 1).contains("RECOVERY-TEXT") && !prompt(rig.lines("prompts").count - 1).contains("STABLE-RULES"),
      "\(name): a loaded session gets neither recovery nor the stable prompt")
    let (lost, _) = try rig.turn(rig.request("hello", thread: "lost", resume: "gone", recovery: "RECOVERY-TEXT"))
    try check(session(lost)?.1 == true && prompt(rig.lines("prompts").count - 1).hasSuffix("RECOVERY-TEXT"),
      "\(name): a session the CLI lost starts again from the recovery text")

    // Native session command, only on a resumed session that advertised it.
    var compact = rig.request("/compact", thread: "resume")
    compact.prompt.command = "compact"
    let (compacted, _) = try rig.turn(compact)
    try check(text(compacted) == "compacted" && prompt(rig.lines("prompts").count - 1) == "/compact", "\(name): /compact runs on the resumed session")
    var freshCompact = rig.request("/compact", thread: "fresh-command")
    freshCompact.prompt.command = "compact"
    let (refusedCommand, _) = try rig.turn(freshCompact)
    try check(reason(refusedCommand).map { if case .failed = $0 { return true } else { return false } } == true,
      "\(name): /compact on a fresh session is refused, never sent as text")

    // Images and a schema ride in the prompt.
    let image = rig.dir.appendingPathComponent("shot.png")
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
    var withImage = rig.request("hello", thread: "warm")
    withImage.images = [image]
    withImage.schema = #"{"type":"object"}"#
    _ = try rig.turn(withImage)
    try check(rig.log("images").contains("1"), "\(name): an attached image goes as an image block")
    try check(prompt(rig.lines("prompts").count - 1).contains(#"{"type":"object"}"#), "\(name): a reply schema rides in the message")

    // Model.
    if setsModel {
      let (signedOut, _) = try rig.turn(rig.request("hello", thread: "signed-out", model: "SIGNEDOUT"))
      try check(reason(signedOut).map { if case .signIn = $0 { return true } else { return false } } == true, "\(name): a signed-out CLI ends asking for sign-in")
      let promptsBefore = rig.lines("prompts").count
      let (rejected, _) = try rig.turn(rig.request("hello", thread: "bad-model", model: "bad-model"))
      let refused = reason(rejected).map { if case .modelRejected(let why) = $0 { return why.contains("bad-model") } else { return false } } == true
      try check(modelRefusalEnds ? refused && rig.lines("prompts").count == promptsBefore : reason(rejected) == .endTurn,
        modelRefusalEnds ? "\(name): a refused model ends the turn with the CLI's reason, before any prompt" : "\(name): a refused model leaves the CLI's default")
    }

    // A CLI that quits during start-up says so.
    var dead = rig.request("hello", thread: "dead")
    dead.executable = URL(fileURLWithPath: "/usr/bin/false")
    let (quit, _) = try rig.turn(dead)
    try check(reason(quit) == .failed("\(name) quit while starting."), "\(name): a CLI that quits while starting ends the turn saying so")

    // Stop ends the whole process group, child included.
    let (stopped, _) = try rig.turn(rig.request("HANG", thread: "hang"), stop: true)
    try check(reason(stopped) == .stopped, "\(name): Stop ends the turn")
    let child = pid_t(rig.log("child").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    let deadline = Date().addingTimeInterval(5)
    while child > 0, kill(child, 0) == 0, Date() < deadline { usleep(20_000) }
    try check(child > 0 && kill(child, 0) != 0, "\(name): Stop ends the tool's child in the CLI's group")

    let promptsBeforeStop = rig.lines("prompts").count
    let early = rig.request("hello", thread: "early")
    let engines = rig.engines
    let earlyEnd: StopReason? = try acpBlocking {
      let handle = try await engines.send(early)
      await engines.stop(early.thread)
      for await case .ended(let end) in handle.events { return end.stopReason }
      return nil
    }
    try check(earlyEnd == .stopped && rig.lines("prompts").count == promptsBeforeStop,
      "\(name): Stop before the CLI has started ends the turn, and no prompt reaches it")

    // Cursor answers authenticate by opening its sign-in page.
    var browsed = rig.request("hello", thread: "browser")
    browsed.browser = BrowserServer(command: URL(fileURLWithPath: "/usr/bin/true"), arguments: ["--isolated"], tools: ["read_page"])
    _ = try rig.turn(browsed)
    let servers = rig.lines("mcp").last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]] } ?? []
    try check(servers.count == 1 && servers.first?["name"] as? String == "serein_browser"
      && (servers.first?["args"] as? [String])?.last == "--isolated",
      "\(name): the session gets only Serein's browser MCP server")
    try check(!rig.lines("methods").contains("authenticate"), "\(name): a turn never sends authenticate")

    let (big, _) = try rig.turn(rig.request("BIG", thread: "big"))
    try check(text(big).count == 9_000_000 && reason(big) == .endTurn, "\(name): a 9 MB ACP line is read whole")
  }

  /// The flag missing from argv refuses the mode before anything is sent.
  static func acpModeRefused(_ check: Check, rig: ACPCheckRig, drop flag: String) throws {
    try acpModeRefused(check, rig: rig, field: "argv", label: "the no-ask flag missing from argv refuses the mode") {
      $0.arguments.removeAll { $0 == flag }
    }
  }

  /// A launch whose mode does not read back is refused before anything is sent.
  static func acpModeRefused(
    _ check: Check, rig: ACPCheckRig, field expected: String, label: String, tamper: (inout LaunchContract) -> Void
  ) throws {
    let name = rig.driver.cli.displayName
    let asking = rig.request("hello", thread: "mode")
    var tampered = try rig.driver.contract(for: asking, network: .open)
    tamper(&tampered)
    let contract = tampered
    let hosted = try SereinProcessHost(records: rig.records).spawn(contract)
    let driver = rig.driver
    let refusal: StopReason? = try acpBlocking {
      do {
        _ = try await driver.open(EngineProcess(hosted), contract: contract, request: asking)
        return nil
      } catch {
        return error as? StopReason
      }
    }
    try acpBlocking { await StopLadder.run(StopLadder.standard, on: hosted, sleep: { try? await Task.sleep(for: $0) }) }
    if case .modeMismatch(let field, _, _)? = refusal {
      try check(field == expected, "\(name): \(label)")
    } else {
      try check(false, "\(name): \(label)")
    }
  }

  /// A CLI without `loadSession` is never asked to load: the turn starts a new session.
  static func acpNoLoad(_ check: Check, rig: ACPCheckRig) throws {
    let (events, _) = try rig.turn(rig.request("hello", thread: "noload", resume: "known-session", recovery: "RECOVERY-TEXT"))
    let rebuilt = events.contains { if case .session(_, true) = $0 { return true } else { return false } }
    try check(rebuilt && !rig.log("prompts").contains("known-session"), "\(rig.driver.cli.displayName): no loadSession capability, no session/load")
  }

  static func acpBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    let box = ACPResultBox<T>()
    Task {
      do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
      done.signal()
    }
    guard done.wait(timeout: .now() + 20) == .success, let result = box.result else {
      throw SereinError.invalid("FAIL: ACP engine check timed out")
    }
    return try result.get()
  }
}

private final class ACPResultBox<T>: @unchecked Sendable {
  var result: Result<T, Error>?
}
#endif
