#if DEBUG
import AVFoundation
import SereinCore
import WebKit

extension SmokeTest {
  @MainActor static func reviewRegressions(browser: BrowserModel, agent: AgentModel) async throws -> [String] {
    var results: [String] = []
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    let base = ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"]!
    let tab = BrowserTab(store: .nonPersistent())
    try tab.navigate(base + "plain")
    for _ in 0..<100 {
      if !tab.web.isLoading, tab.web.url != nil { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    await tab.settle(limit: 3)
    let plain = await ComposerContext.capture(tab)
    try check(!plain.sensitive && plain.text.contains("Seat map"), "Regular page context remains readable")
    _ = try await tab.script("document.body.appendChild(Object.assign(document.createElement('iframe'),{src:'\(base.replacingOccurrences(of: "127.0.0.1", with: "localhost"))frame'})); true")
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let framed = await ComposerContext.capture(tab)
    try check(framed.sensitive && framed.text.isEmpty, "Cross-origin sensitive frame excludes page context")
    _ = try await tab.script("document.querySelector('iframe').remove(); true")
    tab.frames = tab.frames.filter { $0.value.isMainFrame }
    // Inject the race at the reader boundary, after the first sensitivity probe.
    _ = try await tab.script("globalThis.originalRead=__serein.readContext; __serein.readContext=(...a)=>({...originalRead(...a),sensitive:true,text:'must stay private'}); true")
    let raced = await ComposerContext.capture(tab)
    try check(raced.sensitive && raced.text.isEmpty, "Capture honors sensitivity returned with the text")
    _ = try await tab.script("__serein.readContext=(...a)=>({...originalRead(...a),documentID:'different-document'}); true")
    let navigated = await ComposerContext.capture(tab)
    try check(navigated.sensitive && navigated.text.isEmpty, "Capture rejects a changed document identity")
    _ = try await tab.script("__serein.readContext=originalRead; true")

    let setting = GateSettings.shared.object(forKey: FeaturePolicy.key(.routing))
    defer { GateSettings.shared.set(setting, forKey: FeaturePolicy.key(.routing)) }
    FeaturePolicy.set(.routing, false)
    let oldMode = agent.mode
    let oldError = agent.error
    agent.mode = .auto
    agent.route("synthetic routing privacy check")
    try check(!agent.running && agent.error?.contains("Automatic routing is off") == true,
      "Disabled routing refuses the classifier before connecting a provider")
    agent.mode = oldMode
    agent.error = oldError

    let owned = BrowserTab(owner: "review-takeover", store: .nonPersistent())
    browser.agentTabs.opened(owned, task: "review-takeover", isolated: false)
    try owned.navigate(base + "plain")
    for _ in 0..<100 {
      if !owned.web.isLoading, owned.web.url != nil { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    await owned.settle(limit: 3)
    let denied = try await owned.web.evaluateJavaScript("Notification.permission") as? String
    browser.takeOver(owned)
    try await Task.sleep(nanoseconds: 200_000_000)
    let adopted = try await owned.web.evaluateJavaScript("window.__sereinSite.deny") as? Bool
    let permission = try await owned.web.evaluateJavaScript("Notification.permission") as? String
    try check(denied == "denied" && adopted == false && permission == "default",
      "Takeover restores site features in the existing document")
    try owned.navigate(base + "plain")
    await owned.settle(limit: 3)
    let next = try await owned.web.evaluateJavaScript("window.__sereinSite.deny") as? Bool
    try check(next == false, "Taken-over tab retains site features after navigation")
    browser.close(owned)

    let session = SessionExtras.shared
    session.attach(browser)
    let foldTab = browser.newTab(base + "plain", select: false)
    session.fold([foldTab], name: "Review fixture")
    let group = session.folded.first!
    ClosedWindows.record([base + "plain"], browser: browser)
    session.forgetHistory(nil)
    let before = browser.tabs.count
    session.restore(group)
    try check(browser.recentlyClosed.isEmpty && session.folded.isEmpty && !ClosedWindows.canReopen
      && browser.tabs.count == before
      && !FileManager.default.fileExists(atPath: browser.library.root.appendingPathComponent("sessions/folded.json").path),
      "Clearing reopen data removes folded tabs, windows, disk records and stale undo actions")

    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
    buffer.frameLength = 160
    for i in 0..<160 { buffer.floatChannelData![0][i] = 0 }
    let file = browser.library.root.appendingPathComponent("recording-check.caf")
    let audio = PendingTalkAudio()
    audio.append(buffer)
    try check(!FileManager.default.fileExists(atPath: file.path), "Pending dictation audio stays off disk")
    audio.discard()
    try check(!audio.save(to: file) && !FileManager.default.fileExists(atPath: file.path),
      "Sensitive or cancelled dictation cannot be saved")
    let safeAudio = PendingTalkAudio()
    safeAudio.append(buffer)
    let saved = safeAudio.save(to: file)
    let frames = (try? AVAudioFile(forReading: file).length) ?? 0
    try check(saved && frames == 160, "Approved dictation recording remains playable")
    try? FileManager.default.removeItem(at: file)
    return results
  }
}
#endif
