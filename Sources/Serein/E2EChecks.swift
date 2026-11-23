#if DEBUG
import AppKit
import AVFoundation
import SereinCore
import WebKit

extension SmokeTest {
  /// One end-to-end pass over the features on this branch (`--verify-e2e`, scripts/e2e.py): a fake
  /// Claude Code reaches every tool through the real serein-browser-mcp and socket, pages come from
  /// loopback fixtures, and every card is a real approval card answered by FixtureApprovals in the
  /// order the scenario expects. No provider usage. The gate files keep one card open at a time;
  /// an unexpected card, prompt or alert fails the run.
  @MainActor static func e2e(browser: BrowserModel, agent: AgentModel) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
      // The report is written only at the end; a run that stops early still shows what passed.
      FileHandle.standardError.write(Data(("PASS: " + label + "\n").utf8))
    }
    func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(seconds)
      while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
    }
    let env = ProcessInfo.processInfo.environment
    guard FixtureApprovals.isAllowed(root: browser.library.root),
      let base = env["SEREIN_FIXTURE_URL"], base.hasSuffix("/"), let baseURL = URL(string: base),
      baseURL.scheme == "http", let host = baseURL.host, host == "127.0.0.1", env["SEREIN_CONNECT_PROXY"] != nil
    else { throw SereinError.invalid("FAIL: The E2E check needs a marked temporary library and loopback fixtures.") }
    guard let relay = RelayOrchestrator.shared else { throw SereinError.invalid("FAIL: Serein's assistant did not start") }

    // The fake CLI, its fixed answers and its log.
    let folder = browser.library.root.appendingPathComponent("e2e-check", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let cli = folder.appendingPathComponent("claude")
    try fakeE2EClaude.write(to: cli, atomically: true, encoding: .utf8)
    chmod(cli.path, 0o755)
    try JSONSerialization.data(withJSONObject: ["base": base]).write(to: folder.appendingPathComponent("config.json"))
    let log = folder.appendingPathComponent("log.jsonl")
    func records() -> [[String: Any]] {
      ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }
    }
    func record(_ key: String) -> [String: Any]? { records().last { $0[key] != nil } }

    // Settings the scenario turns on live only in the volatile argument domain, never in the
    // person's defaults.
    let defaults = UserDefaults.standard
    let argumentsBefore = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    func setArgument(_ key: String, _ value: Any?) {
      var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
      domain[key] = value
      defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
      NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }
    defer {
      defaults.setVolatileDomain(argumentsBefore, forName: UserDefaults.argumentDomain)
      NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }
    // Gate switches live in GateSettings, which a check never opens: these stay in memory and
    // are put back after the scenario.
    let gateKeys = [PageTools.enabledKey, PageTools.sitesKey, SiteRules.key, TaskDownloadPolicy.enabledKey]
    let gatesBefore = gateKeys.map { GateSettings.shared.object(forKey: $0) }
    func setGate(_ key: String, _ value: Any?) { GateSettings.shared.set(value, forKey: key) }
    defer { for (key, value) in zip(gateKeys, gatesBefore) { setGate(key, value) } }

    // Finished tasks start no report turn, so every Relay turn below is one the scenario sent.
    setArgument(RelayOrchestrator.reportsKey, false)
    // Agent tabs follow Dark pages too; the replay frames are measured on the page as served.
    setArgument("serein.darkPages", false)
    // The most permissive level, so every card below is one the gates ask whatever it is set to.
    agent.pin(.claude, executable: cli.path)
    var alerts: [String] = []
    let networkBefore = relay.networkOnline
    relay.autopilotOverride = true
    relay.learnsOverride = false
    relay.proactiveOverride = .off
    relay.restyleOverride = false
    relay.alertOverride = { alerts.append($0); return false }
    relay.networkOnline = { true }
    defer {
      relay.autopilotOverride = nil
      relay.learnsOverride = nil
      relay.proactiveOverride = nil
      relay.restyleOverride = nil
      relay.alertOverride = nil
      relay.networkOnline = networkBefore
    }
    let approvals = try FixtureApprovals(browser: browser, agent: agent)
    defer { approvals.close() }
    // Phase 0: only the fake CLI, the real cards, the marked library, loopback fixtures.
    try check(agent.available.count == 1 && agent.available[.claude] == cli.path && relay.confirmOverride == nil,
              "E2E-01 Only the fake Claude Code is available, cards are real, the library is marked and the fixtures are loopback")

    // Allow all: the person's task sends and submits with no card, the password goes only through
    // the secure card the person submits, its answer reaches the running task as a steer, the task ends
    // done, and the value reaches no model or file.
    do {
      let canary = "E2E-secret-5b81-Qx7"
      let levelBefore = GateSettings.shared.object(forKey: RelayOrchestrator.autopilotKey)
      relay.autopilotOverride = nil
      setGate(RelayOrchestrator.autopilotKey, ApprovalLevel.proactive.storedValue)
      defer {
        setGate(RelayOrchestrator.autopilotKey, levelBefore)
        relay.autopilotOverride = true
      }
      let level = relay.level
      var cardTitle = ""
      // Serein's own assistant has no tabs (AssistantWeb): the person starts the web task here.
      agent.clear()
      agent.provider = .claude
      agent.model = ""
      agent.mode = .research
      agent.allowActions = true
      let allowID = agent.conversationID
      try await approvals.perform(expecting: [], timeout: 60) {
        agent.send("E2E ALLOW ALL child")
        try await waitFor(45) { !browser.secureCards.open.isEmpty }
        guard let card = browser.secureCards.open.first else {
          throw SereinError.invalid("FAIL: No secure card rose [status: \(agent.status), error: \(relay.lastError ?? "none"), held: \(relay.held.map(\.message.reason)), working: \(relay.working), provider: \(relay.provider.name), tail: \(relay.transcript.suffix(3).map(\.text)), run: \(agent.hub.latest(for: allowID).map { "\($0.record.outcome.rawValue) \($0.record.summary ?? "") \($0.record.attentionDetail ?? "") \($0.transcript.suffix(3).map(\.text))" } ?? "none")]: \(records().suffix(6))")
        }
        cardTitle = card.title
        guard browser.secureCards.submit(card.id, SecretEntry(key: canary)) == nil else {
          throw SereinError.invalid("FAIL: The secure card refused the entry")
        }
        try await waitFor(50) { record("allow_done") != nil && agent.hub.run(for: allowID) == nil }
      }
      let done = record("allow_done")?["allow_done"] as? [String: Any] ?? [:]
      let errors = done["errors"] as? [Any] ?? ["no steps"]
      let page = done["page"] as? String ?? ""
      let run = agent.hub.latest(for: allowID)
      let outcome = run?.record.outcome.rawValue ?? "none"
      let root = browser.library.root.path
      let needle = Data(canary.utf8)
      var leaks = ((try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? []).filter {
        (try? Data(contentsOf: URL(fileURLWithPath: root + "/" + $0)))?.range(of: needle) != nil
      }
      let memory = (relay.transcript.map(\.text) + (run?.transcript.map(\.text) ?? []) + relay.approvals.map(\.detail))
      if memory.contains(where: { $0.contains(canary) }) { leaks.append("memory") }
      try check(level == .proactive && cardTitle == "Sign in to \(host)" && done["asked"] as? String == "asked"
                && (done["heard"] as? String ?? "").contains("I answered the secure card for \(host): filled")
                && errors.isEmpty && page.contains("Sent: E2E hello") && page.contains("Signed in with \(canary.count) characters")
                && outcome == RunRecord.Outcome.done.rawValue && leaks.isEmpty && browser.secureCards.open.isEmpty,
                "E2E-53 At Allow all a task sends and submits with no card, the person fills the password in the secure card, the task ends done, and the value is in no tool result, transcript, record or log [level: \(level.rawValue), card: \(cardTitle), errors: \(errors.count), outcome: \(outcome), leaks: \(leaks)]")
    }

    return results
  }
}

