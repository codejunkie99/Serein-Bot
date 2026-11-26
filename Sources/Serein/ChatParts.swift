import AppKit
import QuartzCore
import SereinCore
import SwiftUI

// The parts of Serein's chat on the personal-assistant screens (Nb boards): a reply,
// another assistant's message, the centred system line, the receipt's line and card, the
// typing row, quick-reply chips, queued messages, the paced reveal of a streaming reply, and the
// moving parts that keep every wait from standing still. RelayPanel.swift puts them in order.

// MARK: - Moving parts

/// Words with a light that moves across them every 1.6 seconds, for a wait ("Waiting for
/// Gmail…", "Asking Planner…", a plan's live step). Core Animation moves the light
/// (`ShimmerBand`), only while the words show; under Reduce Motion the words stand still.
struct ShimmerText: View {
  let text: String
  var font: Font = AssistantType.meta
  /// The words' own colour; `secondary` when nil, with an `ink` light. Words already in `ink`
  /// (the plan's current step) get a `secondary` light, so the light still shows.
  var color: Color? = nil
  /// The moving light's colour, when neither default fits (Grok's activity line: `faint` to `ink`).
  var light: Color? = nil
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    let base: Color = color ?? p.secondary
    let light: Color = self.light ?? (color == nil ? p.ink : p.secondary)
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    let words = Text(verbatim: text).font(font)
    if reduce {
      words.foregroundStyle(base)
    } else {
      words.foregroundStyle(base)
        .overlay {
          ShimmerBand(color: light)
            .mask { words }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
  }
}

/// The light of a shimmer: a band 40% of the words' width (at least 24 points) that runs from
/// before their start to past their end every 1.6 seconds. Core Animation runs it, at most 30
/// frames a second, and only while its view shows (`ShownMotionView`): scrolled away, hidden or
/// covered, it holds still.
struct ShimmerBand: NSViewRepresentable {
  var color: Color
  func makeNSView(context: Context) -> BandView { BandView() }
  func updateNSView(_ view: BandView, context: Context) {
    view.color = color.resolve(in: context.environment).cgColor
  }
  final class BandView: ShownMotionView {
    private let band = CAGradientLayer()
    var color: CGColor? {
      didSet {
        guard let color, let clear = color.copy(alpha: 0) else { return }
        // Fades to the same colour, as SwiftUI's gradient from .clear does.
        instantly { band.colors = [clear, color, clear] }
      }
    }
    override init(frame: NSRect) {
      super.init(frame: frame)
      band.startPoint = CGPoint(x: 0, y: 0.5)
      band.endPoint = CGPoint(x: 1, y: 0.5)
      layer?.masksToBounds = true
      layer?.addSublayer(band)
    }
    required init?(coder: NSCoder) { nil }
    override func layOut() {
      let width: CGFloat = max(24, bounds.width * 0.4)
      instantly {
        band.contentsScale = window?.backingScaleFactor ?? 2
        band.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        // At rest the light is before the words, out of sight.
        band.position = CGPoint(x: -width / 2, y: bounds.midY)
      }
    }
    override func loop() {
      let half: CGFloat = band.bounds.width / 2
      let sweep = CABasicAnimation(keyPath: "position.x")
      sweep.fromValue = -half
      sweep.toValue = bounds.width + half
      band.loopInStep(sweep, period: Motion.shimmerDuration, forKey: "sweep")
    }
  }
}

/// A placeholder block that pulses while what it stands for loads (a skeleton row or tile): the
/// `track` block fades to 45% and back every 1.6 seconds on Core Animation (`SkeletonPulse`),
/// only while it shows; still under Reduce Motion.
struct SkeletonBar: View {
  var width: CGFloat? = nil
  var height: CGFloat = 12
  /// The block's corner; nil rounds the ends (a line of words). A photo tile's is 12.
  var radius: CGFloat? = nil
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    let corner: CGFloat = radius ?? height / 2
    Group {
      if reduce {
        RoundedRectangle(cornerRadius: corner, style: .continuous).fill(p.track)
      } else {
        SkeletonPulse(color: p.track, radius: corner)
      }
    }
    .frame(width: width, height: height)
    .accessibilityHidden(true)
  }
}

/// A skeleton's block, drawn and faded by Core Animation (see `SkeletonBar`).
struct SkeletonPulse: NSViewRepresentable {
  var color: Color
  var radius: CGFloat
  func makeNSView(context: Context) -> PulseView { PulseView() }
  func updateNSView(_ view: PulseView, context: Context) {
    view.color = color.resolve(in: context.environment).cgColor
    view.radius = radius
  }
  final class PulseView: ShownMotionView {
    private let block = CALayer()
    var color: CGColor? { didSet { instantly { block.backgroundColor = color } } }
    var radius: CGFloat = 6 { didSet { if radius != oldValue { needsLayout = true } } }
    override init(frame: NSRect) {
      super.init(frame: frame)
      layer?.addSublayer(block)
    }
    required init?(coder: NSCoder) { nil }
    override func layOut() {
      let corner: CGFloat = min(radius, min(bounds.width, bounds.height) / 2)
      instantly {
        block.frame = bounds
        block.cornerRadius = corner
        block.cornerCurve = .continuous
      }
    }
    override func loop() {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1.0
      fade.toValue = 0.45
      fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      fade.autoreverses = true
      block.loopInStep(fade, period: Motion.shimmerDuration, forKey: "pulse")
    }
  }
}

