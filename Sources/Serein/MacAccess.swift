import AppKit
import ApplicationServices
import SereinCore
import SwiftUI

/// The three macOS grants behind Mac actions (Anywhere tasks): Accessibility to see and operate
/// windows, Screen Recording for pictures of them, Automation to run approved scripts. Each row
/// shows whether it is granted now and asks for it with one click; macOS does the asking.
@MainActor enum MacAccess {
  enum Grant: String, CaseIterable, Identifiable {
    case accessibility, screen, automation, fullDisk
    var id: String { rawValue }
    /// The three behind Mac actions: the setup step and Settings › AI apps list these.
    static let macActions: [Grant] = [.accessibility, .screen, .automation]
    /// Panes whose list takes Serein's icon by drag; Automation has no list to drop into.
    var drags: Bool { self != .automation }
    var title: String {
      switch self {
      case .accessibility: return "Accessibility"
      case .screen: return "Screen Recording"
      case .automation: return "Automation"
      case .fullDisk: return "Full Disk Access"
      }
    }
    var detail: String {
      switch self {
      case .accessibility: return "Lets an agent see the controls in a Mac app and click or type in it."
      case .screen: return "Lets an agent take a picture of a Mac app's window. macOS may ask to reopen Serein."
      case .automation: return "Lets an agent run the one-step scripts you approve, through System Events."
      case .fullDisk: return "Lets Serein read Messages and see Desktop, Documents and iCloud without macOS asking."
      }
    }
    var icon: String {
      switch self {
      case .accessibility: return "hand.point.up.left"
      case .screen: return "camera.viewfinder"
      case .automation: return "applescript"
      case .fullDisk: return "internaldrive"
      }
    }
    var pane: String {
      switch self {
      case .accessibility: return "Privacy_Accessibility"
      case .screen: return "Privacy_ScreenCapture"
      case .automation: return "Privacy_Automation"
      case .fullDisk: return "Privacy_AllFiles"
      }
    }
    /// What the person does, in order, for the guided setup step.
    var steps: [String] {
      switch self {
      case .accessibility:
        return [
          "Click Allow below. macOS says Serein would like to control this computer.",
          "Choose Open System Settings. Privacy & Security › Accessibility opens.",
          "Turn on the switch next to Serein and confirm with Touch ID or your password.",
          "Come back to this window. The step ticks itself off within a few seconds.",
        ]
      case .screen:
        return [
          "Click Allow below, then Open System Settings in the macOS dialog.",
          "In Screen & System Audio Recording, turn on the switch next to Serein and confirm with Touch ID or your password.",
          "When macOS asks, choose Quit & Reopen. Serein opens again on this step.",
        ]
      case .automation:
        return [
          "Click Allow below.",
          "macOS asks whether Serein may control System Events. Click Allow.",
          "That's all. No restart is needed.",
        ]
      case .fullDisk:
        return [
          "Click Allow below. Privacy & Security › Full Disk Access opens.",
          "Drag Serein into the list, or turn on its switch, and confirm with Touch ID or your password.",
          "When macOS asks, choose Quit & Reopen.",
        ]
      }
    }
    var trouble: String {
      switch self {
      case .accessibility, .screen, .fullDisk:
        return "Serein is already listed and switched on, but this still says not allowed? That entry belongs to an older copy of Serein. Select it, click −, then click Allow again."
      case .automation:
        return "Clicked Don't Allow before? macOS won't ask again. Click Open Settings, expand Serein and turn on System Events."
      }
    }
  }
  enum State { case granted, denied, unknown }

  /// A preview's grants (`--ui-onboarding mac-one`): these read as given, the rest not. nil reads macOS.
  static var previewGranted: Set<Grant>?

