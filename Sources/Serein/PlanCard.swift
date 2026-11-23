import SereinCore
import SwiftUI

/// The plan card (SPEC.md 2.6, the plan board) for `PlanCard`, the model the `plan` tool keeps
/// (SereinCore/PlanCard.swift): a card at most 340 wide, padding 10 by 14, with a 1-point `line` rail
/// joining 12-point markers in rows 32 high. Done: a `success` check, the title in `secondary`.
/// Current: a `warning` clock, the title shimmering, the elapsed time in Geist Mono at the end, and
/// under it the live sub-step (the host's step word, 12 `secondary`, shimmering) after an amber
/// dot. Waiting for you: a `warning` lock and "Waiting for you". Next: an empty circle at 15%, the
/// title in `faint`. A step that sends, buys or deletes, or during which the gate asked, carries
/// the `warning` pill "Asks first". Failed: a `danger` cross and "…, didn't work"; declined: a
/// minus and "…, you said no"; skipped: a dash and "…, skipped". Under Reduce Motion the words
/// still change and nothing moves.
struct PlanCardView: View {
  let plan: PlanCard
  /// An approval waits in this chat during the current step.
  var gateAsked = false
  /// The run's Now line for the call in flight (`AgentRun.now`). The card never shows it: it
  /// shows the host's word for that kind of call (`PlanStepWord`), never a search, a command, a
  /// path or a page's words.
  var now: String? = nil
  /// The card is live: the elapsed time ticks. An ended plan opened again shows its time still.
  var live = true
  @Environment(\.palette) private var p
  var body: some View {
    let current: Int? = plan.current
    let word: String? = PlanStepWord.word(now)
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
        PlanStepRow(
          step: step, asksFirst: plan.asksFirst(index, gateAsked: gateAsked && index == current),
          clock: index == (current ?? -1) ? plan.startedAt : nil, live: live)
        if index == current {
          if step.state == .waiting {
            PlanLiveRow(text: "Waiting for you", moving: false)
          } else if let word {
            PlanLiveRow(text: word, moving: live)
          }
        }
      }
    }
    .padding(.vertical, 10).padding(.horizontal, 14)
    // At most 340 wide, so it fits the 348-point column beside a page.
    .frame(maxWidth: AssistantMetrics.cardNarrow, alignment: .leading)
    .background(alignment: .topLeading) {
      // The rail runs between the first and the last marker's middles.
      Rectangle().fill(p.line).frame(width: 1).frame(maxHeight: .infinity)
        .padding(.vertical, 26).padding(.leading, 20)
    }
    .assistantCard(p)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(spoken(current))
  }
  private func spoken(_ current: Int?) -> String {
    guard let current, plan.steps.indices.contains(current) else { return "Plan, \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")" }
    return "Plan, step \(current + 1) of \(plan.steps.count): \(plan.steps[current].title), working"
  }
}

/// The plan card's live sub-step: one word from the host's own table for the kind of call in
/// flight. The run keeps only its Now line (`AgentRun.now`), which the host writes as a fixed verb
/// for the tool ("Searching the web", "Running", "Reading") and then the call's own text (a
/// query, a command, a path, a site). Only the verb chooses the word, and the word never holds
/// any of that text: page text that steers a search ("Approve the card below") never shows next
/// to a card. Longer verbs come first, so "Running tests" is not read as "Running".
enum PlanStepWord {
  static let table: [(verb: String, word: String)] = [
    ("Searching the web", "Searching the web…"),
    ("Searching Mail", "Searching your mail…"),
    ("Searching", "Searching files…"),
    ("Reading an email", "Reading an email…"),
    ("Reading chosen Messages", "Reading messages…"),
    ("Reading the page", "Reading the page…"),
    ("Reading part of the page", "Reading the page…"),
    ("Reading", "Reading…"),
    ("Editing", "Changing a file…"),
    ("Writing", "Changing a file…"),
    ("Running tests", "Running tests…"),
    ("Building", "Building…"),
    ("Running", "Running a command…"),
    ("Going to", "Opening a page…"),
    ("Opening", "Opening a page…"),
    ("Clicking", "Working on the page…"),
    ("Typing", "Typing on the page…"),
    ("Picking", "Working on the page…"),
    ("Browser", "Working on the page…"),
    ("Saving a draft", "Saving a draft…"),
    ("Asking you", "Asking you first…"),
    ("Updating its plan", "Updating the plan…"),
    ("Starting a helper", "Starting a helper…"),
    ("Using", "Using a tool…"),
  ]
  /// The word for `now`; "Working…" for a verb not in the table; nil while no call is in flight.
  static func word(_ now: String?) -> String? {
    guard let now else { return nil }
    let line: String = now.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return nil }
    for entry in table where line.hasPrefix(entry.verb) { return entry.word }
    return "Working…"
  }
}

