import SereinCore
import SwiftUI

/// Serein's first message on the first launch and its choices (SPEC.md 2.1, the welcome board):
/// "Hey, welcome to Serein. Which AI app should I use?" (`Welcome.firstMessage`) with one
/// row per AI app Serein supports (`Welcome.choices`: the app's logo, its name, and Ready, Sign in
/// or Install). A click runs `Welcome.step`: an install or a sign-in goes through the existing
/// harness actions (`SereinConnect`), and a finished install starts the sign-in, a finished
/// sign-in opens the model picker, with no other click. A ready app opens Serein's own model
/// picker (`ModelPickerView`) in place. After a pick: "Done. I think with {Model} now." and three
/// chips; the welcome does not come back. While no AI app can think for Serein later, the same
/// choices come back as one card (`firstMessage` false).
struct WelcomeFlowView: View {
  @ObservedObject var relay: RelayOrchestrator
  /// The first launch's message above the choices; the later card shows the choices alone.
  var firstMessage = true
  /// Sends a chip's words as the person's message.
  var ask: (String) -> Void
  @ObservedObject private var registry = HarnessRegistry.shared
  @ObservedObject private var connect = SereinConnect.shared
  @ObservedObject private var network = NetworkMonitor.shared
  /// The app whose install or sign-in this card started.
  @State private var chosen: HarnessDriver?
  /// The ready app whose model picker is open in place.
  @State private var picking: HarnessDriver?
  /// The model picked, for the receipt line.
  @State private var pickedModel: String?
  @State private var showAll = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  static let welcomedKey = "serein.assistants.welcomed"
  static let shownRows = 5
  static let pickedChips = ["Make an assistant for my inbox", "Remind me tomorrow at 9", "What can you do?"]
  /// True once the person picked a model here (or chatted with an AI app ready): no welcome again.
  static var welcomed: Bool { UserDefaults.standard.bool(forKey: welcomedKey) }

