import SereinCore
import SwiftUI

/// A message bubble, as Grok draws it: an 18-point continuous rounded rectangle whose bottom
/// corner on the sender's side tightens to 6 on the last message of a run.
struct MessageBubbleShape: Shape {
  enum Tail { case none, leading, trailing }
  var radius: CGFloat = AssistantMetrics.bubbleRadius
  var tail: Tail = .none
  func path(in rect: CGRect) -> Path {
    let r = min(radius, min(rect.width, rect.height) / 2)
    let tight = min(6, r)
    return UnevenRoundedRectangle(
      topLeadingRadius: r, bottomLeadingRadius: tail == .leading ? tight : r,
      bottomTrailingRadius: tail == .trailing ? tight : r, topTrailingRadius: r, style: .continuous
    ).path(in: rect)
  }
}

extension SereinReplyBubble where Accessory == EmptyView {
  init(text: String, tail: Bool = true, @ViewBuilder content: () -> Content) {
    self.init(text: text, tail: tail, content: content, accessory: { EmptyView() })
  }
}

/// Serein's words in its chat: a soft bubble with a tail on the last of a run, as a message from a
/// contact. A short one-paragraph message hugs its words; a longer one takes up to the reply width.
struct SereinReplyBubble<Content: View, Accessory: View>: View {
  let text: String
  var tail = true
  @ViewBuilder var content: Content
  /// Drawn just after the bubble, on its last line: the reply's Copy and Read aloud.
  @ViewBuilder var accessory: Accessory
  @Environment(\.palette) private var p
  /// The accessory's width. The row keeps that much room past the bubble, so Reply and ⋯ stay
  /// inside the message's hover area (`MessageHoverControls`) and take the pointer.
  @State private var accessoryWidth: CGFloat = 0
  var body: some View {
    HStack(spacing: 0) {
      Group {
        if Self.hugs(text) {
          // The unwrapped width is measured only for short words, where it costs little.
          ViewThatFits(in: .horizontal) {
            bubble(content.fixedSize(horizontal: true, vertical: false))
            bubble(content)
          }
        } else {
          bubble(content)
        }
      }
      // Hung just past the bubble's own edge, not the reply width's, so it stays by short words.
      .overlay(alignment: .bottomTrailing) {
        accessory.alignmentGuide(.trailing) { $0[.leading] - 6 }
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { accessoryWidth = $0 }
      }
      .frame(maxWidth: AssistantMetrics.replyMax, alignment: .leading)
      Spacer(minLength: max(40, accessoryWidth + 6))
    }
  }
  static func hugs(_ text: String) -> Bool { text.count <= 160 && !text.contains("\n") && !text.contains("`") }
  private func bubble(_ words: some View) -> some View {
    words
      .padding(.horizontal, 12).padding(.vertical, 7)
      .background(p.assistantBubble, in: MessageBubbleShape(tail: tail ? .leading : .none))
      .modifier(ChatBubbleHover())
  }
}

extension Palette {
  /// An `ask_user` form waiting for its answers: the accent as a wash behind its controls. Messages
  /// keep one color whether or not they end in a question.
  var questionWash: Color { accent.opacity(isDark ? 0.2 : 0.12) }
}

/// A reply's pieces (`ChatBubbles`), each drawn by `row`, which is told whether it is the last.
struct ReplyPieces<Row: View>: View {
  let text: String
  var spacing: CGFloat = AssistantMetrics.bubbleGap
  @ViewBuilder var row: (ChatBubbles.Piece, Bool) -> Row
  var body: some View {
    let pieces: [ChatBubbles.Piece] = messageCachedBubbles(text)
    VStack(alignment: .leading, spacing: spacing) {
      ForEach(pieces) { piece in row(piece, piece.id == pieces.last?.id) }
    }
  }
}

