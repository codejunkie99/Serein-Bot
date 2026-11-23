#if DEBUG
import Foundation
import SereinCore

/// Serein's own assistant works on websites through a Mac (AssistantWeb): its run lists no tab
/// tools or page helpers and no web destination, while other runs keep their tabs.
extension AssistantCoreChecks {
  static func assistantWeb(_ check: Check) throws {
    let W = AssistantWeb.self
    let full = ["--relay", "--mac", "--fast", "--repl", "--page-tools", "--click-point", "--computer", "--computer-mac"]
    let withTabs = Set(ToolSchema.offered(full).compactMap { $0["name"] as? String })
    let without = Set(ToolSchema.offered(full + [W.flag]).compactMap { $0["name"] as? String })
    for name in ["open", "read", "click", "do", "repl"] {
      try check(withTabs.contains(name), "A run with tabs keeps \(name)")
      try check(!without.contains(name), "The assistant's run has no \(name)")
    }
    try check(without.isDisjoint(with: W.tabTools), "The assistant's run lists no tab tool by either name")
    for name in ["mac_observe", "mac_act", "computer_open_url", "computer_screenshot", "agent_start", "research_start"] {
      try check(without.contains(name), "The assistant's run keeps \(name)")
    }
    try check(W.tabTools.contains("open_tab") && W.tabTools.contains("navigate"), "The isolated names are refused too")
    try check(!W.tabTools.contains("mac_act") && !W.tabTools.contains("computer_screenshot"), "The Mac tools are not tab tools")

    let start = ToolSchema.offered(full + [W.flag]).first { $0["name"] as? String == "agent_start" }
    let schema = start?["inputSchema"] as? [String: Any]
    let destination = (schema?["properties"] as? [String: Any])?["destination"] as? [String: Any]
    let choices = destination?["enum"] as? [String] ?? []
    try check(!choices.isEmpty && !choices.contains("web"), "agent_start offers no web destination to the assistant")
    try check(choices.contains("mac") && choices.contains("project"), "agent_start keeps its other destinations")
    let words = start?["description"] as? String ?? ""
    try check(!words.contains("isolated tabs") && words.contains("mac (Mac apps)"), "agent_start's description drops only the web destination")
    let other = ToolSchema.offered(["--relay"]).first { $0["name"] as? String == "agent_start" }
    let otherChoices = (((other?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["destination"] as? [String: Any])?["enum"] as? [String] ?? []
    try check(otherChoices.contains("web"), "Without the flag, agent_start keeps web")

    try check(W.promptLine.contains("mac_observe") && W.promptLine.contains("computer_open_url"), "The prompt sends websites to a Mac")
    try check(W.promptLine.contains("signed in"), "The prompt sends a site that needs the person's account to their Mac")
    try check(W.refusal.contains("mac_observe") && W.refusal.contains("computer_open_url"), "A refused tab tool names both Macs")
  }
}
#endif
