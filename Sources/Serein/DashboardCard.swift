import SereinCore
import SwiftUI

/// A dashboard in the chat (SPEC.md 2.9, the dashboard board): closed, one row with the grid
/// tile, the title in medium, the one-line summary (`DashboardSummary.line`) and a chevron; a
/// click opens it in place (height and fade together in 0.16 s, the one height that animates;
/// at once under Reduce Motion) to the stat (`card-stat`: its label, the value in the title size
/// and the trend pill), the rows (`table-mini`: label in `meta`, value in Geist Mono), when it was
/// updated, and up to three chips that ask a follow-up. A second click closes it. Every word in
/// it can come from pages or mail, so it is drawn as plain text; an invalid spec draws nothing.
struct DashboardCard: View {
  let spec: DashboardSpec
  /// When it was last updated; nil hides the line.
  var updated: Date? = nil
  /// The follow-ups its chips ask ("Show the hotels").
  var chips: [String] = []
  var ask: ((String) -> Void)? = nil
  /// The same dashboard further down the chat starts closed.
  @State private var open: Bool
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects

  init(spec: DashboardSpec, updated: Date? = nil, chips: [String] = [], ask: ((String) -> Void)? = nil, open: Bool = false) {
    self.spec = spec
    self.updated = updated
    self.chips = chips
    self.ask = ask
    _open = State(initialValue: open)
  }
  private var reduce: Bool { systemReduceMotion || previewReducedEffects }
  private var summary: String { DashboardSummary.line(spec) }

  var body: some View {
    if spec.isValid {
      VStack(alignment: .leading, spacing: 0) {
        header
        if open {
          Rectangle().fill(p.line).frame(height: UIStyle.hairline)
          content.transition(reduce ? AnyTransition.identity : AnyTransition.opacity)
        }
      }
      .frame(maxWidth: AssistantMetrics.cardWide, alignment: .leading)
      .clipShape(RoundedRectangle(cornerRadius: AssistantMetrics.cardRadius, style: .continuous))
      .assistantCard(p)
      .pressGuard(spec.title)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("\(spec.title), \(summary), \(open ? "expanded" : "collapsed")")
    }
  }

  private var header: some View {
    Button {
      if reduce { open.toggle() } else { withAnimation(Motion.enter) { open.toggle() } }
    } label: {
      HStack(spacing: 10) {
        InterfaceIcon(systemName: "square.grid.2x2", size: 14).foregroundStyle(p.accent)
          .frame(width: 28, height: 28)
          .background(p.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(verbatim: spec.title).font(AssistantType.name).foregroundStyle(p.ink).lineLimit(1)
          Text(verbatim: summary).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
        }.frame(maxWidth: .infinity, alignment: .leading)
        InterfaceIcon(systemName: "chevron.down", size: 12).foregroundStyle(p.secondary)
          .rotationEffect(.degrees(open ? 180 : 0))
          .frame(width: 24, height: 24)
          .accessibilityHidden(true)
      }
      .padding(.vertical, 12).padding(.horizontal, 14)
      .contentShape(Rectangle())
    }
    .buttonStyle(.pressable)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint(open ? "Closes it" : "Opens it")
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        stat.frame(maxWidth: .infinity, alignment: .leading)
        if !spec.rows.isEmpty { rows.frame(maxWidth: .infinity, alignment: .leading) }
      }
      if let updated {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          Text(DashboardSummary.updated(updated, now: context.date, calendar: .current))
            .font(AssistantType.meta).foregroundStyle(p.faint)
        }
      }
      if let ask, !chips.isEmpty {
        QuickReplyChips(chips: Array(chips.prefix(3)), send: ask)
      }
    }
    .padding(14)
  }

  private var stat: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Text(verbatim: spec.stat.label).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
        Spacer(minLength: 4)
        if let trend = spec.stat.trend { trendPill(trend) }
      }
      Text(verbatim: spec.stat.value).font(AssistantType.title).foregroundStyle(p.ink).lineLimit(1)
        .contentTransition(.opacity)
    }
  }
  private func trendPill(_ trend: DashboardSpec.Trend) -> some View {
    let tone: Color
    let arrow: String
    switch trend.direction {
    case .up:
      tone = p.success
      arrow = "arrow.up.right"
    case .down:
      tone = p.danger
      arrow = "arrow.down.right"
    case .flat:
      tone = p.secondary
      arrow = "arrow.right"
    }
    return HStack(spacing: 2) {
      Image(systemName: arrow).font(.system(size: 9, weight: .semibold))
      Text(verbatim: trend.text).font(AssistantType.meta)
    }
    .foregroundStyle(tone)
    .padding(.vertical, 3).padding(.horizontal, 7)
    .background(tone.opacity(0.12), in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(trend.text)
  }
  private var rows: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(spec.rows.prefix(DashboardSpec.maxRows).enumerated()), id: \.offset) { index, row in
        if index > 0 { Rectangle().fill(p.line).frame(height: UIStyle.hairline) }
        HStack {
          Text(verbatim: row.label).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
          Spacer(minLength: 8)
          Text(verbatim: row.value).font(AssistantType.figures).foregroundStyle(p.ink).lineLimit(1)
            .contentTransition(.opacity)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.label), \(row.value)")
      }
    }
  }
}
