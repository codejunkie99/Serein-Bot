import SereinCore
import SwiftUI

/// Activity (Window › Activity, “See All in Activity” under the Working strip's “+N”): every task
/// on one day from `sessions/runs.jsonl`, grouped by project, in History’s Activity segment.
struct TodayView: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  var embedded = false
  @State private var expanded: Set<String> = []
  @State private var day = Date()
  @State private var records: [RunRecord] = []
  @Environment(\.palette) var p
  var live: Set<String> { Set(hub.active.map(\.id)) }
  var groups: [RunGroup] { RunDay.group(records) }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Group {
        if embedded {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
              Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(UIStyle.metaStrong)
              Text(summaryLine).role(.meta)
            }
            Spacer()
            dayControls
          }
        } else {
          PageHeader(Calendar.current.isDateInToday(day) ? "Activity" : day.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                     subtitle: summaryLine) { dayControls }
        }
      }
      if records.isEmpty {
        Text(Calendar.current.isDateInToday(day)
          ? "Nothing yet today. What Serein and its tasks do shows up here, with how each one ended."
          : "No tasks on this day.")
          .role(.meta).padding(.top, 8)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 8) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProjectProgressGlyph(runs: group.runs.map { $0.effectiveOutcome(live: live) })
                Text(group.name).role(.section)
                Text("\(group.runs.count)").font(UIStyle.microMono).foregroundStyle(p.faint)
              }.padding(.bottom, 4).accessibilityElement(children: .combine)
              ForEach(group.runs) { record in row(record) }
            }.padding(16).card(p)
          }
        }.padding(.bottom, 40)
      }
    }.pageColumn()
      .onAppear(perform: load)
      .onChange(of: day) { _, _ in load() }
      .onChange(of: hub.revision) { _, _ in load() }
  }
  var dayControls: some View {
    HStack(spacing: 2) {
        Button { shift(-1) } label: { InterfaceIcon(systemName: "chevron.left", size: 14) }
          .buttonStyle(QuietButton()).help("Previous day").accessibilityLabel("Previous day")
        Button("Today") { day = Date() }.buttonStyle(QuietButton())
          .disabled(Calendar.current.isDateInToday(day))
        Button { shift(1) } label: { InterfaceIcon(systemName: "chevron.right", size: 14) }
          .buttonStyle(QuietButton()).disabled(Calendar.current.isDateInToday(day))
          .help("Next day").accessibilityLabel("Next day")
    }
  }
  var summaryLine: String {
    let outcomes = records.map { $0.effectiveOutcome(live: live) }
    let done = outcomes.filter { $0 == .done }.count
    let waiting = outcomes.filter { $0 == .waiting }.count
    let failed = outcomes.filter { $0 == .stuck }.count
    var parts = ["\(records.count) task\(records.count == 1 ? "" : "s")"]
    if done > 0 { parts.append("\(done) done") }
    if waiting > 0 { parts.append("\(waiting) waiting for you") }
    if failed > 0 { parts.append("\(failed) could not finish") }
    return "What your agents did · " + parts.joined(separator: ", ")
  }
  func row(_ record: RunRecord) -> some View {
    let outcome = record.effectiveOutcome(live: live)
    let known = agent.openThreadItem(record.threadID) != nil
    let open = expanded.contains(record.id)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 8) {
        Button { SereinRouter.open(threadID: record.threadID) } label: {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            RunGlyph(outcome: outcome)
            VStack(alignment: .leading, spacing: 3) {
              Text(record.title).font(UIStyle.body).lineLimit(1).foregroundStyle(p.ink)
              if let summary = record.summary, !summary.isEmpty { Text(summary).role(.meta).lineLimit(2) }
              Text(detail(record, outcome: outcome)).role(.micro).lineLimit(1)
              if let meter = record.context { ContextMeterLine(meter: meter) }
            }
            Spacer(minLength: 0)
          }.padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.pressable).disabled(!known)
          .help(known ? "Open chat" : "This chat was deleted")
        Button {
          if open { expanded.remove(record.id) } else { expanded.insert(record.id) }
        } label: {
          InterfaceIcon(systemName: open ? "chevron.down" : "chevron.right", size: 10)
            .foregroundStyle(p.secondary).frame(width: 24, height: 28).contentShape(Rectangle())
        }.buttonStyle(.pressable).help(open ? "Hide details" : "Show details")
          .accessibilityLabel("Details for " + record.title).accessibilityValue(open ? "Expanded" : "Collapsed")
      }
      if open {
        VStack(alignment: .leading, spacing: 4) {
          Text("AI app: " + record.provider)
          if !record.model.isEmpty { Text("Model: " + record.model) }
          if !record.effort.isEmpty { Text("Reasoning: " + record.effort) }
        }.font(UIStyle.monoMeta).foregroundStyle(p.secondary).textSelection(.enabled)
          .padding(.leading, 24).padding(.bottom, 8)
      }
    }
  }
  func detail(_ r: RunRecord, outcome: RunRecord.Outcome) -> String {
    let time = r.startedAt.formatted(date: .omitted, time: .shortened)
    let length = AgentTabStatus.duration((r.endedAt ?? r.lastEventAt).timeIntervalSince(r.startedAt))
    let status = outcome == .stopped && r.outcome == .running ? "Interrupted" : nil
    return ([time, length, "\(r.toolCount) step\(r.toolCount == 1 ? "" : "s")"]
      + (status.map { [$0] } ?? [])).joined(separator: " · ")
  }
  /// Serein's own replies are not tasks: only the tasks themselves are listed.
  func load() { records = browser.library.runs(on: day).filter { !agent.isSereinChatID($0.threadID) } }
  func shift(_ amount: Int) {
    day = Calendar.current.date(byAdding: .day, value: amount, to: day) ?? day
  }
}

/// How far a project's runs for the day have got: a ring that fills with finished runs,
/// accent while any run is still working. Shape and count, never color alone.
private struct ProjectProgressGlyph: View {
  var runs: [RunRecord.Outcome]
  @Environment(\.palette) var p
  var finished: Int { runs.filter { $0 != .running }.count }
  var body: some View {
    let share = runs.isEmpty ? 0 : Double(finished) / Double(runs.count)
    ZStack {
      Circle().stroke(p.line, lineWidth: 2)
      Circle().trim(from: 0, to: share).stroke(
        runs.contains(.running) ? p.accent : p.secondary,
        style: StrokeStyle(lineWidth: 2, lineCap: .round)
      ).rotationEffect(.degrees(-90))
    }.frame(width: 12, height: 12)
      .accessibilityLabel("\(finished) of \(runs.count) finished")
  }
}
