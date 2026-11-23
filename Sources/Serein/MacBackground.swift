import AppKit
import ApplicationServices
import ScreenCaptureKit
import SereinCore
import SwiftUI

/// What background work needs from the task that asks: the chat it belongs to (its line shows
/// Stop there), whether a person is there to answer, and where its cards show.
struct MacBackgroundAsk {
  let thread: String?
  /// Read again after every card: a scheduled turn may have started meanwhile.
  let unattended: () -> Bool
  /// A card for the person: title, detail and the words on its primary button.
  let ask: (_ title: String, _ detail: String, _ button: String) async -> ApprovalGate.HumanAnswer

  /// The card as an alert, for a task Serein's chat does not hold (MacApproval, like a mac_act).
  @MainActor static func alert(_ title: String, _ detail: String, button: String, thread: String?) async -> ApprovalGate.HumanAnswer {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    return await MacApproval.ask(alert, button: button, decline: "Decline", thread: thread)
  }
}

/// Background work in Mac apps, per task: the apps the person allowed on the start card, the
/// window chosen in each, and the latest picture of it. Stop ends it for the rest of the task;
/// an ended task forgets it. Nothing here runs unless Settings › AI apps › Mac access turns it on.
@MainActor final class MacBackground: ObservableObject {
  static let shared = MacBackground()
  struct Grant {
    /// The app's bundle identifier, else its name in lower case.
    let id: String
    let app: String
    /// A relaunched app is a new process and asks again.
    let pid: pid_t
    let thread: String?
    var window: String
  }
  /// Task id → the apps allowed in it, in the order they were allowed.
  @Published private(set) var grants: [String: [Grant]] = [:]
  /// Task id → the latest picture of its window (this launch only; never sent anywhere by itself).
  @Published private(set) var pictures: [String: NSImage] = [:]
  /// Tasks the person stopped: background work stays refused for the rest of each.
  private var stopped: Set<String> = []

  static var enabled: Bool { GateSettings.shared.bool(forKey: MacBackgroundPolicy.enabledKey) }
  static func key(_ app: NSRunningApplication) -> String { app.bundleIdentifier ?? (app.localizedName ?? "").lowercased() }
  /// This process, its bundle, or another Serein by name (a `swift run` build has no bundle id).
  static func isSerein(_ app: NSRunningApplication) -> Bool {
    app.processIdentifier == ProcessInfo.processInfo.processIdentifier
      || (app.bundleIdentifier != nil && app.bundleIdentifier == Bundle.main.bundleIdentifier)
      || (app.localizedName ?? "").lowercased().hasPrefix("serein")
  }

