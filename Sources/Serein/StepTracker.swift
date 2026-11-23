import SwiftUI

/// Displays progress through the task steps.
struct StepTracker: View {
  struct Step: Identifiable, Equatable {
    let id: String
    let title: String
    let done: Bool
  }
  let title: String
  let steps: [Step]
  let toggle: (String) -> Void
  @State private var shown = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduce
  private var count: Int { steps.filter(\.done).count }
  /// Slower than a control's response on purpose: the bar reports progress, and a quick jump hides it.
  private var settle: Animation { reduce ? Motion.reduced : .timingCurve(0.22, 1, 0.36, 1, duration: 0.6) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(UIStyle.bodyStrong).foregroundStyle(p.ink)
        Spacer()
        (Text("\(count)").foregroundStyle(p.ink) + Text("/\(steps.count)")).font(UIStyle.font(12)).monospacedDigit()
          .foregroundStyle(p.secondary).contentTransition(.numericText(value: Double(count))).animation(settle, value: count)
          .accessibilityHidden(true)
      }
      Capsule().fill(p.track).frame(height: 6)
        .overlay(alignment: .leading) {
          GeometryReader { bar in
            Capsule().fill(p.accent)
              .frame(width: steps.isEmpty ? 0 : bar.size.width * CGFloat(count) / CGFloat(steps.count))
              .animation(settle, value: count)
          }
        }
        .accessibilityElement().accessibilityLabel(title).accessibilityValue("\(count) of \(steps.count) done")
      VStack(spacing: 2) {
        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
          Button { toggle(step.id) } label: { StepRow(step: step) }
            .buttonStyle(.pressable)
            .accessibilityLabel(step.title).accessibilityValue(step.done ? "Done" : "Not done")
            .accessibilityHint(step.done ? "Marks this step as not done" : "Marks this step as done")
            .opacity(shown ? 1 : 0).offset(y: shown || reduce ? 0 : Motion.rise)
            .animation(Motion.entering(reduce).delay(reduce ? 0 : 0.05 * Double(min(index, 8))), value: shown)
        }
      }
    }.onAppear { shown = true }
  }
}

private struct StepRow: View {
  let step: StepTracker.Step
  @State private var hovered = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduce
  var body: some View {
    let draw: Animation = reduce ? Motion.reduced : .timingCurve(0.22, 1, 0.36, 1, duration: 0.3)
    HStack(spacing: 10) {
      ZStack {
        Circle().fill(step.done ? p.accent : .clear)
        Circle().strokeBorder(step.done ? p.accent : p.borderStrong, lineWidth: 1.5)
        Tick().trim(from: 0, to: step.done ? 1 : 0)
          .stroke(p.onAccent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
          .animation(step.done ? draw.delay(reduce ? 0 : 0.1) : Motion.leaving(reduce), value: step.done)
      }.frame(width: 18, height: 18)
        .scaleEffect(step.done && !reduce ? 1 : 0.94).animation(Motion.popping(reduce), value: step.done)
      Text(step.title).font(UIStyle.font(14)).lineLimit(1).truncationMode(.tail)
        .foregroundStyle(step.done ? p.secondary : p.ink)
        .overlay(alignment: .leading) {
          Rectangle().fill(p.secondary).frame(height: 1).scaleEffect(x: step.done ? 1 : 0, anchor: .leading)
            .animation(step.done ? draw.delay(reduce ? 0 : 0.14) : Motion.leaving(reduce), value: step.done)
        }
        .animation(Motion.swapping(reduce), value: step.done)
      Spacer(minLength: 0)
    }.padding(.vertical, 6).padding(.horizontal, 6)
      .background(hovered ? p.hover : .clear, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
      .contentShape(Rectangle()).onHover { hovered = $0 }.help(step.title)
  }
}

private struct Tick: Shape {
  func path(in rect: CGRect) -> Path {
    let unit = rect.width / 24
    var path = Path()
    path.move(to: CGPoint(x: 6.5 * unit, y: 12.5 * unit))
    path.addLine(to: CGPoint(x: 10 * unit, y: 16 * unit))
    path.addLine(to: CGPoint(x: 17.5 * unit, y: 8 * unit))
    return path
  }
}
