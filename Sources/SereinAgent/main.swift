import Darwin
import Foundation
import SereinCore

// `serein-agent`: outside agents (Grok Bot, Claude Code, Codex) use Serein's browser. Each call
// is one request on the socket in the library's agents folder; Serein answers through the same
// guarded path its own agents use (OutsideAgents.swift). Output is one JSON object on stdout.

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  let value = args[i + 1]
  args.removeSubrange(i...(i + 1))
  return value
}
func flag(_ name: String) -> Bool {
  guard let i = args.firstIndex(of: name) else { return false }
  args.remove(at: i)
  return true
}
func emit(_ value: Any) { print(jsonString(value)) }
func fail(_ message: String, needsUser: Bool = false) -> Never {
  var out: [String: Any] = ["error": message]
  if needsUser { out["needs_user"] = true }
  emit(out)
  exit(1)
}
/// A refused call; `needsUser` when only the user can unblock it.
struct CallError: LocalizedError {
  let message: String
  let needsUser: Bool
  var errorDescription: String? { message }
}
func fail(_ error: Error) -> Never { fail(error.localizedDescription, needsUser: (error as? CallError)?.needsUser == true) }

let root = AgentAccess.defaultRoot
let socket = AgentAccess.socketPath(root: root)
let pairing = option("--as") ?? ProcessInfo.processInfo.environment["SEREIN_AGENT_AS"]
let outFile = option("--out")

/// The token of this agent's pairing, from the file Serein wrote when it paired.
func token() -> String {
  let files = (try? FileManager.default.contentsOfDirectory(at: AgentAccess.clients(root: root), includingPropertiesForKeys: nil)) ?? []
  let clients = files.compactMap { file -> (name: String, token: String)? in
    guard let o = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] }),
      let name = o["name"], let token = o["token"]
    else { return nil }
    return (name, token)
  }
  let names = clients.map(\.name).sorted().joined(separator: ", ")
  if let pairing {
    guard let match = clients.first(where: { $0.name.lowercased() == pairing.lowercased() }) else {
      fail("No pairing named \(pairing). Paired: \(names.isEmpty ? "none" : names).")
    }
    return match.token
  }
  switch clients.count {
  case 1: return clients[0].token
  case 0:
    fail("This agent is not paired with Serein. Ask the user to open Serein › Settings › AI apps › Other agents that use Serein, choose Add an agent and give you the code, then run: serein-agent pair <code>", needsUser: true)
  default: fail("Several agents are paired with Serein (\(names)). Add --as \"<your name>\" to every call.")
  }
}

func reachable() -> Bool {
  let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0, var address = try? LocalSocket.address(socket) else { return false }
  defer { Darwin.close(fd) }
  return withUnsafePointer(to: &address) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
    }
  }
}
/// Starts Serein behind the other windows when it is closed, and waits for its socket.
func ensureRunning() throws {
  if reachable() { return }
  let open = Process()
  open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  open.arguments = ["-g", "-b", "local.serein.browser", "--args", "--background"]
  open.standardOutput = FileHandle.nullDevice
  open.standardError = FileHandle.nullDevice
  guard (try? open.run()) != nil else { throw CallError(message: "Serein is not running. Ask the user to open it.", needsUser: true) }
  open.waitUntilExit()
  guard open.terminationStatus == 0 else {
    throw CallError(message: "Serein is not installed on this Mac, or it did not start.", needsUser: true)
  }
  for _ in 0..<80 {
    if reachable() { return }
    usleep(250_000)
  }
  throw CallError(message: "Serein is open but does not answer agents. Ask the user to update Serein or restart it.", needsUser: true)
}
/// One request to Serein; a connection that fails comes back as an error answer.
func request(_ envelope: [String: Any]) -> [String: Any] {
  do {
    try ensureRunning()
    return try LocalSocket.request(envelope, socket: socket)
  } catch {
    var out: [String: Any] = ["error": error.localizedDescription]
    if (error as? CallError)?.needsUser == true { out["needs_user"] = true }
    return out
  }
}
func call(_ tool: String, _ arguments: [String: Any], token: String) -> [String: Any] {
  request(["op": "tool", "token": token, "name": tool, "arguments": arguments])
}

