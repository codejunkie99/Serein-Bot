import SereinCore
import SwiftUI
import Charts

@MainActor final class SiteNavigation: ObservableObject {
  static let shared = SiteNavigation()
  @Published var selected: String?
  /// The goal tracker open in Pages.
  @Published var goal: String?
  func open(_ id: String, browser: BrowserModel) { goal = nil; selected = id; browser.section = ShellSection.sites }
  func openGoal(_ id: String, browser: BrowserModel) { selected = nil; goal = id; browser.section = ShellSection.sites }
}

extension PersonalGoal.Kind: Identifiable { public var id: String { rawValue } }

/// Serein's own text field, as the New team sheet draws it: plain text on `card` with a hairline.
private struct GoalField: ViewModifier {
  var padding: CGFloat = 0
  @Environment(\.palette) private var p
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: UIStyle.controlRadius)
    content.textFieldStyle(.plain).font(UIStyle.font(14)).foregroundStyle(p.ink)
      .padding(.horizontal, 10).padding(.vertical, padding).frame(minHeight: 34)
      .background(p.card, in: shape).overlay(shape.strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
  }
}

/// A choice among a few, drawn as the inspector's tabs: a raised pill on a `track` capsule.
struct GoalSegments<Value: Hashable>: View {
  let label: String
  let options: [(Value, String)]
  @Binding var selection: Value
  @Namespace private var pill
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduce
  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.0) { value, title in
        Button { withAnimation(Motion.swapping(reduce)) { selection = value } } label: {
          Text(title).font(UIStyle.font(12)).lineLimit(1).fixedSize()
            .foregroundStyle(selection == value ? p.ink : p.secondary)
            .padding(.horizontal, 14).frame(height: UIStyle.wide(24))
            .contentShape(RoundedRectangle(cornerRadius: UIStyle.controlRadius, style: .continuous))
        }.buttonStyle(SwitchSegmentStyle(selected: selection == value, pill: pill))
          .accessibilityAddTraits(selection == value ? .isSelected : [])
      }
    }.padding(2).frame(height: UIStyle.wide(28)).fixedSize(horizontal: true, vertical: false)
      .background(p.track, in: Capsule())
      .accessibilityElement(children: .contain).accessibilityLabel(label)
  }
}

