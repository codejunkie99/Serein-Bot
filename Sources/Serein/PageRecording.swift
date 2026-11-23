import AppKit
import AVFoundation
import CoreVideo
import SereinCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A manual, local recording. Frames come only from the selected WKWebView's bounds, never
/// from a window or display capture. No recording tool or file is exposed to agents.
@MainActor final class PageViewportRecorder: ObservableObject {
  static let shared = PageViewportRecorder()
  enum State { case idle, starting, recording, finishing, ready, saving }
  private enum FrameUnavailable: Error { case resized }
  @Published private(set) var state: State = .idle
  @Published private(set) var seconds = 0
  @Published private(set) var paused = false
  private(set) var tabID: String?
  private weak var tab: BrowserTab?
  private weak var web: WKWebView?
  private weak var browser: BrowserModel?
  private var movie: ViewportMovieWriter?
  private var loop: Task<Void, Never>?
  private var directory: URL?
  private var output: URL?
  private var elapsed = 0.0
  private let automaticallyOfferSave: Bool
  init(automaticallyOfferSave: Bool = true) { self.automaticallyOfferSave = automaticallyOfferSave }
  var busy: Bool { state != .idle }
  var duration: String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }

  static func eligible(_ tab: BrowserTab?) -> Bool {
    guard let tab else { return false }
    return !tab.privateMode && tab.owner == nil && !tab.sleeping && !tab.address.isEmpty
  }

  func belongs(to browser: BrowserModel) -> Bool { self.browser === browser }

  func start(tab: BrowserTab, browser: BrowserModel? = nil) async throws {
    guard !busy, Self.eligible(tab), Self.visible(tab.web) else {
      throw SereinError.invalid("Open a regular webpage to record its viewport. Private and agent-owned tabs are excluded.")
    }
    state = .starting
    self.tab = tab
    web = tab.web
    tabID = tab.id
    self.browser = browser
    seconds = 0
    elapsed = 0
    paused = false
    do {
      var firstImage: CGImage?
      for _ in 0..<10 {
        do { firstImage = try await Self.snapshot(tab.web); break }
        catch FrameUnavailable.resized { try await Task.sleep(nanoseconds: 30_000_000) }
      }
      guard let image = firstImage else { throw SereinError.invalid("Let the page finish resizing before recording.") }
      guard web === tab.web, Self.eligible(tab), Self.visible(tab.web) else {
        throw SereinError.invalid("The page changed before recording could start.")
      }
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-recording-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      directory = folder
      let file = folder.appendingPathComponent("Viewport.mp4")
      output = file
      let writer = try ViewportMovieWriter(url: file, width: image.width, height: image.height)
      movie = writer
      var wroteFirstFrame = false
      for _ in 0..<50 {
        if try await writer.append(image, seconds: 0) { wroteFirstFrame = true; break }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      guard wroteFirstFrame else { throw SereinError.invalid("The video encoder did not become ready.") }
      state = .recording
      loop = Task { [weak self] in await self?.captureFrames() }
    } catch {
      await movie?.cancel()
      cleanup()
      throw error
    }
  }

  private static func visible(_ web: WKWebView) -> Bool {
    guard let window = web.window else { return false }
    return window.isVisible && !window.isMiniaturized && !web.isHiddenOrHasHiddenAncestor
      && web.fullscreenState == .notInFullscreen && web.bounds.width >= 2 && web.bounds.height >= 2
  }

  static func snapshot(_ web: WKWebView) async throws -> CGImage {
    let bounds = web.bounds
    let configuration = WKSnapshotConfiguration()
    configuration.rect = bounds
    let scale = web.window?.backingScaleFactor ?? 2
    configuration.snapshotWidth = NSNumber(value: Double(min(1600 / scale, web.bounds.width)))
    configuration.afterScreenUpdates = false
    let picture = try await web.takeSnapshot(configuration: configuration)
    // A live resize can change the viewport while WebKit is preparing the bitmap. Drop that
    // frame rather than include content outside the new viewport; the next frame retries.
    guard web.bounds == bounds else { throw FrameUnavailable.resized }
    guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw SereinError.invalid("This page could not be recorded.")
    }
    return image
  }

  private func captureFrames() async {
    var previous = ProcessInfo.processInfo.systemUptime
    while !Task.isCancelled && state == .recording {
      guard let tab, let web, tab.web === web, !tab.sleeping, Self.eligible(tab) else {
        stop()
        return
      }
      let selected = browser.map { $0.section == ShellSection.browser && $0.active === tab } ?? true
      guard selected && Self.visible(web) else {
        paused = true
        try? await Task.sleep(nanoseconds: 200_000_000)
        previous = ProcessInfo.processInfo.systemUptime
        continue
      }
      paused = false
      let now = ProcessInfo.processInfo.systemUptime
      elapsed += now - previous
      previous = now
      do {
        let image = try await Self.snapshot(web)
        guard !Task.isCancelled, state == .recording else { return }
        guard tab.web === web else { stop(); return }
        if let movie { _ = try await movie.append(image, seconds: elapsed) }
        if seconds != Int(elapsed) { seconds = Int(elapsed) }
      } catch FrameUnavailable.resized {
        try? await Task.sleep(nanoseconds: 66_666_667)
        continue
      } catch {
        browser?.notice = "Recording stopped: " + error.localizedDescription
        stop()
        return
      }
      // One snapshot and one encode at a time; slow pages drop frames instead of queuing them.
      let spent = ProcessInfo.processInfo.systemUptime - now
      try? await Task.sleep(nanoseconds: UInt64(max(0.001, 1.0 / 15 - spent) * 1_000_000_000))
    }
  }

  func stop() {
    guard state == .recording else { return }
    state = .finishing
    Task {
      do {
        _ = try await completeFinish()
        if automaticallyOfferSave { await save() }
      } catch {
        browser?.notice = "Recording could not be finished: " + error.localizedDescription
        await movie?.cancel()
        cleanup()
      }
    }
  }

  /// Finishes before opening a save panel. Kept separate so native checks can inspect the MP4.
  func finish() async throws -> URL {
    guard state == .recording else {
      throw SereinError.invalid("There is no recording to finish.")
    }
    state = .finishing
    return try await completeFinish()
  }

  private func completeFinish() async throws -> URL {
    guard let movie, let output else { throw SereinError.invalid("The recording is unavailable.") }
    let capturing = loop
    capturing?.cancel()
    await capturing?.value
    loop = nil
    try await movie.finish(seconds: elapsed)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    self.movie = nil
    paused = false
    state = .ready
    return output
  }

  func save() async {
    guard state == .ready, let output else { return }
    state = .saving
    let panel = ChatExport.savePanel(
      named: ChatExport.movieName("recording", at: Date()), title: "Save page recording", types: [.mpeg4Movie])
    let answer: NSApplication.ModalResponse
    if let window = web?.window ?? NSApp.keyWindow {
      answer = await panel.beginSheetModal(for: window)
    } else {
      answer = panel.runModal()
    }
    guard answer == .OK, let destination = panel.url else {
      state = .ready // Cancel keeps the finished video available for Save or Discard.
      return
    }
    do {
      try ChatExport.place(output, at: destination)
      browser?.notice = "Saved page recording to " + destination.lastPathComponent
      cleanup()
    } catch {
      state = .ready
      browser?.notice = "Recording could not be saved. Try Save again. " + error.localizedDescription
    }
  }

  func discard() {
    guard state == .ready else { return }
    cleanup()
  }

  private func cleanup() {
    loop?.cancel()
    loop = nil
    movie = nil
    if let directory { try? FileManager.default.removeItem(at: directory) }
    directory = nil
    output = nil
    tab = nil
    web = nil
    browser = nil
    tabID = nil
    paused = false
    state = .idle
  }
}