/// The page in a result: a read returns it, an action returns it under "page".
func page(of result: [String: Any]) -> [String: Any]? {
  if result["elements"] != nil { return result }
  return result["page"] as? [String: Any]
}
/// The element whose visible label is `label`: an exact match first, then one that contains it.
/// Refs change after every action, so steps name elements by label and find them again each time.
func resolve(_ label: String, act: String, in page: [String: Any]) throws -> String {
  let rows = (page["elements"] as? [[String: Any]] ?? []).filter { $0["ref"] is String }
  let want = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  let label = { (row: [String: Any]) in (row["label"] as? String ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
  let fits = { (row: [String: Any]) in (row["acts"] as? [String])?.contains(act) ?? true }
  for matches in [rows.filter { label($0) == want }, rows.filter { label($0).contains(want) }] {
    let usable = matches.filter(fits).isEmpty ? matches : matches.filter(fits)
    if usable.count == 1 { return usable[0]["ref"] as! String }
    if usable.count > 1 {
      let list = usable.prefix(6).map { "\($0["ref"]!) \"\($0["label"] ?? "")\"" }.joined(separator: ", ")
      throw SereinError.invalid("Several elements match \"\(want)\": \(list). Use a ref or a longer label.")
    }
  }
  throw SereinError.invalid("No element matches \"\(want)\" on this page. Read the page for its elements.")
}
/// Runs one tool; a "label" in place of "ref" is found on `last` (or a fresh read).
func run(_ tool: String, _ arguments: [String: Any], token: String, last: [String: Any]?) throws -> [String: Any] {
  var a = arguments
  if let label = a.removeValue(forKey: "label") as? String {
    guard let tab = a["tab"] as? String else { throw SereinError.invalid("A label needs a tab.") }
    var current = last.flatMap(page(of:))
    if current == nil || current?["tab"] as? String != tab {
      current = try checked(call("read", ["tab": tab], token: token))
    }
    a["ref"] = try resolve(label, act: tool == "type" ? "type" : tool == "select" ? "select" : "click", in: current!)
  }
  return try checked(call(tool, a, token: token))
}
func checked(_ result: [String: Any]) throws -> [String: Any] {
  if let error = result["error"] as? String { throw CallError(message: error, needsUser: result["needs_user"] as? Bool == true) }
  return result
}
/// A screenshot goes to a file: agents read the path, and the picture stays out of the transcript.
func saved(_ result: [String: Any], tab: String) -> [String: Any] {
  if let content = result["content"] as? [[String: Any]], let image = content.first(where: { $0["type"] as? String == "image" }),
    let b64 = image["data"] as? String, let png = Data(base64Encoded: b64)
  {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("serein-agent")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = outFile.map { URL(fileURLWithPath: $0) }
      ?? dir.appendingPathComponent("\(tab.prefix(8))-\(Int(Date().timeIntervalSince1970 * 1000)).png")
    do { try png.write(to: file) } catch { fail("Could not write \(file.path): \(error.localizedDescription)") }
    return ["tab": tab, "file": file.path]
  }
  guard let outFile, page(of: result) != nil else { return result }
  do { try Data(jsonString(result).utf8).write(to: URL(fileURLWithPath: outFile)) } catch {
    fail("Could not write \(outFile): \(error.localizedDescription)")
  }
  let p = page(of: result) ?? [:]
  return ["tab": p["tab"] ?? tab, "title": p["title"] ?? "", "url": p["url"] ?? "", "file": outFile,
    "chars": (p["text"] as? String)?.count ?? 0]
}

let usage = """
  serein-agent: use Serein's browser from an agent. Output is JSON.
    pair <code>                 pair with the code from Serein › Settings › AI apps
    status                      this pairing, and your open tabs
    open <url>                  open a tab; returns the page with element refs
    go <tab> <url> | back <tab> | wait <tab> | close <tab> | tabs
    read <tab> [--start N] [--frame F] [--out FILE]
    click <tab> <ref>           or: click <tab> --label "Sign in"
    type <tab> <ref> <text> [--enter] [--append]     (or --label instead of <ref>)
    select <tab> <ref> <value> | hover <tab> <ref> | key <tab> <ref> <Enter|Escape|Tab|...>
    scroll <tab> <up|down|top|bottom>
    screenshot <tab> [--out FILE]   saves a PNG and prints its path
    steps '<json array>'        several steps in one call, e.g.
                                '[{"tool":"type","tab":"T","label":"Search","text":"cats","press_enter":true},{"tool":"click","tab":"T","label":"Images"}]'
    done <summary> | finish <done|waiting|stuck> <summary>     end your session
    settings                    Serein's own settings, with their values
    set <setting> <value>       e.g. set appearance dark, set text_size 120%
    update [check|install]      look for a Serein update, or install a downloaded one
    sign-in <agent>             start a coding agent's sign-in, e.g. sign-in codex
    end                         close your tabs now
    skill                       how to use this, for an agent's instructions
    mcp                         the same tools as an MCP server on stdin and stdout
    ask <text> [--wait N]       ask Serein (the pairing must allow it); waits up to 25 s. Same as relay ask
    relay status | relay stop   Serein's latest reply and state, or stop what it is doing
    plugin init <name> [folder] a working Serein plugin template
    plugin validate [folder]    check a plugin as Serein will
    look validate <file.json>   check a look for Serein's hologram as Serein will
    look presets | look guide   Serein's looks as JSON, or how to write one
  Options: --as <name> when several agents are paired.
  """

guard let command = args.first else {
  print(usage)
  exit(0)
}
args.removeFirst()
switch command {
case "help", "--help", "-h": print(usage)
case "skill": print(Skill.text)
case "plugin": PluginCommand.main(args)
case "look": LookCommand.main(args)
case "relay", "ask":
  // `serein-agent ask` is `relay ask`; the relay verbs stay for scripts that use them.
  if command == "ask" { args.insert("ask", at: 0) }
  let wait = option("--wait").flatMap(Int.init)
  guard let sub = args.first, ["ask", "status", "stop"].contains(sub) else {
    fail("Usage: serein-agent ask <text> [--wait N] | relay status | relay stop")
  }
  var body: [String: Any] = ["op": "relay_" + sub, "token": token()]
  if sub == "ask" {
    let text = args.dropFirst().joined(separator: " ")
    guard !text.isEmpty else { fail("Usage: serein-agent ask <text>") }
    body["text"] = text
    if let wait { body["wait"] = wait }
  }
  let result = request(body)
  emit(result)
  exit(result["error"] == nil ? 0 : 1)
case "hook":
  // Fire a registered webhook from the command line: serein-agent hook --secret <s> '<json>'.
  guard let secret = option("--secret"), !secret.isEmpty else {
    fail("Usage: serein-agent hook --secret <secret> '<json body>'")
  }
  let body = args.joined(separator: " ")
  var request = URLRequest(url: URL(string: "http://127.0.0.1:\(RelayHook.port)\(RelayHook.path)")!)
  request.httpMethod = "POST"
  request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
  request.httpBody = Data((body.isEmpty ? "{}" : body).utf8)
  let done = DispatchSemaphore(value: 0)
  let outcome = LockedBox<(status: Int, ok: Bool)?>()
  URLSession.shared.dataTask(with: request) { data, response, _ in
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    outcome.set((status, data.flatMap { String(data: $0, encoding: .utf8)?.contains("\"ok\"") ?? false } ?? false))
    done.signal()
  }.resume()
  guard done.wait(timeout: .now() + 10) == .success, let answer = outcome.get(), let result = answer else {
    fail("Serein did not answer the webhook. Is Relay running with webhooks on?")
  }
  emit(["ok": result.ok, "status": result.status])
  exit(result.ok ? 0 : 1)
case "pair":
  guard let code = args.first else { fail("Usage: serein-agent pair <code>") }
  let result = request(["op": "pair", "code": code])
  emit(result)
  exit(result["error"] == nil ? 0 : 1)
case "status", "end":
  let result = request(["op": command, "token": token()])
  emit(result)
  exit(result["error"] == nil ? 0 : 1)
case "mcp": MCP.serve(token: token())
case "steps":
  guard let text = args.first, let steps = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] else {
    fail("Usage: serein-agent steps '[{\"tool\":\"click\",\"tab\":\"…\",\"label\":\"…\"}, …]'")
  }
  let key = token()
  var last: [String: Any]?
  var done: [[String: Any]] = []
  var tab: String?
  for (index, step) in steps.enumerated() {
    var arguments = step
    guard let tool = arguments.removeValue(forKey: "tool") as? String else { fail("Step \(index + 1) has no tool.") }
    if arguments["tab"] == nil, tool != "open", tool != "tabs", tool != "finish", let tab { arguments["tab"] = tab }
    do {
      let result = try run(tool, arguments, token: key, last: last)
      tab = (page(of: result)?["tab"] as? String) ?? (arguments["tab"] as? String) ?? tab
      last = result
      done.append(["tool": tool, "ok": true])
    } catch {
      var out: [String: Any] = ["error": error.localizedDescription, "failed_step": index + 1, "steps": done,
        "page": last.flatMap(page(of:)) ?? NSNull()]
      if (error as? CallError)?.needsUser == true { out["needs_user"] = true }
      emit(out)
      exit(1)
    }
  }
  emit(["steps": done, "result": last.map { saved($0, tab: tab ?? "") } ?? [:]])
default:
  // Positional words for each tool, then the flags it takes.
  let words: [String: [String]] = [
    "tabs": [], "open": ["url"], "go": ["tab", "url"], "read": ["tab"], "click": ["tab", "ref"],
    "type": ["tab", "ref", "text"], "select": ["tab", "ref", "value"], "hover": ["tab", "ref"],
    "key": ["tab", "ref", "key"], "scroll": ["tab", "direction"], "back": ["tab"], "wait": ["tab"],
    "screenshot": ["tab"], "close": ["tab"], "finish": ["outcome", "summary"], "done": ["summary"],
    "settings": [], "set": ["name", "value"], "update": ["action"], "sign-in": ["agent"],
  ]
  // Serein's own settings go by the same names as the MCP tools.
  let toolNames = ["settings": "settings_get", "set": "settings_set", "sign-in": "agent_sign_in"]
  if command == "update" && args.isEmpty { args = ["check"] }
  guard var names = words[command] else {
    print(usage)
    exit(1)
  }
  var arguments: [String: Any] = [:]
  if let label = option("--label") {
    arguments["label"] = label
    names.removeAll { $0 == "ref" }
  }
  if let start = option("--start") { arguments["start"] = Int(start) ?? 0 }
  if let frame = option("--frame") { arguments["frame"] = frame }
  if let result = option("--result-tab") { arguments["result_tab"] = result }
  if flag("--enter") { arguments["press_enter"] = true }
  if flag("--append") { arguments["append"] = true }
  guard args.count >= names.count else { fail("Usage: serein-agent \(command) " + names.map { "<\($0)>" }.joined(separator: " ")) }
  for (i, name) in names.enumerated() {
    // The last word takes the rest, so text and summaries need no quotes.
    arguments[name] = i == names.count - 1 ? args[i...].joined(separator: " ") : args[i]
  }
  var tool = toolNames[command, default: command]
  if command == "done" {
    tool = "finish"
    arguments["outcome"] = "done"
  }
  do {
    emit(saved(try run(tool, arguments, token: token(), last: nil), tab: arguments["tab"] as? String ?? ""))
  } catch {
    fail(error)
  }
}

/// One answer from the network, written once from the callback thread.
final class LockedBox<T> {
  private let lock = NSLock()
  private var value: T?
  func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
  func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