/// Progress as a ring with its percent inside, so a card reads at a glance.
private struct GoalRing: View {
  let fraction: Double
  var size: CGFloat = 48
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduce
  var body: some View {
    ZStack {
      Circle().stroke(p.track, lineWidth: 4)
      Circle().trim(from: 0, to: fraction).stroke(p.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        .rotationEffect(.degrees(-90)).animation(reduce ? nil : .easeOut(duration: 0.25), value: fraction)
      Text("\(Int(fraction * 100))%").font(UIStyle.font(size / 4, weight: .medium)).foregroundStyle(p.ink)
    }.frame(width: size, height: size)
      .accessibilityElement().accessibilityLabel("Progress").accessibilityValue("\(Int(fraction * 100)) percent")
  }
}

struct GoalTrackerCard: View {
  let id: String
  var compact = false
  var browser: BrowserModel? = nil
  @ObservedObject private var book = TodoBook.shared
  @State private var reading = ""
  @State private var error: String?
  @State private var reminder = Date().addingTimeInterval(86_400)
  @State private var editingReminder = false
  @State private var editing = false
  @State private var confirmDelete = false
  @Environment(\.palette) private var p
  private var card: TodoCard? { book.cards.first { $0.id == id } }
  var body: some View {
    if let card {
      if compact, let browser {
        Button { SiteNavigation.shared.openGoal(id, browser: browser) } label: { content(card) }
          .buttonStyle(AssistantPressStyle()).accessibilityHint("Opens this goal")
      } else { content(card) }
    } else { Text("This goal is no longer saved.").font(UIStyle.meta).foregroundStyle(p.secondary) }
  }
  private func content(_ card: TodoCard) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: card.goal?.kind.symbol ?? "flag").font(.system(size: 24, weight: .light))
          .foregroundStyle(p.accent).frame(width: 42, height: 42).background(p.track, in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 5) {
          Text(card.title).font(UIStyle.font(compact ? 18 : 24, weight: .semibold)).foregroundStyle(p.ink)
          if let notes = card.notes, !compact { Text(notes).font(UIStyle.font(13)).foregroundStyle(p.secondary) }
        }
        Spacer(minLength: 0)
        if let fraction = card.goal?.fraction { GoalRing(fraction: fraction, size: compact ? 48 : 60) }
      }
      if let goal = card.goal {
        if let target = goal.target {
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(goal.current, format: .number.precision(.fractionLength(0...2))).font(UIStyle.font(32, weight: .semibold))
                .foregroundStyle(p.ink)
              Text("of \(target.formatted()) \(goal.unit)").font(UIStyle.font(13)).foregroundStyle(p.secondary)
            }
            if let left = goal.remaining {
              Text(left > 0 ? [left.formatted(), goal.unit, "to go"].filter { !$0.isEmpty }.joined(separator: " ") : "Target reached")
                .font(UIStyle.font(12)).foregroundStyle(p.secondary)
            }
          }
        } else if !goal.steps.isEmpty {
          Text("\(goal.steps.filter(\.done).count) of \(goal.steps.count) steps done").font(UIStyle.font(13)).foregroundStyle(p.secondary)
        }
        if !compact, goal.entries.count >= 2 {
          let sameDay: Bool = Calendar.current.isDate(goal.entries[0].at, inSameDayAs: goal.entries[goal.entries.count - 1].at)
          let label: Date.FormatStyle = sameDay ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day()
          Chart {
            ForEach(goal.entries) { entry in
              LineMark(x: .value("Date", entry.at), y: .value("Progress", entry.value))
                .foregroundStyle(p.accent).interpolationMethod(.linear)
              PointMark(x: .value("Date", entry.at), y: .value("Progress", entry.value)).foregroundStyle(p.accent)
            }
            if let target = goal.target {
              RuleMark(y: .value("Target", target)).foregroundStyle(p.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .bottom, alignment: .leading) {
                  Text("Target").font(UIStyle.font(10)).foregroundStyle(p.secondary)
                }
            }
          }.chartXAxis {
            // The first and last reading only: automatic marks repeat one label when readings are close together.
            AxisMarks(values: [goal.entries[0].at, goal.entries[goal.entries.count - 1].at]) { mark in
              AxisValueLabel(format: label, anchor: mark.index == 0 ? .topLeading : .topTrailing)
            }
          }.frame(height: 150).accessibilityLabel("Recorded progress over time")
        }
        if compact, let next = goal.next {
          VStack(alignment: .leading, spacing: 5) {
            Text("Next step").font(UIStyle.font(11, weight: .medium)).foregroundStyle(p.secondary)
            Text(next.title).font(UIStyle.font(14)).foregroundStyle(p.ink)
          }
        } else if !compact {
          if !goal.steps.isEmpty {
            StepTracker(title: "Steps", steps: goal.steps.map { .init(id: $0.id, title: $0.title, done: $0.done) }) { step in
              var changed = goal
              if let index = changed.steps.firstIndex(where: { $0.id == step }) { changed.steps[index].done.toggle() }
              attempt { try book.updateGoal(id, details: changed) }
            }
          }
          if goal.target != nil {
            HStack {
              TextField("New total", text: $reading).modifier(GoalField()).frame(maxWidth: 160).onSubmit { record(goal) }
              Text(goal.unit).font(UIStyle.font(12)).foregroundStyle(p.secondary)
              Button("Record progress") { record(goal) }.buttonStyle(QuietButton(bordered: true))
            }
            Text("Your recorded progress, not an automatic measurement.").font(UIStyle.font(11)).foregroundStyle(p.faint)
          }
        }
      }
      if !compact {
        Button("Plan next steps with Serein", systemImage: "sparkle") {
          if let relay = RelayOrchestrator.shared {
            SereinRouter.home()
            relay.ask("Help me plan the next steps for my saved goal “\(card.title)” and update its plan. Keep completed steps and recorded progress.")
          }
        }.buttonStyle(QuietButton())
      }
      if let deadline = card.deadline {
        Label(deadline.formatted(date: .abbreviated, time: .shortened), systemImage: "bell")
          .font(UIStyle.font(12)).foregroundStyle(p.secondary)
      }
      if !compact {
        HStack(spacing: 16) {
          Button("Reminder", systemImage: "bell.badge") { reminder = card.deadline ?? Date().addingTimeInterval(86_400); editingReminder = true }
            .buttonStyle(QuietButton()).popover(isPresented: $editingReminder) {
              VStack(alignment: .leading, spacing: 16) {
                Text("Remind me about this goal").font(UIStyle.bodyStrong)
                DatePicker("When", selection: $reminder, in: Date()...)
                Button("Save reminder") {
                  attempt { try book.edit(id, title: card.title, notes: card.notes, deadline: reminder, assistantID: card.assistantID) }
                  editingReminder = false
                }.buttonStyle(QuietButton())
                if card.deadline != nil {
                  Button("Remove reminder") {
                    attempt { try book.edit(id, title: card.title, notes: card.notes, deadline: nil, assistantID: card.assistantID) }
                    editingReminder = false
                  }.buttonStyle(QuietButton())
                }
              }.padding(22)
            }
          Button(card.column == .done ? "Reopen" : "Mark complete") {
            attempt { try book.move(id, to: card.column == .done ? .next : .done) }
          }.buttonStyle(QuietButton())
          Spacer(minLength: 0)
          Button("Edit", systemImage: "pencil") { editing = true }.buttonStyle(QuietButton())
          Button("Delete", systemImage: "trash") { confirmDelete = true }.buttonStyle(QuietButton())
        }
      }
      if let error { Text(error).font(UIStyle.font(12)).foregroundStyle(p.warning) }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(p.card, in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.line, lineWidth: 1))
      .sheet(isPresented: $editing) { PersonalGoalEditor(editing: card) { editing = false } }
      .confirmationDialog("Delete “\(card.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
        Button("Delete goal", role: .destructive) { attempt { try book.delete(id) } }
        Button("Cancel", role: .cancel) {}
      } message: { Text("Its steps, recorded progress and reminder go with it. This cannot be undone.") }
  }
  private func record(_ goal: PersonalGoal) {
    attempt {
      guard let value = Double(reading) else { throw SereinError.invalid("Enter a number such as 250 or 3.5.") }
      var changed = goal
      guard changed.record(value: value, note: nil) else { throw SereinError.invalid("Enter zero or a positive number.") }
      try book.updateGoal(id, details: changed); reading = ""
    }
  }
  private func attempt(_ action: () throws -> Void) { do { try action(); error = nil } catch { self.error = error.localizedDescription } }
}