  static func state(_ grant: Grant) -> State {
    if let given = previewGranted { return given.contains(grant) ? .granted : .denied }
    switch grant {
    case .accessibility: return MacControl.accessibilityGranted(prompt: false) ? .granted : .denied
    case .screen: return CGPreflightScreenCaptureAccess() ? .granted : .denied
    case .fullDisk:
      let home = FileManager.default.homeDirectoryForCurrentUser
      return AgentFileGuard.holdsFullDiskAccess(home: home, canOpen: FullDiskAccessNotice.canOpen) ? .granted : .denied
    case .automation:
      guard let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents").aeDesc?.pointee
      else { return .unknown }
      var address = target
      let status = AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, false)
      switch status {
      case noErr: return .granted
      case OSStatus(errAEEventWouldRequireUserConsent): return .unknown
      default: return .denied
      }
    }
  }
  /// Whether macOS lets Serein send Apple Events to the app with `bundleID` (System Settings ›
  /// Privacy & Security › Automation), without asking. nil when macOS cannot say: an app that is
  /// not running answers procNotFound whatever the permission is, so it is unknown, never
  /// “undetermined”. Blocking for a moment at most, so callers run it off the main thread.
  nonisolated static func automationState(bundleID: String) -> AutomationState? {
    // The descriptor owns the AEDesc's data handle, so it stays alive for the whole call.
    let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
    let status: OSStatus = withExtendedLifetime(descriptor) {
      guard let address = descriptor.aeDesc else { return OSStatus(procNotFound) }
      return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false)
    }
    switch status {
    case noErr: return .allowed
    case OSStatus(errAEEventNotPermitted): return .denied
    case OSStatus(errAEEventWouldRequireUserConsent): return .undetermined
    default: return nil
    }
  }
  /// Asks macOS. Accessibility and Screen Recording get their system dialog and a listing in
  /// System Settings; Automation prompts on the first event sent to System Events; Full Disk
  /// Access has no dialog, so its pane opens. A pane with a list gets the drag card.
  static func ask(_ grant: Grant) {
    if grant.drags { MacAccessGuide.show(grant, palette: Palette.current) }
    switch grant {
    case .accessibility: _ = MacControl.accessibilityGranted(prompt: true)
    case .screen: _ = CGRequestScreenCaptureAccess()
    case .fullDisk: openSettings(.fullDisk)
    case .automation:
      DispatchQueue.global(qos: .userInitiated).async {
        let script = NSAppleScript(source: "tell application \"System Events\" to get name of first process")
        var error: NSDictionary?
        _ = script?.executeAndReturnError(&error)
      }
    }
  }
  nonisolated static func settingsLink(_ grant: Grant) -> String { "x-apple.systempreferences:com.apple.preference.security?\(grant.pane)" }
  /// Opens the grant's pane; a pane with a list gets the drag card beside it.
  static func openSettings(_ grant: Grant) {
    if let url = URL(string: settingsLink(grant)) {
      NSWorkspace.shared.open(url)
    }
    if grant.drags, MacAccessGuide.shownGrant != grant { MacAccessGuide.show(grant, palette: Palette.current) }
  }
  /// macOS gives Screen Recording to a program when it starts. A copy of Serein that runs
  /// keeps the answer "not allowed" after the switch is on, until it opens again. This closes
  /// Serein and opens it again; setup comes back at the step it was on.
  static func reopen() {
    // Only the app can open again; a bare program of a development build has nothing to open.
    guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    // The new copy must start after this one has gone: this one holds the lock on the library.
    task.arguments = [
      "-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; open \"$0\"",
      Bundle.main.bundlePath,
    ]
    guard (try? task.run()) != nil else { return }
    NSApp.terminate(nil)
    // Only reached when Serein did not quit (downloads still run and the person kept them):
    // the helper must not open Serein after a later quit.
    task.terminate()
  }
}