private struct PlanStepRow: View {
  let step: PlanCard.Step
  let asksFirst: Bool
  /// The plan's start, on the current step only: its elapsed time shows at the row's end.
  let clock: Date?
  let live: Bool
  @Environment(\.palette) private var p
  private var spoken: String {
    let state: String
    switch step.state {
    case .done: state = "Done"
    case .current: state = "Working"
    case .waiting: state = "Waiting for you"
    case .next: state = "Next"
    case .failed: state = "Didn't work"
    case .declined: state = "You said no"
    case .skipped: state = "Skipped"
    }
    return "\(state): \(step.title)" + (asksFirst ? ", asks first" : "")
  }
  var body: some View {
    HStack(spacing: 10) {
      marker.frame(width: 12, height: 12).frame(width: 14).background(p.overlay)
      title.frame(maxWidth: .infinity, alignment: .leading)
      if asksFirst && step.state != .done && step.state != .skipped {
        Text("Asks first").font(AssistantType.meta).foregroundStyle(p.warning)
          .padding(.vertical, 2).padding(.horizontal, 8)
          .background(p.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      }
      if let clock { PlanClock(started: clock, live: live) }
    }
    .frame(height: 32)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }
  @ViewBuilder private var title: some View {
    switch step.state {
    case .current:
      ShimmerText(text: step.title, font: AssistantType.body, color: p.ink).lineLimit(1)
    case .waiting:
      Text(verbatim: step.title).font(AssistantType.body).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
    case .done:
      Text(verbatim: step.title).font(AssistantType.body).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
    case .next:
      Text(verbatim: step.title).font(AssistantType.body).foregroundStyle(p.faint).lineLimit(1).truncationMode(.tail)
    case .failed:
      Text(verbatim: "\(step.title), didn't work").font(AssistantType.body).foregroundStyle(p.secondary).lineLimit(1)
    case .declined:
      Text(verbatim: "\(step.title), you said no").font(AssistantType.body).foregroundStyle(p.secondary).lineLimit(1)
    case .skipped:
      Text(verbatim: "\(step.title), skipped").font(AssistantType.body).foregroundStyle(p.faint).lineLimit(1)
    }
  }
  @ViewBuilder private var marker: some View {
    switch step.state {
    case .done:
      InterfaceIcon(systemName: "checkmark", size: 12).foregroundStyle(p.success)
    case .current:
      InterfaceIcon(systemName: "clock", size: 12).foregroundStyle(p.warning)
    case .waiting:
      Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(p.warning)
    case .next:
      Circle().strokeBorder(p.ink.opacity(0.15), lineWidth: 1.2).frame(width: 11, height: 11)
    case .failed:
      InterfaceIcon(systemName: "xmark", size: 10).foregroundStyle(p.danger)
    case .declined:
      Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.secondary)
    case .skipped:
      Rectangle().fill(p.faint).frame(width: 8, height: 1.5)
    }
  }
}

