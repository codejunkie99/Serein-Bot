import AppKit
import ApplicationServices
import SereinCore

/// Show and tell: while the person holds the key and speaks, Serein notes the app they are in,
/// the text they have selected, and what the pointer rests on, circles or underlines, so “this”
/// and “that” in their words have something to mean (`ScreenContext`).
///
/// - Only while "Share what I select or point at while I talk" is on (a gate, off by default),
///   and only from the hold to the release: nothing is read at any other time.
/// - Text comes through Accessibility from the app that was in front when the key went down.
///   Where the pointer was is read twenty-five times a second; no click and no key is read.
/// - With "Include a picture of that window" also on, one picture of that window alone is taken
///   at the release (`MacControl.windowPicture`, which needs Screen Recording), with a ring round
///   what the pointer marked.
/// - A file the pointer is on (a Desktop or Finder item, or the document the window shows) is
///   picked up where it is: a picture as a picture, a document Serein reads as a document. A
///   picture with no file behind it, and no picture of the window, is asked for instead: the
///   chat opens and the person drags it in (`ScreenContext.missedPicture`).
/// - Never Serein itself, a password manager (`RelayAutonomy.holdsSecrets`) or a password field.
/// - What is taken goes with the spoken message as one attachment, fenced as untrusted, and its
///   text passes the same redaction as every attachment.
@MainActor final class ScreenContextCapture: ObservableObject {
  static let shared = ScreenContextCapture()
  nonisolated static var enabled: Bool { GateSettings.shared.bool(forKey: ScreenContext.enabledKey) }
  nonisolated static var pictureEnabled: Bool { enabled && GateSettings.shared.bool(forKey: ScreenContext.pictureKey) }

  /// What is being noted while the key is held, for the bar: "Pages · circled".
  @Published private(set) var seeing: String?

  /// What one hold took: the attachment's text, the window's picture when there is one, and the
  /// files the pointer was on, each a chip of its own.
  struct Captured {
    var context: ScreenContext
    var picture: PageContext.Picture?
    var files: [SereinAttachment] = []
    /// Every chip that goes with the spoken message: what was shown first, then the files.
    var attachments: [SereinAttachment] {
      [SereinAttachment(
        title: context.title, icon: "cursorarrow.rays", body: context.body, suffix: context.summary,
        note: "What you selected or pointed at while you spoke. Serein gets it with your message", picture: picture)]
        + files
    }
    /// Every waiting file of this hold, for a hold whose words never go.
    var filePaths: [String] { attachments.flatMap(\.filePaths) }
  }

  private var app: NSRunningApplication?
  private var trail: [PointerGesture.Sample] = []
  private var timer: DispatchSourceTimer?
  private var startSelection: String?
  private static let sampleInterval = 0.04
  /// A minute of readings: a longer hold keeps its first minute.
  private static let trailLimit = 1_500
  /// How long one Accessibility question may take, so a busy app never holds up the release.
  private static let patience: Float = 0.25

  // MARK: the hold

