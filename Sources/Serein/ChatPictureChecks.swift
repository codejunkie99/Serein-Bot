#if DEBUG
import AppKit
import Foundation
import SereinCore

/// `--verify-chat-pictures`: a screenshot a task takes shows in its chat, and a line that is
/// only a Markdown image shows a local picture. No window and no provider: the run is /bin/sleep.
@MainActor func checkChatPictures() async throws {
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("FAIL: " + label) }
    print("PASS: " + label)
    fflush(stdout)
  }
  try await checkComputerPictureHeader(check)
  // A line that is only a Markdown image is a picture; one inside a sentence or code is not.
  func line(_ text: String, _ alt: String, _ source: String) -> Bool {
    messageImageLine(text).map { $0.alt == alt && $0.source == source } == true
  }
  try check(line("![Chart](/tmp/a.png)", "Chart", "/tmp/a.png")
    && line(#"![A shot](<~/My Pictures/s 1.png> "Title")"#, "A shot", "~/My Pictures/s 1.png")
    && messageImageLine("Look at ![x](/tmp/a.png) here") == nil,
    "A line that is only a Markdown image is read as a picture, with a path in <> and a title")
  try check(messagePieces("Before\n![S](/tmp/a.png)\nAfter") == [
    MessagePiece(id: 0, content: .prose("Before\n")),
    MessagePiece(id: 1, content: .image(source: "/tmp/a.png", alt: "S")),
    MessagePiece(id: 2, content: .prose("After")),
  ] && messagePieces("```\n![S](/tmp/a.png)\n```") == [MessagePiece(id: 0, content: .code("![S](/tmp/a.png)\n", language: nil))],
    "A picture line splits the prose, and stays text inside a code block")

  let root = FileManager.default.temporaryDirectory.appendingPathComponent("serein-pictures-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let browser = try BrowserModel(root: root)
  defer { browser.shutdown() }
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
  guard let png = bitmap?.representation(using: .png, properties: [:]) else { throw SereinError.invalid("FAIL: no test picture") }
  guard let saved = browser.saveChatPicture(png) else { throw SereinError.invalid("FAIL: the picture was not saved") }
  try check(saved.hasPrefix("chat-images/") && saved.hasSuffix(".png")
    && FileManager.default.fileExists(atPath: root.appendingPathComponent(saved).path),
    "A screenshot is saved in the library's chat-images folder")

  // Only a local image file shows: no web address, no other kind of file, nothing outside chat-images.
  try check(MessageImage.file(saved, library: root)?.path == root.appendingPathComponent(saved).path
    && MessageImage.file(root.appendingPathComponent(saved).path, library: root) != nil
    && MessageImage.file("file://" + root.appendingPathComponent(saved).path, library: root) != nil,
    "A picture shows from its library path, an absolute path and a file address")
  try check(MessageImage.file("https://example.com/a.png", library: root) == nil
    && MessageImage.file("chat-images/../secret.png", library: root) == nil
    && MessageImage.file("notes/a.png", library: root) == nil
    && MessageImage.file("/etc/hosts", library: root) == nil
    && MessageImage.file("/no/such/picture.png", library: root) == nil,
    "A web address, a path out of chat-images, another kind of file and a missing file show no picture")
  // A picture outside the chat's folders (Messages attachments, Photos) does not show, also not
  // through a symlink in chat-images; one in the thread's project does.
  let project = FileManager.default.temporaryDirectory.appendingPathComponent("serein-project-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: project) }
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  let outside = project.appendingPathComponent("chart.png")
  try png.write(to: outside)
  try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("chat-images/link.png"), withDestinationURL: outside)
  try check(MessageImage.file(outside.path, library: root) == nil
    && MessageImage.file("chat-images/link.png", library: root) == nil
    && MessageImage.file(outside.path, library: root, folder: project) != nil,
    "Only a picture in the chat's folders shows: not one elsewhere, not through a symlink, yes in the project")

  // The run that owns the browser task gets the picture in its answer; text updates keep it.
  let agent = AgentModel(browser: browser, discoverProviders: false)
  let task = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
  let spec = RunSpec(threadID: UUID().uuidString, provider: .codex, executable: "/bin/sleep",
    model: "", effort: "low", mode: .research, projectID: nil, projectName: nil, title: "Pictures", scope: "",
    autoRouting: false, grants: RunGrants(), limits: .init(hard: 60, idle: 60))
  let run = try agent.hub.start(spec, task: task, arguments: ["60"], folder: root, prompt: "",
    transcript: [AgentMessage(role: "you", text: "Take a picture of the page")])
  defer {
    agent.hub.stop(run)
    browser.endTask(task.capability.task)
  }
  browser.onTaskPicture?("another-task", saved)
  try check(run.transcript.allSatisfy { ($0.images ?? []).isEmpty }, "A picture from another task does not join this chat")
  browser.onTaskPicture?(task.capability.task, saved)
  try check(run.transcript.last?.role == "assistant" && run.transcript.last?.images == [saved],
    "A screenshot joins the answer of the run that took it")
  let action = RunActivity(tool: "read", now: "Reading files", done: "Read Sources/App.swift")
  run.track(action, id: "read")
  run.track(action, id: "read")
  run.failStep("read", "Synthetic failure")
  try check(run.transcript.last?.activities?.count == 1 && run.transcript.last?.activities?.first?.failed == true
    && run.transcript.last?.images == [saved], "A live action is deduplicated, marked failed and retained with its picture")
  run.append("Here is the page.")
  run.startNewMessage()
  run.append("Done.")
  try check(run.transcript.last?.text == "Done." && run.transcript.last?.images == [saved],
    "The picture stays with the answer while its text streams and moves to the commentary")
  let stored = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(run.transcript.last!))
  let older = try JSONDecoder().decode(AgentMessage.self, from: Data(#"{"id":"m","role":"assistant","text":"Hi"}"#.utf8))
  try check(stored.images == [saved] && stored.activities?.count == 1 && older.images == nil && older.activities == nil,
    "Pictures and actions are saved with the thread, and older threads still open")
}
/// Exercise Vision and the outgoing PNG together, including where the hidden pixels land.
@MainActor private func checkComputerPictureHeader(_ check: (Bool, String) throws -> Void) async throws {
  func picture(secondY: CGFloat) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 720, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw SereinError.invalid("Could not create the screenshot fixture") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1000, height: 720).fill()
    let style: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .medium),
                                                .foregroundColor: NSColor.black]
    for (text, y) in [("Group 42424242", CGFloat(664)), ("Reference 42424242", secondY), ("Notebook ready", CGFloat(210))] {
      (text as NSString).draw(at: NSPoint(x: 100, y: y), withAttributes: style)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SereinError.invalid("Could not encode screenshot fixture") }
    return png
  }
  let header = try picture(secondY: 615)
  try check(await BoxPictureMask.shows(header), "An unchecked picture containing the split test card is withheld")
  guard let safe = await BoxPictureMask.screenedPNG(header), let bitmap = NSBitmapImageRep(data: safe) else {
    throw SereinError.invalid("The header could not be safely covered")
  }
  // NSBitmapImageRep pixel indices start at the top.
  func brightness(_ y: Int) -> CGFloat? { bitmap.colorAt(x: 10, y: y)?.usingColorSpace(.deviceRGB)?.redComponent }
  try check(brightness(90) == 0 && brightness(210) == 1, "The outgoing PNG covers the header and keeps the page below it")
  try check(await BoxPictureMask.screenedPNG(try picture(secondY: 370)) == nil, "Digits split between the header and the page withhold the screenshot")
  let edges = try picture(secondY: 35)
  guard let covered = await BoxPictureMask.screenedPNG(edges), let panel = NSBitmapImageRep(data: covered) else {
    throw SereinError.invalid("The desktop panels could not be safely covered")
  }
  func red(_ y: Int) -> CGFloat? { panel.colorAt(x: 110, y: y)?.usingColorSpace(.deviceRGB)?.redComponent }
  try check(red(50) == 0 && red(660) == 0 && red(360) == 1, "Split numbers on opposite panels are covered and the middle stays visible")
  let task = UUID().uuidString
  FilledValues.shared.add("private fixture", task: task)
  defer { FilledValues.shared.forget(task: task) }
  try check(await BoxPictureMask.screenedPNG(header) == nil, "Registered private values keep the original withholding rule")
}
#endif
