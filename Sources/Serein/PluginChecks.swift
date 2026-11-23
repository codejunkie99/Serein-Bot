#if DEBUG
import CryptoKit
import Foundation
import Network
import SereinCore

extension SmokeTest {
  /// Plugins end to end, no provider usage: the bundled example plugin (examples/plugins/
  /// notes-demo) is installed, reviewed and turned on; a fake Claude Code in Relay's run reaches
  /// its skills and tools through the real serein-browser-mcp and socket; risks decide what runs
  /// on its own and what asks; a probe plugin shows the sandbox closes the home folder, other
  /// writes and the network; a changed tool schema is refused until reviewed again.
  /// OAuth 2.1 sign-in against a real (loopback) server: discovery, dynamic registration, a
  /// PKCE-checked token exchange through the automated browser, then the tokens authorize a
  /// real remote MCP call, and sign-out clears the Keychain.
  @MainActor static func oauthLive() async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
    }
    let server = try OAuthTestServer()
    defer { server.stop() }
    let manifest = try PluginManifest.decode(Data("""
      {"id":"dev.example.livemcp","name":"Live","version":"1.0.0","description":"d",
       "mcp":{"url":"\(server.base)/mcp","auth":"oauth2"},"tools":[{"name":"search","risk":"read"}]}
      """.utf8))
    #if DEBUG
    PluginSignIn.browserOverride = { authorize in
      let (data, _) = try await URLSession.shared.data(from: authorize)
      let callback = try JSONDecoder().decode([String: String].self, from: data)["callback"]!
      return URL(string: callback)!
    }
    #endif
    var signInError: String?
    do { try await PluginSignIn.run(manifest: manifest) } catch { signInError = error.localizedDescription }
    #if DEBUG
    PluginSignIn.browserOverride = nil
    #endif
    try check(signInError == nil, signInError ?? "OAuth sign-in against the local server")
    let tokens = PluginHost.oauthTokens(plugin: "dev.example.livemcp")
    try check(tokens?.accessToken == "at-live-123", "The token exchange stored the access token")
    try check(tokens?.clientID == "test-client", "Dynamic registration returned the client id")
    let bearer = try await PluginHost.bearer(plugin: "dev.example.livemcp")
    try check(bearer == "at-live-123", "The bearer token answers from the Keychain")
    let result = try PluginSession.runRemote(
      url: URL(string: "\(server.base)/mcp")!, headers: ["Authorization": "Bearer \(bearer)"], timeout: 15
    ) { rpc in try rpc("tools/list", [:]) }
    try check((result["tools"] as? [[String: Any]])?.first?["name"] as? String == "search",
      "The signed-in tokens authorize a remote MCP call")
    PluginSignIn.signOut(manifest)
    try check(PluginHost.oauthTokens(plugin: "dev.example.livemcp") == nil, "Sign out clears the Keychain")
    return results
  }
  @MainActor static func plugins(browser: BrowserModel, agent: AgentModel) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
    }
    func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(seconds)
      while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
    }
    let proxied = PluginSandbox.profile(
      home: FileManager.default.homeDirectoryForCurrentUser, plugin: URL(fileURLWithPath: "/tmp"), data: nil,
      network: false, proxyPort: 8443)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    compile.arguments = ["-p", proxied, "/usr/bin/true"]
    compile.standardError = FileHandle.nullDevice
    try compile.run()
    compile.waitUntilExit()
    try check(compile.terminationStatus == 0, "A plugin sandbox that allows only its egress proxy compiles and runs")
    let host = PluginHost.shared
    let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../examples/plugins/notes-demo").standardizedFileURL
    let package = try host.install(from: example)
    try check(package.id == "dev.serein.notes-demo" && package.skills.map(\.name) == ["daily-review"],
              "The example plugin installs with its manifest and skill")
    try check(!host.isEnabled(package) && host.relayTools.isEmpty, "A tool plugin stays off until reviewed")
    try await host.enable(package)
    let names = host.relayTools.compactMap { $0["name"] as? String }.sorted()
    try check(names == ["dev_serein_notes_demo__add_note", "dev_serein_notes_demo__clear_notes", "dev_serein_notes_demo__list_notes"],
              "Turning it on starts its server in the sandbox and pins its three tools")

    // Relay's run reaches skills and plugin tools through the real helper.
    let folder = browser.library.root.appendingPathComponent("plugin-check", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let cli = folder.appendingPathComponent("claude")
    try fakePluginClaude.write(to: cli, atomically: true, encoding: .utf8)
    chmod(cli.path, 0o755)
    let log = folder.appendingPathComponent("log.jsonl")
    func record(_ key: String) -> Any? {
      ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }.last { $0[key] != nil }?[key]
    }
    agent.pin(.claude, executable: cli.path)
    guard let relay = RelayOrchestrator.shared else { throw SereinError.invalid("FAIL: Relay did not start") }
    let autopilotBefore = relay.autopilotOverride
    let confirmBefore = relay.confirmOverride
    let chatBefore = relay.chatOnScreen
    let pluginThread = relay.threadID
    relay.autopilotOverride = false
    relay.confirmOverride = nil
    relay.chatOnScreen = { true }
    defer {
      for approval in relay.approvals where approval.threadID == pluginThread { approval.answer(.no) }
      if let run = relay.run, run.spec.threadID == pluginThread { agent.hub.stop(run) }
      relay.autopilotOverride = autopilotBefore
      relay.confirmOverride = confirmBefore
      relay.chatOnScreen = chatBefore
    }
    var asked: [String] = []
    let data = browser.library.root.appendingPathComponent("plugin-data/dev.serein.notes-demo/notes.json")
    func answer(_ tool: String, detail: String, more: String? = nil,
                resultKey: String, with answer: ApprovalGate.HumanAnswer) async throws {
      try await waitFor(40) { !relay.approvals.isEmpty || record(resultKey) != nil || relay.run == nil }
      let title = "Allow “Notes demo” to “\(tool.replacingOccurrences(of: "_", with: " "))”?"
      guard relay.approvals.count == 1, let approval = relay.approvals.first,
        approval.title == title, approval.detail == detail, approval.button == "Allow",
        approval.threadID == pluginThread, approval.app == nil,
        approval.more == more, approval.moreName == "the details", record(resultKey) == nil,
        tool != "add_note" || !FileManager.default.fileExists(atPath: data.path)
      else {
        throw SereinError.invalid("FAIL: \(tool) did not wait for its exact plugin approval: \(relay.approvals.map(\.title))")
      }
      asked.append(approval.title)
      approval.answer(answer)
    }
    relay.ask("Use my plugins.")
    try await waitFor(5) { relay.run != nil }
    // Writes change state; self-declared reads without structural evidence remain unknown.
    // Answer only the exact fixture cards through the same path as a person's choice.
    try await answer("add_note", detail: "It changes what Notes demo keeps.", more: "text: buy milk",
                     resultKey: "added", with: .yes)
    try await answer("list_notes", detail: "It reads from Notes demo. Nothing is changed.",
                     resultKey: "listed", with: .yes)
    try await answer("clear_notes", detail: "It deletes something.", resultKey: "cleared", with: .no)
    try await waitFor(60) { relay.run == nil }
    try check(relay.run == nil, "The plugin turn finishes after the person answers its cards")
    let listed = record("tools") as? [String] ?? []
    try check(Set(names).isSubset(of: listed) && listed.contains("skill_read"), "Relay's CLI lists the plugin tools and skill tools")
    let skills = (record("skills") as? [String: Any])?["skills"] as? [[String: Any]] ?? []
    try check(skills.contains { $0["name"] as? String == "daily-review" }, "skill_list shows the installed skill")
    try check(skills.first?["name"] as? String == "design-your-look", "skill_list includes Serein's own design-your-look skill first")
    let read = record("skill") as? [String: Any]
    try check((read?["instructions"] as? String)?.contains("Daily review") == true, "skill_read returns its instructions")
    try check((record("added") as? String)?.contains("Saved. 1 notes.") == true,
              "A write tool waits for its exact approval under Every step, then writes the note")
    try check((record("listed") as? String)?.contains("buy milk") == true,
              "A self-declared read waits for approval, then returns the plugin's answer")
    try check((record("cleared") as? String)?.contains("declined") == true && asked.contains { $0.contains("clear notes") },
              "A delete tool asks first, and a decline stops it")
    try check((try? String(contentsOf: data, encoding: .utf8))?.contains("buy milk") == true,
              "The plugin wrote only to its own data folder")
    let history = browser.library.root.appendingPathComponent("agent-history")
    try check(FileManager.default.fileExists(atPath: history.path), "Plugin calls go through agent history")

    // Only Relay's run may call plugin tools.
    let plain = try browser.beginTask(isolated: true, allowActions: true, includeCurrent: false)
    do {
      _ = try await browser.handle(["task": plain.capability.task, "token": plain.capability.token,
                                    "name": "dev_serein_notes_demo__list_notes", "arguments": [:]])
      try check(false, "Other tasks are refused plugin tools")
    } catch {
      try check(error.localizedDescription.contains("only available to Serein"), "Other tasks are refused plugin tools")
    }
    browser.endTask(plain.capability.task)

    // The sandbox, from inside a plugin.
    let probeSource = folder.appendingPathComponent("probe-src", isDirectory: true)
    try FileManager.default.createDirectory(at: probeSource, withIntermediateDirectories: true)
    try probeManifest.write(to: probeSource.appendingPathComponent(PluginManifest.fileName), atomically: true, encoding: .utf8)
    try probeServer.write(to: probeSource.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    let probe = try host.install(from: probeSource)
    try await host.enable(probe)
    let content = try await host.call("dev_serein_probe__probe", ["home": NSHomeDirectory()])
    let text = (content["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    let outcome = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]) ?? [:]
    try check(outcome["home_read"] == "denied", "The sandbox closes the user's home folder (\(outcome["home_read"] ?? text))")
    try check(outcome["plugin_write"] == "denied", "A plugin cannot change its own installed files")
    try check(outcome["data_write"] == "ok", "A plugin may write in its data folder")
    try check(outcome["network"] == "denied", "A plugin without listed hosts has no network (\(outcome["network"] ?? ""))")

    // A schema that changed after review is refused.
    let installedServer = probe.folder.appendingPathComponent("server.py")
    let changed = try String(contentsOf: installedServer, encoding: .utf8).replacingOccurrences(of: "Probe the sandbox.", with: "Now does more.")
    try changed.write(to: installedServer, atomically: true, encoding: .utf8)
    do {
      _ = try await host.call("dev_serein_probe__probe", ["home": NSHomeDirectory()])
      try check(false, "A changed tool is refused until reviewed")
    } catch {
      try check(error.localizedDescription.contains("changed"), "A changed tool is refused until reviewed")
    }
    try host.remove(probe)
    try host.remove(package)
    try check(host.packages.isEmpty && host.relayTools.isEmpty, "Removing plugins removes their tools")

    // From GitHub, pinned to one commit, each file checked against the tree.
    var commit = String(repeating: "c", count: 40)
    var files: [String: Data] = [:]
    for name in ["serein-plugin.json", "server.py", "README.md", "skills/daily-review/SKILL.md"] {
      files["plugins/notes/" + name] = try Data(contentsOf: example.appendingPathComponent(name))
    }
    var tampered = false
    PluginHost.fetchOverride = { url in
      let s = url.absoluteString
      if s == "https://api.github.com/repos/acme/tools/commits/main" { return Data(jsonString(["sha": commit]).utf8) }
      if s.hasPrefix("https://api.github.com/repos/acme/tools/git/trees/\(commit)") {
        let tree = files.map { ["path": $0.key, "type": "blob", "mode": "100644", "sha": GitHubPluginSource.blobID($0.value), "size": $0.value.count] as [String: Any] }
        return Data(jsonString(["sha": commit, "tree": tree, "truncated": false]).utf8)
      }
      let prefix = "https://raw.githubusercontent.com/acme/tools/\(commit)/"
      if s.hasPrefix(prefix), let data = files[String(s.dropFirst(prefix.count))] {
        return tampered && s.hasSuffix("server.py") ? Data("print('changed')".utf8) : data
      }
      throw SereinError.invalid("unexpected \(s)")
    }
    defer { PluginHost.fetchOverride = nil }
    let fetched = try await host.fetch("https://github.com/acme/tools/tree/main/plugins/notes")
    let link = "https://github.com/acme/tools/tree/main/plugins/notes"
    let fromGitHub = try host.install(from: fetched.folder, source: fetched.source, link: link, commit: fetched.commit)
    try? FileManager.default.removeItem(at: fetched.folder)
    try check(fromGitHub.id == "dev.serein.notes-demo" && host.states[fromGitHub.id]?.source == "acme/tools/plugins/notes@cccccccccccc",
              "A GitHub link installs the plugin at its commit and remembers where it came from")
    try await host.enable(fromGitHub)
    try check(host.relayTools.count == 3, "A plugin from GitHub turns on like a local one")
    try check(try await host.checkUpdate(fromGitHub) == nil, "The same commit is up to date")
    commit = String(repeating: "d", count: 40)
    let manifestKey = "plugins/notes/serein-plugin.json"
    files[manifestKey] = Data(String(decoding: files[manifestKey]!, as: UTF8.self)
      .replacingOccurrences(of: "\"version\": \"1.0.0\"", with: "\"version\": \"1.1.0\"").utf8)
    guard let newer = try await host.checkUpdate(fromGitHub) else { throw SereinError.invalid("FAIL: no update found") }
    try host.update(fromGitHub, with: newer)
    try? FileManager.default.removeItem(at: newer.folder)
    let updated = host.packages.first { $0.id == fromGitHub.id }
    try check(updated?.manifest?.version == "1.1.0" && host.states[fromGitHub.id]?.commit == commit
              && host.states[fromGitHub.id]?.source == "acme/tools/plugins/notes@dddddddddddd",
              "A newer commit updates the plugin and records it")
    try check(host.relayTools.isEmpty && host.states[fromGitHub.id]?.enabled == false,
              "An updated tool plugin is off until its tools are reviewed again")
    try host.remove(updated ?? fromGitHub)
    tampered = true
    do {
      _ = try await host.fetch("github.com/acme/tools/tree/main/plugins/notes")
      try check(false, "A file that does not match the commit is refused")
    } catch {
      try check(error.localizedDescription.contains("did not match"), "A file that does not match the commit is refused")
    }
    return results
  }
}

private let fakePluginClaude = #"""
#!/usr/bin/python3 -I
import json, os, subprocess, sys
here = os.path.dirname(os.path.abspath(sys.argv[0]))
log = open(os.path.join(here, "log.jsonl"), "a")
def record(obj):
    log.write(json.dumps(obj) + "\n"); log.flush()
args = sys.argv[1:]
if args == ["--version"]:
    print("2.1.303 (Claude Code)"); sys.exit(0)
if args[:2] == ["auth", "status"]:
    print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty"})); sys.exit(0)
session = "fake-%d" % os.getpid()
if "--input-format" in args and args[args.index("--input-format") + 1] == "stream-json":
    for line in sys.stdin:
        message = json.loads(line)
        if message.get("type") == "control_request":
            print(json.dumps({"type": "control_response", "response": {"subtype": "success", "request_id": message["request_id"],
                "response": {"current_permission_mode": "dontAsk"}}}), flush=True)
        elif message.get("type") == "user":
            break
    else:
        sys.exit(0)
else:
    sys.stdin.read()
print(json.dumps({"type": "system", "subtype": "init", "session_id": session, "permissionMode": "dontAsk"}), flush=True)
server = json.loads(args[args.index("--mcp-config") + 1])["mcpServers"]["serein_browser"]
mcp = subprocess.Popen([server["command"]] + server["args"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
n = [0]
def rpc(method, params):
    n[0] += 1
    mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n[0], "method": method, "params": params}) + "\n"); mcp.stdin.flush()
    return json.loads(mcp.stdout.readline())
