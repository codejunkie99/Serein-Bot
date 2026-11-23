#if DEBUG
import AppKit
import SereinCore

/// Mac tools while Accessibility is off (MacAccessWait): the chat's one card, what the model
/// hears, the one turn that carries on, and the card that floats over System Settings
/// (MacAccessDragCard, MacAccessGuide).
extension AssistantCoreChecks {
  static func macAccess(_ check: Check) throws {
    try macAccessWait(check)
    try macAccessDragCard(check)
  }

  private static func macAccessWait(_ check: Check) throws {
    var wait = MacAccessWait()
    try check(wait.call("mac_observe", chat: "chat", granted: false) == MacAccessWait.toolResult,
              "A Mac tool while Accessibility is off tells the model Serein waits for it")
    try check(wait.call("mac_act", chat: "chat", granted: false) != nil && wait.chats.count == 1,
              "A second Mac tool in the same chat keeps its one card")
    try check(wait.call("mac_script", chat: "other", granted: false) == nil && wait.state(in: "other") == nil,
              "A Mac script runs through Automation and shows no Accessibility card")
    try check(wait.call("mac_observe", chat: "other", granted: true) == nil && wait.state(in: "other") == nil,
              "A Mac tool goes ahead with no card once Accessibility is on")
    try check(MacAccessWait.toolResult.contains("Do not call Mac tools again"),
              "The model hears not to try the Mac again this turn")
    try check(!wait.carryOn(chat: "chat"), "A chat whose card still waits does not carry on")

    let saved = try JSONDecoder().decode(MacAccessWait.self, from: JSONEncoder().encode(wait))
    try check(saved == wait && saved.state(in: "chat") == .waiting, "A waiting card comes back after Serein reopens")

    try check(wait.grant() && wait.state(in: "chat") == .granted, "Accessibility coming on turns the waiting card into its line")
    try check(!wait.grant(), "A second look at the same grant changes nothing")
    let granted = try JSONDecoder().decode(MacAccessWait.self, from: JSONEncoder().encode(wait))
    try check(granted.state(in: "chat") == .granted, "A granted line still waiting to carry on comes back after Serein reopens")
    try check(!wait.carryOn(chat: "other"), "Another chat does not start the follow-up")
    try check(wait.carryOn(chat: "chat"), "The chat carries on once Accessibility is on")
    try check(!wait.carryOn(chat: "chat") && wait.state(in: "chat") == nil, "The follow-up starts once, not twice")
    try check(wait.call("mac_observe", chat: "chat", granted: false) != nil && wait.state(in: "chat") == .waiting,
              "Accessibility turned off again brings the card back")

    try check(RelayAutomatic.kind(of: MacAccessWait.followUp) == .macAccess,
              "The follow-up shows in the chat as a line, not as its prompt")
    try check(RelayAutomatic.label(MacAccessWait.followUp) == MacAccessWait.line, "The line reads Serein can use your Mac now")
    try check(MacAccess.settingsLink(.accessibility) == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
              "Open Accessibility opens Privacy & Security › Accessibility")
    try check(MacAccess.Grant.allCases.filter(\.drags) == [.accessibility, .screen, .fullDisk],
              "Every pane with a list gets the drag card; Automation has no list")
    try check(MacAccess.settingsLink(.fullDisk) == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
              "Open Full Disk Access opens its own pane")
    try check(MacAccess.Grant.macActions == [.accessibility, .screen, .automation],
              "The Mac actions step keeps its three grants")
  }

  private static func macAccessDragCard(_ check: Check) throws {
    typealias D = MacAccessDragCard
    let size = CGSize(width: 320, height: 68)
    // A 1440x900 main display with a 25-point menu bar and no Dock.
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let window = CGRect(x: 400, y: 100, width: 640, height: 500)
    try check(D.appKit(window, mainHeight: 900) == CGRect(x: 400, y: 300, width: 640, height: 500),
              "A window 100 points from the top sits 300 points from the bottom on a 900-point screen")
    try check(D.origin(window: window, mainHeight: 900, visible: visible, size: size) == CGPoint(x: 560, y: 316),
              "The card sits centred just inside the bottom edge of System Settings")
    let short = CGRect(x: 400, y: 100, width: 640, height: 80)
    try check(D.origin(window: short, mainHeight: 900, visible: visible, size: size) == CGPoint(x: 560, y: 636),
              "A window too short for the card puts it just below the window")
    try check(D.origin(window: nil, mainHeight: 900, visible: visible, size: size) == CGPoint(x: 560, y: 56),
              "With no System Settings window the card sits at the bottom centre of the screen")
    let edge = CGRect(x: -200, y: 850, width: 300, height: 40)
    let kept = D.origin(window: edge, mainHeight: 900, visible: visible, size: size)
    try check(kept.x == 0 && kept.y == 0, "A window off the screen's edge keeps the card on screen")

    try check(D.close(granted: true, settingsSeen: true, settingsThere: true, elapsed: 1) == .granted,
              "The card goes once Accessibility is on")
    try check(D.close(granted: false, settingsSeen: true, settingsThere: false, elapsed: 1) == .settingsClosed,
              "The card goes when System Settings closes")
    try check(D.close(granted: false, settingsSeen: false, settingsThere: false, elapsed: 1) == nil,
              "The card stays while System Settings is still opening")
    try check(D.close(granted: false, settingsSeen: true, settingsThere: true, elapsed: 180) == .timedOut,
              "The card goes after three minutes")
    try check(D.close(granted: false, settingsSeen: true, settingsThere: true, elapsed: 179) == nil,
              "The card stays while System Settings is open and the grant has not come")

    let board = NSPasteboard(name: NSPasteboard.Name("serein.checks.mac-access-drag"))
    board.clearContents()
    board.writeObjects([MacAccessGuide.dragWriter])
    let carried = board.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL
    board.releaseGlobally()
    try check(carried?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL,
              "A drag of the card carries the running app's own bundle, not a copy")
    try check(MacAccessGuide.dragURL == Bundle.main.bundleURL && MacAccessGuide.dragURL.isFileURL,
              "A drag of the card carries Serein's own app")
  }
}
#endif