/// A small card that floats at the bottom of the System Settings window while the person gives a
/// grant there. The whole card drags Serein's app (its bundle, as a file URL) into the pane's list,
/// and macOS then adds Serein with its switch on; the person does the drag, Serein never drops,
/// toggles or asks. It never takes focus. Every half second it follows the window and goes when the
/// grant is there, the window is gone, three minutes pass, or the person presses ×.
/// System Settings' frame comes from `CGWindowListCopyWindowInfo`: only a window's name needs
/// Screen Recording, not its bounds (measured by an app with no Screen Recording:
/// bounds came back, the name did not). With no frame the card sits at the bottom centre of the screen.
@MainActor enum MacAccessGuide {
  private static var panel: NSPanel?
  private static var follow: Task<Void, Never>?
  /// The grant the card is up for, nil when none.
  private(set) static var shownGrant: MacAccess.Grant?
  static let size = CGSize(width: 320, height: 68)
  /// What a drag carries: the running app's own bundle, the item the Accessibility list takes.
  nonisolated static var dragURL: URL { Bundle.main.bundleURL }
  /// Serein's own icon file: the system's icon for the bundle comes back boxed in a grey square.
  static let icon = Bundle.main.image(forResource: "Serein") ?? NSApp.applicationIconImage ?? NSImage()
  /// What AppKit puts on the drag pasteboard: the bundle's own file URL, not a copy of the app.
  nonisolated static var dragWriter: NSPasteboardWriting { dragURL as NSURL }

