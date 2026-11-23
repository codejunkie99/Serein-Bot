import SereinCore
import SwiftUI

/// What an assistant does while it works, as a trail: a header that counts the seconds, the places
/// it searched, and one line for each step as it arrives. A click on the header folds the trail.
/// While a card or a question waits on the person the header stands still and says so. Only the
/// newest few steps show while it works, under a row that opens the earlier ones. When the work
/// ends, the header reads "Worked for 7s" and the trail folds; opened, a last row says how it
/// ended. A step that was not done stays in sight when the trail is folded.
struct ThinkingTrail: View {
  struct Source: Identifiable, Equatable {
    /// The connected app's slug, which finds its logo (`Brand.app`).
    let app: String
    /// What was read there ("Slack · #team-offsite").
    let name: String
    var id: String { app + "\n" + name }
  }
  struct Step: Identifiable, Equatable {
    let id: String
    let label: String
    var sources: [Source] = []
    /// It was not done: its row stays when the trail folds.
    var failed = false
    /// A step on Serein's computer: its row offers Watch, which opens the view watch-first.
    var computerTask: String? = nil
  }
  let steps: [Step]
  let startedAt: Date
  var endedAt: Date? = nil
  var doneLabel = "Finished thinking"
  /// A card or a question waits on the person: no shimmer, and the clock stops until they answer.
  var waiting = false
  /// The turn ended as asked: the last row wears the check. A stop or a failure wears a plain dot.
  var endedWell = true
  /// Which try this turn is, of the same words: from the second the header says so.
  var attempt = 1
  /// The reply's first words have come.
  var replied = false
  /// Stops the turn. With it, a turn that has shown nothing for 20 seconds offers to keep
  /// waiting or stop (`TurnActivity.slowReply`).
  var stop: (() -> Void)? = nil
  /// Retry on a finished turn's failed call (`ToolCallRow`): sends its words as the person's next message.
  var retry: ((String) -> Void)? = nil
  /// How many sources a search row shows before the rest fold behind "+N more".
  var sourceLimit = 4
  /// The person's own choice; until they make one the trail is open while the work goes on.
  @State private var open: Bool?
  private var isOpen: Bool { open ?? (endedAt == nil) }
  @State private var allSources: Set<String> = []
  /// The person opened the steps before the live trail's newest few.
  @State private var showsEarlier = false
  /// When the wait on the person began: the clock holds that moment's reading.
  @State private var waitingSince: Date?
  /// How long the turn had run when the slow-reply moment came; 0 before it.
  @State private var quietFor: TimeInterval = 0
  /// The person chose to keep waiting.
  @State private var keptWaiting = false
  @Environment(\.palette) private var p
  @Environment(\.reducesMotion) private var reduce

