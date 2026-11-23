import Foundation
import SereinCore

/// `serein-agent mcp`: the same tools for clients with no shell, such as Claude Desktop. One
/// JSON-RPC message per line on stdin and stdout; each tool call is one request to Serein.
enum MCP {
  static func tools() -> [[String: Any]] {
    let browser = ToolSchema.tools(isolated: false).filter { tool in
      ["tabs", "open", "go", "read", "click", "type", "select", "hover", "scroll", "key", "back", "wait",
       "screenshot", "close", "finish"].contains(tool["name"] as? String ?? "")
    }
    let status: [String: Any] = [
      "name": "status", "description": "This pairing (sign-ins, clicks and typing, local hosts) and your open tabs.",
      "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
    ]
    return [status] + browser + ToolSchema.settingsTools
  }
  static func serve(token: String) -> Never {
    let available = tools()
    while let line = readLine() {
      guard line.utf8.count <= 1_000_000,
        let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
        let method = message["method"] as? String, let id = message["id"]
      else { continue }
      var result: [String: Any]
      switch method {
      case "initialize":
        result = [
          "protocolVersion": "2025-11-25", "capabilities": ["tools": ["listChanged": false]],
          "serverInfo": ["name": "serein", "version": "0.1.0"],
          "instructions": Skill.mcpNote,
        ]
      case "ping": result = [:]
      case "tools/list": result = ["tools": available]
      case "tools/call":
        let params = message["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let reply: [String: Any]
        if !available.contains(where: { $0["name"] as? String == name }) {
          reply = ["error": "Unknown tool \(name)."]
        } else if name == "status" {
          reply = request(["op": "status", "token": token])
        } else {
          reply = call(name, params["arguments"] as? [String: Any] ?? [:], token: token)
        }
        if let error = reply["error"] as? String {
          result = ["isError": true, "content": [["type": "text", "text": error]]]
        } else if let content = reply["content"] {
          result = ["content": content]
        } else {
          result = ["content": [["type": "text", "text": jsonString(reply)]]]
        }
      default:
        print(jsonString(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]))
        fflush(stdout)
        continue
      }
      print(jsonString(["jsonrpc": "2.0", "id": id, "result": result]))
      fflush(stdout)
    }
    exit(0)
  }
}
