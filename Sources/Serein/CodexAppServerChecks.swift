#if DEBUG
import Foundation
import SereinCore

extension SmokeTest {
  /// The parts of Codex's app server that stay beside Engines, against a fake server that speaks
  /// the discovered protocol (no provider, no model call): the probe, the config refusal, native
  /// fork, the model list and the idle stop. Turns run through CodexDriver (EngineChecks+Codex).
  @MainActor static func codexAppServer(browser: BrowserModel, agent: AgentModel) async throws
    -> [String]
  {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    let fm = FileManager.default
    let dir = browser.library.root.appendingPathComponent("codex-fake-" + UUID().uuidString.prefix(8))
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let fake = dir.appendingPathComponent("codex")
    let baseURL = dir.appendingPathComponent("codex-baseurl")
    for url in [fake, baseURL] {
      try fakeCodexAppServer.write(to: url, atomically: true, encoding: .utf8)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let log = dir.appendingPathComponent("received.jsonl")
    func sent(_ method: String) -> [[String: Any]] {
      ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }.filter { $0["method"] as? String == method }.map { $0["params"] as? [String: Any] ?? [:] }
    }
    func waitFor(_ seconds: Double = 15, _ condition: () -> Bool) async throws {
      for _ in 0..<Int(seconds * 10) where !condition() {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }

    let supported = await CodexAppServerProbe.probe(fake.path)
    try check(supported && CodexAppServerProbe.usable(fake.path), "Codex app-server probe reads the CLI's generated protocol schema")

    // Native fork.
    let source = "thread-source"
    let copy = try await CodexAppServer.shared(fake.path).fork(thread: source, cwd: nil)
    let forkParams = sent("thread/fork").first ?? [:]
    try check(
      copy.hasPrefix("thread-") && copy != source && forkParams["threadId"] as? String == source
        && (forkParams["config"] as? [String: Any] ?? [:]).keys.allSatisfy { !$0.contains("serein_browser") }
        && sent("thread/unsubscribe").contains { $0["threadId"] as? String == copy },
      "Continue in a copy forks the Codex thread natively, unloaded at once")
    try await waitFor(5) { CodexCatalog.shared.models.contains { $0.model == "fake-model" } }
    try check(
      CodexCatalog.shared.models.contains { $0.model == "fake-model" },
      "The app server's model list feeds the Codex model menu")

    // A user config that overrides the endpoint: Codex uses exec, and Settings says why.
    _ = await CodexAppServerProbe.probe(baseURL.path)
    let refusal = CodexAppServer.existing(baseURL.path)?.refusal ?? ""
    try check(
      !CodexAppServerProbe.usable(baseURL.path) && refusal.contains("openai_base_url")
        && refusal.hasPrefix("Codex runs through codex exec because your Codex config overrides"),
      "A user config that overrides openai_base_url keeps Codex on codex exec, with the reason")

    // An idle server stops, and the next start brings it back.
    let server = CodexAppServer.shared(fake.path)
    let limit = CodexAppServer.idleLimit
    server.terminate()
    try await waitFor(5) { !server.isRunning }
    CodexAppServer.idleLimit = 0.4
    try await server.ensureStarted()
    try await waitFor(5) { !server.isRunning }
    let stopped = !server.isRunning
    CodexAppServer.idleLimit = limit
    try await server.ensureStarted()
    try check(stopped && server.isRunning, "An idle Codex server stops, and the next start brings it back")

    for url in [fake, baseURL] { CodexAppServer.existing(url.path)?.terminate() }
    return results
  }
}

/// A stand-in for `codex app-server`, written from the generated schema. It logs every line it
/// receives next to itself so the checks can inspect what Serein sent.
let fakeCodexAppServer = #"""
#!/usr/bin/python3 -I
import json, os, sys, threading, time
here = os.path.dirname(os.path.abspath(__file__))
rogue = "rogue" in os.path.basename(__file__)
baseurl = "baseurl" in os.path.basename(__file__)
args = sys.argv[1:]
if args[:1] == ["exec"]:
    prompt = sys.stdin.read()
    path = args[args.index("--output-last-message") + 1] if "--output-last-message" in args else ""
    with open(os.path.join(here, "received.jsonl"), "a") as log:
        log.write(json.dumps({"method": "exec", "params": {"prompt": prompt, "arguments": args, "output": path, "at": time.time()}}) + "\n")
    # `resume forgotten-thread`: as Codex 0.165 does, a new session instead of the one asked for,
    # answering without the conversation unless Serein replaces it first.
    resumed = args[args.index("resume") + 1] if "resume" in args else None
    context = any("Previous conversation is context" in a for a in args)
    thread = "exec-new-thread" if resumed == "forgotten-thread" else ("exec-fresh-thread" if context else "exec-thread")
    print(json.dumps({"type": "thread.started", "thread_id": thread}), flush=True)
    if "FINISH" in prompt:
        # Narration, the answer, then the finish call; the turn closes 2 s later unless stopped.
        print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "Checking once."}}))
        print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "FINISHED_ANSWER"}}))
        print(json.dumps({"type": "item.completed", "item": {"type": "mcp_tool_call", "tool": "finish"}}), flush=True)
        time.sleep(2)
        with open(os.path.join(here, "finish-closed"), "w") as closed:
            closed.write(str(time.time()))
        print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "AFTER_FINISH"}}), flush=True)
        sys.exit(0)
    if "CONTEXT" in prompt:
        if resumed == "forgotten-thread":
            time.sleep(10)
        answer = "WITH_CONTEXT" if context else "NO_CONTEXT"
        print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": answer}}))
        if "--output-last-message" in args:
            with open(args[args.index("--output-last-message") + 1], "w") as output:
                output.write(answer)
        sys.exit(0)
    if "WAIT" in prompt:
        print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "Working on it"}}), flush=True)
        time.sleep(30)
    for text in ["I'll check the guidance.", "The skill folder is restricted.", "EXEC_FALLBACK\n\nSecond paragraph."]:
        print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": text}}))
    if "--output-last-message" in args:
        with open(args[args.index("--output-last-message") + 1], "w") as output:
            output.write("EXEC_FALLBACK\n\nSecond paragraph.")
    sys.exit(1 if "FAIL" in prompt else 0)
