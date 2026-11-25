#if DEBUG
import Darwin
import Foundation
import SereinCore
@testable import SereinEngines

/// Grok over ACP as the review measured it (grok 1.0.88): asks with no `locations`, a refused ask
/// ending the prompt `cancelled`, model retries on `_x.ai/session_notification`, and a shell
/// child in its own process group. Through Engines and the real process host.
extension AssistantCoreChecks {
  static func grokACPFixes(_ check: Check) throws {
    let driver = GrokDriver()
    let rig = try ACPCheckRig(driver, name: "grok")
    defer { try? rig.finish() }
    try grokFake(rig.dir).write(to: rig.executable, atomically: true, encoding: .utf8)
    func reason(_ events: [EngineEvent]) -> StopReason? {
      for case .ended(let end) in events { return end.stopReason }
      return nil
    }

    for level in [ProjectLevel.review, .edits, .commands, .full] {
      let contract = try driver.contract(for: rig.request("hi", thread: "argv", level: level), network: .open)
      try check(!contract.arguments.contains("auto"), "Grok: \(level) never launches Grok's own auto mode")
    }
    let commands = try driver.contract(for: rig.request("hi", thread: "argv", level: .commands), network: .open)
    try check(commands.arguments.starts(with: ["--permission-mode", "acceptEdits"]), "Grok: Commands asks Serein like Edits")

    _ = try rig.turn(rig.request("NOLOC-IN", thread: "noloc", level: .edits))
    try check(rig.lines("answers").last == "yes", "Grok: an in-folder edit with no locations is allowed from its file_path")
    _ = try rig.turn(rig.request("NOLOC-META", thread: "noloc", level: .edits))
    try check(rig.lines("answers").last == "yes", "Grok: an in-folder edit named only in _meta is allowed")
    let (outside, _) = try rig.turn(rig.request("NOLOC-OUT", thread: "noloc", level: .edits))
    let card = outside.compactMap { if case .declined(let value) = $0 { return value } else { return nil } }.first
    try check(rig.lines("answers").last == "no" && card?.target.contains("hosts") == true,
      "Grok: an outside edit named only in _meta is refused and its card names the file")

    let (refused, _) = try rig.turn(rig.request("REFUSED", thread: "refused", level: .edits))
    let ended = reason(refused)
    try check(ended.map { if case .declined(let why) = $0 { return why.contains("Edit /etc/hosts") } else { return false } } == true,
      "Grok: a prompt cancelled after a refusal ends declined naming the tool, not stopped")

    var first = rig.request("hello", thread: "model", model: "model-one")
    _ = try rig.turn(first)
    let launches = rig.lines("starts").count
    first.model = "model-two"
    first.effort = "high"
    _ = try rig.turn(first)
    let config = rig.lines("config")
    try check(rig.lines("starts").count == launches && config.contains("session/set_model - model-two")
      && config.contains("session/set_config_option reasoning_effort high"),
      "Grok: a model and effort change on a warm thread is sent before the prompt")

    let (retried, _) = try rig.turn(rig.request("RETRY", thread: "retry"))
    let notices = retried.filter { if case .notice(let text) = $0 { return text.contains("retrying its model") } else { return false } }
    try check(notices.count == 4, "Grok: each model retry is shown")
    try check(endText(retried, contains: "error decoding response body") && reason(retried) != .stopped && rig.log("cancel").contains("RETRY"),
      "Grok: after the retry limit Serein cancels and the turn ends failed with Grok's reason, from a failed try's message too")

    let (stopped, _) = try rig.turn(rig.request("HANG", thread: "hang"), stop: true)
    let child = pid_t(rig.log("child").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    defer { if child > 0 { kill(child, SIGKILL) } }
    let deadline = Date().addingTimeInterval(3)
    while child > 0, kill(child, 0) == 0, Date() < deadline { usleep(20_000) }
    try check(reason(stopped) == .stopped && rig.log("cancel").contains("HANG"), "Grok: Stop sends session/cancel before input closes")
    try check(child > 0 && kill(child, 0) != 0, "Grok: Stop ends a tool child that left the CLI's process group")

    try check(HarnessPermissionRequest.acpKind("other", title: "notes serein_browser copy") == .other
      && HarnessPermissionRequest.acpKind("other", title: "serein_browser__read_page") == .browser,
      "Only Serein's exact browser server name counts as the browser")
  }

  private static func endText(_ events: [EngineEvent], contains text: String) -> Bool {
    for case .ended(let end) in events {
      switch end.stopReason {
      case .failed(let why), .offline(let why): return why.contains(text)
      default: return false
      }
    }
    return false
  }

  private static func grokFake(_ dir: URL) -> String {
    #"""
    #!/usr/bin/env python3
    import json, os, queue, subprocess, sys, threading
    DIR = "\#(dir.path)"
    def append(name, text):
        with open(os.path.join(DIR, name), "a") as f: f.write(text + "\n")
    append("starts", " ".join(sys.argv[1:]))
    inbox = queue.Queue()
    def reader():
        for line in sys.stdin: inbox.put(json.loads(line))
        inbox.put(None)
    threading.Thread(target=reader, daemon=True).start()
    def read(timeout=None):
        try: m = inbox.get(timeout=timeout)
        except queue.Empty: return {}
        if m is None: os._exit(0)
        return m
    def send(obj): sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
    def ok(i, result): send({"jsonrpc": "2.0", "id": i, "result": result})
    def note(method, sid, u): send({"jsonrpc": "2.0", "method": method, "params": {"sessionId": sid, "update": u}})
    def text(sid, t): note("session/update", sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}})
    held = []
    def wait_cancel(body, seconds):
        while True:
            m = read(seconds)
            if not m: return False
            if m.get("method") == "session/cancel": append("cancel", body); return True
            held.append(m)
    OPTIONS = [{"optionId": "yes-always", "kind": "allow_always", "name": "Always"},
        {"optionId": "yes", "kind": "allow_once", "name": "Yes"}, {"optionId": "no", "kind": "reject_once", "name": "No"}]
    def ask(sid, call):
        send({"jsonrpc": "2.0", "id": 7000, "method": "session/request_permission",
            "params": {"sessionId": sid, "toolCall": call, "options": OPTIONS}})
        while True:
            m = read()
            if m.get("id") == 7000 and "method" not in m:
                answer = ((m.get("result") or {}).get("outcome") or {}).get("optionId", "cancelled")
                append("answers", answer); return answer
            held.append(m)
    def play(i, sid, body):
        if body.endswith("NOLOC-IN"):
            ask(sid, {"toolCallId": "w1", "kind": "edit", "title": "Write `inside.txt`",
                "rawInput": {"variant": "Write", "file_path": os.path.join(DIR, "inside.txt"), "content": "hi"}})
        elif body.endswith("NOLOC-META"):
            ask(sid, {"toolCallId": "w4", "kind": "edit", "title": "Write `meta.txt`",
                "_meta": {"x.ai/tool": {"name": "write", "input": {"path": os.path.join(DIR, "meta.txt")}}}})
        elif body.endswith("NOLOC-OUT"):
            ask(sid, {"toolCallId": "w2", "kind": "edit", "title": "Write `/etc/hosts`",
                "_meta": {"x.ai/tool": {"name": "write", "input": {"path": "/etc/hosts"}}}})
        elif body.endswith("REFUSED"):
            ask(sid, {"toolCallId": "w3", "kind": "edit", "title": "Edit /etc/hosts", "locations": [{"path": "/etc/hosts"}]})
            ok(i, {"stopReason": "cancelled", "_meta": {"cancellationCategory": "PermissionRejected",
                "cancellationContext": {"tool_name": "write", "reason": "User rejected the execution"}}}); return
        elif body.endswith("RETRY"):
            for n in range(1, 4):
                note("_x.ai/session_notification", sid, {"sessionUpdate": "retry_state", "type": "retrying", "attempt": n,
                    "max_retries": 15, "error_type": "http", "reason": "tcp connect error: Connection refused (os error 61)"})
            # As Grok 1.0.89 recorded it: a failed try names its error `message`.
            note("_x.ai/session_notification", sid, {"sessionUpdate": "retry_state", "type": "failed", "error_type": "http",
                "message": "reqwest error stream: error decoding response body"})
            wait_cancel(body, 3)
            ok(i, {"stopReason": "cancelled"}); return
        elif body.endswith("HANG"):
            child = subprocess.Popen(["/bin/sleep", "300"], start_new_session=True)
            append("child", str(child.pid))
            note("session/update", sid, {"sessionUpdate": "tool_call", "toolCallId": "t-hang", "title": "Run sleep 300",
                "kind": "execute", "status": "in_progress", "rawInput": {"command": "sleep 300"}})
            if wait_cancel(body, 30): child.kill()
            ok(i, {"stopReason": "cancelled"}); return
        text(sid, "hello")
        ok(i, {"stopReason": "end_turn"})
    count = [0]
    while True:
        m = held.pop(0) if held else read()
        method, i, p = m.get("method"), m.get("id"), m.get("params") or {}
        if method == "initialize":
            ok(i, {"protocolVersion": 1, "agentCapabilities": {"loadSession": True, "promptCapabilities": {"image": True}}, "authMethods": []})
        elif method == "session/new":
            count[0] += 1
            ok(i, {"sessionId": "g-%d-%d" % (os.getpid(), count[0])})
        elif method in ("session/set_model", "session/set_config_option"):
            append("config", "%s %s %s" % (method, p.get("configId", "-"), p.get("modelId") or p.get("value")))
            ok(i, None)
        elif method == "session/prompt":
            play(i, p["sessionId"], "".join(b.get("text", "") for b in p["prompt"] if b.get("type") == "text"))
        elif i is not None and method:
            send({"jsonrpc": "2.0", "id": i, "error": {"code": -32601, "message": "Method not found"}})
    """#
  }
}
#endif