/// The newest reply, at the paced reveal's speed while it streams in and until its last words
/// show after the turn ends. A new bubble starts when its words do.
struct PacedReplyPieces<Row: View>: View {
  let text: String
  let streaming: Bool
  var spacing: CGFloat = AssistantMetrics.bubbleGap
  @ViewBuilder var row: (ChatBubbles.Piece, Bool) -> Row
  @StateObject private var model: PacedTextModel
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  init(text: String, streaming: Bool, spacing: CGFloat = AssistantMetrics.bubbleGap,
       @ViewBuilder row: @escaping (ChatBubbles.Piece, Bool) -> Row) {
    self.text = text
    self.streaming = streaming
    self.spacing = spacing
    self.row = row
    // A reply that has only begun is paced from its first word; one that is long already (the
    // chat opened mid-reply) starts whole and paces only what comes next.
    let live: Bool = streaming && text.count < 80
    _model = StateObject(wrappedValue: PacedTextModel(text: text, live: live))
  }
  private var reduce: Bool { systemReduceMotion || previewReducedEffects }
  var body: some View {
    // A tag half written is hidden only while more words are to come.
    let partial: Bool = streaming || model.shown.count < text.count
    ReplyPieces(text: partial ? ChatBubbles.withoutPartialTag(model.shown) : model.shown, spacing: spacing, row: row)
      .onAppear { model.update(text: text, streaming: streaming, reduce: reduce) }
      .onChange(of: text) { _, now in model.update(text: now, streaming: streaming, reduce: reduce) }
      .onChange(of: streaming) { _, now in model.update(text: text, streaming: now, reduce: reduce) }
      .onDisappear { model.stop() }
  }
}

/// Over a bubble that answers one message of a burst: that message's first line, by an accent bar.
struct ReplyQuote: View {
  let text: String
  @Environment(\.palette) private var p
  var body: some View {
    let first: String = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    HStack(spacing: 6) {
      Capsule().fill(p.accent).frame(width: 2).accessibilityHidden(true)
      Text(verbatim: String(first.prefix(70))).font(AssistantType.meta).foregroundStyle(p.secondary)
        .lineLimit(1).truncationMode(.tail)
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Replying to: \(first)")
  }
}

/// Under the person's newest message: Sent, then Seen once the AI app has started answering; Not
/// sent when the turn could not start.
struct PersonStatusLine: View {
  let status: ChatReading.PersonStatus
  @Environment(\.palette) private var p
  var body: some View {
    let words: String = status == .notSent ? HeldMessage.staleChip : status == .seen ? "Seen" : "Sent"
    let spoken: String = status == .notSent ? "Message not sent" : status == .seen ? "Message seen" : "Message sent, not seen yet"
    Text(words).font(AssistantType.meta).foregroundStyle(p.secondary).padding(.trailing, 4).accessibilityLabel(spoken)
  }
}

/// A chat's time line: before its first message, then after a pause (`MessageTimeline`).
struct MessageTimeLine: View {
  let at: Date
  @Environment(\.palette) private var p
  var body: some View {
    Text(MessageTimeline.label(at))
      .font(UIStyle.font(12)).tracking(0.12).foregroundStyle(p.secondary)
      .frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, 6)
      .accessibilityLabel("Messages from " + at.formatted(date: .complete, time: .shortened))
  }
}

/// Above a message in a task's or a past chat's transcript, as Serein's own chat spaces it: the
/// room before a new turn (`ChatTurns`), then the time when the chat picks up after a pause.
/// Its parent stack's spacing is `AssistantMetrics.turnInnerGap`.
struct TurnLead: View {
  let message: AgentMessage
  /// When the message drawn before this one was sent; nil for the first.
  let before: Date?
  let breaks: Set<String>
  init(message: AgentMessage, after: AgentMessage?, breaks: Set<String>) {
    self.init(message: message, before: after.flatMap(ChatTurns.endTime(of:)), breaks: breaks)
  }
  init(message: AgentMessage, before: Date?, breaks: Set<String>) {
    self.message = message
    self.before = before
    self.breaks = breaks
  }
  var body: some View {
    if breaks.contains(message.id) {
      Color.clear.frame(height: AssistantMetrics.turnGap - 2 * AssistantMetrics.turnInnerGap).accessibilityHidden(true)
    }
    if MessageTimeline.startsGroup(ChatTurns.time(of: message), after: before), let at = ChatTurns.time(of: message) {
      MessageTimeLine(at: at)
    }
  }
}