/// H.264 in an MP4, encoded off the UI actor, with fixed even dimensions and letterboxing
/// on resize. Every input image is a WKWebView viewport; there is no screen-capture fallback.
actor ViewportMovieWriter {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let width: Int
  private let height: Int
  private var lastTime: CMTime?

  init(url: URL, width: Int, height: Int) throws {
    self.width = max(2, width / 2 * 2)
    self.height = max(2, height / 2 * 2)
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: self.width, AVVideoHeightKey: self.height,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoExpectedSourceFrameRateKey: 15],
    ])
    input.expectsMediaDataInRealTime = true
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: self.width, kCVPixelBufferHeightKey as String: self.height,
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ])
    guard writer.canAdd(input) else { throw SereinError.invalid("MP4 recording is unavailable on this Mac.") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? SereinError.invalid("MP4 recording could not start.") }
    writer.startSession(atSourceTime: .zero)
  }

  func append(_ image: CGImage, seconds: Double) throws -> Bool {
    guard writer.status == .writing else { throw writer.error ?? SereinError.invalid("The video encoder stopped.") }
    guard input.isReadyForMoreMediaData else { return false }
    guard let pool = adaptor.pixelBufferPool else { throw SereinError.invalid("The video encoder has no frame buffer.") }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
      throw SereinError.invalid("There is not enough memory for another recording frame.")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
      throw SereinError.invalid("The recording frame could not be drawn.")
    }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
    let w = Double(image.width) * scale, h = Double(image.height) * scale
    context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
    let time = max(CMTime(seconds: seconds, preferredTimescale: 600), lastTime.map { $0 + CMTime(value: 1, timescale: 600) } ?? .zero)
    guard adaptor.append(buffer, withPresentationTime: time) else {
      throw writer.error ?? SereinError.invalid("The recording frame could not be encoded.")
    }
    lastTime = time
    return true
  }

  func finish(seconds: Double) async throws {
    guard let lastTime else { writer.cancelWriting(); throw SereinError.invalid("No video frames were recorded.") }
    writer.endSession(atSourceTime: max(CMTime(seconds: seconds, preferredTimescale: 600), lastTime + CMTime(value: 1, timescale: 15)))
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? SereinError.invalid("The recording could not be saved as MP4.") }
  }
  func cancel() { if writer.status == .writing { writer.cancelWriting() } }
}

