#if DEBUG
import AppKit
import AVFoundation
import SereinCore
import WebKit

/// Real WebKit frames encoded and decoded as an MP4. Uses only a synthetic, nonpersistent page.
@MainActor func checkPageRecording() async throws {
  func require(_ value: Bool, _ message: String) throws {
    if !value { throw SereinError.invalid("Page recording check: " + message) }
  }
  let tab = BrowserTab(store: .nonPersistent())
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
    styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 440))
  chrome.wantsLayer = true
  chrome.layer?.backgroundColor = NSColor.magenta.cgColor
  window.contentView = chrome
  tab.web.frame = NSRect(x: 55, y: 65, width: 480, height: 300)
  chrome.addSubview(tab.web)
  window.orderBack(nil)
  defer { tab.discardPage(); window.close() }
  tab.address = "https://recording.preview.invalid/"
  tab.web.loadHTMLString("""
    <!doctype html><meta name="viewport" content="width=device-width">
    <style>html,body{margin:0;background:rgb(25,165,70);height:2000px}
    #outside{position:absolute;top:1000px;width:100%;height:700px;background:yellow}</style>
    <div id="outside">This is outside the viewport and must not be recorded.</div>
    """, baseURL: URL(string: tab.address))
  for _ in 0..<100 {
    if !tab.web.isLoading { break }
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  try await Task.sleep(nanoseconds: 250_000_000)
  let privateTab = BrowserTab(privateMode: true, store: .nonPersistent())
  defer { privateTab.discardPage() }
  privateTab.address = tab.address
  try require(!PageViewportRecorder.eligible(privateTab), "private tabs are excluded")
  let agentTab = BrowserTab(owner: "test-agent", store: .nonPersistent())
  defer { agentTab.discardPage() }
  agentTab.address = tab.address
  try require(!PageViewportRecorder.eligible(agentTab), "agent-owned tabs are excluded")

  let recorder = PageViewportRecorder()
  try await recorder.start(tab: tab)
  try await Task.sleep(nanoseconds: 400_000_000)
  tab.web.removeFromSuperview()
  try await Task.sleep(nanoseconds: 400_000_000)
  try require(recorder.paused, "recording pauses when the source leaves the window")
  let pausedSeconds = recorder.seconds
  try await Task.sleep(nanoseconds: 400_000_000)
  try require(recorder.seconds == pausedSeconds, "paused time is excluded")
  // The magenta browser chrome is now the only visible view. It must never become a frame.
  chrome.addSubview(tab.web)
  tab.web.frame = NSRect(x: 55, y: 65, width: 320, height: 240)
  _ = try await tab.web.evaluateJavaScript("document.documentElement.style.background='rgb(35,70,205)'; document.body.style.background='rgb(35,70,205)'")
  try await Task.sleep(nanoseconds: 600_000_000)
  try require(!recorder.paused, "returning to the source resumes recording")
  let output = try await recorder.finish()
  defer { recorder.discard() }
  try require(output.pathExtension == "mp4", "MP4 extension")
  let asset = AVURLAsset(url: output)
  let tracks = try await asset.loadTracks(withMediaType: .video)
  let audio = try await asset.loadTracks(withMediaType: .audio)
  try require(tracks.count == 1 && audio.isEmpty, "one video track, no audio")
  let duration = try await asset.load(.duration).seconds
  try require(duration > 0.5 && duration < 2.5, "valid duration without hidden-tab time")
  let size = try await tracks[0].load(.naturalSize)
  // WebKit's image representation may use points or backing pixels. Either must preserve
  // the source viewport's aspect and exclude the surrounding 640×440 magenta window.
  try require(abs(size.width / size.height - 480.0 / 300.0) < 0.02, "only the viewport's aspect is recorded")
  let decoder = AVAssetImageGenerator(asset: asset)
  decoder.requestedTimeToleranceBefore = .zero
  decoder.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 15)
  let first = try decoder.copyCGImage(at: .zero, actualTime: nil)
  let last = try decoder.copyCGImage(at: CMTime(seconds: max(0, duration - 0.15), preferredTimescale: 600), actualTime: nil)
  func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { buffer in
      let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
    }
    return bytes
  }
  for (image, name) in [(first, "first"), (last, "last")] {
    for (x, y) in [(image.width / 2, image.height / 2), (image.width / 4, image.height / 4)] {
      let color = pixel(image, x: x, y: y)
      try require(!(color[0] > 150 && color[2] > 150 && color[1] < 80), "\(name) frame excludes magenta browser chrome")
      try require(!(color[0] > 150 && color[1] > 150 && color[2] < 80), "\(name) frame excludes yellow off-viewport content")
    }
  }
  let green = pixel(first, x: first.width / 2, y: first.height / 2)
  let blue = pixel(last, x: last.width / 2, y: last.height / 2)
  try require(green[1] > green[0] + 60 && green[1] > green[2] + 60, "first frame has the green page")
  try require(blue[2] > blue[0] + 60 && blue[2] > blue[1] + 60, "last frame has the changed blue page")
  try require(recorder.state == .ready, "finished video remains available for save/cancel/retry")
  let closing = PageViewportRecorder(automaticallyOfferSave: false)
  try await closing.start(tab: tab)
  try await Task.sleep(nanoseconds: 200_000_000)
  tab.discardPage()
  for _ in 0..<80 {
    if closing.state == .ready { break }
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  try require(closing.state == .ready, "discarding the source finishes the video without keeping its page alive")
  closing.discard()
  print("PASS: viewport-only MP4 pixels, changing page, resize, hidden-source pause/resume, silent track, private/agent exclusions, and export-ready state")
}
#endif