  /// `stays`: for a picture of the card; it sits at the bottom of the main screen and never goes by itself.
  static func show(_ grant: MacAccess.Grant, palette: Palette, stays: Bool = false) {
    close()
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    // A drag on the card carries Serein; it never moves the card.
    panel.isMovableByWindowBackground = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let host = NSHostingView(
      rootView: Guide(grant: grant).frame(width: size.width, height: size.height).environment(\.palette, palette))
    // The panel keeps the size given here; the view does not resize it.
    host.sizingOptions = []
    host.frame = NSRect(origin: .zero, size: size)
    panel.contentView = host
    let window = stays ? nil : settingsWindow()
    panel.setFrameOrigin(origin(window))
    panel.orderFrontRegardless()
    self.panel = panel
    shownGrant = grant
    guard !stays else { return }
    let opened = Date()
    follow = Task {
      var seen = window != nil
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled, let shown = self.panel, shown === panel else { return }
        let windows = settingsWindows()
        let window = mainWindow(windows)
        seen = seen || window != nil
        if MacAccessDragCard.close(granted: MacAccess.state(grant) == .granted, settingsSeen: seen,
                                   settingsThere: window != nil, elapsed: Date().timeIntervalSince(opened)) != nil {
          close()
          return
        }
        // A password sheet or prompt is a second window; the card stays out of its way until it goes.
        if windows.count > 1 {
          shown.orderOut(nil)
        } else {
          shown.setFrameOrigin(origin(window))
          if !shown.isVisible { shown.orderFrontRegardless() }
        }
      }
    }
  }
  static func close() {
    follow?.cancel()
    follow = nil
    shownGrant = nil
    guard let shown = panel else { return }
    shown.close()
    panel = nil
    // A grant that closed the card settles the chat's card into its line now.
    RelayOrchestrator.shared?.checkMacAccess()
  }
  /// System Settings' largest window, its main one, in Quartz coordinates; nil while it has none on screen.
  static func settingsWindow() -> CGRect? { mainWindow(settingsWindows()) }
  private static func mainWindow(_ windows: [CGRect]) -> CGRect? { windows.max { $0.width * $0.height < $1.width * $1.height } }
  private static func settingsWindows() -> [CGRect] {
    let owners = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").map(\.processIdentifier))
    guard !owners.isEmpty,
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return list.compactMap { info in
      guard (info[kCGWindowLayer as String] as? Int) == 0,
        let pid = info[kCGWindowOwnerPID as String] as? pid_t, owners.contains(pid),
        let bounds = info[kCGWindowBounds as String] as? NSDictionary
      else { return nil }
      return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
  }
  private static func origin(_ window: CGRect?) -> NSPoint {
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    let screen = window.flatMap { window in
      NSScreen.screens.first { $0.frame.intersects(MacAccessDragCard.appKit(window, mainHeight: mainHeight)) }
    } ?? NSScreen.main
    return MacAccessDragCard.origin(window: window, mainHeight: mainHeight, visible: screen?.visibleFrame ?? .zero, size: size)
  }
  /// The card as a picture (`--ui-mac-guide`).
  static func capture(to url: URL) {
    guard let view = panel?.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: image)
    try? image.representation(using: .png, properties: [:])?.write(to: url)
  }

  private struct Guide: View {
    /// The icon's place on the card: 14 in from the left, centred in its 68 height.
    static let iconFrame = CGRect(x: 14, y: 14, width: 40, height: 40)
    let grant: MacAccess.Grant
    @Environment(\.palette) var p
    var body: some View {
      HStack(spacing: 12) {
        SereinAppTile(size: Self.iconFrame.width)
        VStack(alignment: .leading, spacing: 2) {
          Text("Serein").font(UIStyle.body).foregroundStyle(p.ink).lineLimit(1)
          Text(grant == .screen || grant == .fullDisk ? "Drag Serein into the list above, then Quit & Reopen" : "Drag Serein into the list above")
            .font(UIStyle.micro).foregroundStyle(p.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 30)
      }.padding(.leading, Self.iconFrame.minX).padding(.trailing, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
        // The whole card drags; the picture that moves is the icon on its left.
        .overlay(SereinDragArea(picture: Self.iconFrame))
        .overlay(alignment: .topTrailing) {
          Button { MacAccessGuide.close() } label: {
            InterfaceIcon(systemName: "xmark", size: 10).foregroundStyle(p.secondary)
              .frame(width: 22, height: 22).contentShape(Rectangle())
          }.buttonStyle(.pressable).accessibilityLabel("Close").padding(.top, 8).padding(.trailing, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Serein, drag into the list in System Settings")
    }
  }
}

/// Serein's own app icon. A drag carries the app (`MacAccessGuide.dragURL`), so it can be dropped
/// into a list in System Settings › Privacy & Security.
struct SereinAppTile: View {
  let size: CGFloat
  var body: some View {
    Image(nsImage: MacAccessGuide.icon).resizable().interpolation(.high)
      .frame(width: size, height: size)
      .overlay(SereinDragArea())
      .accessibilityLabel("Serein, drag into the list in System Settings")
  }
}

/// Starts an AppKit drag of Serein's bundle. SwiftUI's `onDrag` handed the list a copy of the app
/// in its drag cache (measured on the cloud Mac), and a copy's grant would not cover the running app.
struct SereinDragArea: NSViewRepresentable {
  /// Where the dragged icon starts, from the view's top left; nil is the whole view.
  var picture: CGRect?
  func makeNSView(context: Context) -> DragView {
    let view = DragView()
    view.picture = picture
    view.toolTip = "Drag Serein into the list in System Settings"
    return view
  }
  func updateNSView(_ view: DragView, context: Context) {}

  final class DragView: NSView, NSDraggingSource {
    var picture: CGRect?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
      let item = NSDraggingItem(pasteboardWriter: MacAccessGuide.dragWriter)
      item.setDraggingFrame(picture ?? bounds, contents: MacAccessGuide.icon)
      beginDraggingSession(with: [item], event: event, source: self)
    }
    // A drag held over Serein's own card for a few seconds brought Serein's window over System
    // Settings (measured on the cloud Mac); while the drag runs, the card lets the pointer through.
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
      window?.ignoresMouseEvents = true
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
      window?.ignoresMouseEvents = false
    }
    // No move or delete, so a drop on the Trash never takes the app away.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
      context == .outsideApplication ? [.copy, .link, .generic] : []
    }
  }
}