/// One busy assistant, as Grok's activity line: its 20-point face, what it is doing in the
/// shimmer ("Working on it" until a step is known), and from its first second how long the turn
/// has run ("· 12s", "· 3m", "· 1h 4m"). One row per assistant that works for this chat.
/// VoiceOver hears "{Name} is typing" once per wait, politely (`announceKey`).
struct TypingRow: View {
  let name: String
  var profile: RelayProfile? = nil
  var caption: String? = nil
  /// When the turn began; nil shows no time.
  var since: Date? = nil
  /// One wait (a turn): the announcement is said once for each key. nil says nothing.
  var announceKey: String? = nil
  /// It enters 80 ms after the wait begins, so a fast first word never flashes the line.
  @State private var shown = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    let phrase: String = caption ?? "Working on it"
    HStack(alignment: .center, spacing: 8) {
      if let profile { TeamFace(profile: profile, size: 20).accessibilityHidden(true) }
      ShimmerText(text: phrase, font: UIStyle.font(14), color: p.faint, light: p.ink)
        .tracking(0.14).lineLimit(1).truncationMode(.tail)
      if let since {
        TimelineView(.periodic(from: since, by: 1)) { context in
          let seconds = Int(context.date.timeIntervalSince(since))
          if seconds >= 1 {
            Text(verbatim: "· " + Self.elapsed(seconds)).font(UIStyle.font(14)).tracking(0.14).foregroundStyle(p.faint)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4).padding(.vertical, 2)
    .opacity(shown ? 1 : 0)
    .task {
      try? await Task.sleep(nanoseconds: 80_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(Motion.entering(reduce)) { shown = true }
      if let announceKey { ChatAnnouncement.typing(name, key: announceKey) }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(caption ?? "\(name) is typing")
    .accessibilityAddTraits(.updatesFrequently)
  }
  /// Grok's compact elapsed time: "12s", "3m", "1h 4m".
  static func elapsed(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 { return "\(s)s" }
    let m = s / 60
    return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
  }
}

/// The 2-point bar under the Undo toast that drains in the 10 seconds Undo lasts (one Core
/// Animation run from what is left, so it never restarts when the view draws again).
struct DrainingBar: NSViewRepresentable {
  var color: Color
  var ends: Date
  var total: TimeInterval
  func makeNSView(context: Context) -> DrainingBarView { DrainingBarView() }
  func updateNSView(_ view: DrainingBarView, context: Context) {
    view.color = color.resolve(in: context.environment).cgColor
    view.timing = DrainingBarView.Timing(ends: ends, total: total)
  }
}

final class DrainingBarView: MotionLayerView {
  struct Timing: Equatable {
    var ends: Date
    var total: TimeInterval
  }
  private let bar = CALayer()
  var color: CGColor? { didSet { instantly { bar.backgroundColor = color } } }
  var timing = Timing(ends: Date(), total: UndoToken.removalWindow) {
    didSet { if timing != oldValue { restart() } }
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    layer?.addSublayer(bar)
  }
  required init?(coder: NSCoder) { nil }
  override func restart() {
    guard !bounds.isEmpty else { return }
    let left: TimeInterval = max(0, timing.ends.timeIntervalSinceNow)
    let total: TimeInterval = max(timing.total, 0.001)
    let fraction = CGFloat(min(1, left / total))
    instantly {
      bar.removeAllAnimations()
      bar.anchorPoint = CGPoint(x: 0, y: 0.5)
      bar.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
      bar.position = CGPoint(x: 0, y: bounds.midY)
      bar.cornerRadius = bounds.height / 2
      // Its resting state is empty: the run below drains it to there.
      bar.transform = CATransform3DMakeScale(0.0001, 1, 1)
    }
    guard left > 0 else { return }
    let drain = CABasicAnimation(keyPath: "transform.scale.x")
    drain.fromValue = fraction
    drain.toValue = 0.0001
    drain.duration = left
    drain.timingFunction = CAMediaTimingFunction(name: .linear)
    bar.add(drain, forKey: "drain")
  }
}

// MARK: - Messages

/// The tint of the assistant a chat is with, for the person's bubbles (nil keeps the `bubble`
/// wash). A plain key, not `@Entry`: the Command Line Tools ship no SwiftUI macro plugin.
private struct PersonBubbleTintKey: EnvironmentKey {
  static let defaultValue: Color? = nil
}

extension EnvironmentValues {
  var personBubbleTint: Color? {
    get { self[PersonBubbleTintKey.self] }
    set { self[PersonBubbleTintKey.self] = newValue }
  }
}

/// The person's own words in Grok's bubble: 15 on 22, 7 by 12 padding, radius 18, at most
/// 560 wide, in white on the chat assistant's tint (`personBubbleTint`), else on `userBubble`.
/// The last of a run tightens its bottom-trailing corner to 6.
struct PersonBubble: View {
  let text: String
  var tail = true
  @Environment(\.palette) private var p
  @Environment(\.personBubbleTint) private var tint
  @Environment(\.messageSelection) private var selection
  @Environment(\.messageSelectionPrefix) private var prefix
  var body: some View {
    // A reply: the words it answered as a chip above, the person's own in the bubble.
    if let reply = DraftQuote.split(text) {
      VStack(alignment: .trailing, spacing: 4) {
        ReplyQuoteChip(quote: reply.quote)
        bubble(reply.words)
      }
    } else {
      bubble(text)
    }
  }
  private func bubble(_ shown: String) -> some View {
    words(shown)
      .padding(.vertical, 7).padding(.horizontal, 12)
      .background(tint ?? p.userBubble, in: MessageBubbleShape(tail: tail ? .trailing : .none))
      .modifier(ChatBubbleHover())
      .modifier(BubbleWidth())
  }
  /// In a conversation with one selection, native text that joins it; elsewhere SwiftUI's own.
  @ViewBuilder private func words(_ text: String) -> some View {
    let ink: Color = .white
    if selection != nil {
      SelectableMessageText(
        text: { var run = AttributedString(text); run.foregroundColor = ink; return run }(),
        size: 15, lineSpacing: 4, selectionOrder: prefix, hugs: true)
    } else {
      Text(verbatim: text).font(AssistantType.bubble).foregroundStyle(ink)
        .lineSpacing(4)
        .textSelection(.enabled)
    }
  }
}

/// A person's bubble is as wide as its words, up to `bubbleMax`, so what sits beside it on hover
/// stays next to it. A plain `maxWidth` frame would claim the full width even for "ok".
private struct BubbleWidth: ViewModifier {
  func body(content: Content) -> some View { HugUpTo(limit: AssistantMetrics.bubbleMax) { content } }
}

private struct HugUpTo: Layout {
  let limit: CGFloat
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let only = subviews.first else { return .zero }
    return only.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? limit, limit), height: nil))
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
  }
}

