import Foundation

/// Serein's own assistant works on websites through a Mac, never through Serein's built-in tabs:
/// the person's Mac (mac_observe/mac_act, in their own browser with its sign-ins) or Serein's
/// virtual Mac (computer_*, in its browser). The tab tools stay for the runs that are built on
/// them: research, recipes, and a task the person starts in their own tab.
public enum AssistantWeb {
  /// The helper argument that leaves the tab tools off a run's list.
  public static let flag = "--no-tabs"

  /// Page helpers that work only in Serein's tabs.
  static let pageHelpers: Set<String> = ["do", "repl", "page_tool", "click_point"]

  /// Every tab tool by both of its names (Claude's short ones and the isolated aliases), and the
  /// page helpers: what a run without tabs refuses.
  public static let tabTools: Set<String> = {
    let names = ToolSchema.tools(isolated: false).compactMap { $0["name"] as? String }
    return Set(names).union(ToolSchema.isolated).union(pageHelpers).subtracting(["finish", "person_step"])
  }()

  public static let refusal =
    "Serein's built-in tabs are off for the assistant. For a website, use a Mac: the person's own (mac_observe, then mac_act, in their browser where they are signed in) or Serein's virtual Mac (computer_open_url, then computer_screenshot)."

  /// The `agent_start` destinations a run without tabs may use: web tasks run in tabs.
  public static func destinations(tabs: Bool) -> [RelayTools.Destination] {
    tabs ? RelayTools.Destination.allCases : RelayTools.Destination.allCases.filter { $0 != .web }
  }

  static let webWords = "web (research or act on websites in isolated tabs), "

  /// `agent_start` as a run without tabs lists it: no web destination. Every other tool as it is.
  public static func withoutWeb(_ tool: [String: Any]) -> [String: Any] {
    guard tool["name"] as? String == "agent_start",
      var schema = tool["inputSchema"] as? [String: Any],
      var properties = schema["properties"] as? [String: Any],
      var destination = properties["destination"] as? [String: Any]
    else { return tool }
    destination["enum"] = destinations(tabs: false).map(\.rawValue)
    properties["destination"] = destination
    schema["properties"] = properties
    var changed = tool
    changed["inputSchema"] = schema
    changed["description"] = (tool["description"] as? String ?? "").replacingOccurrences(of: webWords, with: "")
    return changed
  }

  public static let webRefusal =
    "destination web is off: Serein's built-in tabs are off for the assistant. Do the website yourself on a Mac, or delegate with destination mac."

  /// The prompt's line for websites.
  public static let promptLine =
    "For websites, use a Mac, not built-in tabs (you have none): when the site needs the person's account (X, their mail, a dashboard) use their Mac's browser with mac_observe then mac_act, where they are signed in; for anything else prefer Serein's virtual Mac with computer_open_url and computer_screenshot, and if it is unavailable or offline use the person's Mac."
}