/// The grants' rows with live state (the three behind Mac actions unless told); used by the first run and
/// Settings › AI apps.
struct MacAccessRows: View {
  var grants: [MacAccess.Grant] = MacAccess.Grant.macActions
  @State private var states: [MacAccess.Grant: MacAccess.State] = [:]
  /// The grants the person went to System Settings for in this view.
  @State private var asked: Set<MacAccess.Grant> = []
  @ObservedObject private var setup = SetupRun.shared
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(grants) { grant in
        let state = states[grant] ?? .unknown
        HStack(alignment: .top, spacing: 12) {
          InterfaceIcon(systemName: grant.icon, size: 14).foregroundStyle(p.secondary)
            .frame(width: 18).padding(.top, 2)
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Text(grant.title).font(UIStyle.body)
              InterfaceIcon(systemName: state == .granted ? "checkmark.circle.fill" : "circle", size: 12)
                .foregroundStyle(state == .granted ? p.success : p.faint)
                .accessibilityLabel(state == .granted ? "Granted" : "Not granted")
            }
            Text(grant.detail).role(.meta).fixedSize(horizontal: false, vertical: true)
            // macOS gives Screen Recording to a program when it starts, so the tick cannot
            // come while this copy runs. The way on is to open Serein again.
            if grant == .screen, state != .granted, asked.contains(.screen) {
              HStack(spacing: 8) {
                Text("Is its switch on? macOS gives it to Serein when Serein opens again.")
                  .font(UIStyle.micro).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
                Button("Reopen Serein") { MacAccess.reopen() }.buttonStyle(QuietButton())
                  .disabled(setup.active)
                  .help(setup.active ? "After setup has brought everything over" : "Closes Serein and opens it again")
              }.padding(.top, 2)
            }
          }
          Spacer(minLength: 12)
          if state != .granted {
            Button("Allow…") {
              asked.insert(grant)
              MacAccess.ask(grant)
            }.buttonStyle(PrimaryButton())
              .help("macOS asks you; Serein never changes this by itself")
            Button("Settings") {
              asked.insert(grant)
              MacAccess.openSettings(grant)
            }.buttonStyle(QuietButton())
              .help("The exact pane in System Settings")
          }
        }.accessibilityElement(children: .combine)
      }
    }
    // Grants change outside the app; the rows follow while on screen.
    .task {
      while !Task.isCancelled {
        refresh()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
      }
    }
    .onDisappear { MacAccessGuide.close() }
    // `--ui-mac-guide <png>`: a picture of the panel for a UI preview.
    .task {
      guard CommandLine.arguments.contains("--ui-preview"),
        let path = CommandLine.arguments.drop(while: { $0 != "--ui-mac-guide" }).dropFirst().first
      else { return }
      asked.insert(.screen)
      MacAccessGuide.show(.screen, palette: p, stays: true)
      try? await Task.sleep(nanoseconds: 700_000_000)
      MacAccessGuide.capture(to: URL(fileURLWithPath: path))
    }
  }
  func refresh() {
    for grant in grants { states[grant] = MacAccess.state(grant) }
  }
}

/// Setup step: optional, for people who want agents to work in Mac apps. Walks through one grant at a
/// time with numbered instructions and moves on by itself once macOS reports the grant.
struct MacAccessStep: View {
  @Environment(\.palette) var p
  @State private var states: [MacAccess.Grant: MacAccess.State] = [:]
  @State private var selected: MacAccess.Grant = .accessibility
  /// The grants the person asked for in this view: Screen Recording then offers "Reopen Serein".
  @State private var asked: Set<MacAccess.Grant> = []
  @ObservedObject private var setup = SetupRun.shared