  /// Whether background work may touch `app` for `task` at all: the setting, Stop, a person to
  /// answer, and the apps it never uses. Throws the reason.
  func mayUse(_ app: NSRunningApplication, appName: String, task: String, unattended: Bool) throws {
    guard Self.enabled else { throw SereinError.invalid(MacBackgroundPolicy.off) }
    guard !stopped.contains(task) else { throw SereinError.invalid(MacBackgroundPolicy.stopped) }
    guard !unattended else { throw SereinError.invalid(MacBackgroundPolicy.unattended) }
    if let refusal = MacBackgroundPolicy.refusal(
      app: appName, bundleID: app.bundleIdentifier, isSerein: Self.isSerein(app))
    {
      throw SereinError.invalid(refusal)
    }
  }
  /// `mayUse`, and the person's yes on the start card for this app (this process) in this task.
  func check(task: String, app: NSRunningApplication, appName: String, unattended: Bool) throws {
    try mayUse(app, appName: appName, task: task, unattended: unattended)
    guard grants[task]?.contains(where: { $0.id == Self.key(app) && $0.pid == app.processIdentifier }) == true else {
      throw SereinError.invalid(
        "Ask with mac_observe background=true first: the person allows background work in each app once per task.")
    }
  }
  /// The start card, the first time in a task for an app: “Work in Notes in the background?”.
  /// Autopilot never answers it and an unattended run is refused before it; a later observe only
  /// notes the window it chose.
  func admit(task: String, app: NSRunningApplication, appName: String, window: String, access: MacBackgroundAsk)
    async throws
  {
    try mayUse(app, appName: appName, task: task, unattended: access.unattended())
    let key = Self.key(app)
    if let index = grants[task]?.firstIndex(where: { $0.id == key && $0.pid == app.processIdentifier }) {
      grants[task]?[index].window = window
      return
    }
    // Without a chat there is no line to show Stop on, so the person could not end it.
    guard access.thread != nil else {
      throw SereinError.invalid("Background work needs a chat to show its Stop line; use mac_observe without background.")
    }
    // Autopilot never answers it: the card goes straight to the person.
    let card = MacBackgroundPolicy.startCard(app: appName, window: window)
    let human = await access.ask(card.title, card.detail, MacBackgroundPolicy.startButton)
    guard human == .yes else {
      throw SereinError.invalid(human == .no ? ActionAdmission.declined : ActionAdmission.needsPerson)
    }
    // Stop, the setting or an unattended turn may have come while the card was up.
    try mayUse(app, appName: appName, task: task, unattended: access.unattended())
    var allowed = grants[task] ?? []
    allowed.removeAll { $0.id == key }
    allowed.append(Grant(id: key, app: appName, pid: app.processIdentifier, thread: access.thread, window: window))
    grants[task] = allowed
  }
  /// Stop: ends background work for `task`; every later background call in it is refused.
  func stop(_ task: String) {
    stopped.insert(task)
    grants[task] = nil
    pictures[task] = nil
    MacControl.shared.forget(task)
  }
  /// The task ended (BrowserModel.endTask).
  func end(_ task: String) {
    stopped.remove(task)
    grants[task] = nil
    pictures[task] = nil
  }
  /// The setting went off: every grant goes, so turning it on again asks again.
  func turnedOff() {
    grants = [:]
    pictures = [:]
  }
  /// The tasks of one chat that work in the background now.
  func tasks(thread: String) -> [String] {
    grants.filter { entry in entry.value.contains { $0.thread == thread } }.map(\.key).sorted()
  }
  /// Keeps the latest picture, only while the task still works in the background (not after Stop).
  func show(_ image: CGImage, task: String) {
    guard grants[task] != nil else { return }
    pictures[task] = NSImage(cgImage: image, size: .zero)
  }
  /// A fresh picture of the task's latest window, for Watch. A minimised window is left alone.
  func refreshPicture(task: String) async {
    guard let grant = grants[task]?.last else { return }
    let root = AXUIElementCreateApplication(grant.pid)
    guard let window = MacControl.window(root, titled: grant.window.isEmpty ? nil : grant.window),
      MacControl.value(window, kAXMinimizedAttribute) as? Bool != true,
      let image = await MacControl.windowPicture(pid: grant.pid, frame: MacControl.frame(window), title: grant.window),
      // Stop may have come while it was captured.
      grants[task] != nil
    else { return }
    show(image, task: task)
  }
}

extension MacControl {
  /// One window alone through ScreenCaptureKit, also when other windows cover it. nil without
  /// Screen Recording, or when ScreenCaptureKit does not list the window (minimised windows are
  /// caught earlier, from Accessibility).
  static func windowPicture(pid: pid_t, frame: CGRect?, title: String) async -> CGImage? {
    guard CGPreflightScreenCaptureAccess(),
      let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    else { return nil }
    let theirs = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
    let byFrame = frame.flatMap { frame in
      theirs.first { window in
        abs(window.frame.minX - frame.minX) < 2 && abs(window.frame.minY - frame.minY) < 2
          && abs(window.frame.width - frame.width) < 2 && abs(window.frame.height - frame.height) < 2
      }
    }
    // By title only when one window has it: two “Untitled” windows could show the wrong one.
    let titled = theirs.filter { !title.isEmpty && $0.title == title }
    guard let match = byFrame ?? (titled.count == 1 ? titled[0] : nil) else { return nil }
    let filter = SCContentFilter(desktopIndependentWindow: match)
    let configuration = SCStreamConfiguration()
    // Sharp on a Retina screen, at most 1600 pixels wide so the picture stays small.
    let scale = min(CGFloat(filter.pointPixelScale), 1600 / max(match.frame.width, 1))
    configuration.width = max(1, Int(match.frame.width * scale))
    configuration.height = max(1, Int(match.frame.height * scale))
    configuration.showsCursor = false
    return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
  }
}

