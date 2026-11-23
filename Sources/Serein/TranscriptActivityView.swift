import SereinCore
import SwiftUI

/// The turn's recorded actions folded into Grok's "N steps" pill; open, a hairline timeline with a
/// 6-point dot per step (`success` done, `danger` failed).
struct TranscriptActivityView: View {
  let activities: [TranscriptActivity]
  @State private var expanded = false
  @State private var hovered = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { expanded.toggle() } label: {
        HStack(spacing: 4) {
          Text(verbatim: "\(activities.count) \(activities.count == 1 ? "step" : "steps")")
          InterfaceIcon(systemName: "chevron.down", size: 10).opacity(0.66)
            .rotationEffect(.degrees(expanded ? 180 : 0))
        }.font(UIStyle.font(12)).tracking(0.12).foregroundStyle(hovered ? p.secondary : p.faint)
          .padding(.horizontal, 8).padding(.vertical, 2)
          .background(Capsule().fill(p.hover).opacity(hovered ? 1 : 0))
          .contentShape(Capsule())
      }.buttonStyle(.pressable).padding(.leading, 4)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.16), value: expanded)
        .accessibilityLabel(TranscriptActivity.summary(activities))
        .accessibilityValue("\(activities.count) actions, \(expanded ? "expanded" : "collapsed")")
        .help(expanded ? "Hide actions" : "Show recorded actions")
      if expanded {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(activities.enumerated()), id: \.offset) { _, action in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(verbatim: action.label).font(UIStyle.font(13)).tracking(0.195).lineSpacing(2.5).foregroundStyle(p.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
              if action.failed { Text("Failed").font(UIStyle.font(12)).foregroundStyle(p.faint) }
            }
            // Centred on the rail, its foot a point above the first line's baseline.
            .overlay(alignment: .topLeading) {
              Circle().fill(action.failed ? p.danger : p.success).frame(width: 6, height: 6)
                .background(Circle().fill(p.background).padding(-2))
                .offset(x: -12, y: 5.5).accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
          }
        }
        .padding(.leading, 9.5)
        .overlay(alignment: .leading) { Rectangle().fill(p.hairline).frame(width: 1) }
        .padding(.leading, 12).padding(.top, 7).padding(.bottom, 5)
      }
    }.padding(.vertical, -4).frame(maxWidth: .infinity, alignment: .leading)
  }
}