if args[:1] != ["app-server"]:
    sys.exit(1)
if "generate-json-schema" in args:
    out = args[args.index("--out") + 1]
    def schema(name, methods):
        with open(os.path.join(out, name), "w") as f:
            json.dump({"oneOf": [{"properties": {"method": {"enum": [m]}}} for m in methods]}, f)
    schema("ClientRequest.json", ["initialize", "config/read", "thread/start", "thread/resume",
        "thread/fork", "thread/unsubscribe", "turn/start", "turn/interrupt", "mcpServerStatus/list", "model/list",
        "experimentalFeature/list", "thread/read"])
    schema("ServerNotification.json", ["turn/started", "turn/completed", "item/started", "item/completed",
        "item/agentMessage/delta", "thread/tokenUsage/updated", "error"])
    schema("ServerRequest.json", ["item/fileChange/requestApproval", "item/commandExecution/requestApproval"])
    sys.exit(0)
log = open(os.path.join(here, "received.jsonl"), "a")
lock = threading.Lock()
def send(o):
    with lock:
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
def later(seconds, fn):
    t = threading.Timer(seconds, fn); t.daemon = True; t.start()
def note(method, params):
    send({"method": method, "params": params})
counter = [0]
configs = {}
cwds = {}
waiting = {}
approval = {}
user_servers = ["rogue.server"] if rogue else ["user_server"]
def new_id(prefix):
    counter[0] += 1
    return "%s-%d" % (prefix, counter[0])
def thread_result(tid, p, forked=None):
    sandbox = {"type": "workspaceWrite", "writableRoots": [p.get("cwd", "/")], "networkAccess": False} \
        if p.get("sandbox") == "workspace-write" else {"type": "readOnly", "networkAccess": False}
    return {"thread": {"id": tid, "forkedFromId": forked, "turns": [], "status": {"type": "idle"}},
            "model": "fake-model", "modelProvider": "openai", "cwd": p.get("cwd", "/"),
            "approvalPolicy": p.get("approvalPolicy", "never"),
            "approvalsReviewer": p.get("approvalsReviewer", "user"), "sandbox": sandbox}
def turn_obj(tid, status):
    return {"id": tid, "items": [], "itemsView": "notLoaded", "status": status, "error": None,
            "startedAt": 1, "completedAt": None, "durationMs": None}
