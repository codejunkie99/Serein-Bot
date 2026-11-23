#if DEBUG
import Foundation
import SereinCore

/// Each assistant keeps its own model: a pick for one never moves another. Synthetic rosters only.
extension AssistantCoreChecks {
  static func assistantOwn(_ check: Check) throws {
    let main = RelayTeam.mainID
    let codex = AssistantRoute(provider: "codex", model: "gpt-5")
    let claude = AssistantRoute(provider: "claude", model: "opus")
    // What an assistant with no route thinks with while Serein has none: Settings' default AI app.
    let defaultApp = AssistantRoute(provider: "claude", model: "")
    func team(serein: AssistantRoute?) -> RelayTeam {
      RelayTeam(
        profiles: [RelayProfile(id: main, name: "Serein", route: serein), RelayProfile(id: "w", name: "Writer")],
        activeID: main)
    }
    func route(_ team: RelayTeam?, _ id: String) -> AssistantRoute? {
      team?.profiles.first { $0.id == id }.flatMap { team?.route(of: $0) } ?? defaultApp
    }

    let fresh = team(serein: nil)
    try check(route(fresh, "w") == defaultApp && route(fresh, main) == defaultApp,
      "With no routes, Serein and Writer both use the default AI app")
    let first = fresh.settingRoute(main, codex, fallback: defaultApp)
    try check(route(first, main) == codex && route(first, "w") == defaultApp,
      "A first pick for Serein moves only Serein: Writer stays on the default AI app")

    let stored = team(serein: claude)
    try check(route(stored, "w") == claude, "A stored Writer with no route still thinks as Serein does")
    let moved = stored.settingRoute(main, codex, fallback: defaultApp)
    try check(route(moved, main) == codex && route(moved, "w") == claude,
      "Changing Serein's model keeps Writer on the model it already thought with")
    let again = moved?.settingRoute(main, claude, fallback: defaultApp)
    try check(route(again, main) == claude && route(again, "w") == claude,
      "A later pick for Serein still leaves Writer where it was")

    let writer = stored.settingRoute("w", codex, fallback: defaultApp)
    try check(route(writer, "w") == codex && route(writer, main) == claude,
      "A pick for Writer changes only Writer")

    try MainActor.assumeIsolated {
      let pane = AssistantInspector()
      pane.follow("w")
      try check(!pane.open && pane.assistantID == nil, "A switch leaves a closed pane closed")
      pane.show(main, tab: .library)
      pane.follow("w")
      try check(pane.open && pane.assistantID == "w" && pane.tab(for: "w") == .activity,
        "A switch with the pane open redraws it for the assistant now answering, on that assistant's own tab")
      pane.follow(main)
      try check(pane.assistantID == main && pane.tab(for: main) == .library,
        "Switching back shows Serein again, on the tab it showed")
    }
  }
}
#endif