/// The fake Claude Code for `--verify-e2e`. It reaches Serein's tools only through the real
/// serein-browser-mcp named in `--mcp-config`, waits for the check's gate file before each step
/// that can open a card, and logs every step to log.jsonl. A run with no MCP server is a helper
/// call and fails closed; a prompt it does not know is logged as unexpected and answered briefly.
private let fakeE2EClaude = #"""
#!/usr/bin/python3 -I
import json, os, select, subprocess, sys, time
here = os.path.dirname(os.path.abspath(sys.argv[0]))
args = sys.argv[1:]
if args == ["--version"]:
    print("2.1.325 (Claude Code)"); sys.exit(0)
if args[:2] == ["auth", "status"]:
    print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty"})); sys.exit(0)
with open(os.path.join(here, "config.json")) as f:
    config = json.load(f)
BASE = config["base"]
log = open(os.path.join(here, "log.jsonl"), "a")
def record(obj):
    log.write(json.dumps(obj) + "\n"); log.flush()
def arg(name):
    if name not in args:
        return ""
    i = args.index(name)
    return args[i + 1] if i + 1 < len(args) else ""
stream = arg("--input-format") == "stream-json"
system_file = arg("--append-system-prompt-file")
system = open(system_file).read() if system_file else arg("--append-system-prompt")
session = "e2e-%d" % os.getpid()
relay = any(n in system for n in ("You are the user's personal assistant in Serein", "You are Serein, the user's personal assistant", "You are Relay"))
def next_prompt():
    if not stream:
        return sys.stdin.read()
    # One stdin line per message; the start-up request comes first.
    while True:
        line = sys.stdin.readline()
        if not line:
            return None
        message = json.loads(line)
        if message.get("type") == "control_request":
            print(json.dumps({"type": "control_response", "response": {"subtype": "success", "request_id": message["request_id"],
                "response": {"current_permission_mode": "dontAsk"}}}), flush=True)
            continue
        if message.get("type") != "user":
            continue
        print(json.dumps({"type": "system", "subtype": "init", "session_id": session, "permissionMode": "dontAsk"}), flush=True)
        # Claude Code with --replay-user-messages says when it read a line.
        print(json.dumps({"type": "user", "message": message["message"], "uuid": message.get("uuid"), "isReplay": True}), flush=True)
        content = message["message"]["content"]
        return "".join(b.get("text", "") for b in content if b.get("type") == "text") if isinstance(content, list) else content