/// Another assistant's message (Grok's sender label): its 16-point face and name over the first
/// bubble in `meta` `secondary`, and the words in the same bubble as a reply, up to 560 wide, with
/// a tail on the last of a run. In a team chat its picture sits beside the last bubble of the run,
/// as in a group text. Its words are its own: shown as text, never as instructions.
struct GroupMessageRow<Content: View>: View {
  let profile: RelayProfile
  var showsName = true
  var tail = true
  /// A team chat: the column for its picture, drawn on the last bubble of the run.
  var showsFace = false
  /// The words, when a short message should hug them (`SereinReplyBubble.hugs`).
  var hugging: String? = nil
  @ViewBuilder var content: () -> Content
  @Environment(\.palette) private var p
  var body: some View {
    HStack(alignment: .bottom, spacing: showsFace ? GroupFace.gap : 0) {
      if showsFace { GroupFace(profile: tail ? profile : nil) }
      VStack(alignment: .leading, spacing: 2) {
        if showsName {
          HStack(spacing: 6) {
            TeamFace(profile: profile, size: 16).accessibilityHidden(true)
            Text(verbatim: profile.name).font(AssistantType.meta).foregroundStyle(p.secondary)
          }.padding(.leading, 4)
        }
        if let hugging, SereinReplyBubble<EmptyView, EmptyView>.hugs(hugging) {
          ViewThatFits(in: .horizontal) {
            bubble(content().fixedSize(horizontal: true, vertical: false))
            bubble(content())
          }
        } else {
          bubble(content())
        }
      }.frame(maxWidth: AssistantMetrics.replyMax, alignment: .leading)
      Spacer(minLength: 0)
    }
  }
  private func bubble(_ words: some View) -> some View {
    words
      .padding(.vertical, 7).padding(.horizontal, 12)
      .background(p.assistantBubble, in: MessageBubbleShape(tail: tail ? .leading : .none))
      .modifier(ChatBubbleHover())
  }
}

/// The picture column beside a team member's bubbles and typing dots. Nil keeps the column empty,
/// so a run's bubbles line up.
struct GroupFace: View {
  static let side: CGFloat = 24
  static let gap: CGFloat = 6
  let profile: RelayProfile?
  var body: some View {
    Group {
      if let profile { TeamFace(profile: profile, size: Self.side) } else { Color.clear }
    }.frame(width: Self.side, height: Self.side).accessibilityHidden(true)
  }
}

/// A centred system line ("You made Inbox Zero", "Asked Planner", "Messaged Scout"): 12
/// `secondary` on the `track` capsule, with each assistant it names after its 14-point face. The words are
/// Serein's own (`AgentMessage.line`), drawn as plain text.
struct SystemLineCapsule: View {
  let line: String
  let profiles: [RelayProfile]
  @Environment(\.palette) private var p
  var body: some View {
    let names: [(id: String, name: String)] = profiles.map { (id: $0.id, name: $0.name) }
    let parts: [SystemLineParts.Part] = SystemLineParts.split(line, names: names)
    HStack(spacing: 0) {
      ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
        switch part {
        case .words(let words):
          Text(verbatim: words)
        case .name(let id, let text):
          HStack(spacing: 4) {
            AssistantMark(profile: profiles.first(where: { $0.id == id }), size: 14)
            Text(verbatim: text)
          }.padding(.horizontal, 2)
        }
      }
    }
    .font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
    .padding(.vertical, 6).padding(.horizontal, 12)
    .background(p.track, in: Capsule())
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(line)
  }
}

/// A system line the host wrote (`AgentMessage.line`): the centred capsule; with `from` set, a
/// `warning` line about that assistant's held-back answer (SPEC.md 2.5); with words in `text`, a
/// folded line ("Serein asked you") that opens to them in place. Every word is drawn as text.
struct HostLineView: View {
  let message: AgentMessage
  let profiles: [RelayProfile]
  @State private var open = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    let line: String = message.line ?? ""
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    if message.from != nil {
      InfoBanner(text: line, tone: p.warning, icon: "exclamationmark.triangle")
    } else if !message.text.isEmpty {
      VStack(spacing: AssistantMetrics.cardGap) {
        Button {
          // Under Reduce Motion the chevron turns at once; the words still fade in (their transition).
          withAnimation(reduce ? nil : Motion.enter) { open.toggle() }
        } label: {
          HStack(spacing: 6) {
            Text(verbatim: line)
            InterfaceIcon(systemName: "chevron.right", size: 9).rotationEffect(.degrees(open ? 90 : 0))
          }
          .font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
          .padding(.vertical, 6).padding(.horizontal, 12)
          .background(p.track, in: Capsule())
          .contentShape(Capsule())
        }
        .buttonStyle(AssistantPressStyle())
        .accessibilityLabel(line)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        if open {
          Text(verbatim: message.text).font(AssistantType.body).foregroundStyle(p.ink).lineSpacing(3)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .padding(12).frame(maxWidth: AssistantMetrics.bubbleMax, alignment: .leading)
            .background(p.track, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .transition(Motion.arrival(reduce))
        }
      }.frame(maxWidth: .infinity)
    } else {
      SystemLineCapsule(line: line, profiles: profiles)
    }
  }
}

