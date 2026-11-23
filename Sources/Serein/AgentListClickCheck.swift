import SwiftUI

/// Where the Agents list's controls drew, for `AgentListClickCheck`. Nothing in a release build.
@MainActor enum AgentListProbe {
  static var frames: [String: CGRect] = [:]
  /// The row that drew each label last: a row replaced by another of the same name leaves its frame.
  static var owners: [String: UUID] = [:]
}
extension EnvironmentValues {
  /// Before each label in a list that repeats rows of another, so the two are told apart.
  @Entry var agentListProbePrefix = ""
}
#if DEBUG
  private struct AgentListProbeReport: ViewModifier {
    let label: String
    @Environment(\.agentListProbePrefix) private var prefix
    @State private var owner = UUID()
    func body(content: Content) -> some View {
      content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
        AgentListProbe.frames[prefix + label] = $0
        AgentListProbe.owners[prefix + label] = owner
      }.onDisappear {
        guard AgentListProbe.owners[prefix + label] == owner else { return }
        AgentListProbe.frames[prefix + label] = nil
      }
    }
  }
#endif
extension View {
  @ViewBuilder func agentListProbe(_ label: String) -> some View {
    #if DEBUG
      modifier(AgentListProbeReport(label: label))
    #else
      self
    #endif
  }
}

#if DEBUG
import AppKit

/// `--ui-agent-list-clicks`, with `--ui-agent-list`: real mouse events sent to the preview's own
/// window, so the Agents list's hit areas and order are checked as drawn. Rows are found through
/// the frames they report (`agentListProbe`). Synthetic data only. Captures go to the folder named by `--ui-capture`'s
/// path, and each result prints as a line.
@MainActor enum AgentListClickCheck {
  private static let settle: UInt64 = 900_000_000
  private static let fixtureTitles = [
    "Tidy the onboarding copy", "Why does the build use so much memory", "Pick a chart library",
    "Review the release notes", "Speed up the start page", "Ship the docs search",
    "Fix the flaky upload test", "Rewrite the settings page", "Add dark mode to the site",
  ]

  static func run(window: NSWindow, capture: URL?) async {
    var failures = 0
    func report(_ passed: Bool, _ words: String) {
      if !passed { failures += 1 }
      print((passed ? "PASS: " : "FAIL: ") + words)
    }
    func shot(_ name: String) {
      guard let capture else { return }
      let target = capture.deletingLastPathComponent().appendingPathComponent("clicks-\(name).png")
      try? UIPreview.renderInProcess(window.attachedSheet ?? window, destination: target)
    }
    func wait() async { try? await Task.sleep(nanoseconds: settle) }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    await wait()

    let first = order(window)
    print("ORDER: " + first.joined(separator: " | "))
    report(first.count >= 2, "The fixture's rows are found in the list")
    shot("1-list")

    // Someone's own “Always” in System Settings wins, so there is nothing to check for them.
    let chosen = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleShowScrollBars"] as? String
    if chosen == nil || chosen == "WhenScrolling" {
      let scrollers = window.contentView.map(scrollViews) ?? []
      report(!scrollers.isEmpty && scrollers.allSatisfy { $0.scrollerStyle == .overlay }, "No scrollbar in the window draws a track")
    }

    report(click("Why does the build use so much memory", in: window), "The row can be found to click")
    await wait()
    report(first.count >= 2 && order(window) == first, "Opening a session moves no row")
    shot("2-opened")

    report(click("Fix the flaky upload test", in: window), "A second row can be found to click")
    await wait()
    report(first.count >= 2 && order(window) == first, "Opening another session moves no row")
    shot("3-second")

    report(click("Show 2 sub-threads", in: window), "The sub-thread chevron can be found to click")
    await wait()
    report(labels(window).contains("Sub-thread: Find every place the copy appears"), "A click on the chevron shows the sub-threads")
    report(first.count >= 2 && order(window) == first, "Showing sub-threads moves no row")
    shot("4-subthreads")

    report(click("Tidy the onboarding copy", in: window), "The parent row can be clicked")
    await wait()
    report(labels(window).contains("Sub-thread: Find every place the copy appears"), "Opening a session keeps its sub-threads open")
    report(first.count >= 2 && order(window) == first, "Opening the parent moves no row")

    report(click("Sub-thread: Find every place the copy appears", in: window), "The sub-thread row can be found to click")
    await wait()
    let focus = SubThreadFocus.shared
    report(window.attachedSheet == nil && focus.open?.shown.helper.title.contains("Find every place the copy appears") == true,
      "A click on a sub-thread opens it in the main view, not a sheet")
    shot("5-transcript")
    report(click("Tidy the onboarding copy", in: window), "The parent row can be clicked from its sub-thread")
    await wait()
    report(focus.open == nil, "The parent's own row shows the parent again")

    report(recents(window).isEmpty, "Recents starts folded")
    let inside = AgentListProbe.frames["Recents"].map { $0.maxY <= (window.contentView?.bounds.height ?? 0) } ?? false
    report(inside, "Recents stays in view however long the projects run")
    report(click("Recents", in: window), "The Recents row can be found to click")
    await wait()
    let recent = recents(window)
    print("RECENTS: " + recent.joined(separator: " | "))
    report(recent.first == "Rewrite the settings page", "Recents leads with the newest activity")
    report(recent.count >= 2 && recent.first != "Fix the flaky upload test", "Opening a session does not count as activity")
    report(first.count >= 2 && order(window) == first, "Opening Recents moves no row in a project")
    shot("6-recents")

    report(click("Recents", in: window), "The Recents row can be clicked again")
    await wait()
    report(!recent.isEmpty && recents(window).isEmpty, "A second click folds Recents")
    shot("7-folded")

    print(failures == 0 ? "RESULT: all passed" : "RESULT: \(failures) failed")
    exit(failures == 0 ? 0 : 1)
  }

  /// The fixture's rows, top to bottom.
  private static func order(_ window: NSWindow) -> [String] {
    AgentListProbe.frames.filter { fixtureTitles.contains($0.key) }.sorted { $0.value.minY < $1.value.minY }.map(\.key)
  }
  private static func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
  }
  /// The fixture's rows in Recents, top to bottom.
  private static func recents(_ window: NSWindow) -> [String] {
    let prefix = "Recents: "
    return AgentListProbe.frames
      .filter { $0.key.hasPrefix(prefix) && fixtureTitles.contains(String($0.key.dropFirst(prefix.count))) }
      .sorted { $0.value.minY < $1.value.minY }.map { String($0.key.dropFirst(prefix.count)) }
  }
  private static func labels(_ window: NSWindow) -> [String] { Array(AgentListProbe.frames.keys) }
  /// A real press and release at the middle of what `label` drew, or nearer its leading edge
  /// (`AgentListProbe` frames count from the window's top left).
  @discardableResult private static func click(_ label: String, in window: NSWindow) -> Bool {
    guard let frame = AgentListProbe.frames[label], let height = window.contentView?.bounds.height else { return false }
    let middle = NSPoint(x: frame.minX + min(frame.width / 2, 60), y: height - frame.midY)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard let event = NSEvent.mouseEvent(
        with: type, location: middle, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
      else { return false }
      window.sendEvent(event)
    }
    return true
  }
}
#endif