def call(name, arguments):
    r = rpc("tools/call", {"name": name, "arguments": arguments})["result"]
    text = r["content"][0]["text"]
    return text if r.get("isError") or not text.startswith("{") else json.loads(text)
rpc("initialize", {})
record({"tools": [t["name"] for t in rpc("tools/list", {})["result"]["tools"]]})
record({"skills": call("skill_list", {})})
record({"skill": call("skill_read", {"name": "daily-review"})})
record({"added": call("dev_serein_notes_demo__add_note", {"text": "buy milk"})})
record({"listed": call("dev_serein_notes_demo__list_notes", {})})
record({"cleared": call("dev_serein_notes_demo__clear_notes", {})})
print(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Plugins used."}]}}), flush=True)
print(json.dumps({"type": "result", "subtype": "success", "stop_reason": "end_turn", "is_error": False}), flush=True)
"""#

private let probeManifest = """
  {"id": "dev.serein.probe", "name": "Probe", "version": "1.0.0", "description": "Checks the plugin sandbox.",
   "mcp": {"command": "/usr/bin/python3", "args": ["-I", "server.py"]},
   "tools": [{"name": "probe", "risk": "read"}], "permissions": {"files": "plugin-data"}}
  """

private let probeServer = #"""
import json, os, socket, sys
TOOLS = [{"name": "probe", "description": "Probe the sandbox.",
          "inputSchema": {"type": "object", "properties": {"home": {"type": "string"}}}}]
def attempt(fn):
    try:
        fn(); return "ok"
    except Exception:
        return "denied"
def probe(home):
    def read_home():
        os.listdir(os.path.join(home, "Library", "Preferences"))
    def write_plugin():
        open(os.path.join(os.getcwd(), "x.txt"), "w").write("x")
    def write_data():
        open(os.path.join(os.environ["SEREIN_PLUGIN_DATA"], "ok.txt"), "w").write("ok")
    def network():
        socket.create_connection(("1.1.1.1", 443), timeout=3).close()
    return {"home_read": attempt(read_home), "plugin_write": attempt(write_plugin),
            "data_write": attempt(write_data), "network": attempt(network)}
for line in sys.stdin:
    msg = json.loads(line)
    mid = msg.get("id")
    if mid is None: continue
    m = msg.get("method")
    if m == "initialize": result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}}
    elif m == "tools/list": result = {"tools": TOOLS}
    else: result = {"content": [{"type": "text", "text": json.dumps(probe(msg["params"]["arguments"]["home"]))}]}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n"); sys.stdout.flush()
