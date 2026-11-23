import Foundation
import SereinCore

/// `serein-agent plugin init|validate`: start a plugin from a working template, and check one
/// the way Serein will (manifest, skills, then its server in the same sandbox, listing tools).
enum PluginCommand {
  static let usage = """
    serein-agent plugin init <name> [folder]   a working plugin template (manifest, Python MCP server, skill)
    serein-agent plugin validate [folder]      check it as Serein will, including its server in the sandbox
    serein-agent plugin test <folder> <tool> ['<json arguments>']   call one tool in the sandbox, as Serein would
    """

  static func main(_ args: [String]) -> Never {
    guard let sub = args.first else {
      print(usage)
      exit(0)
    }
    do {
      switch sub {
      case "init":
        guard args.count >= 2 else { throw SereinError.invalid("Usage: serein-agent plugin init <name> [folder]") }
        let folder = try initialize(name: args[1], at: args.count > 2 ? URL(fileURLWithPath: args[2]) : nil)
        print("Created \(folder.path). Next: serein-agent plugin validate \(folder.path)")
      case "validate":
        let folder = URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath)
        let report = try validate(folder)
        print(report.joined(separator: "\n"))
        exit(report.contains { $0.hasPrefix("✗") } ? 1 : 0)
      case "test":
        guard args.count >= 3 else { throw SereinError.invalid("Usage: serein-agent plugin test <folder> <tool> ['<json arguments>']") }
        let arguments = args.count > 3
          ? (try JSONSerialization.jsonObject(with: Data(args[3].utf8)) as? [String: Any]) ?? [:] : [:]
        let lines = try test(URL(fileURLWithPath: args[1]), tool: args[2], arguments: arguments)
        print(lines.joined(separator: "\n"))
        exit(lines.contains { $0.hasPrefix("✗") } ? 1 : 0)
      default: throw SereinError.invalid(usage)
      }
    } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      exit(1)
    }
    exit(0)
  }

  /// A folder named after the plugin with a manifest, a standard-library Python MCP server with
  /// one read tool, a skill and a README. Refuses to write into a folder that exists.
  static func initialize(name: String, at location: URL?) throws -> URL {
    let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    guard !slug.isEmpty else { throw SereinError.invalid("Give the plugin a name, such as \"weather\".") }
    let folder = location ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(slug)
    guard !FileManager.default.fileExists(atPath: folder.path) else { throw SereinError.invalid("\(folder.path) already exists.") }
    let tool = slug.replacingOccurrences(of: "-", with: "_") + "_hello"
    let files: [String: String] = [
      PluginManifest.fileName: """
        {
          "id": "dev.local.\(slug)",
          "name": "\(name)",
          "version": "0.1.0",
          "description": "Describe what \(name) does in one sentence.",
          "license": "MIT",
          "mcp": { "command": "/usr/bin/python3", "args": ["-I", "server.py"] },
          "tools": [{ "name": "\(tool)", "risk": "read" }],
          "permissions": { "files": "plugin-data" }
        }

        """,
      "server.py": """
        \"\"\"\(name): a stdio MCP server for Serein, standard library only.

        Serein starts it for each call in a sandbox. Write files only in SEREIN_PLUGIN_DATA. List
        every tool in serein-plugin.json with its risk: read, write, send, delete or pay.
        \"\"\"
        import json, sys

        TOOLS = [{"name": "\(tool)", "description": "Say hello to someone.",
                  "inputSchema": {"type": "object", "properties": {"who": {"type": "string"}},
                                  "additionalProperties": False}}]

        def call(name, args):
            if name == "\(tool)":
                return "Hello, %s!" % args.get("who", "world")
            raise ValueError("unknown tool " + name)

        def reply(mid, result):
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\\n")
            sys.stdout.flush()

        for line in sys.stdin:
            msg = json.loads(line)
            mid, method = msg.get("id"), msg.get("method")
            if mid is None:
                continue
            if method == "initialize":
                reply(mid, {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}})
            elif method == "tools/list":
                reply(mid, {"tools": TOOLS})
            elif method == "tools/call":
                p = msg.get("params", {})
                try:
                    reply(mid, {"content": [{"type": "text", "text": call(p.get("name"), p.get("arguments") or {})}]})
                except Exception as e:
                    reply(mid, {"content": [{"type": "text", "text": str(e)}], "isError": True})
            else:
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "not found"}}) + "\\n")
                sys.stdout.flush()

        """,
      "skills/\(slug)/SKILL.md": """
        ---
        name: \(slug)
        description: When to use \(name): describe the job, so Serein knows when to read this.
        ---

        1. Steps Serein should follow, in order.
        2. Name the tools to use, such as \(tool).

        """,
      "README.md": """
        # \(name)

        A Serein plugin. Check it with `serein-agent plugin validate .`, then add this folder in
        Serein › Settings › Plugins and turn it on. Guide: docs/PLUGINS-GUIDE.md in Serein.

        """,
    ]
    for (path, text) in files {
      let url = folder.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return folder
  }

  /// One tool call the way Relay makes it: what its policy decides by the declared risk, then
  /// the call itself in the sandbox, with a throwaway data folder and no secrets.
  static func test(_ folder: URL, tool: String, arguments: [String: Any]) throws -> [String] {
    let package = PluginCatalog.load(folder)
    guard let manifest = package.manifest, let server = manifest.mcp else {
      throw SereinError.invalid(package.problems.first ?? "That folder has no tool plugin.")
    }
    guard let declared = manifest.tools?.first(where: { $0.name == tool }) else {
      return ["✗ \(tool) is not in the manifest, so Serein never calls it."]
    }
    var out = [
      "Serein calls it \(manifest.qualified(tool)); risk \(declared.risk.rawValue): "
        + (ApprovalDoor.reads(.plugin(name: declared.gateName, declared: declared.risk))
          ? "runs on its own at every level." : "runs on its own with Allow all and Only risky steps, asks with Every step."),
    ]
    let commandText = server.command ?? ""
    guard !commandText.isEmpty else {
      out.append("· A remote server (\(server.url ?? "")) is not tested offline; Serein reaches it with your key when the tool runs.")
      return out
    }
    let command = commandText.hasPrefix("/") ? commandText : folder.appendingPathComponent(commandText).standardizedFileURL.path
    let data = FileManager.default.temporaryDirectory.appendingPathComponent("serein-plugin-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: data) }
    let hosts = manifest.permissions?.network ?? []
    let egress = try Self.commandEgress(hosts: hosts)
    defer { egress?.stop() }
    let profile = PluginCommandNetwork.profile(
      home: FileManager.default.homeDirectoryForCurrentUser, plugin: folder, data: data,
      hosts: hosts, proxyPort: egress?.port)
    let result = try PluginSession.run(
      arguments: ["-p", profile, command] + (server.args ?? []), folder: folder,
      environment: Self.commandEnvironment(data: data, egress: egress),
      timeout: 20) { rpc in try rpc("tools/call", ["name": declared.serverName, "arguments": arguments]) }
    let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    out.append((result["isError"] as? Bool == true ? "✗ The tool reported an error: " : "✓ ") + text)
    return out
  }

  /// ✓ and ✗ lines: what Serein will accept, and why not.
  static func validate(_ folder: URL) throws -> [String] {
    var out: [String] = []
    let package = PluginCatalog.load(folder)
    for problem in package.problems { out.append("✗ " + problem) }
    for skill in package.skills { out.append("✓ skill \(skill.name): \(skill.description)") }
    guard let manifest = package.manifest else {
      if package.skills.isEmpty && package.problems.isEmpty { out.append("✗ No SKILL.md or \(PluginManifest.fileName).") }
      return out
    }
    out.append("✓ \(manifest.name) \(manifest.version) (\(manifest.id))")
    out += manifest.permissionSummary.map { "  · " + $0 }
    guard let server = manifest.mcp else { return out }
    let commandText = server.command ?? ""
    guard !commandText.isEmpty else {
      out.append("· remote server \(server.url ?? "") (https only; the token stays in your Keychain)")
      return out
    }
    let command = commandText.hasPrefix("/") ? commandText : folder.appendingPathComponent(commandText).standardizedFileURL.path
    guard FileManager.default.isExecutableFile(atPath: command) else {
      out.append("✗ mcp.command \(commandText) is not an executable file.")
      return out
    }
    // Checks run without the user's secrets: the server must list its tools without them.
    let data = FileManager.default.temporaryDirectory.appendingPathComponent("serein-plugin-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: data) }
    let hosts = manifest.permissions?.network ?? []
    let egress = try Self.commandEgress(hosts: hosts)
    defer { egress?.stop() }
    let profile = PluginCommandNetwork.profile(
      home: FileManager.default.homeDirectoryForCurrentUser, plugin: folder, data: data,
      hosts: hosts, proxyPort: egress?.port)
    do {
      let listed = try PluginSession.run(
        arguments: ["-p", profile, command] + (server.args ?? []), folder: folder,
        environment: Self.commandEnvironment(data: data, egress: egress),
        timeout: 20) { rpc in try rpc("tools/list", [:]) }
      let offered = listed["tools"] as? [[String: Any]] ?? []
      let (tools, missing) = PluginSchemas.relayTools(offered, manifest: manifest)
      out.append("✓ The server starts in Serein's sandbox and lists \(offered.count) tool(s).")
      for tool in manifest.tools ?? [] where !missing.contains(tool.name) {
        out.append("✓ tool \(tool.name) (\(tool.risk.rawValue)) → Serein calls it \(manifest.qualified(tool.name))")
      }
      for name in missing { out.append("✗ The manifest lists \(name), but the server does not offer it.") }
      let hidden = offered.compactMap { $0["name"] as? String }.filter { name in !(manifest.tools ?? []).contains { $0.serverName == name } }
      for name in hidden { out.append("  · \(name) is not in the manifest, so Serein will not see it.") }
      _ = tools
    } catch {
      out.append("✗ The server did not answer tools/list: \(error.localizedDescription)")
    }
    return out
  }

  /// The egress proxy when the manifest lists hosts. An empty list gets no listener and no network.
  private static func commandEgress(hosts: [String]) throws -> PluginEgress? {
    guard PluginCommandNetwork.limit(hosts: hosts).requiresProxy else { return nil }
    return try PluginEgress(allowed: hosts)
  }

  private static func commandEnvironment(data: URL, egress: PluginEgress?) -> [String: String] {
    var environment = [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
      "SEREIN_PLUGIN_DATA": data.path,
    ]
    if let egress {
      let proxy = "http://127.0.0.1:\(egress.port)"
      for name in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] { environment[name] = proxy }
      environment["NO_PROXY"] = "127.0.0.1,localhost"
    }
    return environment
  }
}