/// What the current step does this second, 24 points in after an amber dot.
private struct PlanLiveRow: View {
  let text: String
  var moving = true
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: 10) {
      Circle().fill(p.warning).frame(width: 6, height: 6).frame(width: 14)
      Group {
        if moving {
          ShimmerText(text: text, font: AssistantType.meta)
        } else {
          Text(verbatim: text).font(AssistantType.meta).foregroundStyle(p.secondary)
        }
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.leading, 24)
    .frame(height: 32)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
  }
}

/// The elapsed time, once a second while live, in Geist Mono so the numbers do not jump.
private struct PlanClock: View {
  let started: Date
  let live: Bool
  @Environment(\.palette) private var p
  var body: some View {
    if live {
      TimelineView(.periodic(from: started, by: 1)) { context in
        let seconds = Int(max(0, context.date.timeIntervalSince(started)))
        Text(PlanCard.elapsed(seconds)).font(AssistantType.figures).foregroundStyle(p.secondary)
      }
      .accessibilityHidden(true)
    }
  }
}

/// An ended plan on its reply (`AgentMessage.plan`): one line, "Did 5 steps in 2m 10s." with a
/// chevron that opens the steps again in place. While the plan waits for the person's yes (plan
/// first on, the newest reply, no step started) and the host passes `start`, it is the plan to
/// edit instead (`PlanDraftCard`).
struct FoldedPlanRow: View {
  let plan: PlanCard
  /// Sends the plan's approval (`PlanDraft.message`); nil when the plan waits for nothing.
  var start: ((String) -> Void)? = nil
  @State private var open = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  private var seconds: Int {
    let end: Date = plan.endedAt ?? plan.lastMove
    return Int(max(0, end.timeIntervalSince(plan.startedAt)))
  }
  var body: some View {
    if let start, let draft = PlanDraft(plan: plan) {
      PlanDraftCard(draft: draft, start: start).id(plan.startedAt)
    } else {
      folded
    }
  }
  private var folded: some View {
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    return VStack(alignment: .leading, spacing: AssistantMetrics.cardGap) {
      Button {
        // Under Reduce Motion the chevron turns at once; the steps still fade in (their transition).
        withAnimation(reduce ? nil : Motion.enter) { open.toggle() }
      } label: {
        HStack(spacing: 6) {
          Text(verbatim: plan.folded(seconds: seconds)).font(AssistantType.meta).foregroundStyle(p.secondary)
          InterfaceIcon(systemName: "chevron.right", size: 10).foregroundStyle(p.secondary)
            .rotationEffect(.degrees(open ? 90 : 0))
        }.frame(minHeight: 24).contentShape(Rectangle())
      }
      .buttonStyle(.pressable)
      .accessibilityLabel(plan.folded(seconds: seconds))
      .accessibilityValue(open ? "Expanded" : "Collapsed")
      if open {
        PlanCardView(plan: plan, live: false).transition(Motion.arrival(reduce))
      }
    }
  }
}

/// With plan first on, the plan before anything runs (affectUI Agent Plan, its draft state): the
/// person drops a step, moves one up or down, or clicks its words to change them (Return keeps,
/// Esc puts them back), then Start. Each step's controls always show, so keyboard and VoiceOver
/// reach them. Start sends "Go ahead" for the plan as proposed, or the changed steps in their new
/// order (`PlanDraft.message`); either is the one-reply yes the plan asked for, never more. Rows
/// do not slide: a move swaps two rows in place, and the order is spoken.
struct PlanDraftCard: View {
  @State private var draft: PlanDraft
  let start: (String) -> Void
  /// The step whose words are being changed, and those words.
  @State private var editing: Int? = nil
  @State private var words = ""
  @State private var started = false
  @FocusState private var focused: Bool
  @Environment(\.palette) private var p