"""#

/// A real OAuth 2.1 server on loopback for the live check: metadata, dynamic registration, an
/// authorize endpoint that hands back the callback (the automated "browser"), a token endpoint
/// that verifies the PKCE challenge, and an MCP endpoint that demands the bearer token.
final class OAuthTestServer {
  let listener: NWListener
  let queue = DispatchQueue(label: "oauth-test")
  let io = DispatchQueue(label: "oauth-test-io")
  var port: UInt16 = 0
  private var challenge: String?
  private var code = "test-code-123"
  private var state = "test-state-456"

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
    listener = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
      if case .failed = state { ready.signal() }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      connection.start(queue: self.io)
      self.read(connection, buffer: Data())
    }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    port = UInt16(listener.port?.rawValue ?? 0)
  }
  func stop() { listener.cancel() }
  var base: String { "http://127.0.0.1:\(port)" }
  var callbackURL: String { "http://127.0.0.1/serein-plugin-callback?code=\(code)&state=\(state)" }

  private func read(_ connection: NWConnection, buffer: Data) {
    // The head and the body can arrive in separate packets; wait for the whole request.
    if OAuthTestServer.complete(buffer), let request = OAuthTestServer.request(buffer) {
      respond(connection, request)
      return
    }
    guard buffer.count < 1_000_000 else { connection.cancel(); return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
      guard let self, let data, !data.isEmpty else { connection.cancel(); return }
      var next = buffer
      next.append(data)
      self.read(connection, buffer: next)
    }
  }

  private func respond(_ connection: NWConnection, _ request: (method: String, path: String, body: Data, headers: [String: String])) {
    var status = "200 OK"
    var payload = Data("{}".utf8)
    switch (request.method, request.path) {
    // Query strings ride on the authorize and well-known paths, so those match by prefix.
    case (_, let path) where request.method == "GET" && path.hasPrefix("/.well-known/oauth-authorization-server"):
      payload = Data(#"{"authorization_endpoint":"\#(base)/authorize","token_endpoint":"\#(base)/token","registration_endpoint":"\#(base)/register","scopes_supported":["mcp"]}"#.utf8)
    case (_, let path) where request.method == "GET" && path.hasPrefix("/authorize"):
      challenge = OAuthTestServer.query(request.path, "code_challenge")
      // Echo the requester's state back, as a real server does.
      if let requested = OAuthTestServer.query(request.path, "state") { state = requested }
      payload = Data(#"{"callback":"\#(callbackURL)"}"#.utf8)
    case ("POST", "/register"):
      payload = Data(#"{"client_id":"test-client"}"#.utf8)
    case ("POST", "/token"):
      let fields = String(decoding: request.body, as: UTF8.self)
      let verifier = OAuthTestServer.formValue(fields, "code_verifier")
      let computed = PluginOAuth.challenge(verifier ?? "")
      if computed == challenge, fields.contains("grant_type=authorization_code"), fields.contains("client_id=test-client") {
        payload = Data(#"{"access_token":"at-live-123","refresh_token":"rt-live-456","expires_in":3600}"#.utf8)
      } else {
        status = "400 Bad Request"
        payload = Data(#"{"error":"invalid_grant","body":"\#(String(decoding: request.body, as: UTF8.self).prefix(300))"}"#.utf8)
      }
    case ("POST", "/mcp"):
      guard request.headers["authorization"] == "Bearer at-live-123" else {
        status = "401 Unauthorized"
        break
      }
      payload = Data(#"{"jsonrpc":"2.0","id":0,"result":{"tools":[{"name":"search","description":"s","inputSchema":{"type":"object"}}]}}"#.utf8)
    default:
      status = "404 Not Found"
      payload = Data()
    }
    let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
    connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
  }

  /// Whether the head and the declared body are both in the buffer yet.
  static func complete(_ buffer: Data) -> Bool {
    guard let text = String(data: buffer, encoding: .utf8),
      let headEnd = text.range(of: "\r\n\r\n") else { return false }
    let head = String(text[..<headEnd.lowerBound])
    let length = head.components(separatedBy: "\r\n").compactMap { line -> Int? in
      guard line.lowercased().hasPrefix("content-length:") else { return nil }
      return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
    }.first ?? 0
    return text[headEnd.upperBound...].utf8.count >= length
  }

  static func request(_ buffer: Data) -> (method: String, path: String, body: Data, headers: [String: String])? {
    guard let text = String(data: buffer, encoding: .utf8),
      let headEnd = text.range(of: "\r\n\r\n") else { return nil }
    let head = String(text[..<headEnd.lowerBound])
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst()
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines {
      if let colon = line.firstIndex(of: ":") {
        headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      }
    }
    let length = Int(headers["content-length"] ?? "0") ?? 0
    let bodyData = Data(text[headEnd.upperBound...].utf8.prefix(length))
    return (String(parts[0]), String(parts[1]), bodyData, headers)
  }

  static func query(_ path: String, _ name: String) -> String? {
    guard let query = path.split(separator: "?").dropFirst().first else { return nil }
    for pair in query.split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1)
      if kv.first == Substring(name) { return kv.count > 1 ? String(kv[1]) : "" }
    }
    return nil
  }

  static func formValue(_ body: String, _ name: String) -> String? {
    for pair in body.split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1)
      if kv.first == Substring(name) { return kv.count > 1 ? String(kv[1]) : "" }
    }
    return nil
  }
}
#endif
