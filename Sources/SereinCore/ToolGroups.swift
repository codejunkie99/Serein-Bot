import Foundation

/// Relay tools a typical turn does not use, kept off the list every turn sends and reached
/// through two small tools, the way skills are reached through skill_list and skill_read:
/// `tools_more` lists the groups or gives one group's schemas, and `tool_run` runs one of them.
/// The browser helper answers `tools_more` itself and forwards `tool_run` to Serein as the inner
/// tool's own call, so it takes the same path, asks, receipts and step label as a direct call.
public enum ToolGroups {
  public struct Group: Sendable {
    public let id: String
    public let line: String
    public let tools: [String]
  }
  public static let moreTool = "tools_more"
  public static let runTool = "tool_run"
  /// The settings tools (`update`, `agent_sign_in`) stay listed: every run calls them directly,
  /// Codex's approve list included (R14).
  /// `setup_offer` stays too: first-time setup uses it.
  public static let groups: [Group] = [
    Group(
      id: "look", line: "Your hologram's look: read it, change it, undo a change or play a state.",
      tools: ["look_get", "look_set", "look_undo", "look_show"]),
    Group(
      id: "links", line: "Links other apps call to wake an assistant, and saved recipes to run or change.",
      tools: ["hook_make", "hook_list", "hook_remove", "recipe_run", "recipe_update"]),
    Group(
      id: "assistants",
      line: "Make, change or delete an assistant, propose a team, share a note with every assistant, or propose new standing instructions.",
      tools: ["assistant_make", "assistant_change", "assistant_delete", "team_propose", "memory_share", "instructions_propose"]),
    Group(
      id: "sites", line: "Sites and dashboards: list, save or show a tracker or website you made, or make a dashboard.",
      tools: ["site_list", "site_save", "site_show", "dashboard_make"]),
    Group(
      id: "views", line: "Draw a custom view under your reply from blocks: stats, badges, tables, lists, progress, charts, and buttons and controls the person can press.",
      tools: ["ui_show"]),
    Group(id: "apps", line: "What each AI app on this Mac can do.", tools: ["harness_capabilities"]),
  ]
  public static let hidden: Set<String> = Set(groups.flatMap(\.tools))

  static func name(_ tool: [String: Any]) -> String { tool["name"] as? String ?? "" }

  /// A relay turn's list: every tool but the hidden ones, then the two that reach them.
  public static func shown(_ every: [[String: Any]]) -> [[String: Any]] {
    every.filter { !hidden.contains(name($0)) } + tools
  }
  /// The hidden tools this turn may run through tool_run: those its full list holds.
  public static func reachable(_ every: [[String: Any]]) -> [[String: Any]] {
    every.filter { hidden.contains(name($0)) }
  }

  public static var tools: [[String: Any]] {
    [
      [
        "name": moreTool,
        "description":
          "More of Serein's tools, kept out of this list until needed. Without group: each group in one line with its tool names. With group: those tools' full schemas. Run one with tool_run.",
        "inputSchema": [
          "type": "object", "properties": ["group": ["type": "string", "enum": groups.map(\.id)]],
          "required": [], "additionalProperties": false,
        ],
        "annotations": ["readOnlyHint": true],
      ],
      [
        "name": runTool,
        "description":
          "Run one tool tools_more lists: name is the tool, arguments a JSON object matching its schema. It runs exactly as that tool would, with the same approvals and cards.",
        "inputSchema": [
          "type": "object", "properties": ["name": ["type": "string"], "arguments": ["type": "object"]],
          "required": ["name"], "additionalProperties": false,
        ],
      ],
    ]
  }

  /// `tools_more`'s answer, from the tools this turn may reach.
  public static func more(_ arguments: [String: Any], reachable: [[String: Any]]) throws -> [String: Any] {
    let offered = Set(reachable.map(name))
    let id = (arguments["group"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else {
      let listed = groups.filter { !offered.isDisjoint(with: $0.tools) }.map { group -> [String: Any] in
        ["group": group.id, "about": group.line, "tools": group.tools.filter(offered.contains)]
      }
      return ["groups": listed, "note": "Call tools_more with a group for its tools' schemas, then tool_run with name and arguments."]
    }
    guard let group = groups.first(where: { $0.id == id }) else {
      throw SereinError.invalid("No group by that name. Call tools_more without a group to list them.")
    }
    return ["group": group.id, "tools": reachable.filter { group.tools.contains(name($0)) }, "note": "Run one with tool_run."]
  }

  /// The request Serein receives for a `tool_run` call: the inner tool's own name and arguments,
  /// exactly as a direct call sends them. Only a tool of a group this turn holds.
  public static func request(_ arguments: [String: Any], reachable: Set<String>) throws -> [String: Any] {
    guard let inner = arguments["name"] as? String, reachable.contains(inner) else {
      throw SereinError.invalid("tool_run runs only a tool tools_more lists. Call tools_more to see them.")
    }
    // Some models send the arguments as JSON text rather than an object.
    let given = arguments["arguments"]
    let parsed = (given as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    return ["name": inner, "arguments": parsed ?? given as? [String: Any] ?? [:]]
  }
}