/// Above the first reply the person has not read yet.
struct UnreadLine: View {
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: 10) {
      Rectangle().fill(p.accent.opacity(0.4)).frame(height: 1)
      Text("Unread").font(AssistantType.meta).foregroundStyle(p.accent)
      Rectangle().fill(p.accent.opacity(0.4)).frame(height: 1)
    }
    .accessibilityElement(children: .ignore).accessibilityLabel("Unread messages start here")
  }
}

/// Under the Unread line when the person comes back after Serein worked: how long they were away,
/// then what needs them, what did not finish and what is done (`AwaySummary`). Each line opens its
/// item, as in the Tasks tab; this chat's own waiting cards go to the card. Got it folds it back
/// to the line. Nothing to say draws nothing, so the line stands alone.
@MainActor struct AwaySummaryCard: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject private var sessions = SereinSessions.shared
  /// Since and back are read once, as the card first shows: a later trip away is a later card.
  @State private var since: Date?
  @State private var back = Date()
  @State private var folded = false
  let goToCard: ((UUID) -> Void)?
  @Environment(\.palette) private var p
  init(relay: RelayOrchestrator, firstUnreadAt: Date?, goToCard: ((UUID) -> Void)?) {
    self.relay = relay
    self.goToCard = goToCard
    // After a launch Serein has not seen the person leave: the first unread reply stands in.
    _since = State(initialValue: RelayController.leftAt ?? firstUnreadAt)
  }
  var body: some View {
    let groups: [AwaySummary.Group] = AwaySummary.groups(sessions.entries, since: since)
    let asks: [RelayOrchestrator.Approval] = goToCard == nil ? [] : relay.approvals.filter { $0.threadID == relay.threadID }
    if !folded, !groups.isEmpty || !asks.isEmpty { card(groups, asks: asks) }
  }
  private func card(_ groups: [AwaySummary.Group], asks: [RelayOrchestrator.Approval]) -> some View {
    let away: String? = since.flatMap { AwaySummary.awayWords(from: $0, to: back) }
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("While you were away").font(UIStyle.metaStrong).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
        if let away { Text(verbatim: away).font(UIStyle.meta).foregroundStyle(p.secondary) }
        Spacer(minLength: 8)
        Button { folded = true } label: {
          Text("Got it").font(UIStyle.metaStrong).foregroundStyle(p.accent)
        }.buttonStyle(QuietButton()).fixedSize().help("Fold this summary")
      }.padding(.horizontal, 8)
      if !asks.isEmpty, let goToCard {
        section(AwaySummary.Kind.needsYou.title) {
          ForEach(asks) { ask in
            Button { goToCard(ask.id) } label: {
              HStack(spacing: 10) {
                Circle().strokeBorder(p.warning, lineWidth: 3.5).opacity(0.9).frame(width: 15, height: 15)
                  .frame(width: 18, height: 18).accessibilityHidden(true)
                Text(verbatim: ask.title).font(UIStyle.font(13, weight: .medium)).foregroundStyle(p.ink)
                  .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text("Go to card").font(UIStyle.meta).foregroundStyle(p.secondary)
              }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }.buttonStyle(InspectorRowStyle())
              .help(ask.title)
              .accessibilityLabel("Needs you: \(ask.title)").accessibilityHint("Shows this card in the chat")
          }
        }
      }
      ForEach(groups, id: \.kind) { group in
        // Asks above already head Needs you; the tasks that need the person join them under it.
        section(group.kind == .needsYou && !asks.isEmpty ? nil : group.kind.title) {
          InspectorShowMore(items: group.entries) { entry in
            InspectorTaskRow(entry: entry, session: ExternalSessionStore.shared.sessions.first { $0.id == entry.sourceID },
                             agent: relay.agent)
          }
        }
      }
    }
    .padding(.vertical, 16).padding(.horizontal, 8)
    .frame(maxWidth: AssistantMetrics.replyMax, alignment: .leading)
    .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("While you were away" + (away.map { ", " + $0 } ?? ""))
  }
  private func section<Rows: View>(_ title: String?, @ViewBuilder rows: () -> Rows) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if let title {
        Text(title).font(UIStyle.micro).foregroundStyle(p.secondary).padding(.horizontal, 8).accessibilityAddTraits(.isHeader)
      }
      rows()
    }
  }
}