/// What the running turn has to show now (`AssistantDesk`, SPEC.md 2.4 to 2.6): the names it asks
/// ("Asking Planner…", shimmering), its system lines and other assistants' answers, its receipts,
/// and its live plan card. They land on the reply when the turn ends (`landTurnFacts`). The desk
/// is a small observable object, so only this part of the chat redraws for them.
struct LiveTurnFacts: View {
  @ObservedObject var desk: AssistantDesk
  let chat: String
  let relay: RelayOrchestrator
  let profiles: [RelayProfile]
  /// The host's step word for the tool call in flight, under the plan's current step.
  var now: String? = nil
  /// An approval waits in this chat: the plan's current step asks first.
  var gateAsked = false
  @Environment(\.palette) private var p
  /// Whether `LiveTurnFacts` renders `message` while the foreground turn is still running.
  static func draws(_ message: AgentMessage, profiles: [RelayProfile]) -> Bool {
    if message.line != nil { return true }
    if message.role == "you", !message.text.isEmpty { return true }
    if let id = message.from, profiles.contains(where: { $0.id == id }), !message.text.isEmpty { return true }
    return false
  }
  var body: some View {
    let facts: AssistantDesk.Facts? = desk.facts[chat]
    let above: [AgentMessage] = facts?.above ?? []
    if let names = desk.asking[chat], !names.isEmpty {
      AskingCapsule(names: names, profiles: profiles)
    }
    ForEach(above, id: \.id) { message in
      if message.line != nil {
        HostLineView(message: message, profiles: profiles)
      } else if message.role == "you", !message.text.isEmpty {
        HStack {
          Spacer(minLength: 80)
          PersonBubble(text: message.text, tail: true)
        }
      } else if let id = message.from, let author = profiles.first(where: { $0.id == id }), !message.text.isEmpty {
        GroupMessageRow(profile: author) {
          Text(verbatim: message.text).font(AssistantType.body).foregroundStyle(p.ink).lineSpacing(3)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(author.name) answered: \(message.text)")
      }
    }
    if let receipts = facts?.receipts, !receipts.isEmpty {
      ReceiptBlock(receipts: receipts, replyText: "", relay: relay)
    }
    if let plan = desk.plans[chat] {
      PlanCardView(plan: plan, gateAsked: gateAsked, now: now)
    }
  }
}

/// A `bt-info` line in a tint (`warning`, `danger`): its glyph and its words on a 10% wash with a
/// 25% ring, radius 14.
struct InfoBanner: View {
  let text: String
  let tone: Color
  var icon: String = "info.circle"
  @Environment(\.palette) private var p
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: AssistantMetrics.bannerRadius, style: .continuous)
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      // The glyph's middle on the first line's middle: about half a 12-point cap height above
      // the baseline, not its foot on the baseline.
      InterfaceIcon(systemName: icon, size: 13).foregroundStyle(tone).accessibilityHidden(true)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
      Text(verbatim: text).font(AssistantType.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 10).padding(.horizontal, 12)
    .frame(maxWidth: AssistantMetrics.cardWide, alignment: .leading)
    .background(tone.opacity(0.10), in: shape)
    .overlay(shape.strokeBorder(tone.opacity(0.25), lineWidth: 1))
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

/// The names a running turn asks now (`AssistantDesk.asking`): "Asking Planner…" shimmering in
/// the centred capsule with the faces of those it names.
struct AskingCapsule: View {
  let names: [String]
  let profiles: [RelayProfile]
  @Environment(\.palette) private var p
  var body: some View {
    let named: [RelayProfile] = names.compactMap { name in profiles.first { $0.name == name } }
    HStack(spacing: 6) {
      ForEach(named) { profile in AssistantMark(profile: profile, size: 14, status: .replying) }
      ShimmerText(text: AskPolicy.asking(names))
    }
    .padding(.vertical, 6).padding(.horizontal, 12)
    .background(p.track, in: Capsule())
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AskPolicy.asking(names))
  }
}

/// Several apps to connect from one message (`AgentMessage.connect`): one chip each, "Connect
/// Gmail", with the app's logo; a tap says it in the chat, which opens its card.
struct ConnectChips: View {
  let links: [ConnectLink]
  let ask: (String) -> Void
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: AssistantMetrics.chipGap) {
      ForEach(links, id: \.self) { link in
        Button { ask("Connect \(link.name)") } label: {
          HStack(spacing: 6) {
            BrandLogo(Brand.app(link.app), size: 14, name: link.name, round: true)
            Text(verbatim: "Connect \(link.name)").font(AssistantType.meta).foregroundStyle(p.accent).lineLimit(1)
          }
          .padding(.horizontal, 12).frame(minHeight: 28)
          .background(p.track, in: Capsule())
          .contentShape(Capsule())
        }
        .buttonStyle(AssistantPressStyle())
        .accessibilityLabel("Connect \(link.name)")
      }
    }
  }
}

/// Tap-to-send replies under the newest reply (`QuickReplies`): at most 3, `accent` words (12)
/// on a `track` pill at least 28 high, 8 apart. A tap sends the chip's words as the person's message. They wrap to a column
/// when the row has no room.
struct QuickReplyChips: View {
  let chips: [String]
  let send: (String) -> Void
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: AssistantMetrics.chipGap) { chipViews }
      VStack(alignment: .leading, spacing: AssistantMetrics.chipGap) { chipViews }
    }
  }
  @ViewBuilder private var chipViews: some View {
    ForEach(chips, id: \.self) { chip in QuickReplyChip(text: chip) { send(chip) } }
  }
}

struct QuickReplyChip: View {
  let text: String
  let action: () -> Void
  @Environment(\.palette) private var p
  var body: some View {
    Button(action: action) {
      Text(verbatim: text).font(AssistantType.meta).foregroundStyle(p.accent).lineLimit(1)
        .padding(.horizontal, 12).frame(minHeight: 28)
        .background(p.track, in: Capsule())
        .contentShape(Capsule())
    }.buttonStyle(AssistantPressStyle())
      .help("Send “\(text)”")
      .accessibilityLabel("Reply: \(text)")
  }
}