  private var reduce: Bool { systemReduceMotion || previewReducedEffects }
  private var choices: [WelcomeChoice] { Welcome.choices(snapshots: registry.snapshots, settings: registry.settings) }
  private var probing: Bool { registry.snapshots.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: AssistantMetrics.chatGap) {
      if relay.transcript.isEmpty {
        WelcomeHero(firstMessage: firstMessage)
      }
      featuredCard
      choicesCard
      WelcomeAfterward()
      if let driver = picking { pickerBlock(driver) }
      if let model = pickedModel { pickedBlock(model) }
    }
    .animation(Motion.entering(reduce), value: picking)
    .animation(Motion.entering(reduce), value: pickedModel)
    .task { if probing { await registry.refreshAll(includeDisabled: true) } }
    // No extra click: a finished install goes on to the sign-in (SereinConnect does), and a
    // finished sign-in opens the model picker here.
    .onChange(of: connect.flow) { _, flow in
      guard let flow, flow.driver == chosen, flow.phase == .connected else { return }
      connect.dismiss()
      picking = flow.driver
    }
  }

  // MARK: the choices

  /// The two accounts most people already pay for (Claude, ChatGPT), as big tiles that say which
  /// account each one uses. The first is marked Recommended.
  private var featured: [WelcomeChoice] {
    SereinChatSetup.accounts.compactMap { driver in choices.first { $0.driver == driver } }
  }
  @ViewBuilder private var featuredCard: some View {
    if !probing, !featured.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
          Text("Step 1 of 2").font(AssistantType.meta).foregroundStyle(p.onSolid)
            .padding(.horizontal, 8).frame(height: 20).background(p.solid, in: Capsule())
          Text("Pick the account you already have").font(AssistantType.name).foregroundStyle(p.ink)
        }.accessibilityElement(children: .combine)
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 10) { featuredTiles }
          VStack(spacing: 10) { featuredTiles }
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          InterfaceIcon(systemName: "lock", size: 11).foregroundStyle(p.secondary).accessibilityHidden(true)
          Text("You sign in on the app's own website. Serein never sees your password, and it takes about a minute.")
            .font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }.frame(maxWidth: AssistantMetrics.cardWide, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
  }
  @ViewBuilder private var featuredTiles: some View {
    ForEach(Array(featured.enumerated()), id: \.element.id) { index, choice in
      featuredTile(choice, recommended: index == 0)
    }
  }
  private func featuredTile(_ choice: WelcomeChoice, recommended: Bool) -> some View {
    let account: String = SereinConnect.account(choice.driver) ?? choice.name
    return Button { choose(choice) } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          ModelMonogram(provider: Provider(choice.driver), size: 28)
          Spacer(minLength: 8)
          if recommended {
            Text("Recommended").font(AssistantType.meta).foregroundStyle(p.secondary)
          }
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: "Use my \(account) account").font(AssistantType.name).foregroundStyle(p.ink)
          Text(verbatim: "Connects \(choice.name)").font(AssistantType.meta).foregroundStyle(p.secondary)
        }
        HStack {
          if working(choice.driver) || connect.flow?.driver == choice.driver && chosen == choice.driver {
            state(choice)
          } else {
            Text(Self.action(choice.next)).font(AssistantType.meta).foregroundStyle(recommended ? p.onSolid : p.ink)
              .padding(.horizontal, 14).frame(height: 28)
              .background(recommended ? p.solid : p.track, in: Capsule())
          }
          Spacer(minLength: 0)
        }
      }
      .padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .assistantCard(p)
      .contentShape(Rectangle())
    }
    .buttonStyle(AssistantPressStyle())
    .disabled(working(choice.driver))
    .accessibilityLabel("Use my \(account) account. \(Self.action(choice.next))\(recommended ? ". Recommended" : "")")
  }
  /// A choice's button in words anyone knows.
  static func action(_ next: WelcomeChoice.Next) -> String {
    switch next {
    case .install: return "Set it up"
    case .signIn: return "Sign in"
    case .ready: return "Use it"
    }
  }

  private var choicesCard: some View {
    let all: [WelcomeChoice] = featured.isEmpty ? choices : choices.filter { !featured.contains($0) }
    let shown: [WelcomeChoice] = showAll ? all : []
    let more: Int = all.count - shown.count
    return VStack(alignment: .leading, spacing: 0) {
      if probing {
        ForEach(0..<3, id: \.self) { index in
          if index > 0 { divider }
          skeletonRow
        }
      } else {
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, choice in
          if index > 0 { divider }
          choiceRow(choice)
        }
        if more > 0 {
          if !shown.isEmpty { divider }
          Button { showAll = true } label: {
            Text(featured.isEmpty ? "Show \(more) more" : "I use a different AI app (\(more) more)").font(AssistantType.meta).foregroundStyle(p.accent)
              .frame(maxWidth: .infinity, alignment: .leading).frame(height: 40).contentShape(Rectangle())
          }.buttonStyle(AssistantPressStyle()).padding(.horizontal, 4)
        }
      }
      if let problem = problem { problemLine(problem) }
    }
    .padding(.vertical, 6).padding(.horizontal, 14)
    .frame(maxWidth: AssistantMetrics.cardWide, alignment: .leading)
    .assistantCard(p)
    .pressGuard(probing ? "probing" : "\(all.count)")
    .accessibilityElement(children: .contain)
    .accessibilityLabel(probing ? "Looking for AI apps on this Mac." : "AI apps")
  }
  private var divider: some View { Rectangle().fill(p.line).frame(height: UIStyle.hairline) }
  private var skeletonRow: some View {
    HStack(spacing: 12) {
      SkeletonBar(width: 20, height: 20)
      SkeletonBar(width: 120, height: 12)
      Spacer(minLength: 0)
    }.frame(height: 44).padding(.horizontal, 4)
  }
  private func choiceRow(_ choice: WelcomeChoice) -> some View {
    Button { choose(choice) } label: {
      HStack(spacing: 12) {
        ModelMonogram(provider: Provider(choice.driver), size: 20)
        Text(verbatim: choice.name).font(AssistantType.name).foregroundStyle(p.ink).lineLimit(1)
        Spacer(minLength: 8)
        state(choice)
      }
      .frame(height: 44).padding(.horizontal, 4).contentShape(Rectangle())
    }
    .buttonStyle(AssistantPressStyle())
    .disabled(working(choice.driver))
    .accessibilityLabel("\(choice.name), \(choice.next.words)")
  }
  /// The row's state word, or what its setup does now.
  @ViewBuilder private func state(_ choice: WelcomeChoice) -> some View {
    if let flow = connect.flow, flow.driver == choice.driver, chosen == choice.driver {
      switch flow.phase {
      case .checking: ShimmerText(text: "Checking…")
      case .installing: ShimmerText(text: "Installing \(choice.name)…")
      case .updating: ShimmerText(text: "Updating \(choice.name)…")
      case .signingIn: ShimmerText(text: "Signing in…")
      case .connected: Text("Ready").font(AssistantType.meta).foregroundStyle(p.secondary)
      case .failed: Text(choice.next.words).font(AssistantType.meta).foregroundStyle(p.secondary)
      }
    } else {
      Text(choice.next.words).font(AssistantType.meta).foregroundStyle(p.secondary)
    }
  }
  private func working(_ driver: HarnessDriver) -> Bool {
    guard let flow = connect.flow, flow.driver == driver else { return false }
    return flow.phase == .checking || flow.phase == .installing || flow.phase == .updating || flow.phase == .signingIn
  }

  /// One line under the rows: offline, a sign-in to finish, an install that failed, or the
  /// connect flow's own words for an update that failed or a tool the install needs and this Mac
  /// lacks (npm, Homebrew).
  private enum Problem: Equatable {
    case offline, signingIn(String), installFailed(String), stillSignedOut(String), failed(String)
  }
  private var problem: Problem? {
    if !network.online { return .offline }
    guard let flow = connect.flow, flow.driver == chosen else { return nil }
    let name: String = choices.first { $0.driver == flow.driver }?.name ?? "The app"
    switch flow.phase {
    case .signingIn: return .signingIn(name)
    case .failed(let step, let missing):
      if !missing.isEmpty || step == .update || step == .check { return .failed(SereinConnect.failure(name, step: step, missing: missing)) }
      return step == .install ? .installFailed(name) : .stillSignedOut(name)
    case .checking, .installing, .updating, .connected: return nil
    }
  }
  @ViewBuilder private func problemLine(_ problem: Problem) -> some View {
    switch problem {
    case .offline:
      banner("I cannot reach the internet. I will look again when you are back online.", tone: p.warning, retry: false)
    case .signingIn(let name):
      banner("Finish signing in to \(name) in the window that opened.", tone: p.secondary, retry: false)
    case .installFailed(let name):
      banner("\(name) did not install. Try again, or pick another one.", tone: p.danger, retry: true)
    case .stillSignedOut(let name):
      banner("\(name) is still signed out. Try again.", tone: p.warning, retry: true)
    case .failed(let words):
      banner(words, tone: p.danger, retry: true)
    }
  }
  private func banner(_ words: String, tone: Color, retry: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: words).font(AssistantType.meta).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      if retry, let driver = chosen {
        Button { SereinConnect.shared.start(driver) } label: {
          Text("Try again").font(AssistantType.meta).foregroundStyle(p.accent).linkTarget()
        }.buttonStyle(AssistantPressStyle()).fixedSize()
      }
    }.padding(.vertical, 10).padding(.horizontal, 4)
  }

  /// `Welcome.step`: install or sign in through the app's own flow, or open the picker.
  private func choose(_ choice: WelcomeChoice) {
    chosen = choice.driver
    pickedModel = nil
    switch Welcome.step(for: choice) {
    case .install(let driver), .signIn(let driver):
      picking = nil
      SereinConnect.shared.start(driver)
    case .showModelPicker:
      picking = choice.driver
    }
  }

  // MARK: the picker and the pick

  private func pickerBlock(_ driver: HarnessDriver) -> some View {
    let name: String = choices.first { $0.driver == driver }?.name ?? "Your AI app"
    let main: String = relay.team.main?.id ?? RelayTeam.mainID
    return VStack(alignment: .leading, spacing: AssistantMetrics.cardGap) {
      let words: String = "\(name) is ready. Pick a model. You can change it later in the message bar."
      SereinReplyBubble(text: words) {
        Text(verbatim: words).font(AssistantType.bubble).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
      }
      // At most the picker's own width: beside, the column is narrower than 360.
      ModelPickerView(agent: relay.agent, assistant: main) { picked() }
        .frame(maxWidth: KeelPicker.width)
        .frame(height: KeelPicker.height)
        .assistantCard(p)
    }
    .transition(Motion.arrival(reduce))
  }
  private func picked() {
    let main: String = relay.team.main?.id ?? RelayTeam.mainID
    pickedModel = ModelPill.name(relay.chatEngine(ofAssistant: main))
    picking = nil
    // The welcome stays in this chat with its last message (WelcomeMoment), though it is done.
    WelcomeMoment.pickedIn = relay.threadID
    RelayOrchestrator.setSetting(true, forKey: Self.welcomedKey)
  }
  private func pickedBlock(_ model: String) -> some View {
    VStack(alignment: .leading, spacing: AssistantMetrics.cardGap) {
      let words: String = "Done. I think with \(model) now."
      SereinReplyBubble(text: words) { Text(verbatim: words).font(AssistantType.bubble) }
      QuickReplyChips(chips: Self.pickedChips, send: ask)
    }
    .transition(Motion.arrival(reduce))
  }
}