/// “Working in Notes in the background · Show window · Stop”: under a chat while its task works
/// in a Mac app's window in the background. Show window opens the window's picture under the
/// line (BackgroundWindowPicture); Stop ends that work for the task (MacBackground.stop).
struct MacBackgroundLine: View {
  let thread: String
  var full = true
  @ObservedObject private var work = MacBackground.shared
  @State private var showing = false
  @Environment(\.palette) var p
  var body: some View {
    let tasks = work.tasks(thread: thread)
    if !tasks.isEmpty {
      let words = "Working in \(ListFormatter.localizedString(byJoining: apps(tasks))) in the background"
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          InterfaceIcon(systemName: "macwindow", size: 11).foregroundStyle(p.secondary).accessibilityHidden(true)
          Text(words).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
          Text("·").font(UIStyle.meta).foregroundStyle(p.secondary).accessibilityHidden(true)
          // The font sits on the label: QuietButton sets its own on the label, which would win.
          Button { showing.toggle() } label: {
            Text(showing ? "Hide window" : "Show window").font(UIStyle.metaStrong).foregroundStyle(p.secondary)
          }.buttonStyle(QuietButton()).fixedSize()
            .help(showing ? "Hides the picture of the window" : "Shows a picture of the window Serein works in")
            .accessibilityLabel(showing ? "Hide the window picture" : "Show the window picture")
          Text("·").font(UIStyle.meta).foregroundStyle(p.secondary).accessibilityHidden(true)
          Button { for task in tasks { work.stop(task) } } label: {
            Text("Stop").font(UIStyle.metaStrong).foregroundStyle(p.ink)
          }.buttonStyle(QuietButton()).fixedSize()
            .help("Ends background work in these apps for this task")
            .accessibilityLabel("Stop working in the background")
          Spacer(minLength: 0)
        }.padding(.horizontal, full ? 0 : 14).frame(height: 32)
          .frame(maxWidth: full ? UIStyle.composerWidth : .infinity).padding(.horizontal, full ? 16 : 0)
          .frame(maxWidth: .infinity)
          .accessibilityElement(children: .contain).accessibilityLabel(words)
        if showing {
          BackgroundWindowPicture(thread: thread).padding(.horizontal, full ? 16 : 14).padding(.bottom, 8)
            .frame(maxWidth: full ? UIStyle.composerWidth : .infinity)
        }
      }
    }
  }
  /// Each app once, in the order it was allowed.
  private func apps(_ tasks: [String]) -> [String] {
    var names: [String] = []
    for grant in tasks.flatMap({ work.grants[$0] ?? [] }) where !names.contains(grant.app) { names.append(grant.app) }
    return names
  }
}

/// The window a chat's task works in, as ScreenCaptureKit sees it, with Watch (a fresh picture
/// every two seconds while on). Shown under MacBackgroundLine, whose Stop ends the work.
struct BackgroundWindowPicture: View {
  let thread: String
  @ObservedObject private var work = MacBackground.shared
  @State private var watching = false
  @Environment(\.palette) var p
  var body: some View {
    if let task = work.tasks(thread: thread).last, let grant = work.grants[task]?.last {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text(grant.window.isEmpty ? grant.app : "\(grant.app) · \(grant.window)")
            .font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
          Spacer(minLength: 8)
          Button(watching ? "Stop Watching" : "Watch") { watching.toggle() }.buttonStyle(QuietButton())
            .help(watching ? "Stops refreshing the picture" : "Refreshes the picture every two seconds")
        }
        if let image = work.pictures[task] {
          Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: UIStyle.rowRadius))
            .overlay(RoundedRectangle(cornerRadius: UIStyle.rowRadius).stroke(p.line))
            .accessibilityLabel("Picture of the \(grant.app) window")
        } else {
          if CGPreflightScreenCaptureAccess() {
            Text("No picture yet. Watch takes one.").role(.meta)
          } else {
            HStack(spacing: 8) {
              Text("Pictures of the window need Screen Recording for Serein.")
                .role(.meta).fixedSize(horizontal: false, vertical: true)
              Button("Allow…") { MacAccess.openSettings(.screen) }.buttonStyle(QuietButton())
            }
          }
        }
      }
      .task(id: watching) {
        while watching, !Task.isCancelled {
          await work.refreshPicture(task: task)
          try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
      }
    }
  }
}