  private let grants = MacAccess.Grant.macActions
  private func granted(_ grant: MacAccess.Grant) -> Bool { states[grant] == .granted }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Optional. Lets Serein and its tasks see and use your Mac apps, such as Calendar or Notes. They ask you first unless you chose Only risky steps in Settings › Assistants › Asks first. macOS needs three permissions; this walks you through each one.")
        .role(.reading).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        ForEach(Array(grants.enumerated()), id: \.element) { index, grant in stepRow(index, grant) }
      }
      Text("\(grants.filter(granted).count) of \(grants.count) allowed").role(.micro)
      ScrollView { detail(selected) }
      Text("Serein never changes these by itself. Drag its icon into the list, or turn on the switch. Change them any time in System Settings › Privacy & Security.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .onDisappear { MacAccessGuide.close() }
      .task {
        refresh(initial: true)
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          refresh(initial: false)
        }
      }
  }

  private func stepRow(_ index: Int, _ grant: MacAccess.Grant) -> some View {
    let done = granted(grant)
    return Button {
      selected = grant
    } label: {
      HStack(spacing: 6) {
        ZStack {
          Circle().fill(done ? p.success : (grant == selected ? p.solid : p.track)).frame(width: 18, height: 18)
          if done {
            InterfaceIcon(systemName: "checkmark", size: 9).foregroundStyle(p.onSolid)
          } else {
            Text("\(index + 1)").font(UIStyle.microMono)
              .foregroundStyle(grant == selected ? p.onSolid : p.secondary)
          }
        }
        Text(grant.title).font(UIStyle.meta)
          .lineLimit(1).minimumScaleFactor(0.8)
      }.padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity)
        .background(grant == selected ? p.selected : Color.clear, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
    }.buttonStyle(.pressable)
      .accessibilityLabel("Step \(index + 1), \(grant.title), \(done ? "allowed" : "not allowed yet")")
  }

  private func detail(_ grant: MacAccess.Grant) -> some View {
    let done = granted(grant)
    let number = (grants.firstIndex(of: grant) ?? 0) + 1
    return VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        InterfaceIcon(systemName: grant.icon, size: 14).foregroundStyle(p.secondary)
        Text("Step \(number) of \(grants.count) · \(grant.title)").role(.section)
      }
      Text(grant.detail).role(.meta).fixedSize(horizontal: false, vertical: true)
      if done {
        HStack(spacing: 8) {
          InterfaceIcon(systemName: "checkmark.circle.fill", size: 14).foregroundStyle(p.success)
          Text(grants.allSatisfy(granted) ? "Allowed. All three are set; choose Continue." : "Allowed.")
            .font(UIStyle.body)
        }
        if let next = grants.first(where: { !granted($0) }) {
          Button("Next: \(next.title)") { selected = next }.buttonStyle(PrimaryButton())
        }
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(grant.steps.enumerated()), id: \.offset) { index, line in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text("\(index + 1)").font(UIStyle.microMono).foregroundStyle(p.faint).frame(width: 12)
              Text(line).font(UIStyle.body).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        HStack(spacing: 8) {
          Button("Allow…") {
            asked.insert(grant)
            MacAccess.ask(grant)
          }.buttonStyle(PrimaryButton())
            .help("macOS asks you; Serein never changes this by itself")
          Button("Open Settings") {
            asked.insert(grant)
            MacAccess.openSettings(grant)
          }.buttonStyle(QuietButton())
            .help("The exact pane in System Settings")
        }
        // macOS gives Screen Recording to a program when it starts, so the tick cannot come
        // while this copy runs. The way on is to open Serein again.
        if grant == .screen, asked.contains(.screen) {
          HStack(spacing: 8) {
            Text("Is its switch on? macOS gives it to Serein when Serein opens again.")
              .font(UIStyle.micro).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
            Button("Reopen Serein") { MacAccess.reopen() }.buttonStyle(QuietButton())
              .disabled(setup.active)
              .help(setup.active ? "After setup has brought everything over" : "Closes Serein and opens it again")
          }
        }
        Text(grant.trouble).role(.micro).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
  }

  /// Opens on the first grant still missing, and moves on when the one on screen is granted.
  private func refresh(initial: Bool) {
    let before = states
    for grant in grants { states[grant] = MacAccess.state(grant) }
    let justGranted = before[selected] != .granted && granted(selected)
    if initial || (justGranted && before[selected] != nil),
      let next = grants.first(where: { !granted($0) })
    {
      selected = next
    }
  }
}