/// The chat where the welcome's model pick happened. The pick saves `welcomed` at once, but that
/// chat keeps the welcome (its first message, "Done. I think with {Model} now." and the chips)
/// while it is empty, so the last message does not go when the chat draws again. Another chat, or
/// the person's first words here, ends it.
@MainActor enum WelcomeMoment {
  static var pickedIn: String?
  /// The welcome greets in `thread`: before the first pick, or in the chat where it just happened.
  static func greets(in thread: String) -> Bool { !WelcomeFlowView.welcomed || pickedIn == thread }
}

/// The top of an empty chat with no AI app: Serein's mark, a greeting by the hour and one plain
/// sentence on what happens next, centred, so the first screen explains itself.
struct WelcomeHero: View {
  /// The first launch says hello; later it says why Serein is waiting.
  var firstMessage: Bool
  @Environment(\.palette) private var p
  var body: some View {
    VStack(spacing: 10) {
      SereinHologramMark(size: 52, glows: true)
      Text(firstMessage ? "Welcome to Serein" : SereinGreeting.text().replacingOccurrences(of: ".", with: ""))
        .font(UIStyle.font(24, weight: .semibold)).tracking(-0.4).foregroundStyle(p.ink)
        .accessibilityAddTraits(.isHeader)
      Text("Serein thinks with an AI app you already use. Connect one below and you can start chatting.")
        .font(AssistantType.body).foregroundStyle(p.secondary).multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
    }.frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, 4)
      .accessibilityElement(children: .combine)
  }
}

/// Under the setup: what Serein can do once connected, in one quiet line, so a newcomer knows
/// why to bother. Words only; nothing here is clickable before an AI app can think.
struct WelcomeAfterward: View {
  @Environment(\.palette) private var p
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Step 2 · Then Serein can").font(AssistantType.meta).foregroundStyle(p.faint)
      Text("Answer plain questions, keep your goals on track with reminders, and tell you when a page changes.")
        .font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: AssistantMetrics.cardWide, alignment: .leading).padding(.top, 6)
      .accessibilityElement(children: .combine)
  }
}