def usage(thread, turn, total, last):
    def b(n):
        return {"totalTokens": n, "inputTokens": n, "cachedInputTokens": 0, "cacheWriteInputTokens": 0,
                "outputTokens": 0, "reasoningOutputTokens": 0}
    note("thread/tokenUsage/updated", {"threadId": thread, "turnId": turn,
        "tokenUsage": {"total": b(total), "last": b(last), "modelContextWindow": 1000}})
def delta(thread, turn, item, text):
    note("item/agentMessage/delta", {"threadId": thread, "turnId": turn, "itemId": item, "delta": text})
for line in sys.stdin:
    log.write(line); log.flush()
    try:
        m = json.loads(line)
    except Exception:
        continue
    method, mid, p = m.get("method"), m.get("id"), m.get("params") or {}
    if method is None and mid in approval:
        thread, turn = approval.pop(mid)
        decision = (m.get("result") or {}).get("decision", "none")
        note("item/completed", {"threadId": thread, "turnId": turn, "completedAtMs": 2,
            "item": {"type": "fileChange", "id": "fc-1", "changes": [{"path": cwds[thread] + "/notes.txt",
            "kind": {"type": "add"}, "diff": ""}], "status": "declined" if decision == "decline" else "completed"}})
        delta(thread, turn, "m-2", "approval=" + decision)
        note("turn/completed", {"threadId": thread, "turn": turn_obj(turn, "completed")})
        continue
    if mid is None:
        continue
    if method == "initialize":
        send({"id": mid, "result": {"userAgent": "fake/0", "codexHome": here, "platformFamily": "unix", "platformOs": "macos"}})
    elif method == "model/list":
        send({"id": mid, "result": {"data": [{"id": "fake-model", "model": "fake-model", "displayName": "Fake model",
            "description": "A test model.", "hidden": False}], "nextCursor": None}})
    elif method == "config/read":
        user = {"mcp_servers": {n: {"command": "x"} for n in user_servers}}
        if baseurl:
            user["openai_base_url"] = "http://127.0.0.1:9/v1"
        layers = [{"name": {"type": "sessionFlags"}, "version": "1", "config": {"notify": []}, "disabledReason": None},
                  {"name": {"type": "user", "file": here + "/config.toml", "profile": None}, "version": "1",
                   "config": user, "disabledReason": None}]
        if "projlayer" in (p.get("cwd") or ""):
            layers.append({"name": {"type": "project", "dotCodexFolder": p["cwd"] + "/.codex"}, "version": "1",
                           "config": {}, "disabledReason": None})
        send({"id": mid, "result": {"config": user, "origins": {}, "layers": layers if p.get("includeLayers") else None}})
    elif method == "experimentalFeature/list":
        c = configs.get(p.get("threadId"), {})
        names = ["hooks", "plugins", "apps", "multi_agent", "memories", "computer_use"]
        data = [{"name": n, "enabled": False} for n in names]
        data.append({"name": "shell_tool", "enabled": c.get("features.shell_tool", True) is not False})
        send({"id": mid, "result": {"data": data, "nextCursor": None}})
    elif method == "thread/read":
        send({"id": mid, "result": {"thread": {"id": p.get("threadId"), "turns": []}}})
    elif method in ("thread/start", "thread/resume", "thread/fork"):
        tid = p["threadId"] if method == "thread/resume" else new_id("thread")
        configs[tid] = p.get("config") or {}
        cwds[tid] = p.get("cwd") or here
        send({"id": mid, "result": thread_result(tid, p, p.get("threadId") if method == "thread/fork" else None)})
    elif method == "mcpServerStatus/list":
        c = configs.get(p.get("threadId"), {})
        data = [{"name": n, "pluginId": None, "tools": {},
                 "runtimeStatus": "disabled" if c.get("mcp_servers.%s.enabled" % n) is False else "connected"}
                for n in user_servers]
        if p.get("cursor") == "page-2":
            data = []
            if "mcp_servers.serein_browser.command" in c:
                data.append({"name": "serein_browser", "pluginId": None, "tools": {}, "runtimeStatus": "connected"})
            send({"id": mid, "result": {"data": data, "nextCursor": None}})
        else:
            send({"id": mid, "result": {"data": data, "nextCursor": "page-2"}})
    elif method == "thread/unsubscribe":
        send({"id": mid, "result": {"status": "unsubscribed"}})
    elif method == "turn/start":
        thread = p["threadId"]
        turn = new_id("turn")
        text = (p.get("input") or [{}])[0].get("text", "")
        send({"id": mid, "result": {"turn": turn_obj(turn, "inProgress")}})
        note("turn/started", {"threadId": thread, "turn": turn_obj(turn, "inProgress")})
        if text.startswith("EDIT"):
            for suffix, method in [("question", "item/tool/requestUserInput"), ("tool", "item/tool/call"),
                                   ("elicitation", "mcpServer/elicitation/request")]:
                send({"id": "input-" + suffix, "method": method,
                      "params": {"threadId": thread, "turnId": turn, "itemId": "input-" + suffix}})
            note("item/started", {"threadId": thread, "turnId": turn, "startedAtMs": 1,
                "item": {"type": "fileChange", "id": "fc-1", "changes": [{"path": cwds[thread] + "/notes.txt",
                "kind": {"type": "add"}, "diff": ""}], "status": "inProgress"}})
            approval["srv-1"] = (thread, turn)
            send({"id": "srv-1", "method": "item/fileChange/requestApproval", "params": {"threadId": thread,
                "turnId": turn, "itemId": "fc-1", "startedAtMs": 1, "reason": "Write notes.txt"}})
        elif text.startswith("WAIT"):
            waiting[thread] = (turn, None)
            delta(thread, turn, "m-1", "Working on it")
        elif text.startswith("SLOWEDIT"):
            folder = cwds[thread]
            open(os.path.join(folder, "early.txt"), "w").write("early\n")
            def late_writes(folder=folder, thread=thread, turn=turn):
                time.sleep(0.5); open(os.path.join(folder, "late1.txt"), "w").write("late\n")
                time.sleep(1.0); open(os.path.join(folder, "late2.txt"), "w").write("later\n")
                time.sleep(1.0)
                note("turn/completed", {"threadId": thread, "turn": turn_obj(turn, "interrupted")})
            waiting[thread] = (turn, late_writes)
            delta(thread, turn, "m-1", "Editing")
        else:
            note("item/reasoning/summaryTextDelta", {"threadId": thread, "turnId": turn, "itemId": "r-1", "delta": "Planning. "})
            note("item/reasoning/textDelta", {"threadId": thread, "turnId": turn, "itemId": "r-1", "delta": "Checking."})
            note("item/completed", {"threadId": thread, "turnId": turn, "item": {"type": "reasoning", "id": "r-1", "summary": ["Planning. "], "content": ["Checking."]}})
            note("item/started", {"threadId": thread, "turnId": turn,
                "item": {"type": "agentMessage", "id": "update-1", "text": "", "phase": "commentary"}})
            delta(thread, turn, "update-1", "I'll check the guidance.")
            note("item/completed", {"threadId": thread, "turnId": turn,
                "item": {"type": "agentMessage", "id": "update-1", "text": "I'll check the guidance.", "phase": "commentary"}})
            delta(thread, turn, "update-2", "The skill folder is restricted.")
            note("item/completed", {"threadId": thread, "turnId": turn,
                "item": {"type": "agentMessage", "id": "update-2", "text": "The skill folder is restricted.", "phase": "commentary"}})
            delta(thread, turn, "m-1", "Hello ")
            delta(thread, turn, "m-1", "from the app serve")
            note("item/completed", {"threadId": thread, "turnId": turn, "completedAtMs": 2,
                "item": {"type": "agentMessage", "id": "m-1", "text": "Hello from the app server", "phase": "final_answer"}})
            usage(thread, turn, 1500, 1500)
            usage(thread, turn, 2100, 600)
            note("turn/completed", {"threadId": thread, "turn": turn_obj(turn, "completed")})
    elif method == "turn/interrupt":
        thread = p.get("threadId")
        if thread in waiting and waiting[thread][0] == p.get("turnId"):
            turn, action = waiting.pop(thread)
            send({"id": mid, "result": {}})
            if action:
                threading.Thread(target=action, daemon=True).start()
            else:
                # The turn takes a moment to stop, as a real one does.
                later(1.5, lambda thread=thread, turn=turn: note("turn/completed",
                    {"threadId": thread, "turn": turn_obj(turn, "interrupted")}))
        else:
            send({"id": mid, "error": {"code": -32600, "message": "no active turn to interrupt"}})
    else:
        send({"id": mid, "error": {"code": -32600, "message": "unknown method " + str(method)}})
"""#
#endif
