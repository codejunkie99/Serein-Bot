#if DEBUG
import Foundation
import SereinCore

/// The glow around the screen's edge (ScreenSignal.swift): when it is on, and the words a Mac
/// step reads in.
extension AssistantCoreChecks {
  static func screenSignal(_ check: Check) throws {
    let start = Date(timeIntervalSince1970: 1_000)
    func glows(_ state: RelayLook.State, _ controls: [Bool]) -> Bool {
      ScreenSignal.resolve(state: state, work: controls.map(ScreenSignal.Work.init(controls:))).glow
    }
    try check(!glows(.idle, []) && !glows(.working, [false, false]), "No glow for work outside a Mac app or a page")
    try check(glows(.working, [false, true]) && glows(.idle, [true]) && glows(.alert, [true]),
      "One run at the controls is enough for the glow, whatever the hologram's state")
    try check(!glows(.dormant, [true]), "Paused: no glow, even with a run on the board")

    for tool in ["mac_observe", "mac_act", "mac_script", "navigate", "click", "fill", "read", "screenshot", "page_tool"] {
      try check(ScreenSignal.holdsControls(tool: tool, at: start, otherAt: nil), "\(tool) holds the controls")
    }
    for tool in ["computer_click", "computer_type", "mail_search", "calendar_read", "finish", "settings_set"] {
      try check(!ScreenSignal.holdsControls(tool: tool, at: start, otherAt: nil), "\(tool) is not a step in a Mac app or a page")
    }
    try check(!ScreenSignal.holdsControls(tool: nil, at: nil, otherAt: start), "A run with no board step holds nothing")
    try check(!ScreenSignal.holdsControls(tool: "mac_act", at: start, failed: true, otherAt: nil),
      "A step that failed or was refused does not hold the controls")
    try check(!ScreenSignal.holdsControls(tool: "mac_act", at: start, waiting: true, otherAt: nil),
      "A run that waits on its own card does not hold the controls")
    try check(!ScreenSignal.holdsControls(tool: "click", at: start, otherAt: start.addingTimeInterval(1)),
      "A run that turned to other work after its page step let go of the controls")
    try check(ScreenSignal.holdsControls(tool: "click", at: start.addingTimeInterval(1), otherAt: start),
      "A page step after other work takes them again")

    func step(_ tool: String, _ arguments: [String: Any]) -> String { RunNow.present(AgentStep.label(tool: tool, arguments: arguments)) }
    try check(step("mac_observe", ["app": "Mail"]) == "Looking at Mail" && step("mac_observe", [:]) == "Checking the open apps",
      "Looking at a Mac app is named by the app")
    try check(step("mac_act", ["app": "Mail", "kind": "click"]) == "Clicking in Mail"
      && step("mac_act", ["app": "Notes", "kind": "scroll"]) == "Scrolling in Notes"
      && step("mac_act", ["app": "Notes", "kind": "key", "key": "return"]) == "Pressing return in Notes",
      "A step in a Mac app is named by its kind and the app")
    try check(step("mac_act", ["app": "Notes", "kind": "type", "text": "my secret answer"]) == "Typing in Notes",
      "Typing in a Mac app never names the text")
    try check(RunNow.present("Clicked “Send” in Mail") == "Clicking “Send” in Mail"
      && RunNow.present("Typed into “Subject” in Mail") == "Typing into “Subject” in Mail",
      "Once a Mac step ran, its line names the control")
    func cli(_ tool: String) -> String? { RunNow.claudeTool("mcp__serein_browser__" + tool, input: [:], folder: nil)?.now }
    try check(cli("mac_act") == "Working in a Mac app" && cli("mac_observe") == "Looking at a Mac app",
      "The AI app's own Now line for a Mac step is in words")
  }
}
#endif
