import SwiftUI

/// Every assistant at work, as a column of cards under one summary line. A click on an assistant
/// opens the helpers it started, to its right, joined to it by lines; the other assistants dim.
struct AgentFleet: View {
  struct Agent: Identifiable, Equatable {
    enum Status { case working, needsYou, done }
    let id: String
    let name: String
    /// The AI app that runs it ("Claude Code"), which finds its logo.
    var app = ""
    let task: String
    let state: Status
    /// Free words under the task, such as the time it has run.
    var detail = ""
    var helpers: [Agent] = []
  }
  let agents: [Agent]
  /// Called with the id of an assistant or helper that waits for an answer.
  var answer: (String) -> Void = { _ in }
  @State private var picked: String?
  /// The picked assistant while it is still listed with helpers. One that left or lost its helpers
  /// counts as closed, so the others do not stay dimmed behind a card nobody can click.
  private var open: String? { agents.first { $0.id == picked && !$0.helpers.isEmpty }?.id }
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduce
  // Fixed heights: the joining lines are drawn from them, with no measuring pass.
  private let cardHeight: CGFloat = 88
  private let helperHeight: CGFloat = 68
  private let gap: CGFloat = 8
  private let gutter: CGFloat = 36
  private let inset: CGFloat = 12

  var body: some View {
    let everyone: [Agent] = agents + agents.flatMap(\.helpers)
    let helpers = agents.reduce(0) { $0 + $1.helpers.count }
    let working = everyone.filter { $0.state == .working }.count
    let waiting = everyone.filter { $0.state == .needsYou }.count
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        Text("At work").font(AssistantType.name).foregroundStyle(p.ink)
        Text("\(agents.count) \(agents.count == 1 ? "assistant" : "assistants") · \(helpers) \(helpers == 1 ? "helper" : "helpers") · \(working) working")
          .font(AssistantType.meta).foregroundStyle(p.secondary)
        if waiting > 0 {
          Text("· \(waiting) \(waiting == 1 ? "needs" : "need") you").font(AssistantType.meta).foregroundStyle(p.warning)
        }
      }
      HStack(alignment: .top, spacing: 0) {
        VStack(spacing: gap) {
          ForEach(agents) { agent in
            Button { withAnimation(Motion.entering(reduce)) { picked = open == agent.id ? nil : agent.id } } label: {
              card(agent, height: cardHeight, selected: open == agent.id, answerOutside: true)
            }.buttonStyle(.pressable).disabled(agent.helpers.isEmpty)
              // A button inside a button's label takes no clicks, so Answer sits over the card.
              .overlay(alignment: .topTrailing) {
                if agent.state == .needsYou { answerButton(agent).padding(inset) }
              }
              .opacity(open == nil || open == agent.id ? 1 : 0.5)
              .accessibilityLabel("\(agent.name), \(label(agent.state))")
              .accessibilityHint(agent.helpers.isEmpty ? "" : open == agent.id ? "Hides its helpers" : "Shows its helpers")
          }
        }.frame(width: 260)
        if let index = agents.firstIndex(where: { $0.id == open }) {
          let shown = agents[index].helpers
          Joins(from: CGFloat(index) * (cardHeight + gap) + cardHeight / 2,
            to: shown.indices.map { CGFloat($0) * (helperHeight + gap) + helperHeight / 2 })
            .stroke(p.borderStrong, lineWidth: 1).frame(width: gutter)
            .frame(height: max(CGFloat(agents.count) * (cardHeight + gap), CGFloat(shown.count) * (helperHeight + gap)))
            .transition(.opacity).accessibilityHidden(true)
          VStack(spacing: gap) {
            ForEach(shown) { helper in card(helper, height: helperHeight, selected: false, answerOutside: false) }
          }.frame(width: 240).transition(Motion.arrival(reduce)).id(open)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private func answerButton(_ agent: Agent) -> some View {
    Button("Answer") { answer(agent.id) }.buttonStyle(PillButton(kind: .tinted, small: true))
      .accessibilityLabel("Answer \(agent.name)")
  }

  private func card(_ agent: Agent, height: CGFloat, selected: Bool, answerOutside: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: UIStyle.rowRadius + 4, style: .continuous)
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        if !agent.app.isEmpty { BrandLogo(Brand.aiApp(agent.app), size: 14, name: agent.app) }
        Text(agent.name).font(AssistantType.name).foregroundStyle(p.ink).lineLimit(1)
        Spacer(minLength: 4)
        if agent.state == .needsYou {
          // Keeps the row's height and the name's room when the real button is drawn over the card.
          answerButton(agent).opacity(answerOutside ? 0 : 1).allowsHitTesting(!answerOutside)
            .accessibilityHidden(answerOutside)
        } else {
          HStack(spacing: 5) {
            if agent.state == .working { ActivityRing(active: true) }
            Text(label(agent.state)).font(AssistantType.meta).foregroundStyle(agent.state == .done ? p.success : p.secondary)
          }
        }
      }.frame(height: 24)
      Text(agent.task).font(AssistantType.body).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
      if height > 70 {
        Text(summary(agent)).font(AssistantType.figures).foregroundStyle(p.faint).lineLimit(1)
      }
    }
    .padding(inset).frame(maxWidth: .infinity, alignment: .leading).frame(height: height, alignment: .top)
    .background(p.overlay, in: shape)
    .overlay(shape.strokeBorder(selected ? p.accent : p.line, lineWidth: 1))
    .contentShape(shape).help(agent.task)
  }

  private func label(_ state: Agent.Status) -> String {
    switch state {
    case .working: return "Working"
    case .needsYou: return "Needs you"
    case .done: return "Done"
    }
  }

  /// "2/4 working · 12m": the helpers still at work, then the assistant's own detail.
  private func summary(_ agent: Agent) -> String {
    let working = agent.helpers.filter { $0.state == .working }.count
    let parts = [agent.helpers.isEmpty ? "" : "\(working)/\(agent.helpers.count) working", agent.detail]
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

/// One curve from the open assistant's middle to each helper's middle, across the gutter.
private struct Joins: Shape {
  let from: CGFloat
  let to: [CGFloat]
  func path(in rect: CGRect) -> Path {
    var path = Path()
    for y in to {
      path.move(to: CGPoint(x: 0, y: from))
      path.addCurve(to: CGPoint(x: rect.width, y: y),
        control1: CGPoint(x: rect.width * 0.6, y: from), control2: CGPoint(x: rect.width * 0.4, y: y))
    }
    return path
  }
}
