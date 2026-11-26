#if DEBUG
import AppKit
import Foundation
import SereinCore

extension SmokeTest {
  /// The voice pill's three holds (RelayPanel). A click before macOS has been asked about the
  /// microphone can click again. A hold from anywhere, including Talk to Serein, is not the
  /// in-window bar ⌘E left behind. A spoken stop never brings the chat forward.
  @MainActor static func voicePillListens(_ controller: RelayController, _ relay: RelayOrchestrator) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
    }
    func waitFor(_ seconds: Double, _ condition: () -> Bool) async {
      let deadline = Date().addingTimeInterval(seconds)
      while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
    let notAsked = controller.microphoneNotAsked
    let requestAccess = controller.requestMicrophoneAccess
    let listen = controller.startDictation
    let openWindow = controller.openWindow
    let chatInFront = controller.chatInFront
    let notice = relay.stopNotice
    defer {
      controller.microphoneNotAsked = notAsked
      controller.requestMicrophoneAccess = requestAccess
      controller.startDictation = listen
      controller.openWindow = openWindow
      controller.chatInFront = chatInFront
      // A press still waiting out its delay has a timer. Releasing ends it; with no hold that
      // release is a tap, and the hide below puts the bar away.
      controller.voicePill.cancel()
      controller.summonReleased()
      controller.hide()
      relay.stopNotice = notice
    }
    // No microphone and no system prompt: the checks say whether macOS has been asked.
    controller.startDictation = { _, _ in }
    var asks = 0
    controller.requestMicrophoneAccess = { asks += 1 }
    controller.microphoneNotAsked = { true }

    controller.summonPressed(listenAfter: 0)
    await waitFor(2) { controller.holding && asks == 1 }
    try check(controller.holding && asks == 1 && !controller.voicePill.pill.latched && !controller.voicePill.pill.shown,
      "Holding the shortcut before the microphone is allowed waits for the key to come up")
    controller.summonReleased()
    try check(!controller.holding && asks == 1, "Letting that key go ends the hold, and does not ask again")

    controller.talkFromMenu()
    try check(asks == 2 && !controller.holding && !controller.voicePill.pill.latched,
      "Talk to Serein, before the microphone is allowed, ends at once so another click can start it")
    controller.talkFromMenu()
    try check(asks == 3 && !controller.holding && !controller.voicePill.pill.latched,
      "That next click asks again, instead of doing nothing")
    controller.hide()

    controller.microphoneNotAsked = { false }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled], backing: .buffered, defer: false)
    controller.showInWindow(window, isPrivate: true)
    controller.hide()
    try check(controller.inWindow, "Putting the in-window bar away keeps the window it sat in")
    controller.talkFromMenu()
    try check(!controller.inWindow && controller.holding && controller.voicePill.pill.latched,
      "Talk to Serein listens from anywhere, not from the window the bar was in")
    controller.talkFromMenu()
    await waitFor(2) { !controller.holding && !controller.voicePill.pill.shown }
    try check(!controller.holding && !controller.voicePill.pill.shown, "A second click sends what Talk to Serein heard")

    controller.showInWindow(window, isPrivate: false)
    controller.hide()
    try check(controller.inWindow, "The window is still remembered after the click")
    controller.summonPressed(listenAfter: 0)
    await waitFor(2) { !controller.inWindow && controller.voicePill.pill.shown }
    try check(!controller.inWindow && controller.holding && !controller.voicePill.pill.latched,
      "A global hold leaves that window too, and listens until the key comes up")
    controller.summonReleased()
    await waitFor(2) { !controller.holding && !controller.voicePill.pill.shown }
    try check(!controller.holding && !controller.voicePill.pill.shown && !controller.inWindow,
      "Letting the key go sends the hold and stays out of the window")

    var opened = 0
    let view = SereinSurface.main.view
    let place = SereinSurface.main.place
    controller.openWindow = { opened += 1 }
    controller.chatInFront = { false }
    try check(!controller.inWindow, "The stop is said from another app, not into the in-window bar")
    controller.voicePill.beginPreview()
    controller.voicePill.release()
    controller.handOff("stop", shown: nil)
    let stopped = relay.stopNotice == .idle(working: relay.liveTasks, others: relay.otherLiveTasks)
    try check(opened == 0 && stopped && !relay.working && !relay.state.paused
      && SereinSurface.main.view == view && SereinSurface.main.place == place,
      "A spoken stop from the pill stops, and never brings the chat forward [opened: \(opened), notice: \(String(describing: relay.stopNotice))]")
    return results
  }
}
#endif