/// Messages written while the assistant replies: each sits in its bubble at 60%, as a held one
/// does. Words its engine reads mid-turn say "Sent" until it reads them (`AgentRun.steering`).
/// The others wait with a clock and "Goes with the next step", then Stop and use now, Edit and
/// Remove (`RunSteering`): they go together when the reply ends (`RelayOrchestrator.pending`).
/// Stop and use now stops the reply and sends all of them at once; Edit gives one back to the box.
struct QueuedBubbles: View {
  @ObservedObject var relay: RelayOrchestrator
  @Environment(\.palette) private var p
  var body: some View {
    if relay.working {
      if let run = relay.run { SentBubbles(run: run) }
      let several: Bool = relay.pending.count > 1
      let canSend: Bool = relay.canSendPendingNow
      ForEach(Array(relay.pending.enumerated()), id: \.offset) { index, text in
        VStack(alignment: .trailing, spacing: 4) {
          PersonBubble(text: text, tail: index == relay.pending.count - 1).opacity(0.6)
          HStack(spacing: 6) {
            InterfaceIcon(systemName: "clock", size: 10).foregroundStyle(p.secondary).accessibilityHidden(true)
            Text(verbatim: RunSteering.nextStep).foregroundStyle(p.secondary)
            dot
            action(RunSteering.useNow(several: several),
                   help: canSend ? "Stop the reply and send this now. Work already done is kept." : "Nothing here can be cut short now",
                   says: "Stop the reply and use this now: \(text)") { relay.sendPendingNow() }
              .disabled(!canSend).opacity(canSend ? 1 : 0.35)
            dot
            action("Edit", help: "Take this back to the message box", says: "Edit the queued message: \(text)") {
              Self.edit(index, relay: relay)
            }
            dot
            action("Remove", help: "Do not send this", says: "Remove the queued message: \(text)") { relay.removePending(at: index) }
          }.font(AssistantType.meta)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(RunSteering.nextStep): \(text)")
      }
    }
  }
  /// Words sent into the reply that runs, until its engine reads them and they join the chat.
  private struct SentBubbles: View {
    @ObservedObject var run: AgentRun
    @Environment(\.palette) private var p
    var body: some View {
      ForEach(run.steering.pendingDisplay, id: \.id) { line in
        VStack(alignment: .trailing, spacing: 4) {
          PersonBubble(text: line.shown, tail: true).opacity(0.6)
          Text(verbatim: run.steering.waitsForNextTurn(line) ? "Waiting for the next reply" : RunSteering.sent(app: run.spec.provider.name)).font(AssistantType.meta).foregroundStyle(p.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
      }
    }
  }
  private var dot: some View {
    Text("·").foregroundStyle(p.secondary).accessibilityHidden(true)
  }
  private func action(_ title: String, help: String, says: String, _ run: @escaping () -> Void) -> some View {
    Button(action: run) { Text(title).foregroundStyle(p.accent).linkTarget() }.buttonStyle(AssistantPressStyle()).fixedSize()
      .help(help).accessibilityLabel(says)
  }
  /// Edit (and ↑ in an empty box): the message leaves the queue for the box, after any words
  /// already there, with the chips that rode with it, and the box takes the keyboard.
  @MainActor static func edit(_ index: Int, relay: RelayOrchestrator) {
    guard let item = relay.takePending(at: index) else { return }
    let surface = SereinSurface.main
    surface.draft = TurnActivity.editing(queued: item.text, draft: surface.draft)
    item.attachments.forEach { surface.attach($0) }
    surface.requestFocus()
  }
}

/// Messages held until they can go (`RelayOrchestrator.heldHere`, SPEC.md 2.4 failures): each
/// waits as a queued bubble at 60% with why under it, and Remove. Offline: "You are offline. I
/// will send this when you are back." and "Waiting for the internet". The usage limit: "{App}
/// reached its limit until {time}." with "Waits until {time}", Continue now and Use another AI
/// app. No AI app: Remove alone under the bubble, and under the held messages one card to sign in
/// to the app this chat thinks with (`AIAppConnectCard`, board 19). One written over 30 minutes
/// ago: "Not sent" with Send now. They go by themselves when what held them clears in time.
struct HeldBubbles: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject private var network = NetworkMonitor.shared
  @Environment(\.palette) private var p
  /// The held message whose model list is open (Choose another AI app or model).
  @State private var picking: String?
  var body: some View {
    // While first-time setup still waits on a choice (SereinChatSetup), nothing goes yet.
    let connected: Bool = SereinSurface.connected(relay.agent) && !SereinChatSetup.shared.requiresChoice(relay)
    let online: Bool = SereinSurface.online(network.online)
    // During setup a request it moved on from already shows in the chat, where it was written.
    let settingUp: Bool = SereinChatSetup.shared.isActive(in: relay)
    ForEach(relay.heldHere.filter { !(settingUp && relay.isSetupRequestCopy($0)) }) { item in
      let next: HeldMessage.Next = HeldMessage.next(item.message, connected: connected, online: online, now: Date())
      VStack(alignment: .trailing, spacing: 4) {
        PersonBubble(text: item.message.text).opacity(0.6)
        footer(item, next: next)
        if let line = failure(item, next: next) {
          Text(verbatim: line).font(AssistantType.meta).foregroundStyle(p.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isStaticText)
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Queued message: \(item.message.text)")
    }
    // No AI app can answer: one card for the app this chat thinks with, for every held message.
    // Setup's own account choices stand in for it while they show.
    if !settingUp, !SereinSurface.connected(relay.agent), relay.heldHere.contains(where: {
      HeldMessage.next($0.message, connected: false, online: online, now: Date()) == .wait(.noAI)
    }) {
      AIAppConnectCard(provider: relay.assistantEngine(relay.team.active).provider, agent: relay.agent,
                       assistant: relay.team.activeID)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    if let notice = relay.heldNotice {
      Text(notice).font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
  private func time(_ date: Date?) -> String {
    guard let date else { return "later" }
    // A reset on another day names the day: "Wed 1:00 PM", never a bare time that reads as today.
    return UsageLimit.when(date, now: Date())
  }
  /// The one `danger` line under the bubble: why it did not go.
  private func failure(_ item: RelayOrchestrator.Held, next: HeldMessage.Next) -> String? {
    switch next {
    case .wait(.offline): return "You are offline. I will send this when you are back."
    case .wait(.usageLimit):
      let line = "\(relay.limitApp(item)) reached its limit until \(time(item.message.resetsAt))."
      return relay.elsewhereOffered[item.id] == "" ? line + " No other AI app is ready to take over." : line
    case .wait(.noAI), .send, .stale: return nil
    }
  }
  @ViewBuilder private func footer(_ item: RelayOrchestrator.Held, next: HeldMessage.Next) -> some View {
    HStack(spacing: 6) {
      switch next {
      case .wait(.offline):
        Text("Waiting for the internet").foregroundStyle(p.secondary)
      case .wait(.usageLimit):
        Text(verbatim: "Waits until \(time(item.message.resetsAt))").foregroundStyle(p.secondary)
        dot
        action("Continue now") { relay.continueHeld(item.id) }
        dot
        if relay.elsewhereOffered[item.id] == "" {
          // Nothing else can answer now: the model list, where another AI app or model connects.
          // A pick there sends this message to it (`RelayOrchestrator.resumeLimitedHolds`).
          chooseElsewhere(item)
        } else {
          action("Use another AI app") { relay.continueElsewhere(item.id, byPerson: true) }
        }
      case .wait(.noAI):
        // The card under the held messages asks for the sign-in (AIAppConnectCard).
        EmptyView()
      case .stale:
        Text(HeldMessage.staleChip).foregroundStyle(p.secondary)
        dot
        action("Send now") { relay.sendHeld(item.id) }
      case .send:
        ShimmerText(text: HeldMessage.chip(next))
      }
      if next != .wait(.noAI) { dot }
      action("Remove") { relay.discardHeld(item.id) }
    }.font(AssistantType.meta)
  }
  private func chooseElsewhere(_ item: RelayOrchestrator.Held) -> some View {
    action("Choose another AI app or model") { picking = item.id }
      .popover(isPresented: Binding(get: { picking == item.id }, set: { if !$0 { picking = nil } }), arrowEdge: .top) {
        ModelPickerView(agent: relay.agent, chat: nil, assistant: relay.team.activeID) { picking = nil }
          .frame(width: KeelPicker.width, height: KeelPicker.height)
          .background(KeelPicker.surface(p.isDark))
          .environment(\.palette, p)
      }
  }
  private var dot: some View {
    Text("·").foregroundStyle(p.secondary).accessibilityHidden(true)
  }
  private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
    Button(action: run) { Text(title).foregroundStyle(p.accent).linkTarget() }.buttonStyle(AssistantPressStyle()).fixedSize()
  }
}

/// One `danger` line in the reply slot (SPEC.md 2.4 failures). It never goes away by itself and
/// is announced at once, at high priority (assertive). "Send again" runs the person's last words
/// once more when no reply followed them.
/// `cause`: what the AI app or the system said, behind Details, at most 600 characters
/// (`TurnActivity.cause`). `attempt`: a turn sent again says which try failed.
struct TurnFailureLine: View {
  let words: String
  var cause: String? = nil
  var attempt = 1
  var retry: (() -> Void)? = nil
  var retryTitle = "Send again"
  @State private var showsCause = false
  @Environment(\.palette) private var p
  var body: some View {
    // The headline already says a plain cause: Details is for one it does not.
    let detail: String? = TurnActivity.cause(cause).flatMap { words.contains($0) ? nil : $0 }
    let actions: [TurnActivity.Action] = TurnActivity.actions(.failed, hasCause: detail != nil, canRetry: retry != nil)
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: words).font(AssistantType.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
        if let tried = TurnActivity.tryWords(attempt) {
          Text(tried).font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize()
        }
        if actions.contains(.details) {
          // Opens at once: the chat's layout never animates.
          Button { showsCause.toggle() } label: {
            Text("Details").font(AssistantType.meta).foregroundStyle(p.accent).linkTarget()
          }.buttonStyle(AssistantPressStyle()).fixedSize()
            .accessibilityValue(showsCause ? "Shown" : "Hidden")
            .accessibilityHint(showsCause ? "Hides what went wrong" : "Shows what went wrong")
        }
        if actions.contains(.retry), let retry {
          Button(action: retry) {
            Text(retryTitle).font(AssistantType.meta).foregroundStyle(p.accent).linkTarget()
          }.buttonStyle(AssistantPressStyle()).fixedSize()
        }
        Spacer(minLength: 0)
      }
      if showsCause, let detail {
        Text(verbatim: detail).font(AssistantType.meta).foregroundStyle(p.secondary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
    }
    .accessibilityElement(children: .contain)
    .onAppear { ChatAnnouncement.post([words, TurnActivity.tryWords(attempt)].compactMap { $0 }.joined(separator: " "), priority: .high) }
  }
}

/// Under a turn's trail once it has shown nothing for 20 seconds (`TurnActivity.slowReply`): one
/// quiet line to keep waiting or stop. Said once to VoiceOver, after what it is saying.
struct SlowReplyLine: View {
  let keepWaiting: () -> Void
  let stop: () -> Void
  @Environment(\.palette) private var p
  private static let words = "No reply yet."
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(Self.words).foregroundStyle(p.secondary)
      action("Keep waiting", help: "Hide this line and let the reply go on", keepWaiting)
      Text("·").foregroundStyle(p.secondary).accessibilityHidden(true)
      action("Stop", help: "Stop this reply", stop)
    }
    .font(AssistantType.meta).padding(.leading, 26)
    .accessibilityElement(children: .contain)
    .onAppear { ChatAnnouncement.post(Self.words + " You can keep waiting or stop.", priority: .medium) }
  }
  private func action(_ title: String, help: String, _ run: @escaping () -> Void) -> some View {
    Button(action: run) { Text(title).foregroundStyle(p.accent).linkTarget() }.buttonStyle(AssistantPressStyle()).fixedSize().help(help)
  }
}

/// Words VoiceOver says at once: `high` interrupts (a failure), `medium` waits its turn (a
/// typing row, once per turn).
@MainActor enum ChatAnnouncement {
  static func post(_ words: String, priority: NSAccessibilityPriorityLevel) {
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: words, .priority: priority.rawValue])
  }
  /// The typing row's "{Name} is typing", said once for each wait (`key`).
  private static var lastTyping: String?
  static func typing(_ name: String, key: String) {
    guard lastTyping != key else { return }
    lastTyping = key
    post("\(name) is typing", priority: .medium)
  }
  /// Serein's own turn, whose trail stands in for the typing row: "{Name} is thinking" once when
  /// it starts, and how it ended once when it does (`key`: the run). An end is said only for the
  /// turn whose start was, so opening another chat says nothing.
  private static var saidTurn: String?
  static func turnBegan(_ name: String, key: String) {
    guard saidTurn != key else { return }
    saidTurn = key
    post("\(name) is thinking", priority: .medium)
  }
  static func turnEnded(_ name: String, how: String, key: String) {
    guard saidTurn == key else { return }
    saidTurn = nil
    post("\(name) \(how)", priority: .medium)
  }
}

/// Try again keeps the reply it replaces (`ReplyVersions`), per chat, in memory for this launch:
/// the newest reply in the open chat, the only one Try again is offered on, can be stepped back.
@MainActor final class ReplyVersionBook: ObservableObject {
  static let shared = ReplyVersionBook()
  @Published private(set) var book: [String: ReplyVersions] = [:]
  /// UI previews only: the chat and question the fixture versions answer.
  private var previewPlace: (chat: String, asked: String)?
  /// The open chat and the person's newest words, which its newest reply answers.
  private var place: (chat: String, asked: String)? {
    if let previewPlace { return previewPlace }
    guard let relay = RelayOrchestrator.shared,
      let asked = relay.transcript.last(where: { $0.role == "you" })?.text else { return nil }
    return (relay.threadID, asked)
  }
  /// Before Try again: the newest reply joins the earlier versions, in its message's words
  /// without its chips (as the bubble shows them), else as `shown`.
  func keep(_ shown: String) {
    guard let place else { return }
    let message = RelayOrchestrator.shared?.transcript.last(where: { $0.role == "assistant" && $0.from == nil })
    let words = message.map { QuickReplies.parse($0.text).text } ?? ""
    ReplyVersions.keep(words.isEmpty ? shown : words, asked: place.asked, chat: place.chat, in: &book)
  }
  /// The newest reply's versions, when Try again kept any.
  var versions: ReplyVersions? {
    place.flatMap { ReplyVersions.of(chat: $0.chat, asked: $0.asked, in: book) }
  }
  /// The newest reply's words on screen: an earlier version while the person stepped back.
  func text(current: String) -> String { versions?.text(current: current) ?? current }
  func step(_ by: Int) {
    guard let place, var versions else { return }
    versions.step(by)
    book[place.chat] = versions
  }
  /// UI previews only: earlier versions of the newest reply, with no chat behind them.
  func preview(chat: String, asked: String, earlier: [String]) {
    previewPlace = (chat, asked)
    for reply in earlier { ReplyVersions.keep(reply, asked: asked, chat: chat, in: &book) }
  }
}

/// A message's actions (`ai-message-actions`): Reply, which quotes it in the draft, and ⋯ with
/// the rest: Copy, then Try again and Read aloud on a reply, or Save as shortcut and Edit on the
/// person's own. 14-point glyphs in `secondary`. No thumbs. Try again keeps the reply it
/// replaces, and once it has, "‹ 1 of 2 ›" steps between the versions; Copy, Reply and Read
/// aloud take the one on screen.
struct MessageActions: View {
  let text: String
  var retry: (() -> Void)? = nil
  var speak: ((String) -> Void)? = nil
  var saveShortcut = false
  var edit: (() -> Void)? = nil
  /// On a reply to Serein's own check-in or brief: the menu's last item, which opens where that
  /// is turned off (`RelayAutomatic.settingsTitle`).
  var settings: (title: String, open: () -> Void)? = nil
  @Environment(\.palette) private var p
  @ObservedObject private var book = ReplyVersionBook.shared
  /// Either control holding the keyboard shows both (`MessageHoverControls`).
  @FocusState private var focused: Bool
  /// So does the ⋯ menu while it is open: the pointer is on its rows, off the message.
  @State private var menuOpen = false
  var body: some View {
    // Only the newest reply has Try again, and only it has versions.
    let versions: ReplyVersions? = retry == nil ? nil : book.versions
    let text: String = versions.map { ChatBubbles.plain($0.text(current: self.text)) } ?? self.text
    let again: (() -> Void)? = retry.map { retry in { book.keep(self.text); retry() } }
    HStack(spacing: 2) {
      if let versions { stepper(versions) }
      Button { Self.reply(text, mine: saveShortcut) } label: { glyph("arrowshape.turn.up.left") }
        .buttonStyle(AssistantPressStyle()).help("Reply").accessibilityLabel("Reply")
        .focused($focused)
      // Serein's own menu (SereinMenu.swift). It opens away from the bubble: over the margin
      // beside the person's words, and past the end of a reply.
      SereinMenuButton("More actions", help: "More", width: 200, leading: !saveShortcut) {
        SereinMenuItem.action("Copy", icon: "doc.on.doc") { Self.copy(text) }
        if let again { SereinMenuItem.action("Try again", icon: "arrow.clockwise", again) }
        if let speak { SereinMenuItem.action("Read aloud", icon: "speaker.wave.2") { speak(text) } }
        if saveShortcut { SereinMenuItem.action("Save as shortcut", icon: "bookmark") { ShortcutBook.offer(text) } }
        if let edit { SereinMenuItem.action("Edit", icon: "pencil", edit) }
        if let settings {
          SereinMenuItem.divider
          SereinMenuItem.action(settings.title, icon: "gearshape", settings.open)
        }
      } label: { glyph("ellipsis") }
        .buttonStyle(AssistantPressStyle()).fixedSize()
        .focused($focused)
        .onPreferenceChange(SereinMenuOpen.self) { menuOpen = $0 }
    }
    .preference(key: MessageControlsFocused.self, value: focused || menuOpen)
  }
  /// "‹ 1 of 2 ›": the arrows held at either end, one adjustable element for VoiceOver.
  private func stepper(_ versions: ReplyVersions) -> some View {
    let first: Bool = versions.index == 0
    let newest: Bool = versions.index == versions.count - 1
    return HStack(spacing: 0) {
      Button { book.step(-1) } label: { glyph("chevron.left") }
        .buttonStyle(AssistantPressStyle()).disabled(first).opacity(first ? 0.35 : 1)
        .help("Earlier version").focused($focused)
      Text(verbatim: versions.position).font(AssistantType.figures).foregroundStyle(p.secondary).fixedSize()
      Button { book.step(1) } label: { glyph("chevron.right") }
        .buttonStyle(AssistantPressStyle()).disabled(newest).opacity(newest ? 0.35 : 1)
        .help("Later version").focused($focused)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Version")
    .accessibilityValue(versions.position)
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: book.step(1)
      case .decrement: book.step(-1)
      @unknown default: break
      }
    }
  }
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  /// Makes `text` the message the next one replies to (the composer's reply bar) and gives the
  /// composer the keyboard. The draft is left as it is. `mine`: the person's own words.
  static func reply(_ text: String, mine: Bool = false) {
    let surface = SereinSurface.main
    let from = mine ? "you" : (RelayOrchestrator.shared?.team.activeName ?? "Serein")
    // A reply to a reply quotes the person's own words, not the quote inside them.
    let words = DraftQuote.split(text)?.words ?? text
    withAnimation(MessageMotion.reply) {
      surface.replyingTo = ReplyTarget(text: words, from: from)
    }
    NotificationCenter.default.post(name: SereinSurface.focus, object: nil)
    NotificationCenter.default.post(name: RelayWindow.focus, object: nil)
  }
  private func glyph(_ symbol: String) -> some View { MessageGlyph(symbol: symbol) }
}

/// One of a message's control glyphs: `secondary`, and `ink` on a soft round wash under the pointer.
private struct MessageGlyph: View {
  let symbol: String
  @State private var hovered = false
  @Environment(\.palette) private var p
  var body: some View {
    InterfaceIcon(systemName: symbol, size: 14).foregroundStyle(hovered ? p.ink : p.secondary)
      .frame(width: 24, height: 24)
      .background(Circle().fill(p.hover).opacity(hovered ? 1 : 0))
      .contentShape(Rectangle())
      .onHover { hovered = $0 }
      .animation(MessageMotion.controls, value: hovered)
  }
}

/// An empty chat (`ai-welcome`, SPEC.md 2.4): the assistant's face at 40, its name in the title
/// size, its job in `meta`, and three chips that ask something it can do.
struct AssistantWelcomeHeader: View {
  let profile: RelayProfile?
  let name: String
  let job: String
  let chips: [String]
  let ask: ((String) -> Void)?
  @Environment(\.palette) private var p
  var body: some View {
    VStack(spacing: 10) {
      AssistantMark(profile: profile, size: 40)
      VStack(spacing: 3) {
        Text(verbatim: name).font(AssistantType.title).foregroundStyle(p.ink)
        Text(verbatim: job).font(AssistantType.meta).foregroundStyle(p.secondary).multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let ask, !chips.isEmpty {
        QuickReplyChips(chips: Array(chips.prefix(3)), send: ask).padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 16)
    .accessibilityElement(children: .contain)
  }
}

// MARK: - Paced streaming

/// The part of a streaming reply to show now (`PacedReveal`): a steady pace a little behind what
/// has arrived, at least 90 characters a second, worked off within 0.4 seconds while it streams
/// and 0.3 seconds after it ends. It ticks 30 times a second only while text is left to show,
/// and only this small object changes, so the chat around it does not redraw for the pace.
@MainActor final class PacedTextModel: ObservableObject {
  @Published private(set) var shown: String
  private var characters: [Character]
  private var count: Int
  private var streaming = true
  private var grewAt = Date()
  private var finishAt: Date?
  private var lastTick: Date?
  private var timer: Timer?

  /// `live`: the reply arrives now, so it starts from nothing; one already there starts whole.
  init(text: String, live: Bool) {
    characters = Array(text)
    count = live ? 0 : characters.count
    shown = live ? "" : text
  }

  func update(text: String, streaming: Bool, reduce: Bool) {
    let next: [Character] = Array(text)
    if next.count != characters.count { grewAt = Date() }
    characters = next
    self.streaming = streaming
    if streaming {
      finishAt = nil
    } else if finishAt == nil {
      finishAt = Date().addingTimeInterval(PacedReveal.finishSeconds)
    }
    // Reduce Motion draws the words as they come.
    if reduce { count = characters.count }
    if count > characters.count { count = characters.count }
    if count < characters.count {
      start()
    } else {
      stop()
      publish()
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func start() {
    guard timer == nil else { return }
    lastTick = nil
    let ticker = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard let self else {
          timer.invalidate()
          return
        }
        self.tick()
      }
    }
    RunLoop.main.add(ticker, forMode: .common)
    timer = ticker
  }

  private func tick() {
    let now = Date()
    let since: TimeInterval = lastTick.map { now.timeIntervalSince($0) } ?? (1.0 / 30)
    let elapsed: TimeInterval = min(PacedReveal.maxStepSeconds, max(0, since))
    lastTick = now
    let holdTail: Bool = now.timeIntervalSince(grewAt) < PacedReveal.tailSettles
    let finishIn: TimeInterval = finishAt.map { $0.timeIntervalSince(now) } ?? PacedReveal.finishSeconds
    count = PacedReveal.next(
      text: characters, shown: count, elapsed: elapsed, streaming: streaming, holdTail: holdTail, finishIn: finishIn)
    publish()
    if count >= characters.count { stop() }
  }

  private func publish() {
    let next = String(characters.prefix(count))
    if next != shown { shown = next }
  }
}