  var body: some View {
    let earlier: Int = TurnActivity.earlierSteps(total: steps.count, live: endedAt == nil, opened: showsEarlier)
    // Folded, only what was not done stays.
    let shown: [Step] = isOpen ? Array(steps.dropFirst(earlier)) : steps.filter(\.failed)
    VStack(alignment: .leading, spacing: 10) {
      Button { withAnimation(Motion.swapping(reduce)) { open = !isOpen } } label: { header }
        .buttonStyle(AssistantPressStyle())
        .accessibilityHint(isOpen ? "Hides the steps" : "Shows the steps")
      if isOpen || !shown.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          if isOpen, earlier > 0 {
            Button { withAnimation(Motion.entering(reduce)) { showsEarlier = true } } label: {
              Text(TurnActivity.earlierWords(earlier)).font(AssistantType.meta).foregroundStyle(p.secondary)
                .padding(.leading, 26).contentShape(Rectangle())
            }
            .buttonStyle(AssistantPressStyle()).accessibilityHint("Shows them")
          }
          ForEach(shown) { step in
            row(step, current: endedAt == nil && step.id == steps.last?.id).transition(Motion.arrival(reduce))
          }
          if isOpen, endedAt != nil {
            HStack(spacing: 10) {
              if endedWell {
                InterfaceIcon(systemName: "checkmark", size: 8).foregroundStyle(p.onAccent)
                  .frame(width: 14, height: 14).background(p.accent, in: Circle()).frame(width: 16)
              } else {
                Circle().fill(p.faint).frame(width: 5, height: 5).frame(width: 16)
              }
              Text(doneLabel).font(AssistantType.body).foregroundStyle(p.ink)
            }.transition(Motion.arrival(reduce))
          }
        }
      }
      if let stop, endedAt == nil,
        TurnActivity.slowReply(elapsed: quietFor, steps: steps.count, replied: replied, waiting: waiting, keptWaiting: keptWaiting)
      {
        SlowReplyLine(keepWaiting: { keptWaiting = true }, stop: stop)
      }
    }
    .animation(Motion.entering(reduce), value: steps)
    .animation(Motion.entering(reduce), value: endedAt)
    .onChange(of: waiting, initial: true) { waitingSince = waiting ? Date() : nil }
    // One wake at the 20-second mark, not a clock: the line needs only that moment.
    .task(id: startedAt) {
      guard stop != nil, endedAt == nil else { return }
      let left: TimeInterval = TurnActivity.slowAfter - Date().timeIntervalSince(startedAt)
      if left > 0 { try? await Task.sleep(for: .seconds(left)) }
      if !Task.isCancelled { quietFor = Date().timeIntervalSince(startedAt) }
    }
  }

  private var header: some View {
    let state: TurnActivity.Header = TurnActivity.header(ended: endedAt != nil, waiting: waiting)
    return HStack(spacing: 10) {
      DotGrid(moving: state == .thinking).frame(width: 16)
      switch state {
      case .worked:
        Text("Worked for \(Self.clock((endedAt ?? startedAt).timeIntervalSince(startedAt)))").font(AssistantType.name).foregroundStyle(p.ink)
      case .waiting:
        Text(TurnActivity.waitingWords).font(AssistantType.name).foregroundStyle(p.ink)
        Text(Self.clock((waitingSince ?? Date()).timeIntervalSince(startedAt))).font(AssistantType.figures).foregroundStyle(p.faint)
      case .thinking:
        ShimmerText(text: "Thinking", font: AssistantType.name)
        TimelineView(.periodic(from: startedAt, by: 1)) { moment in
          Text(Self.clock(moment.date.timeIntervalSince(startedAt))).font(AssistantType.figures).foregroundStyle(p.faint)
        }
      }
      if let tried = TurnActivity.tryWords(attempt) {
        Text(tried).font(AssistantType.meta).foregroundStyle(p.secondary)
      }
    }.contentShape(Rectangle())
  }

  @ViewBuilder private func row(_ step: Step, current: Bool) -> some View {
    if endedAt != nil, step.sources.isEmpty, step.computerTask == nil {
      ToolCallRow(id: step.id, label: step.label, failed: step.failed, retry: retry)
    } else if step.sources.isEmpty {
      HStack(spacing: 10) {
        Circle().fill(current ? p.accent : p.faint).frame(width: 5, height: 5).frame(width: 16)
        // The step in hand shimmers while the work goes on, not while it waits on the person.
        if current, !waiting { ShimmerText(text: step.label, font: AssistantType.body) }
        else { Text(step.label).font(AssistantType.body).foregroundStyle(p.secondary) }
        if let task = step.computerTask {
          Button("Watch") { ComputerHost.shared.showWatching(task: task) }
            .buttonStyle(AssistantPressStyle()).font(AssistantType.meta).foregroundStyle(p.secondary)
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          InterfaceIcon(systemName: "magnifyingglass", size: 13).foregroundStyle(p.secondary).frame(width: 16)
          Text(step.label).font(AssistantType.body).foregroundStyle(p.secondary)
        }
        HStack(alignment: .top, spacing: 10) {
          Rectangle().fill(p.line).frame(width: 1).frame(width: 16)
          FlowLayout(spacing: 6) {
            let all: Bool = allSources.contains(step.id) || step.sources.count <= sourceLimit
            ForEach(all ? step.sources : Array(step.sources.prefix(sourceLimit))) { source in
              HStack(spacing: 6) {
                AppLogoTile(id: source.app, name: source.name, size: 16)
                Text(source.name).font(AssistantType.meta).foregroundStyle(p.ink).lineLimit(1)
              }.padding(.horizontal, 8).frame(height: 26)
                .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius, style: .continuous))
            }
            if !all {
              Button("+\(step.sources.count - sourceLimit) more") {
                withAnimation(Motion.entering(reduce)) { _ = allSources.insert(step.id) }
              }.buttonStyle(AssistantPressStyle()).font(AssistantType.meta).foregroundStyle(p.secondary)
                .padding(.horizontal, 8).frame(height: 26)
            }
          }
        }.fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// "7s" under a minute, then "1m 05s".
  static func clock(_ seconds: TimeInterval) -> String {
    let whole = max(0, Int(seconds))
    return whole < 60 ? "\(whole)s" : "\(whole / 60)m " + String(format: "%02d", whole % 60) + "s"
  }
}

