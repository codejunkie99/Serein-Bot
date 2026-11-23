import SereinCore
import SwiftUI

/// A small spinning arc; static with Reduce Motion.
struct ActivityRing: View {
  var active: Bool
  var waiting = false
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) var systemReduceMotion
  @Environment(\.sereinReducedEffects) var previewReducedEffects
  var body: some View {
    let still = !active || systemReduceMotion || previewReducedEffects
    ZStack {
      Circle().stroke(p.line, lineWidth: 2)
      if still {
        Circle().trim(from: 0, to: active ? 0.3 : 1).stroke(
          active || waiting ? p.accent : p.faint, style: StrokeStyle(lineWidth: 2, lineCap: .round)
        ).rotationEffect(.degrees(-90))
      } else {
        // Turned by Core Animation, so SwiftUI does not redraw the ring for each frame. A point
        // wider each way than the ring: the stroke is centred on its circle.
        TurningArc(color: p.accent).frame(width: 14, height: 14)
      }
    }.frame(width: 12, height: 12).accessibilityHidden(true)
  }
}

/// Adds the browser mark beside the harness or run status while its tabs are in use.
struct BrowserWorkGlyph: View {
  @ObservedObject var run: AgentRun
  @ObservedObject var browser: BrowserModel
  @ObservedObject private var board: AgentTabBoard
  var size: CGFloat
  @Environment(\.palette) private var p
  init(run: AgentRun, browser: BrowserModel, size: CGFloat = 12) {
    self.run = run
    self.browser = browser
    self.size = size
    board = browser.agentTabs
  }
  var body: some View {
    if run.isWorkingInBrowser(browser) {
      InterfaceIcon(systemName: "globe", size: size).foregroundStyle(p.accent)
        .help("Working in browser").accessibilityLabel("Working in browser")
    }
  }
}

/// Outcome glyph on the Today view.
struct RunGlyph: View {
  var outcome: RunRecord.Outcome
  @Environment(\.palette) var p
  var body: some View {
    Group {
      switch outcome {
      case .running: ActivityRing(active: true)
      case .done: Image(systemName: "checkmark.circle").foregroundStyle(p.success)
      case .waiting: Image(systemName: "exclamationmark.bubble").foregroundStyle(p.accent)
      case .stuck: Image(systemName: "xmark.circle").foregroundStyle(p.danger)
      case .stopped: Image(systemName: "stop.circle").foregroundStyle(p.faint)
      }
    }.font(UIStyle.micro).frame(width: 14)
      .accessibilityLabel(
        [
          .running: "Running", .done: "Done", .waiting: "Needs you", .stuck: "Could not finish",
          .stopped: "Stopped",
        ][outcome] ?? "")
  }
}