  /// The key went down. Called before Serein's bar shows, so the app in front is still theirs.
  func begin() {
    stop()
    guard Self.enabled, let front = NSWorkspace.shared.frontmostApplication,
      front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      !RelayAutonomy.holdsSecrets(app: front.localizedName ?? "", bundleID: front.bundleIdentifier)
    else { return }
    app = front
    if MacControl.accessibilityGranted(prompt: false) { startSelection = Self.selection(in: front) }
    seeing = Self.words(app: front.localizedName ?? "", selected: startSelection != nil, gesture: .none)
    let source = DispatchSource.makeTimerSource(queue: .main)
    source.schedule(deadline: .now(), repeating: Self.sampleInterval, leeway: .milliseconds(8))
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.sample() }
    }
    source.resume()
    timer = source
  }

  /// The press was a tap, or part of another shortcut: nothing is kept.
  func cancel() { stop() }

  /// The key came up: what the hold showed, or nil when it showed nothing worth sending.
  func end() async -> Captured? {
    let front = app
    let gesture = PointerGesture.classify(trail)
    let begunWith = startSelection
    stop()
    guard let front, Self.enabled else { return nil }
    let pid = front.processIdentifier
    let trusted = MacControl.accessibilityGranted(prompt: false)
    let window = trusted ? Self.focusedWindow(of: front) : nil
    let selection = trusted ? (Self.selection(in: front) ?? begunWith) : nil
    let nothing: (items: [ScreenContext.Item], files: [URL], sawPicture: Bool) = ([], [], false)
    let found = trusted ? Self.items(for: gesture, window: window?.element) : nothing
    let items = found.items
    // The window's picture is taken first, before any file is read: it shows the window as it was
    // at the release, never what came into it while a document was read.
    var picture: PageContext.Picture?
    if Self.pictureEnabled, let window, let frame = MacControl.frame(window.element),
      let image = await MacControl.windowPicture(pid: pid, frame: frame, title: window.title)
    {
      picture = Self.save(Self.marked(image, gesture: gesture, window: frame))
    }
    // The files the pointer was on, read where they are: pictures as pictures, documents as documents.
    var files: [SereinAttachment] = []
    var sawPicture = found.sawPicture
    for url in found.files.prefix(ScreenContext.filesLimit) {
      if ComposerContext.isPicture(url) {
        if let read = try? ComposerContext.readPicture(url) { files.append(SereinSurface.pictureChip(read)) } else { sawPicture = true }
      } else if DocumentText.kind(url.resolvingSymlinksInPath()) != nil, let document = try? await ComposerContext.readDocument(url) {
        files.append(SereinAttachment(
          title: document.name, icon: "doc.text", body: "", suffix: DocumentText.suffix(document),
          note: DocumentText.detail(document) + ". Serein gets its text with your message", document: document))
      }
    }
    let context = ScreenContext(
      app: front.localizedName ?? "An app", window: window?.title, selection: selection, gesture: gesture, items: items,
      hasPicture: picture != nil, files: files.map(\.title), missedPicture: sawPicture)
    let captured = Captured(context: context, picture: picture, files: files)
    // A picture that could not be read is still worth saying: the chat asks for it.
    guard !context.isEmpty || context.missedPicture else {
      ComposerContext.discard(captured.filePaths, keeping: [])
      return nil
    }
    return captured
  }

  private func stop() {
    timer?.cancel()
    timer = nil
    app = nil
    trail = []
    startSelection = nil
    seeing = nil
  }

  private func sample() {
    guard let app, trail.count < Self.trailLimit else { return }
    let place = NSEvent.mouseLocation
    // AppKit measures from the bottom of the first screen; Accessibility from its top.
    let height = NSScreen.screens.first?.frame.height ?? 0
    trail.append(PointerGesture.Sample(x: place.x, y: height - place.y, t: ProcessInfo.processInfo.systemUptime))
    // Five times a second, the bar says what the pointer has done so far.
    if trail.count % 5 == 0 {
      let words = Self.words(
        app: app.localizedName ?? "", selected: startSelection != nil, gesture: PointerGesture.classify(trail))
      if words != seeing { seeing = words }
    }
  }

  /// "Pages · selected text · circled": only what is true so far.
  static func words(app: String, selected: Bool, gesture: PointerGesture) -> String {
    var parts: [String] = app.isEmpty ? [] : [app]
    if selected { parts.append("selected text") }
    if gesture.region != nil { parts.append(gesture.words) }
    return parts.joined(separator: " · ")
  }

  // MARK: Accessibility

  private static func element(of app: NSRunningApplication) -> AXUIElement {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, patience)
    return element
  }
  private static func child(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let raw = MacControl.value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    return (raw as! AXUIElement)
  }

  /// The text selected in the app's focused control; never a password field's.
  private static func selection(in app: NSRunningApplication) -> String? {
    guard let focused = child(element(of: app), kAXFocusedUIElementAttribute), !MacControl.isSecure(focused),
      let text = MacControl.string(focused, kAXSelectedTextAttribute),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return text
  }

  static func focusedWindow(of app: NSRunningApplication) -> (element: AXUIElement, title: String)? {
    guard let window = child(element(of: app), kAXFocusedWindowAttribute) else { return nil }
    // The app's timeout does not pass to its window; without this a title could wait seconds.
    AXUIElementSetMessagingTimeout(window, patience)
    return (window, MacControl.string(window, kAXTitleAttribute) ?? "")
  }

  /// What is under the pointer, or at each probe of what it circled or underlined: its text, the
  /// files behind it, and whether it was a picture with no file. Any app's control counts (the
  /// Desktop's icons are Finder's whatever app is in front), but never Serein's own, a password
  /// manager's or a password field, and only Finder's stands for a file (`ScreenContext.namesFiles`).
  /// With no file under the pointer, the window's own document.
  private static func items(for gesture: PointerGesture, window: AXUIElement?)
    -> (items: [ScreenContext.Item], files: [URL], sawPicture: Bool)
  {
    let points: [(x: Double, y: Double)]
    switch gesture {
    case .none: return ([], [], false)
    case .rested(let x, let y): points = [(x, y)]
    case .circled(let region): points = region.probes()
    case .underlined(let region): points = region.probes(columns: 5, rows: 1)
    }
    let system = AXUIElementCreateSystemWide()
    // On the system-wide element this is the whole process's timeout, so it lasts only for these
    // reads: 0 puts the default back, and `MacControl`'s later calls wait as long as they did.
    AXUIElementSetMessagingTimeout(system, patience)
    defer { AXUIElementSetMessagingTimeout(system, 0) }
    var items: [ScreenContext.Item] = []
    var files: [URL] = []
    var sawPicture = false
    var allowed: [pid_t: Bool] = [:]
    for point in points {
      var found: AXUIElement?
      guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success, let found
      else { continue }
      var owner: pid_t = 0
      guard AXUIElementGetPid(found, &owner) == .success, readable(owner, known: &allowed), !MacControl.isSecure(found)
      else { continue }
      AXUIElementSetMessagingTimeout(found, patience)
      let role = MacControl.role(found) ?? ""
      if ScreenContext.namesFiles(bundleID: NSRunningApplication(processIdentifier: owner)?.bundleIdentifier),
        let file = fileURL(of: found)
      {
        if !files.contains(file) { files.append(file) }
        items.append(ScreenContext.Item(kind: "file", text: file.lastPathComponent))
        continue
      }
      if role == "AXImage" { sawPicture = true }
      let value = MacControl.string(found, kAXValueAttribute) ?? ""
      // The line under the pointer when the control can say it; else its own short text; else
      // its name. A whole document's text is never taken for one point.
      let text =
        line(in: found, at: point)
        ?? (value.isEmpty || value.count > ScreenContext.itemLimit ? nil : value)
        ?? MacControl.label(found)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      items.append(ScreenContext.Item(kind: ScreenContext.kind(role: role), text: text))
    }
    // Nothing under the pointer was a file: the document the window shows stands for it (a
    // picture open in Preview, a PDF), when the pointer was on a picture or on nothing readable.
    if files.isEmpty, sawPicture || items.isEmpty, let window, let frame = MacControl.frame(window),
      let first = points.first, frame.contains(CGPoint(x: first.x, y: first.y)),
      let shown = MacControl.string(window, kAXDocumentAttribute), let url = URL(string: shown), url.isFileURL
    {
      files.append(url)
    }
    // A picture whose file is picked up was not missed.
    if files.contains(where: { ComposerContext.isPicture($0) }) { sawPicture = false }
    return (items, files, sawPicture)
  }

  /// An app whose controls may be read: not Serein, and not a password manager.
  private static func readable(_ pid: pid_t, known: inout [pid_t: Bool]) -> Bool {
    if let answer = known[pid] { return answer }
    var answer = pid != ProcessInfo.processInfo.processIdentifier
    if answer, let app = NSRunningApplication(processIdentifier: pid) {
      answer = !RelayAutonomy.holdsSecrets(app: app.localizedName ?? "", bundleID: app.bundleIdentifier)
    }
    known[pid] = answer
    return answer
  }

  /// The file a control stands for (a Desktop or Finder item says its address), looking up to
  /// three parents: an icon's picture and name are children of the item.
  private static func fileURL(of element: AXUIElement) -> URL? {
    var current: AXUIElement? = element
    for _ in 0..<4 {
      guard let control = current else { return nil }
      if let raw = MacControl.value(control, kAXURLAttribute) {
        let url = (raw as? URL) ?? (raw as? String).flatMap { URL(string: $0) }
        if let url, url.isFileURL, (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return url }
      }
      current = child(control, kAXParentAttribute)
    }
    return nil
  }

  /// The line of text at a screen point, for a text control that answers by position.
  private static func line(in element: AXUIElement, at point: (x: Double, y: Double)) -> String? {
    var place = CGPoint(x: point.x, y: point.y)
    guard let position = AXValueCreate(.cgPoint, &place),
      let at = range(element, kAXRangeForPositionParameterizedAttribute, position),
      let number = parameterized(element, kAXLineForIndexParameterizedAttribute, NSNumber(value: at.location)) as? NSNumber,
      var whole = range(element, kAXRangeForLineParameterizedAttribute, number), whole.length > 0,
      let wanted = AXValueCreate(.cfRange, &whole),
      let text = parameterized(element, kAXStringForRangeParameterizedAttribute, wanted) as? String
    else { return nil }
    return text
  }
  private static func parameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> AnyObject? {
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &out) == .success else {
      return nil
    }
    return out
  }
  private static func range(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFRange? {
    guard let raw = parameterized(element, attribute, parameter), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
  }

  // MARK: the picture

  /// The window's picture with a ring round what the pointer marked (a small one where it rested).
  private static func marked(_ image: CGImage, gesture: PointerGesture, window frame: CGRect) -> CGImage {
    let region: PointerGesture.Region
    switch gesture {
    case .none: return image
    case .rested(let x, let y): region = PointerGesture.Region(minX: x - 18, minY: y - 18, maxX: x + 18, maxY: y + 18)
    case .circled(let circled): region = circled
    case .underlined(let underlined): region = underlined
    }
    guard frame.width > 0, frame.height > 0,
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.draw(image, in: full)
    let sx = CGFloat(image.width) / frame.width, sy = CGFloat(image.height) / frame.height
    // The window is measured from its top; a bitmap context draws from its bottom.
    let box = CGRect(
      x: (CGFloat(region.minX) - frame.minX) * sx, y: CGFloat(image.height) - (CGFloat(region.maxY) - frame.minY) * sy,
      width: CGFloat(region.width) * sx, height: CGFloat(region.height) * sy
    ).insetBy(dx: -8 * sx, dy: -8 * sy).intersection(full)
    guard box.width > 2, box.height > 2 else { return image }
    let corner = min(14 * sx, box.width / 2, box.height / 2)
    context.setStrokeColor(CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1))
    context.setLineWidth(max(3, 3 * sx))
    context.addPath(CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil))
    context.strokePath()
    return context.makeImage() ?? image
  }

  /// The picture as a waiting file in the attachments folder (0600), like a picture the person
  /// attached: it is staged into the turn's own folder when the message goes and deleted after.
  private static func save(_ image: CGImage) -> PageContext.Picture? {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]),
      let url = try? ComposerContext.attachmentURL(name: "window", extension: "jpg")
    else { return nil }
    do {
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return PageContext.Picture(path: url.path, name: "window.jpg")
  }
}