/// Serein's turn in its own chat, as a trail above its reply: the pages, Mac apps, files and
/// memory it used (the board's steps) and the AI app's own steps, in time order, the newest in the
/// present tense while the turn runs.
struct RunTrail: View {
  @ObservedObject var run: AgentRun
  let browser: BrowserModel
  /// When the person pressed Send for this turn: the clock counts from there, as the bare trail
  /// before the run did. Nil counts from the run's start.
  var since: Date? = nil
  /// A card or a question waits on the person for this turn.
  var waiting = false
  /// Which try this turn is, and what stops it (`ThinkingTrail`).
  var attempt = 1
  var stop: (() -> Void)? = nil
  var retry: ((String) -> Void)? = nil
  /// Watched so a board step draws at once; `run.boardInfo` reads it.
  @ObservedObject var tabs: AgentTabBoard
  /// Scrolls the chat to its end while the person is there: a new step is no new text.
  @Environment(\.chatFollow) private var follow

  init(run: AgentRun, browser: BrowserModel, since: Date? = nil, waiting: Bool = false, attempt: Int = 1,
       stop: (() -> Void)? = nil, retry: ((String) -> Void)? = nil) {
    self.run = run
    self.browser = browser
    self.since = since
    self.waiting = waiting
    self.attempt = attempt
    self.stop = stop
    self.retry = retry
    tabs = browser.agentTabs
  }

  var body: some View {
    let steps = Self.steps(run, board: run.boardInfo(browser))
    // A finished turn that only answered needs no trail.
    if run.isActive || !steps.isEmpty {
      ThinkingTrail(
        steps: steps, startedAt: since.map { min($0, run.record.startedAt) } ?? run.record.startedAt,
        endedAt: run.isActive ? nil : run.record.endedAt ?? run.record.startedAt, doneLabel: run.outcomeText,
        waiting: waiting && run.isActive, endedWell: run.record.outcome == .done, attempt: attempt,
        replied: run.transcript.last.map { $0.role == "assistant" && !$0.text.isEmpty } ?? false, stop: stop,
        retry: retry
      ).onChange(of: steps.last?.id) { if run.isActive { follow?() } }
    }
  }

  static func steps(_ run: AgentRun, board: AgentTabBoard.RunInfo?) -> [ThinkingTrail.Step] {
    // A warm chat keeps its board from turn to turn: a step from before this turn is not this one's.
    let page = (board?.steps ?? []).filter { $0.time >= run.record.startedAt }
    let all = (page + run.steps).sorted { $0.time < $1.time }
    return all.map { step in
      let live = run.isActive && step.id == all.last?.id
      let label = step.failed == nil ? step.label : "Not done: " + step.label
      return ThinkingTrail.Step(
        id: step.id, label: live ? RunNow.present(label) : label, failed: step.failed != nil,
        computerTask: step.tool.hasPrefix("computer_") ? run.taskID : nil)
    }
  }
}

/// Brings the chat's end into view, set only while the person is at the end. A plain key, not
/// `@Entry`.
private struct ChatFollowKey: EnvironmentKey {
  static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
  var chatFollow: (() -> Void)? {
    get { self[ChatFollowKey.self] }
    set { self[ChatFollowKey.self] = newValue }
  }
}

/// Nine dots, three by three. While work goes on, a light runs through them; still otherwise and
/// under Reduce Motion.
private struct DotGrid: View {
  let moving: Bool
  @Environment(\.palette) private var p
  @Environment(\.reducesMotion) private var reduce
  var body: some View {
    TimelineView(.animation(minimumInterval: 0.15, paused: !moving || reduce)) { moment in
      let beat = Int(moment.date.timeIntervalSinceReferenceDate / 0.15)
      VStack(spacing: 2) {
        ForEach(0..<3, id: \.self) { line in
          HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { column in
              let lit: Bool = !moving || reduce || (beat + line * 2 + column) % 5 < 2
              RoundedRectangle(cornerRadius: 1).fill(p.accent).opacity(lit ? 1 : 0.3).frame(width: 3, height: 3)
            }
          }
        }
      }
    }.accessibilityHidden(true)
  }
}
