import Charts
import SereinCore
import SwiftUI

struct UsageDashboard: View {
  @ObservedObject private var usage = UsageStats.shared
  @ObservedObject private var routes = RouteUsage.shared
  @AppStorage(UsageStats.enabledKey) private var enabled = true
  @Environment(\.palette) private var p
  @State private var period = 30
  @State private var confirmReset = false
  @State private var confirmClear = false
  private var rows: [LocalUsageDay] { usage.ledger.series(days: period) }
  private var summary: LocalUsageSummary { LocalUsageSummary(rows: rows) }
  private var tickDays: [String] {
    rows.enumerated().filter {
      $0.offset > 0 && $0.offset < period - 1 && ($0.offset - 1) % max(1, period / 6) == 0
    }.map { $0.element.id }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text("This Mac").font(UIStyle.meta)
          Text(usage.isPreview ? "Synthetic preview" : "Local totals since \(usage.ledger.startedAt.formatted(date: .abbreviated, time: .omitted))")
            .role(.meta)
        }
        Spacer()
        Picker("Time range", selection: $period) {
          Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
      }
      limits
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 10)], spacing: 10) {
        metric("Downloads", value: "\(summary.downloads)", detail: "Completed · \(Bytes.file(summary.downloadBytes))")
        metric("Active time", value: AgentTabStatus.duration(TimeInterval(summary.activeSeconds), compact: true), detail: "Foreground, excluding idle")
        metric("Active days", value: "\(summary.activeDays)", detail: "Of the last \(period) days")
      }
      SettingsGroup("Daily active time") {
        Chart(rows) { row in
          BarMark(x: .value("Day", row.id), y: .value("Minutes", Double(row.activeSeconds) / 60))
            .foregroundStyle(p.ink.opacity(0.8)).cornerRadius(2)
            .accessibilityLabel(row.id)
            .accessibilityValue("\(row.activeSeconds / 60) active minutes")
        }
        .chartXAxis {
          AxisMarks(values: tickDays) { value in
            AxisValueLabel { if let day = value.as(String.self) { Text(String(day.suffix(5))).font(UIStyle.micro) } }
          }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartYScale(domain: 0...max(1, Double(rows.map(\.activeSeconds).max() ?? 0) / 60))
        .frame(height: 155)
        SettingsNote("Minutes per day. Empty days have no recorded activity.")
      }
      SettingsGroup("Analysis") {
        ForEach(usage.ledger.insights(), id: \.self) { Text($0).font(UIStyle.body).foregroundStyle(p.secondary) }
        if let minutes = summary.minutesPerSession {
          Text("On average, \(minutes.formatted(.number.precision(.fractionLength(1)))) active minutes each time you use Serein in this period.")
            .font(UIStyle.body).foregroundStyle(p.secondary)
        }
      }
      models
      SettingsGroup("Local tracking", info: "Only daily time, use and download totals are saved. No URLs, file names, page content or user IDs. Private pages are excluded. Nothing is uploaded. Counts begin when tracking starts; other users and Serein app downloads are not measured here.") {
        Toggle("Record usage on this Mac", isOn: $enabled).disabled(usage.isPreview)
        SettingsNote("Only daily time, use and download totals are saved. No URLs, file names, page content or user IDs. Private pages are excluded, and nothing is uploaded.")
        HStack {
          Button("Export totals…") { usage.export() }.disabled(usage.isPreview)
          Spacer()
          Button("Reset usage…") { confirmReset = true }.disabled(usage.isPreview)
        }
        if let status = usage.status { Text(status).role(.meta) }
      }
    }
    .confirmationDialog("Reset local usage?", isPresented: $confirmReset) {
      Button("Reset usage", role: .destructive) { usage.reset() }
    } message: { Text("Deletes the recorded usage totals. Downloaded files and your history stay on your Mac.") }
    .confirmationDialog("Clear model usage?", isPresented: $confirmClear) {
      Button("Clear model usage", role: .destructive) { routes.clear() }
    } message: { Text("Every model starts again at zero. Warning levels and the reset day stay.") }
  }

  /// Every limit Serein knows, as a meter for this period (UsageMeter): each model's warn level
  /// and each schedule's weekly limit. Amber with words from four fifths, and when the pace so
  /// far passes the limit before the period ends.
  private var limits: some View {
    let now = Date()
    let meters = routes.meters + (RelayOrchestrator.shared?.reminders ?? []).compactMap { $0.meter(now: now) }
    return SettingsGroup("Limits this period", info: "A model's limit is the warning level you pick for it under Models. A schedule's is the weekly limit set on it.") {
      if meters.isEmpty {
        Text("No limits set. Pick a warning level for a model under Models.").role(.meta)
      }
      ForEach(meters) { meter in
        let warning = meter.warning(at: now)
        let tint = meter.level == .under && warning == nil ? p.secondary : p.warning
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(meter.name).lineLimit(1)
            Spacer()
            Text(meter.line).font(UIStyle.monoMeta).foregroundStyle(tint)
          }
          ProgressView(value: min(1, meter.share)).tint(meter.level == .under ? p.ink.opacity(0.8) : p.warning)
          Text(warning ?? meter.rest(at: now)).font(UIStyle.meta).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.name)
        .accessibilityValue(meter.line + ". " + (warning ?? meter.rest(at: now)))
      }
    }
  }

  /// What each model route used through Serein (RouteUsage): tokens per day, each route's
  /// period with its warn level, and when the period starts over.
  private var models: some View {
    SettingsGroup("Models", info: "Counted on this Mac when a turn Serein started ends: one call, and the tokens the AI app printed in its own output (reported by CLI), or about one token per four characters of Serein's prompt and the reply (estimate). Nothing is read from the provider's files or account, and nothing is sent. A model's cell in the model list turns amber at its warning level. Deleting usage/routes.json in Serein's library also starts over.") {
      let counted = routes.ledger.days(14).filter { $0.calls > 0 || $0.tokens > 0 }
      if counted.isEmpty {
        Text("No model turns counted yet. Serein counts each turn it starts when the turn ends.").role(.meta)
      } else {
        ForEach(counted, id: \.day) { day in
          HStack {
            Text(day.date.formatted(date: .abbreviated, time: .omitted))
            Spacer()
            Text(Self.grouped(day.tokens) + " tokens").font(UIStyle.monoMeta).foregroundStyle(p.secondary)
          }
        }
      }
      ForEach(routes.shown, id: \.self) { route in
        let name = RouteUsage.name(route)
        let summary = routes.summary(route)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(name)
            Text(routes.line(summary)).font(UIStyle.meta)
              .foregroundStyle(routes.crossed(route, summary) ? p.warning : p.secondary)
          }
          Spacer()
          SettingsPopUp("Warning level for \(name)", selection: Binding(
            get: { routes.warnings[route] ?? 0 }, set: { routes.setWarning(route, tokens: $0) }),
            choices: RouteUsage.warnLevels.map { level in
              SettingsChoice(value: level, label: level == 0 ? "No warning" : "Warn at \(UsageLedger.Summary.short(level)) tokens")
            }, showsTitle: false)
        }.accessibilityElement(children: .contain)
      }
      HStack(spacing: 12) {
        SettingsPopUp("Counts start over", selection: resetKind, choices: [
          SettingsChoice(value: "daily", label: "Every day"), SettingsChoice(value: "weekly", label: "Every week"),
          SettingsChoice(value: "monthly", label: "Every month"),
        ])
        switch routes.reset {
        case .daily: EmptyView()
        case .weekly(let weekday):
          SettingsPopUp("On", selection: Binding(get: { weekday }, set: { routes.reset = .weekly(weekday: $0) }),
            choices: Calendar.autoupdatingCurrent.weekdaySymbols.enumerated().map { SettingsChoice(value: $0.offset + 1, label: $0.element) })
        case .monthly(let day):
          SettingsPopUp("On day", selection: Binding(get: { day }, set: { routes.reset = .monthly(day: $0) }),
            choices: (1...28).map { SettingsChoice(value: $0, label: "\($0)") })
        }
      }
      SettingsNote("Counted on this Mac from what your AI app reports, or estimated from the text. Nothing is read from the provider's files or account, and nothing is sent.")
      HStack {
        Spacer()
        Button("Clear model usage…") { confirmClear = true }.disabled(routes.ledger.entries.isEmpty)
      }
      if let status = routes.status { Text(status).role(.meta) }
    }
  }
  /// The reset period's kind; a change starts on Monday or the 1st.
  private var resetKind: Binding<String> {
    Binding(
      get: {
        switch routes.reset {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        }
      },
      set: { kind in
        guard kind != resetKind.wrappedValue else { return }
        routes.reset = kind == "weekly" ? .weekly(weekday: 2) : kind == "monthly" ? .monthly(day: 1) : .daily
      })
  }

  private func metric(_ title: String, value: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(UIStyle.meta).foregroundStyle(p.secondary)
      Text(value).font(UIStyle.font(27, weight: .medium)).foregroundStyle(p.ink)
      Text(detail).font(UIStyle.micro).foregroundStyle(p.faint).fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, minHeight: 92, alignment: .leading).padding(12)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .accessibilityElement(children: .combine)
  }

  private static func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }
}