private struct PersonalGoalEditor: View {
  /// The saved goal being changed. A new goal has none.
  var editing: TodoCard? = nil
  @State var kind = PersonalGoal.Kind.general
  let close: () -> Void
  @State private var title = ""
  @State private var steps = ""
  @State private var target = ""
  @State private var unit = ""
  @State private var error: String?
  @Environment(\.palette) private var p
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(editing == nil ? "What would you like to work toward?" : "Edit goal").font(UIStyle.font(22, weight: .semibold))
        .foregroundStyle(p.ink)
      TextField("Name your goal", text: $title).modifier(GoalField())
      GoalSegments(label: "Kind", options: PersonalGoal.Kind.allCases.map { ($0, $0.rawValue.capitalized) }, selection: $kind)
      Text("Next steps · one per line").font(UIStyle.meta).foregroundStyle(p.secondary)
      // A text editor and not a field: Return starts the next step here.
      TextEditor(text: $steps).scrollContentBackground(.hidden).frame(height: 88).modifier(GoalField(padding: 8))
        .accessibilityLabel("Next steps, one per line")
      HStack {
        TextField("Target (optional)", text: $target).modifier(GoalField())
        TextField("Unit · dollars, km, lessons", text: $unit).modifier(GoalField())
      }
      if let error { Text(error).foregroundStyle(p.warning).font(UIStyle.meta) }
      HStack {
        Button("Cancel", action: close).buttonStyle(QuietButton(bordered: true)).keyboardShortcut(.cancelAction)
        Spacer()
        Button(editing == nil ? "Create goal" : "Save") { save() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
          .disabled(TodoBoard.cleanTitle(title).isEmpty)
      }
    }.padding(20).frame(width: 500)
      .onAppear {
        guard let card = editing else { return }
        title = card.title
        guard let goal = card.goal else { return }
        kind = goal.kind; unit = goal.unit
        steps = goal.steps.map(\.title).joined(separator: "\n")
        // `String(3000.0)` is "3000.0"; the field shows what the person typed.
        target = goal.target.map { String($0) }.map { $0.hasSuffix(".0") ? String($0.dropLast(2)) : $0 } ?? ""
      }
  }
  private func save() {
    do {
      let targetValue = target.isEmpty ? nil : Double(target)
      guard target.isEmpty || targetValue != nil else { throw SereinError.invalid("Use a number for the target.") }
      var detail = editing?.goal ?? PersonalGoal()
      detail.kind = kind; detail.steps = detail.steps(editedTo: steps); detail.target = targetValue; detail.unit = unit
      guard detail.valid else { throw SereinError.invalid("Use a positive target and at most 30 steps.") }
      if let old = editing {
        try TodoBook.shared.edit(old.id, title: title, notes: old.notes, deadline: old.deadline, assistantID: old.assistantID)
        try TodoBook.shared.updateGoal(old.id, details: detail)
      } else {
        var card = TodoCard(title: TodoBoard.cleanTitle(title)); card.goal = detail
        try TodoBook.shared.add(card)
      }
      close()
    } catch { self.error = error.localizedDescription }
  }
}