record({"cli_boot": [a for a in args if a.startswith("--")]})
if "--mcp-config" not in args:
    record({"no_mcp": [a for a in args if a.startswith("--")]})
    sys.exit(1)
try:
    servers = json.loads(arg("--mcp-config") or "{}").get("mcpServers", {})
except ValueError:
    servers = {}
if not servers:
    # A helper call (routing, a title, a judgement): nothing in this check needs one.
    prompt = next_prompt() or ""
    record({"helper": prompt[:120]})
    sys.exit(1)
server = servers.get("serein_browser") or list(servers.values())[0]
mcp = subprocess.Popen([server["command"]] + server.get("args", []), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
n = [0]
def rpc(method, params):
    n[0] += 1
    mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n[0], "method": method, "params": params}) + "\n"); mcp.stdin.flush()
    return json.loads(mcp.stdout.readline())
def call(name, arguments):
    r = rpc("tools/call", {"name": name, "arguments": arguments})["result"]
    text = r["content"][0]["text"]
    if r.get("isError"):
        return {"error": text}
    try:
        return json.loads(text)
    except ValueError:
        return {"text": text}
rpc("initialize", {})
names = [t["name"] for t in rpc("tools/list", {})["result"]["tools"]]
ALIAS = {"open_tab": "open", "list_tabs": "tabs", "navigate": "go", "fill": "type"}
def tool(name, arguments):
    return call(name if name in names else ALIAS.get(name, name), arguments)
def page_of(r):
    if isinstance(r, dict) and isinstance(r.get("page"), dict):
        return r["page"]
    return r if isinstance(r, dict) else {}
def ref(page, label):
    rows = page.get("elements") or []
    for row in rows:
        if (row.get("label") or "").strip() == label and row.get("ref"):
            return row["ref"]
    for row in rows:
        if label in (row.get("label") or "") and row.get("ref"):
            return row["ref"]
    return ""
def answer(text):
    print(json.dumps({"type": "assistant", "parent_tool_use_id": None, "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}), flush=True)
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "stop_reason": "end_turn", "result": text, "session_id": session,
        "usage": {"input_tokens": 10, "output_tokens": 5}, "queued_turn_count": 0}), flush=True)
def relay_turn(prompt, context):
    record({"unexpected": prompt[:500], "relay": True})
    return answer("OK.")

def child_turn(prompt):
    if "E2E ALLOW ALL child" in prompt:
        tab = page_of(tool("open_tab", {"url": BASE + "e2e/allow"})).get("tab", "")
        page = page_of(tool("read", {"tab": tab}))
        typed = tool("fill", {"tab": tab, "ref": ref(page, "Message"), "text": "E2E hello"})
        sent = tool("click", {"tab": tab, "ref": ref(page_of(typed), "Send")})
        page = page_of(tool("read", {"tab": tab}))
        secret = next((row.get("ref") for row in page.get("elements") or [] if row.get("secure") == "password"), "") or ref(page, "Password")
        asked = tool("secure_card", {"tab": tab, "ref": secret})
        record({"allow_asked": {"ref": secret, "result": asked}})
        # The card answers `asked` at once; the person's answer comes into this turn as a steer.
        heard = next_prompt() if stream and select.select([sys.stdin], [], [], 40)[0] else None
        record({"allow_heard": heard})
        signed = tool("click", {"tab": tab, "ref": ref(page_of(tool("read", {"tab": tab})), "Sign in")})
        after = page_of(tool("read", {"tab": tab}))
        finished = tool("finish", {"outcome": "done", "summary": "Sent the note and signed in.", "result_tab": tab})
        steps = [typed, sent, asked, signed, after, finished]
        record({"allow_steps": steps})
        record({"allow_done": {"page": after.get("text", ""), "asked": asked.get("result"), "heard": heard or "",
                               "errors": [s.get("error") for s in steps if isinstance(s, dict) and s.get("error")]}})
        return answer("Sent the note and signed in.")
    record({"unexpected": prompt[:500], "relay": False})
    return answer("OK.")

turns = 0
while True:
    prompt = next_prompt()
    if prompt is None:
        break
    turns += 1
    try:
        if relay:
            relay_turn(prompt, prompt + ("\n" + system if turns == 1 else ""))
        else:
            child_turn(prompt)
    except Exception as error:
        record({"unexpected": "fixture error: %r" % (error,)})
        answer("The fixture stopped.")
    if not stream:
        break
"""#
#endif
