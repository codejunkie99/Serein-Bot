import SereinCore
import SwiftUI

/// Above the newest reply in a thread. While the run works: "Thinking for 1m 12s", the model's
/// reasoning and complete action history behind a disclosure, including while it streams.
/// Afterwards: "Thought for 1m 12s · 7 steps", with the reasoning and steps behind a click.
struct ThreadRunTrace: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var run: AgentRun
  /// Compact on the context meter (`AgentModel.compactNow`); offered once the turn ended well.
  var compact: (() -> Void)? = nil
  @State private var open = false
  @Environment(\.palette) var p
  var steps: [AgentStep] {
    ((run.boardInfo(browser)?.steps ?? []) + run.steps).sorted { $0.time < $1.time }
  }
  var thinking: String { run.thinking.trimmingCharacters(in: .whitespacesAndNewlines) }
  var reasoning: AttributedString {
    var text = AttributedString(thinking)
    text.foregroundColor = p.faint
    return text
  }
  var body: some View {
    let active = run.isActive
    let empty = thinking.isEmpty && run.commentary.isEmpty && steps.isEmpty
    VStack(alignment: .leading, spacing: 8) {
      TimelineView(.animation(minimumInterval: 1, paused: !active)) { context in
        let seconds = (run.record.endedAt ?? context.date).timeIntervalSince(run.record.startedAt)
        Button { open.toggle() } label: {
          HStack(spacing: 8) {
            if active {
              ProgressView().controlSize(.mini).frame(width: 12, height: 12).accessibilityHidden(true)
              BrowserWorkGlyph(run: run, browser: browser)
            }
            if !empty || active {
              InterfaceIcon(systemName: open ? "chevron.down" : "chevron.right", size: 9).frame(width: 12)
            }
            Text(active ? "Thinking for \(Self.spoken(seconds))" : "Thought for \(Self.spoken(seconds))")
            if !steps.isEmpty { Text("· \(steps.count) step\(steps.count == 1 ? "" : "s")").foregroundStyle(p.faint) }
          }.font(UIStyle.meta).monospacedDigit().foregroundStyle(p.secondary).contentShape(Rectangle())
        }.buttonStyle(.pressable).disabled(!active && empty)
          .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
          .accessibilityLabel(active ? "Thinking" : "Thought for \(Self.spoken(seconds))")
          .accessibilityValue("\(steps.count) step\(steps.count == 1 ? "" : "s"), \(open ? "expanded" : "collapsed")")
          .help(open ? "Hide reasoning and actions" : "Show all reasoning and actions")
      }
      // The turn's result: how much of the model's context the task has used.
      if !active, let meter = run.record.context {
        ContextMeterLine(meter: meter, advise: !run.folded, fill: run.contextFill,
                         compact: run.record.outcome == .done ? compact : nil).padding(.leading, 20)
      }
      if open {
        if !run.commentary.isEmpty {
          MessageContent(text: run.commentary, showsCopyButton: false,
            read: run.transcript.last(where: { $0.role == "assistant" })?.read).padding(.leading, 20)
        }
        if !thinking.isEmpty {
          SelectableMessageText(text: reasoning, size: 12, lineSpacing: 3).padding(.leading, 20)
        }
        if active, let line = run.display(board: run.boardInfo(browser)).line {
          Text(line).font(UIStyle.micro).foregroundStyle(p.secondary).padding(.leading, 20)
        }
        AgentStepList(steps: steps).padding(.leading, 20)
      }
    }
    .onChange(of: run.id) { _, _ in open = false }
  }
  /// "42s", "1m 12s".
  static func spoken(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.isFinite ? seconds : 0))
    return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
  }
}

/// Above the composer once this thread's agent session has grown past half a million tokens:
/// every follow-up resumes the whole session, so replies slow down and can stop coming. A copy
/// starts from a short summary instead.
struct ThreadSessionNote: View {
  @ObservedObject var agent: AgentModel
  @ObservedObject private var hub: AgentHub
  @State private var dismissed = Set<String>()
  static let threshold = 500_000
  init(agent: AgentModel) {
    self.agent = agent
    _hub = ObservedObject(wrappedValue: agent.hub)
  }
  var body: some View {
    if let run = hub.latest(for: agent.conversationID) {
      ThreadSessionWarning(agent: agent, run: run, dismissed: $dismissed)
    }
  }
}

/// Token metadata can change without any reply text. Observe just this small warning so
/// coalescing transcript publication never delays the large-session notice.
private struct ThreadSessionWarning: View {
  @ObservedObject var agent: AgentModel
  @ObservedObject var run: AgentRun
  @Binding var dismissed: Set<String>
  @Environment(\.palette) var p
  var body: some View {
    // A condensed thread's next turn leaves this session, so the warning no longer applies.
    if let tokens = run.contextTokens, !run.folded,
      tokens >= ThreadSessionNote.threshold, !dismissed.contains(agent.conversationID)
    {
      HStack(alignment: .center, spacing: 10) {
        InterfaceIcon(systemName: "tray.full", size: 14).foregroundStyle(p.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("This thread's \(run.spec.provider.name) session is large: \(TokenCount.label(tokens)).")
            .font(UIStyle.body).foregroundStyle(p.ink)
          Text("Each reply resends all of it, so answers slow down or stop. A copy starts fresh from a summary.")
            .role(.meta)
        }
        Spacer(minLength: 8)
        Button("Continue in a copy") { agent.flow.continueInCopy(native: false) }.buttonStyle(QuietButton())
          .disabled(agent.running)
        Button {
          dismissed.insert(agent.conversationID)
        } label: {
          InterfaceIcon(systemName: "xmark", size: 10)
        }.buttonStyle(QuietButton()).accessibilityLabel("Dismiss")
      }.padding(.horizontal, 24).padding(.vertical, 10).frame(maxWidth: UIStyle.composerWidth)
        .frame(maxWidth: .infinity)
    }
  }
}
