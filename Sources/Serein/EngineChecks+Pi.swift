#if DEBUG
import Darwin
import Foundation
import SereinCore
@testable import SereinEngines

/// The Pi driver through `Engines` and the real process host, against a fake `pi`
/// that speaks Pi's RPC as 0.55.3 does (and Oh My Pi's chunked v2 when named `omp`).
extension AssistantCoreChecks {
  static func enginesPi(_ check: Check) throws {
    let manager = FileManager.default
    let dir = manager.temporaryDirectory.appendingPathComponent("pi-checks-\(UUID().uuidString)")
    try manager.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: dir) }
    let pi = dir.appendingPathComponent("pi"), omp = dir.appendingPathComponent("omp")
    for file in [pi, omp] {
      try fakePi(dir).write(to: file, atomically: true, encoding: .utf8)
      try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    // Under Serein's library, which the file guard closes: Pi must still read its prompt there.
    let files = AgentAccess.defaultRoot.appendingPathComponent("pi-files-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: files) }
    let records = RunRecords(root: dir.appendingPathComponent("runs"))
    let engines = Engines(
      drivers: [
        PiDriver(cli: .pi, files: files, sessionsFolder: dir, handshakeWait: .seconds(2)),
        PiDriver(cli: .ohMyPi, files: files, sessionsFolder: dir, handshakeWait: .seconds(2)),
      ],
      host: SereinProcessHost(records: records),
      records: records, sleep: { try? await Task.sleep(for: min($0, .milliseconds(100))) }, tickEvery: .seconds(3_600))
    func request(
      _ message: String, thread: String, cli: HarnessDriver = .pi, resume: String? = nil, recovery: String? = nil, model: String? = nil
    ) -> TurnRequest {
      TurnRequest(
        thread: ThreadKey(thread), cli: cli, executable: cli == .pi ? pi : omp, access: .project(folder: dir, level: .commands),
        prompt: TurnPrompt(stable: "STABLE-RULES", volatile: "now: 9:00", message: message, recovery: recovery), model: model,
        effort: nil, resume: resume, browser: nil, taskID: "task")
    }
    /// The turn's events, and the steer outcome when `steer` went in at the first tool.
    func turn(_ request: TurnRequest, steer: String? = nil, stop: Bool = false) throws -> ([EngineEvent], SteerOutcome?) {
      try piBlocking {
        let handle = try await engines.send(request)
        var seen: [EngineEvent] = []
        var outcome: SteerOutcome?
        for await event in handle.events {
          seen.append(event)
          guard case .toolStarted = event else { continue }
          if let steer { outcome = await engines.steer(request.thread, steer) }
          if stop { await engines.stop(request.thread) }
        }
        return (seen, outcome)
      }
    }
    func starts() -> [String] {
      ((try? String(contentsOf: dir.appendingPathComponent("starts"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    func log(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
    func text(_ events: [EngineEvent]) -> String {
      events.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
    }

    // A prompt file planted before the launch is replaced, never trusted.
    let driver = PiDriver(cli: .pi, files: files)
    let planted = try driver.contract(for: request("hello", thread: "warm"), network: .open).arguments
      .drop { $0 != "--append-system-prompt" }.dropFirst().first ?? ""
    try manager.createDirectory(at: files, withIntermediateDirectories: true)
    try "PLANTED".write(toFile: planted, atomically: true, encoding: .utf8)

    // Start, handshake, a streamed turn, warm reuse.
    let (first, _) = try turn(request("hello", thread: "warm"))
    try check(log("system") == "STABLE-RULES\n", "Pi reads the stable prompt Serein wrote, not a planted file")
    try check(log("system-write").hasPrefix("denied"), "Pi cannot rewrite its prompt file")
    try check(text(first) == "hello worldagain" && first.last == .ended(TurnEnd(.endTurn, sessionID: dir.path + "/session.jsonl")), "A Pi turn streams to its end")
    try check(first.contains(.newMessage), "A second assistant message is marked as new")
    try check(first.contains(.usage(input: 20, output: 10, cachedInput: 6)), "Usage is summed over the turn's messages")
    try check(first.contains(.session(id: dir.path + "/session.jsonl", rebuilt: false)), "The session id is Pi's session file")
    let launched = starts().first ?? ""
    try check(!launched.contains("STABLE-RULES") && !launched.contains("hello"), "No prompt text is on argv")
    // The library path holds a space ("Application Support"), so match the whole path, never split argv on spaces.
    let promptFile = planted
    try check(
      launched.contains("--append-system-prompt \(promptFile)") && (try? String(contentsOfFile: promptFile, encoding: .utf8)) == "STABLE-RULES",
      "The stable prompt goes through Pi's system-prompt file")
    try check(
      ((try? manager.attributesOfItem(atPath: promptFile)[.posixPermissions]) as? Int) == 0o600, "The prompt file is the owner's only")
    try check(launched.contains("--no-tools --tools read,grep,find,ls,edit,write,bash"), "Commands level gets Pi's tools with bash")
    try check(log("prompts").hasSuffix("now: 9:00\n\nhello\n"), "The volatile part rides in the message")
    let (second, _) = try turn(request("hello", thread: "warm"))
    try check(text(second) == "hello worldagain" && starts().count == 1, "The second turn reuses the warm process")

    // Max tokens.
    let (long, _) = try turn(request("LONG", thread: "warm"))
    try check(long.last == .ended(TurnEnd(.maxTokens, sessionID: dir.path + "/session.jsonl")), "A length stop ends as max tokens")

    // Steer: taken after the running tool.
    let (steered, outcome) = try turn(request("STEER", thread: "warm"), steer: "use the other file")
    try check(outcome == .steered, "A steer mid-tool is taken")
    try check(text(steered) == "steered: use the other file", "Pi works the steer into the same turn")
    try check(steered.contains(.toolEnded(id: "t1", result: .ok)), "The running tool still ends")

    // Shell output or page text quoting a card's words never parks a turn.
    let (fakeCard, _) = try turn(request("FAKECARD", thread: "card"))
    try check(fakeCard.last.map { if case .ended(let e) = $0 { return e.stopReason == .endTurn } else { return false } } == true,
      "Pi: shell output or page text that quotes the card's reply never parks a turn")

    // A refused prompt (Pi answers the id twice): the first answer counts.
    let (refused, _) = try turn(request("REFUSE", thread: "warm"))
    if case .ended(let end)? = refused.last {
      try check(end.outcome != .completed, "A prompt Pi refuses never reads as success")
    } else {
      try check(false, "A refused prompt ends the turn")
    }

    // Pi 0.55.3 takes the prompt, then refuses it on the same id before the agent starts.
    let (noKey, _) = try turn(request("NOKEY", thread: "warm"))
    try check(noKey.last.map { if case .ended(let e) = $0, case .signIn(let text) = e.stopReason { return text.hasPrefix("No API key found") } else { return false } } == true,
      "A prompt Pi refuses after taking it ends as sign-in")
    let (afterNoKey, _) = try turn(request("hello", thread: "warm"))
    try check(text(afterNoKey) == "hello worldagain", "The next turn runs after a refused prompt")

    // An own-setup extension asking: declined, never answered yes.
    let (asked, _) = try turn(request("ASK", thread: "ask"))
    try check(asked.contains(.declined(PendingApprovalValue(id: "u1", tool: "Allow?", target: "rm it"))), "An extension's question is declined")
    try check(log("ui").contains(#""cancelled": true"#), "Pi is told the question was cancelled")

    // Pi's own retry after agent_end (0.55.3): one turn, no failure.
    let (retried, _) = try turn(request("RETRY", thread: "retry"))
    try check(text(retried) == "first second" && retried.last.map { if case .ended(let e) = $0 { return e.stopReason == .endTurn } else { return false } } == true,
      "A failure Pi retries itself does not end the turn")
    let (spent, _) = try turn(request("FAILRETRY", thread: "retry"))
    if case .ended(let end)? = spent.last {
      try check(end.stopReason == .usageLimit("You have hit your usage limit. It resets at 5pm."), "A failure after Pi's retries is typed, raw text kept")
    } else {
      try check(false, "Spent retries end the turn")
    }

    // Serein's replay: before accept only.
    let before = starts().count
    let (replayed, _) = try turn(request("CRASH", thread: "crash"))
    try check(replayed.contains { if case .retrying = $0 { return true } else { return false } }, "A crash before accept is replayed")
    try check(text(replayed) == "hello worldagain" && starts().count == before + 2, "The replay runs on a new process")
    let (late, _) = try turn(request("CRASHLATE", thread: "late"))
    try check(!late.contains { if case .retrying = $0 { return true } else { return false } }, "A crash after accept is never replayed")
    if case .ended(let end)? = late.last { try check(end.outcome == .failed, "A crash after accept ends failed") }

    // Resume.
    let (resumed, _) = try turn(request("hello", thread: "resume", resume: dir.path + "/session.jsonl", recovery: "RECOVERY-TEXT"))
    try check(resumed.contains(.session(id: dir.path + "/session.jsonl", rebuilt: false)), "A known session resumes")
    try check(!log("prompts").contains("RECOVERY-TEXT"), "A resumed session gets no recovery text")
    let (lost, _) = try turn(request("hello", thread: "lost", resume: dir.path + "/gone.jsonl", recovery: "RECOVERY-TEXT"))
    try check(lost.contains(.session(id: dir.path + "/session.jsonl", rebuilt: true)), "A lost session is rebuilt")
    try check(log("prompts").contains("RECOVERY-TEXT"), "The rebuilt session gets the recovery text")
    let outside = manager.temporaryDirectory.appendingPathComponent("pi-outside-\(UUID().uuidString).jsonl")
    try "{}".write(to: outside, atomically: true, encoding: .utf8)
    defer { try? manager.removeItem(at: outside) }
    try manager.createSymbolicLink(at: dir.appendingPathComponent("linked.jsonl"), withDestinationURL: outside)
    let (escaped, _) = try turn(request("hello", thread: "outside", resume: outside.path))
    try check(escaped.contains(.session(id: dir.path + "/session.jsonl", rebuilt: true)), "A resume outside Pi's sessions folder is not loaded")
    let (linked, _) = try turn(request("hello", thread: "linked", resume: dir.path + "/linked.jsonl"))
    try check(linked.contains(.session(id: dir.path + "/session.jsonl", rebuilt: true)), "A resume through a link is not loaded")

    // Sign-in and model read-back.
    let (signedOut, _) = try turn(request("hello", thread: "signin", model: "none/none"))
    try check(signedOut.last.map { if case .ended(let e) = $0, case .signIn = e.stopReason { return true } else { return false } } == true,
      "Pi with no model asks for sign-in")
    let (silent, _) = try turn(request("hello", thread: "silent", model: "silent/silent"))
    try check(silent.last.map { if case .ended(let e) = $0 { return e.outcome == .failed } else { return false } } == true,
      "A Pi that never answers its state is ended and the turn fails")
    let (otherModel, _) = try turn(request("hello", thread: "model", model: "other/x"))
    try check(otherModel.last.map { if case .ended(let e) = $0, case .modelRejected = e.stopReason { return true } else { return false } } == true,
      "A model Pi did not take ends model-rejected")
    let (sameModel, _) = try turn(request("hello", thread: "model2", model: "fake-1"))
    try check(text(sameModel) == "hello worldagain", "The model Pi reports back is accepted")

    let (idOnly, _) = try turn(request("hello", thread: "partial-echo", model: "fixture/id-only"))
    try check(text(idOnly) == "hello worldagain" && log("selected").split(whereSeparator: \.isNewline).last == "fixture/id-only",
      "A provider-qualified Pi route confirms an ID-only echo with set_model before sending")

    // Oh My Pi: RPC v2 with chunked frames.
    let (chunked, _) = try turn(request("hello", thread: "omp", cli: .ohMyPi))
    try check(text(chunked) == "hello worldagain", "Oh My Pi's chunked frames come out whole")
    try check(starts().last?.contains("--no-lsp") == true, "Oh My Pi gets its own isolation flags")

    // Stop ends the whole group, the tool's child included.
    let (stopped, _) = try turn(request("HANG", thread: "hang"), stop: true)
    try check(stopped.last.map { if case .ended(let e) = $0 { return e.stopReason == .stopped } else { return false } } == true, "Stop ends the turn")
    let child = pid_t(log("child").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    let deadline = Date().addingTimeInterval(5)
    while child > 0, kill(child, 0) == 0, Date() < deadline { usleep(20_000) }
    try check(child > 0 && kill(child, 0) != 0, "Stop ends the tool's child in Pi's group")

    let (thought, _) = try turn(request("THINK", thread: "think"))
    try check(thought.contains(.thinking("Checking.")) && text(thought) == "thought", "Pi's reasoning stays out of its answer")

    // Mode read-back: the tool list missing from argv refuses before anything is sent.
    let asking = request("hello", thread: "mode")
    var tampered = try driver.contract(for: asking, network: .open)
    tampered.arguments.removeAll { $0 == "--no-tools" }
    let contract = tampered
    let hosted = try SereinProcessHost(records: records).spawn(contract)
    let refusal: StopReason? = try piBlocking {
      do {
        _ = try await driver.open(EngineProcess(hosted), contract: contract, request: asking)
        return nil
      } catch {
        return error as? StopReason
      }
    }
    try piBlocking { await StopLadder.run(StopLadder.standard, on: hosted, sleep: { try? await Task.sleep(for: $0) }) }
    if case .modeMismatch(let name, _, _)? = refusal {
      try check(name == "argv", "A tool list missing from argv refuses the mode")
    } else {
      try check(false, "A tool list missing from argv refuses the mode")
    }

    // Contract rules.
    func flags(_ access: Access, browser: BrowserServer? = nil) throws -> [String] {
      var asked = request("x", thread: "c")
      asked.access = access
      asked.browser = browser
      return try driver.contract(for: asked, network: .open).arguments
    }
    try check(try flags(.answer).contains("--no-tools") && !(try flags(.answer).contains("--tools")), "An answer turn has no tools")
    try check(try flags(.project(folder: dir, level: .review)).contains("read,grep,find,ls"), "Review reads only")
    try check(try flags(.project(folder: dir, level: .edits)).contains("read,grep,find,ls,edit,write"), "Edits get no bash")
    let own = try flags(.ownSetup(folder: dir))
    try check(!own.contains("--no-extensions") && own.contains("--no-skills"), "Own setup loads the person's extensions and nothing else of theirs")
    try check(try flags(.project(folder: dir, level: .edits)).contains("--no-extensions"), "Other turns keep extensions off")
    let ompDriver = PiDriver(cli: .ohMyPi, files: files)
    let ompFlags = try ompDriver.contract(for: request("x", thread: "c", cli: .ohMyPi), network: .open).arguments
    try check(try flags(.answer).contains("--no-context-files") && ompFlags.contains("--no-context-files"),
      "Pi and Oh My Pi keep AGENTS.md and CLAUDE.md out on every version")
    let web = try flags(.web, browser: BrowserServer(command: URL(fileURLWithPath: "/bin/helper"), arguments: ["--isolated"], tools: ["navigate"]))
    try check(web.contains("serein_browser_navigate") && web.contains("--extension"), "Serein's browser comes in as a Pi extension")
    let helper = BrowserServer(command: URL(fileURLWithPath: "/bin/helper"), arguments: [], tools: ["navigate"])
    try check(try flags(.project(folder: dir, level: .commands), browser: helper).contains("--extension"),
      "A project turn served the browser gets the extension")
    let relay = BrowserServer(command: helper.command, arguments: ["--relay"], tools: ["navigate"])
    try check(try flags(.project(folder: dir, level: .commands), browser: relay).contains("--extension"), "A Relay turn gets the browser extension")
    let script = web.drop { $0 != "--extension" }.dropFirst().first ?? ""
    try check(script.hasSuffix("/PiBrowser.js") && manager.fileExists(atPath: script) && !script.hasPrefix(files.path),
      "The browser extension is the app's own PiBrowser.js")

    var chunks = PiChunks()
    let whole = Data(#"{"type":"x"}"#.utf8)
    func piece(_ index: Int, _ data: Data, count: Int = 2) -> JSON {
      .object([
        "type": .string("rpc_chunk"), "chunkId": .string("c"), "index": .number(Double(index)), "count": .number(Double(count)),
        "byteLength": .number(Double(whole.count)), "data": .string(data.base64EncodedString()),
      ])
    }
    try check(chunks.accept(piece(1, whole.prefix(5))) == nil && chunks.accept(piece(0, whole.prefix(5))) == nil, "A chunk out of order starts nothing")
    try check(chunks.accept(piece(1, whole.dropFirst(5))) == .object(["type": .string("x")]), "Chunks in order join into one frame")

    try piBlocking { await engines.shutdown() }
    if let live = ProcessInfo.processInfo.environment["SEREIN_PI_LIVE"] { try enginesPiLive(check, pi: URL(fileURLWithPath: live)) }
  }

  /// The real `pi` through `Engines`, with an offline stand-in model in the project's own
  /// `.pi/extensions`, so no sign-in is needed. Run with SEREIN_PI_LIVE=<path to pi>.
  private static func enginesPiLive(_ check: Check, pi: URL) throws {
    let manager = FileManager.default
    let dir = manager.temporaryDirectory.appendingPathComponent("pi-live-\(UUID().uuidString)")
    let extensions = dir.appendingPathComponent("project/.pi/extensions")
    try manager.createDirectory(at: extensions, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: dir) }
    try standInProvider.write(to: extensions.appendingPathComponent("standin.ts"), atomically: true, encoding: .utf8)
    let records = RunRecords(root: dir.appendingPathComponent("runs"))
    let engines = Engines(
      drivers: [PiDriver(cli: .pi, files: dir.appendingPathComponent("files"))], host: SereinProcessHost(records: records), records: records)
    let request = TurnRequest(
      thread: ThreadKey("live"), cli: .pi, executable: pi, access: .ownSetup(folder: dir.appendingPathComponent("project")),
      prompt: TurnPrompt(stable: "Answer in three words.", volatile: "", message: "say hi", recovery: nil), model: "standin/standin-1",
      effort: nil, resume: nil, browser: nil, taskID: "live")
    func timed() throws -> ([EngineEvent], Int) {
      try piBlocking {
        let start = ContinuousClock.now
        var seen: [EngineEvent] = []
        for await event in try await engines.send(request).events { seen.append(event) }
        return (seen, Int((ContinuousClock.now - start) / .milliseconds(1)))
      }
    }
    let (cold, coldMs) = try timed(), (warm, warmMs) = try timed()
    try piBlocking { await engines.shutdown() }
    print("Pi live: cold \(coldMs) ms, warm \(warmMs) ms")
    for events in [cold, warm] {
      let reply = events.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
      try check(reply == "live reply ok", "Live Pi streams the stand-in's reply")
      try check(!events.contains { if case .declined = $0 { return true } else { return false } }, "Live Pi asks nothing")
      try check({ if case .ended(let end) = events.last { return end.stopReason == .endTurn } else { return false } }(), "Live Pi ends the turn")
    }
    try check(warmMs < coldMs, "Live Pi's warm turn is faster than its cold one")
  }

  private static let standInProvider = #"""
    import { createAssistantMessageEventStream } from "@mariozechner/pi-ai";
    export default function (pi: any) {
      pi.registerProvider("standin", {
        baseUrl: "http://127.0.0.1:9", apiKey: "standin-key", api: "standin",
        models: [{ id: "standin-1", name: "Stand-in", reasoning: false, input: ["text"],
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 }],
        streamSimple: (model: any) => {
          const stream = createAssistantMessageEventStream();
          const output: any = { role: "assistant", content: [{ type: "text", text: "" }], api: model.api, provider: model.provider,
            model: model.id, stopReason: "stop", timestamp: Date.now(),
            usage: { input: 7, output: 3, cacheRead: 0, cacheWrite: 0, totalTokens: 10, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
          queueMicrotask(() => {
            stream.push({ type: "start", partial: output });
            stream.push({ type: "text_start", contentIndex: 0, partial: output });
            for (const piece of ["live ", "reply ", "ok"]) {
              output.content[0].text += piece;
              stream.push({ type: "text_delta", contentIndex: 0, delta: piece, partial: output });
            }
            stream.push({ type: "text_end", contentIndex: 0, content: output.content[0].text, partial: output });
            stream.push({ type: "done", reason: "stop", message: output });
            stream.end();
          });
          return stream;
        },
      });
    }
    """#

  /// A fake `pi`: answers the RPC commands Serein sends, and plays the turn the prompt names.
  private static func fakePi(_ dir: URL) -> String {
    #"""
    #!/usr/bin/env python3
    import base64, json, os, subprocess, sys, time
    DIR = "\#(dir.path)"
    omp = os.path.basename(sys.argv[0]) == "omp"
    def append(name, text):
        with open(os.path.join(DIR, name), "a") as f: f.write(text + "\n")
    append("starts", " ".join(sys.argv[1:]))
    if "--append-system-prompt" in sys.argv:
        prompt = sys.argv[sys.argv.index("--append-system-prompt") + 1]
        try: append("system", open(prompt).read())
        except OSError as e: append("system", "unreadable: " + str(e))
        try: open(prompt, "a").close(); append("system-write", "written")
        except OSError: append("system-write", "denied")
    if "none/none" in sys.argv:
        sys.stderr.write("No models available. Set an API key.\n"); sys.exit(1)
    session = os.path.join(DIR, "session.jsonl")
    open(session, "a").close()
    v2 = False
    messages = 0
    def chunked(frame):
        data = json.dumps(frame).encode()
        half = len(data) // 2
        cid = "c%d" % time.monotonic_ns()
        for i, part in enumerate([data[:half], data[half:]]):
            sys.stdout.write(json.dumps({"type": "rpc_chunk", "chunkId": cid, "index": i, "count": 2, "byteLength": len(data),
                "data": base64.b64encode(part).decode()}) + "\n")
        sys.stdout.flush()
    def out(frame):
        if v2 and frame.get("type") == "message_update": chunked(frame)
        else: sys.stdout.write(json.dumps(frame) + "\n"); sys.stdout.flush()
    def say(*parts):
        out({"type": "message_start", "message": {"role": "assistant"}})
        for part in parts: out({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "delta": part}})
        out({"type": "message_end", "message": {"role": "assistant", "usage": {"input": 10, "output": 5, "cacheRead": 3}}})
    def end(reason="stop", error=None):
        message = {"role": "assistant", "stopReason": reason}
        if error: message["errorMessage"] = error
        out({"type": "turn_end", "message": message})
        out({"type": "agent_end", "messages": [message]})
    def turn(text, reply):
        if "CRASH" in text and "CRASHLATE" not in text and not os.path.exists(os.path.join(DIR, "crashed")):
            open(os.path.join(DIR, "crashed"), "w").close()
            sys.stderr.write("ECONNRESET socket hang up\n"); sys.exit(1)
        if "REFUSE" in text:
            out({"type": "response", "id": reply, "command": "prompt", "success": False, "error": "Agent is already processing"})
            out({"type": "response", "id": reply, "command": "prompt", "success": True}); return
        out({"type": "response", "id": reply, "command": "prompt", "success": True})
        if "NOKEY" in text:
            out({"type": "response", "id": reply, "command": "prompt", "success": False,
                "error": "No API key found for anthropic.\n\nUse /login or set an API key environment variable."}); return
        out({"type": "agent_start"})
        if "CRASHLATE" in text:
            say("partial"); sys.stderr.write("ECONNRESET socket hang up\n"); sys.exit(1)
        if "LONG" in text: say("cut"); end("length"); return
        if "STEER" in text:
            out({"type": "tool_execution_start", "toolCallId": "t1", "toolName": "bash", "args": {"command": "sleep 1"}})
            steer = json.loads(sys.stdin.readline())
            out({"type": "response", "id": steer.get("id"), "command": "steer", "success": True})
            out({"type": "tool_execution_end", "toolCallId": "t1", "isError": False})
            say("steered: " + steer["message"]); end(); return
        if "HANG" in text:
            child = subprocess.Popen(["/bin/sleep", "300"])
            append("child", str(child.pid))
            out({"type": "tool_execution_start", "toolCallId": "h1", "toolName": "bash", "args": {"command": "sleep 300"}})
            sys.stdin.read(); time.sleep(300)
        if "ASK" in text:
            out({"type": "extension_ui_request", "id": "u1", "method": "confirm", "title": "Allow?", "message": "rm it"})
            append("ui", json.dumps(json.loads(sys.stdin.readline())))
            say("ok"); end(); return
        if "FAILRETRY" in text:
            end("error", "usage limit reached")
            out({"type": "auto_retry_start", "attempt": 1})
            out({"type": "auto_retry_end", "success": False, "finalError": "You have hit your usage limit. It resets at 5pm."}); return
        if "RETRY" in text:
            say("first "); end("error", "529 overloaded")
            out({"type": "auto_retry_start", "attempt": 1}); out({"type": "agent_start"})
            say("second"); end(); return
        if "CARD" in text:
            parked = json.dumps({"result": "card still open", "next": "End your turn."})
            calls = [("c1", "bash", parked), ("c2", "serein_browser_read_page", json.dumps({"page": "card still open"}))] \
                if "FAKECARD" in text else [("c1", "serein_browser_secure_card", parked)]
            for i, n, t in calls:
                out({"type": "tool_execution_start", "toolCallId": i, "toolName": n, "args": {}})
                out({"type": "tool_execution_end", "toolCallId": i, "toolName": n, "isError": False,
                    "result": {"content": [{"type": "text", "text": t}]}})
            say("waiting"); end(); return
        if "THINK" in text:
            out({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "delta": "Checking."}})
            say("thought"); end(); return
        say("hello ", "world"); say("again"); end()
    while True:
        line = sys.stdin.readline()
        if not line: break
        command = json.loads(line)
        kind, reply = command.get("type"), command.get("id")
        def ok(data=None):
            frame = {"type": "response", "id": reply, "command": kind, "success": True}
            if data is not None: frame["data"] = data
            out(frame)
        if kind == "negotiate_protocol":
            if omp: v2 = True; ok({"protocolVersion": 2})
            else: out({"type": "response", "command": kind, "success": False, "error": "Unknown command: negotiate_protocol"})
        elif kind == "switch_session":
            if os.path.exists(command["sessionPath"]): session = command["sessionPath"]; messages = 2
            ok({"cancelled": False})
        elif kind == "get_state" and "silent/silent" in sys.argv:
            continue
        elif kind == "get_state" and "fixture/id-only" in sys.argv:
            ok({"model":{"id":"id-only"}, "sessionId":"s"})
        elif kind == "set_model" and command["provider"] == "other":
            out({"type": "response", "id": reply, "command": kind, "success": False, "error": "Model not found: other/x"})
        elif kind == "set_model":
            append("selected", command["provider"] + "/" + command["modelId"])
            ok()
        elif kind == "get_state":
            ok({"model": {"provider": "fake", "id": "fake-1"}, "sessionFile": session, "sessionId": "s", "messageCount": messages})
        elif kind == "prompt":
            append("prompts", command["message"])
            turn(command["message"], reply)
    """#
  }

  /// Runs async work from a synchronous check, with a deadline so a hang fails instead of stalling.
  private static func piBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    let box = PiResultBox<T>()
    Task {
      do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
      done.signal()
    }
    guard done.wait(timeout: .now() + 20) == .success, let result = box.result else {
      throw SereinError.invalid("FAIL: Pi engine check timed out")
    }
    return try result.get()
  }
}

private final class PiResultBox<T>: @unchecked Sendable {
  var result: Result<T, Error>?
}
#endif
