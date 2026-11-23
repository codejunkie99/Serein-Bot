import AppKit
import ImageIO
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

/// Step pictures: after each step in Serein's computer that succeeded, the computer's screen as
/// the helper showed it (ComputerHost.call), 480 pixels wide as a JPEG, in the task's own folder
/// in the Library (`step-pictures/<task>`, 0700, each picture 0600). They are the person's alone:
/// the step timeline shows them (StepTimeline, StepPictureSheet); no prompt, tool answer or folder
/// an agent may read ever holds one. They follow task recordings' time (Settings › Privacy,
/// StepPicturePolicy.kept): hourly once past it, and at launch and quit. Scaling and writing run
/// off the main thread, after the step has returned. A step other than a screenshot is pictured
/// only on Docker and the built-in computer (ComputerHost.picture(after:)).
@MainActor final class StepPictures: ObservableObject {
  static let shared = StepPictures()
  static let folder = "step-pictures"
  /// Step id -> its picture, for the timeline.
  @Published private(set) var files: [String: URL] = [:]
  private weak var browser: BrowserModel?
  /// Hourly retention while Serein stays open, as task recordings have.
  private var sweep: Task<Void, Never>?

  private var directory: URL? { browser?.library.root.appendingPathComponent(Self.folder, isDirectory: true) }

  /// At launch: deletes what is due, then lists what is left.
  func attach(_ browser: BrowserModel) {
    self.browser = browser
    guard let directory else { return }
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    cleanup(launchOrQuit: true)
    var found: [String: URL] = [:]
    for folder in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
      for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "jpg" {
        let step = file.deletingPathExtension().lastPathComponent
        if StepPicturePolicy.safeName(step) { found[step] = file }
      }
    }
    files = found
    sweep?.cancel()
    sweep = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        guard let self, !Task.isCancelled else { return }
        self.cleanup(launchOrQuit: false)
      }
    }
  }

  /// At quit: what is due goes, every task's under "Until quit".
  func quit() {
    sweep?.cancel()
    sweep = nil
    cleanup(launchOrQuit: true)
  }

  /// One task folder at a time, by its newest picture (the folder's own date moves with each one
  /// written); anything in the folder that is not a task's goes too.
  private func cleanup(launchOrQuit: Bool, now: Date = Date()) {
    guard let directory else { return }
    let fm = FileManager.default
    let days = UserDefaults.standard.integer(forKey: TaskRecordings.keepKey)
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
    for folder in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [] {
      let task = folder.lastPathComponent
      let values = try? folder.resourceValues(forKeys: keys)
      let kept = values?.isDirectory == true && StepPicturePolicy.safeName(task)
        && StepPicturePolicy.kept(
          newest: values?.contentModificationDate ?? .distantPast, now: now, days: days, launchOrQuit: launchOrQuit,
          running: browser?.tasks[task] != nil)
      if kept { continue }
      try? fm.removeItem(at: folder)
      files = files.filter { $0.value.deletingLastPathComponent().lastPathComponent != task }
    }
  }

  /// A step's screenshot (a PNG of the computer's screen, checked by ComputerHost.screenSize):
  /// scaled and written off the main thread, listed once it is on disk.
  func keep(_ png: Data, step: String, task: String) {
    guard StepPicturePolicy.safeName(step), StepPicturePolicy.safeName(task), let directory else { return }
    let folder = directory.appendingPathComponent(task, isDirectory: true)
    let file = folder.appendingPathComponent(step + ".jpg")
    Task.detached(priority: .utility) {
      guard let jpeg = StepPictures.jpeg(png), StepPictures.write(jpeg, to: file, in: folder) else { return }
      await StepPictures.shared.listed(step, file)
    }
  }
  private func listed(_ step: String, _ file: URL) { files[step] = file }

  /// The picture `StepPicturePolicy.width` pixels wide: the thumbnail's longer side is given, so a
  /// screen taller than wide comes out as wide too.
  nonisolated static func jpeg(_ png: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
      let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue, width > 0, height > 0
    else { return nil }
    let longest = (Double(StepPicturePolicy.width) * max(width, height) / width).rounded()
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(longest),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: StepPicturePolicy.quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return out as Data
  }

  /// The task's folder at 0700 and the picture at 0600; a picture that cannot be made private is removed.
  nonisolated private static func write(_ jpeg: Data, to file: URL, in folder: URL) -> Bool {
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard fm.createFile(atPath: file.path, contents: jpeg, attributes: [.posixPermissions: 0o600]) else { return false }
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return true
    } catch {
      try? fm.removeItem(at: file)
      return false
    }
  }
}

/// A step's picture full size, from the task's step timeline, with the step it followed.
struct StepPictureSheet: View {
  let step: AgentStep
  let file: URL?
  /// The step's kind and its time from the start (StepTimeline.detail).
  let detail: String
  let close: () -> Void
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: step.label).font(UIStyle.bodyStrong).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
      Text(verbatim: StepTimeline.clock.string(from: step.time) + " · " + detail).font(UIStyle.meta).foregroundStyle(p.secondary)
      if let file, let image = NSImage(contentsOf: file) {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
          .frame(width: image.size.width, height: image.size.height)
          .clipShape(RoundedRectangle(cornerRadius: UIStyle.controlRadius))
          .accessibilityLabel("Serein's computer after this step")
      } else {
        Text("This picture was deleted.").font(UIStyle.meta).foregroundStyle(p.secondary)
      }
      Text("Kept only on this Mac and never shown to the AI. Deleted on the same schedule as task recordings (Settings › Privacy).")
        .font(UIStyle.micro).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Done", action: close).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
      }
    }
    .padding(20).frame(minWidth: 360, alignment: .topLeading).background(p.panel)
    // Esc closes it too; Done holds Return.
    .onExitCommand(perform: close)
    .accessibilityElement(children: .contain).accessibilityLabel("Picture after: \(step.label)")
  }
}