struct SitesWorkspace: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject private var sites = SiteBook.shared
  @ObservedObject private var goals = TodoBook.shared
  @ObservedObject private var navigation = SiteNavigation.shared
  @Environment(\.palette) private var p
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if let id = navigation.goal, goals.cards.contains(where: { $0.id == id }) {
          HStack {
            Button("All pages", systemImage: "chevron.left") { navigation.goal = nil }.buttonStyle(QuietButton())
            Spacer()
            Button("Bring into conversation", systemImage: "bubble.left") {
              if let relay = RelayOrchestrator.shared {
                relay.showSite("goal-" + id, into: relay.threadID); SereinRouter.home()
              }
            }.buttonStyle(QuietButton())
          }
          // A new goal starts clean: a total typed for one goal must not be recorded on the next.
          GoalTrackerCard(id: id, browser: browser).id(id)
        } else if let id = navigation.selected, let site = sites.find(id) {
          HStack {
            Button("All pages", systemImage: "chevron.left") { navigation.selected = nil }.buttonStyle(QuietButton())
            Spacer()
            Button("Bring into conversation", systemImage: "bubble.left") {
              if let relay = RelayOrchestrator.shared {
                relay.showSite(site.id, into: relay.threadID); SereinRouter.home()
              }
            }.buttonStyle(QuietButton())
          }
          SavedSiteCard(id: id, browser: browser, expanded: true)
        } else {
          Text("Your little tools, all here.").font(UIStyle.font(30, weight: .semibold))
          Text("Trackers, dashboards and websites you make with Serein.").font(UIStyle.font(14)).foregroundStyle(p.secondary)
          if let problem = sites.problem { Text(problem).foregroundStyle(p.warning) }
          if sites.items.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
              Image(systemName: "rectangle.3.group").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(p.accent)
              Text("Make something useful.").font(UIStyle.font(22, weight: .medium))
              Text("Ask Serein for a tracker, a dashboard or a website. It will be saved here.")
                .font(UIStyle.font(14)).foregroundStyle(p.secondary)
              Button("Ask Serein") { SereinRouter.show(draft: "Make me a dashboard that") }.buttonStyle(QuietButton())
            }.padding(32).frame(maxWidth: .infinity, alignment: .leading).background(p.card, in: RoundedRectangle(cornerRadius: 16))
          }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
            ForEach(sites.items) { site in
              Button {
                if let goal = site.goalID { navigation.openGoal(goal, browser: browser) } else { navigation.open(site.id, browser: browser) }
              } label: {
                VStack(alignment: .leading, spacing: 12) {
                  Image(systemName: site.goalID != nil ? "chart.xyaxis.line" : site.dashboard != nil ? "chart.bar" : "globe")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(p.accent)
                  Text(site.title).font(UIStyle.font(18, weight: .medium)).foregroundStyle(p.ink)
                  if let spec = site.dashboard { Text(spec.stat.value).font(UIStyle.font(28, weight: .semibold)).foregroundStyle(p.ink) }
                  Text(site.url.flatMap { URL(string: $0)?.host } ?? (site.goalID != nil ? "Your goal tracker" : "Saved dashboard"))
                    .font(UIStyle.font(12)).foregroundStyle(p.secondary)
                }.padding(16).frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                  .background(p.card, in: RoundedRectangle(cornerRadius: 16))
                  .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.line, lineWidth: 1))
              }.buttonStyle(AssistantPressStyle())
            }
          }
        }
      }.padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
    }
  }
}

struct SavedSiteCard: View {
  let id: String
  var browser: BrowserModel? = nil
  var expanded = false
  @ObservedObject private var sites = SiteBook.shared
  @ObservedObject private var goals = TodoBook.shared
  @Environment(\.palette) private var p
  var body: some View {
    if let site = sites.find(id) {
      VStack(alignment: .leading, spacing: 12) {
        if let goalID = site.goalID { GoalTrackerCard(id: goalID, compact: !expanded, browser: browser ?? RelayOrchestrator.shared?.browser) }
        else if let spec = site.dashboard { DashboardCard(spec: spec, updated: site.updatedAt, open: true) }
        else if let raw = site.url, let url = SavedSite.safeURL(raw) {
          VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "globe").font(.system(size: 30, weight: .light)).foregroundStyle(p.accent)
            Text(site.title).font(UIStyle.font(20, weight: .medium))
            Text(url.host ?? "Website").font(UIStyle.meta).foregroundStyle(p.secondary)
            Link("Open website ↗", destination: url).font(UIStyle.font(14))
            Text("Saved link · contents have not been refreshed here.").font(UIStyle.font(11)).foregroundStyle(p.faint)
          }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(p.card, in: RoundedRectangle(cornerRadius: 16))
        }
        if !expanded, site.goalID == nil {
          Button("Open page") {
            if let browser = browser ?? RelayOrchestrator.shared?.browser { SiteNavigation.shared.open(id, browser: browser) }
          }.buttonStyle(QuietButton())
        }
      }
    } else { Text("This site is no longer saved.").font(UIStyle.meta).foregroundStyle(p.secondary) }
  }
}