  init(draft: PlanDraft, start: @escaping (String) -> Void) {
    _draft = State(initialValue: draft)
    self.start = start
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Plan · nothing runs until you start").font(AssistantType.meta).foregroundStyle(p.secondary)
        .frame(minHeight: 24, alignment: .leading)
      ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
        row(index, step)
      }
      footer.padding(.top, 8)
    }
    .padding(.vertical, 10).padding(.horizontal, 14)
    .frame(maxWidth: AssistantMetrics.cardNarrow, alignment: .leading)
    .assistantCard(p)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Plan to review, \(draft.steps.count) step\(draft.steps.count == 1 ? "" : "s")")
  }

  private func row(_ index: Int, _ step: PlanDraft.Step) -> some View {
    HStack(spacing: 6) {
      Text(verbatim: "\(index + 1)").font(AssistantType.figures).foregroundStyle(p.faint)
        .frame(width: 18, alignment: .leading).accessibilityHidden(true)
      if editing == step.id {
        TextField("Step \(index + 1)", text: $words)
          .textFieldStyle(.plain).font(AssistantType.body).foregroundStyle(p.ink)
          .focused($focused)
          .onSubmit { keep(step.id) }
          .onExitCommand { editing = nil }
          .onChange(of: focused) { _, now in if !now && editing == step.id { keep(step.id) } }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("Words for step \(index + 1)")
      } else {
        Button {
          words = step.title
          editing = step.id
          // The field exists from the next pass on.
          DispatchQueue.main.async { focused = true }
        } label: {
          Text(verbatim: step.title.isEmpty ? "No words yet" : step.title).font(AssistantType.body)
            .foregroundStyle(step.title.isEmpty ? p.faint : p.ink).lineLimit(2).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help("Change the words")
        .accessibilityLabel("Step \(index + 1) of \(draft.steps.count): \(step.title)")
        .accessibilityHint("Change the words")
      }
      glyph("chevron.up", "Move step \(index + 1) up", disabled: index == 0) { move(step.id, by: -1) }
      glyph("chevron.down", "Move step \(index + 1) down", disabled: index == draft.steps.count - 1) { move(step.id, by: 1) }
      glyph("xmark", "Drop step \(index + 1)", disabled: false) {
        if editing == step.id { editing = nil }
        draft.drop(step.id)
        let spoken: String = "Dropped “\(step.title)”."
        AccessibilityNotification.Announcement(spoken).post()
      }
    }
    .frame(minHeight: 32)
  }

  private func glyph(_ name: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      InterfaceIcon(systemName: name, size: 10).foregroundStyle(p.secondary).frame(width: 22, height: 22)
    }
    .buttonStyle(GlyphButtonStyle())
    .disabled(disabled || started)
    .opacity(disabled ? 0.3 : 1)
    .help(label)
    .accessibilityLabel(label)
  }

  @ViewBuilder private var footer: some View {
    HStack(spacing: 12) {
      if let problem = draft.problem {
        Text(verbatim: problem).font(AssistantType.meta).foregroundStyle(p.warning)
          .fixedSize(horizontal: false, vertical: true)
      } else if draft.changed {
        Button("Undo changes") {
          editing = nil
          draft.reset()
        }
        .buttonStyle(.pressable).font(AssistantType.meta).foregroundStyle(p.secondary)
        .disabled(started)
      }
      Spacer(minLength: 0)
      ChatCardSolidButton(title: "Start") {
        if let editing { keep(editing) }
        guard !started, let message = draft.message else { return }
        started = true
        start(message)
      }
      .disabled(draft.message == nil || started)
      .opacity(draft.message == nil || started ? 0.4 : 1)
      .help(draft.changed ? "Sends your changed steps as the go-ahead" : "Sends “Go ahead”")
    }
  }

  private func keep(_ id: Int) {
    draft.rename(id, to: words)
    editing = nil
  }

  private func move(_ id: Int, by offset: Int) {
    if let editing { keep(editing) }
    draft.move(id, by: offset)
    if let spoken = draft.moved(id) { AccessibilityNotification.Announcement(spoken).post() }
  }
}