/// ⋯ › Record This Page…: starts recording this page's viewport; while it records the row reads
/// Stop and Save Recording, and once it stops, Save Recording…. The red line under the page
/// (`PageRecordingStatus`) shows the time and the same actions.
@MainActor enum PageRecordAction {
  static func title(_ recorder: PageViewportRecorder = .shared) -> String {
    switch recorder.state {
    case .ready, .saving: return "Save Recording…"
    case .idle: return "Record This Page…"
    default: return "Stop and Save Recording"
    }
  }
  static func icon(_ recorder: PageViewportRecorder = .shared) -> String {
    recorder.state == .ready ? "square.and.arrow.down" : recorder.busy ? "stop.circle" : "record.circle"
  }
  static func enabled(_ browser: BrowserModel, _ recorder: PageViewportRecorder = .shared) -> Bool {
    recorder.busy ? [.recording, .ready].contains(recorder.state)
      : browser.section == ShellSection.browser && PageViewportRecorder.eligible(browser.active)
  }
  static func run(_ browser: BrowserModel, _ recorder: PageViewportRecorder = .shared) {
    if recorder.state == .recording {
      recorder.stop()
    } else if recorder.state == .ready {
      Task { await recorder.save() }
    } else if !recorder.busy, let tab = browser.active {
      Task {
        do { try await recorder.start(tab: tab, browser: browser) } catch { browser.notice = error.localizedDescription }
      }
    }
  }
}

struct PageRecordingStatus: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject private var recorder = PageViewportRecorder.shared
  @Environment(\.palette) private var p
  var body: some View {
    if recorder.busy && recorder.belongs(to: browser) {
      HStack(spacing: 8) {
        Circle().fill(p.danger).frame(width: 6, height: 6).accessibilityHidden(true)
        Text(status).font(UIStyle.meta)
        Spacer(minLength: 4)
        if recorder.state == .recording {
          Button("Stop and save") { recorder.stop() }.buttonStyle(QuietButton())
        } else if recorder.state == .ready {
          Button("Save…") { Task { await recorder.save() } }.buttonStyle(QuietButton())
          Button("Discard") { recorder.discard() }.buttonStyle(QuietButton())
        }
      }.foregroundStyle(p.ink).padding(.horizontal, 12).padding(.vertical, 4)
        .background(p.card).accessibilityElement(children: .contain).accessibilityLabel("Page recording")
    }
  }
  private var status: String {
    switch recorder.state {
    case .recording: return (recorder.paused ? "Paused · return to the recorded tab" : "Recording page") + " · " + recorder.duration
    case .starting: return "Starting page recording…"
    case .finishing: return "Finishing page recording…"
    case .ready: return "Page recording ready · " + recorder.duration
    case .saving: return "Save page recording"
    case .idle: return ""
    }
  }
}
