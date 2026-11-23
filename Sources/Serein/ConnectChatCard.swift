import AppKit
import Combine
import SereinCore
import SwiftUI

/// One connect card in the chat (SPEC.md 2.8, the connect boards), driven by `ConnectFlow`: the
/// primer ("Connect Gmail", Connect and Not now); the Composio key, when none is kept yet, in a
/// native `SecureField` saved to this Mac's Keychain through the existing Composio key path
/// (`ComposioApps.turnOn(key:)`) and cleared at once; the wait, with the shimmer, while the app's
/// own sign-in is open in the browser; then "Gmail is connected" as a line, and the person's words
/// go on by themselves once. A failure says why and offers Try again. The flow and this model hold
/// no key: the field's text lives in the view until Save and never reaches a model.
@MainActor final class ConnectCardModel: ObservableObject {
  @Published private(set) var flow: ConnectFlow
  /// The pasted key did not answer: the field cleared and says so.
  @Published private(set) var keyRefused = false
  @Published private(set) var savingKey = false
  /// When the sign-in opened, for "Did the window close?" after 30 seconds.
  @Published private(set) var openedAt: Date?
  /// Not now: the card is one line.
  @Published private(set) var declined = false
  private var poll: Task<Void, Never>?
  private let carryOn: () -> Void
  private var follow: Set<AnyCancellable> = []

  init(link: ConnectLink, card: String, carryOn: @escaping () -> Void) {
    flow = ConnectFlow(card: card, link: link)
    self.carryOn = carryOn
    // Composio's accounts as they change, and Serein coming back from the browser: a sign-in
    // started from this card shows here as soon as it finishes, without reopening. While it waits
    // that is the card's usual carry-on; after the wait ran out it only shows the app connected,
    // with Continue for the person to press. A card nobody pressed is left as it is.
    ComposioApps.shared.$accounts.receive(on: RunLoop.main)
      .sink { [weak self] accounts in self?.accountsChanged(accounts) }.store(in: &follow)
    ConnectionWatch.shared.$generation.dropFirst().receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.cameBack() }.store(in: &follow)
  }

  private func accountsChanged(_ accounts: [ConnectedApps.Account]) {
    switch flow.state {
    case .opening, .waiting, .failed: break
    case .primer, .needsKey, .ready: return
    }
    guard ComposioApps.available, accounts.contains(where: { $0.app == flow.link.app && $0.active }) else { return }
    poll?.cancel()
    send(.statusReady)
  }
  /// Back from the browser while waiting: read the status now rather than at the next tick.
  private func cameBack() {
    switch flow.state {
    case .waiting: schedulePoll(0)
    case .failed: ConnectionWatch.shared.refreshAccounts()
    default: break
    }
  }

  func connect() {
    declined = false
    send(.connect(keyKept: ComposioApps.available))
  }
  func notNow() {
    send(.cancelled)
    poll?.cancel()
    declined = true
  }
  func continueNow() { send(.continued) }
  /// The window closed: the sign-in opens again.
  func reopen() {
    send(.cancelled)
    connect()
  }
  /// Checks the key with one listing and keeps it in the Keychain (`ComposioApps.turnOn`). The
  /// caller clears its field whatever the answer.
  func saveKey(_ key: String) {
    guard !savingKey else { return }
    savingKey = true
    keyRefused = false
    Task { [weak self] in
      do {
        try await ComposioApps.shared.turnOn(key: key)
        self?.savingKey = false
        self?.send(.keySaved)
      } catch {
        self?.savingKey = false
        self?.keyRefused = true
      }
    }
  }

  private func send(_ event: ConnectFlow.Event) {
    var next = flow
    let effect: ConnectFlow.Effect = next.next(event)
    flow = next
    run(effect)
  }
  private func run(_ effect: ConnectFlow.Effect) {
    switch effect {
    case .nothing:
      break
    case .openSignIn(let link):
      open(link)
    case .poll(let after):
      schedulePoll(after)
    case .carryOn:
      // A 0.4-second beat on "connected", then the paused words go again, once.
      let go = carryOn
      Task {
        try? await Task.sleep(nanoseconds: 400_000_000)
        go()
      }
    }
  }
  /// Composio's hosted sign-in in the person's default browser (never an agent tab). The call
  /// itself watches for the new account; a failure ends the wait with its plain reason.
  private func open(_ link: ConnectLink) {
    openedAt = Date()
    let app: String = link.app
    Task { [weak self] in
      do {
        try await ComposioApps.shared.connect(app: app)
      } catch {
        self?.send(.statusFailed(reason: error.localizedDescription))
      }
    }
    send(.linkOpened)
  }
  /// Reads the accounts Composio's own watch keeps fresh, every 2 seconds, for at most 3 minutes.
  private func schedulePoll(_ after: TimeInterval) {
    poll?.cancel()
    let app: String = flow.link.app
    poll = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(max(0, after) * 1_000_000_000))
      guard !Task.isCancelled else { return }
      let ready: Bool = ComposioApps.available && ComposioApps.shared.accounts.contains { $0.app == app && $0.active }
      self?.send(ready ? .statusReady : .statusWaiting)
    }
  }
}

struct ConnectChatCard: View {
  /// Who uses the app, for the primer's line.
  let assistant: String
  /// A message's connect link (`AgentMessage.connect`, board 13): the primer is the one-line pill
  /// ("{App} is not connected yet." and "Connect {App}"); the steps after it are the cards.
  let pill: Bool
  @StateObject private var model: ConnectCardModel
  /// The key, only here, only until Save.
  @State private var key = ""
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  static let keyPage = URL(string: "https://dashboard.composio.dev")

  init(link: ConnectLink, card: String, assistant: String, pill: Bool = false, carryOn: @escaping () -> Void) {
    self.assistant = assistant
    self.pill = pill
    _model = StateObject(wrappedValue: ConnectCardModel(link: link, card: card, carryOn: carryOn))
  }
  private var reduce: Bool { systemReduceMotion || previewReducedEffects }
  private var app: String { model.flow.link.name }

  var body: some View {
    Group {
      if model.declined {
        line("Not connected.", check: false)
      } else {
        switch model.flow.state {
        case .needsKey: keyFrame
        case .ready:
          if model.flow.carriedOn { line("\(app) is connected", check: true) } else { readyRow }
        case .primer:
          if pill { pillRow } else { appRow }
        case .opening, .waiting, .failed: appRow
        }
      }
    }
    .animation(Motion.swapping(reduce), value: model.flow)
    .animation(Motion.swapping(reduce), value: model.declined)
    .pressGuard(stepKey)
    // ⌘Return in an empty message bar presses this card's primary button while it is the newest
    // card that waits; Esc on the focused card presses Not now (SPEC.md 2.0 keys).
    .modifier(PrimaryCardKey(key: "connect:" + model.flow.card, active: primary != nil, press: { [cardModel = self.model] in
      ConnectChatCard.pressPrimary(cardModel)
    }))
    .onExitCommand {
      if case .primer = model.flow.state, !model.declined { model.notNow() }
    }
  }
  /// The step's primary button, for ⌘Return: Connect, Try again's Connect, or Continue.
  private var primary: String? {
    if model.declined { return nil }
    switch model.flow.state {
    case .primer, .failed: return "connect"
    case .ready: return model.flow.carriedOn || !model.flow.buttonEnabled ? nil : "continue"
    case .needsKey, .opening, .waiting: return nil
    }
  }
  @MainActor static func pressPrimary(_ model: ConnectCardModel) {
    if model.declined { return }
    switch model.flow.state {
    case .primer, .failed: model.connect()
    case .ready: if !model.flow.carriedOn && model.flow.buttonEnabled { model.continueNow() }
    case .needsKey, .opening, .waiting: break
    }
  }
  /// Changes with each step, so every new step arms the press guard again.
  private var stepKey: String {
    switch model.flow.state {
    case .primer: return "primer"
    case .needsKey: return "key"
    case .opening, .waiting: return "waiting"
    case .ready: return "ready"
    case .failed: return "failed"
    }
  }

  // MARK: the pill (board 13)

  /// The app's logo on a 28-point tile (`--p05`, radius 8), "{App} is not connected yet." in 12,
  /// and a solid "Connect {App}" 28 high, in one capsule at most 440 wide on `overlay` with a
  /// 1-point `line` ring; the words sit centred.
  private var pillRow: some View {
    // The same card as a one-click app's (OneClickConnectPill): its logo tile, its name, and Connect.
    HStack(spacing: 12) {
      AppLogoTile(id: model.flow.link.app, name: app, size: 34)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: app).font(AssistantType.name).foregroundStyle(p.ink).lineLimit(1)
        Text("Not connected").font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
      solidButton("Connect") { model.connect() }
    }
    .padding(.leading, 10).padding(.trailing, 10).padding(.vertical, 10)
    .frame(maxWidth: 340)
    .background(p.overlay, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.line, lineWidth: 1))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(app) is not connected yet")
  }

  // MARK: the app's row: primer, wait, failure

  /// One row while there is room for the words beside the buttons; in a narrow column (beside) the
  /// buttons or the wait go under the words, so the title never wraps to three lines.
  private var appRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        BrandLogo(Brand.app(model.flow.link.app), size: 32, name: app, round: true)
        appWords.frame(minWidth: 0, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
        trailing
      }
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 12) {
          BrandLogo(Brand.app(model.flow.link.app), size: 32, name: app, round: true)
          appWords.frame(maxWidth: .infinity, alignment: .leading)
        }
        trailing.frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding(.vertical, 12).padding(.horizontal, 14)
    .frame(maxWidth: AssistantMetrics.cardWide)
    .assistantCard(p)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Connect \(app)")
  }
  private var appWords: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: "Connect \(app)").font(AssistantType.name).foregroundStyle(p.ink)
      detail
    }
  }
  @ViewBuilder private var detail: some View {
    switch model.flow.state {
    case .failed(let reason):
      Text(verbatim: reason).font(AssistantType.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
        .onAppear { AccessibilityNotification.Announcement(reason).post() }
    case .opening, .waiting:
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: model.flow.title).font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
        WindowClosedLine(openedAt: model.openedAt) { model.reopen() }
      }
    default:
      Text(verbatim: "\(assistant) uses \(app) for this. Sending and changes always ask you first.")
        .font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
  @ViewBuilder private var trailing: some View {
    switch model.flow.state {
    case .opening, .waiting:
      ShimmerText(text: model.flow.button)
    case .failed:
      solidButton(model.flow.button) { model.connect() }
    default:
      HStack(spacing: 10) {
        Button { model.notNow() } label: {
          Text("Not now").font(AssistantType.meta).foregroundStyle(p.secondary).linkTarget()
        }.buttonStyle(.pressable)
        solidButton(model.flow.button) { model.connect() }
      }
    }
  }
  private var readyRow: some View {
    HStack(spacing: 12) {
      BrandLogo(Brand.app(model.flow.link.app), size: 32, name: app, round: true)
      Text(verbatim: model.flow.title).font(AssistantType.name).foregroundStyle(p.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
      solidButton(model.flow.button) { model.continueNow() }.disabled(!model.flow.buttonEnabled)
    }
    .padding(.vertical, 12).padding(.horizontal, 14)
    .frame(maxWidth: AssistantMetrics.cardWide)
    .assistantCard(p)
  }

  // MARK: the key frame

  /// The Composio key (`auth-signin` frame): one masked field with a lock, no show button,
  /// "Where do I find it?", Save, and "Kept in this Mac's Keychain only." The field clears at once
  /// after Save, whatever the answer.
  private var keyFrame: some View {
    let ring = RoundedRectangle(cornerRadius: 12, style: .continuous)
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        BrandLogo(.composio, size: 22)
        Text(verbatim: model.flow.title).font(AssistantType.name).foregroundStyle(p.ink)
        Spacer(minLength: 0)
        if let page = Self.keyPage {
          Button { _ = NSWorkspace.shared.open(page) } label: {
            Text("Where do I find it?").font(AssistantType.meta).foregroundStyle(p.accent).linkTarget()
          }.buttonStyle(.pressable)
        }
      }
      HStack(spacing: 10) {
        InterfaceIcon(systemName: "lock", size: 15).foregroundStyle(p.secondary).frame(width: 20).accessibilityHidden(true)
        SecureField("Paste your key", text: $key)
          .textFieldStyle(.plain).font(AssistantType.body)
          .onSubmit(save)
          .accessibilityLabel("Composio key")
          .accessibilityHint(ConnectFlow.keyNote)
      }
      .padding(.horizontal, 14).frame(height: AssistantMetrics.barHeight)
      .overlay(ring.strokeBorder(p.wash(0.15), lineWidth: 1))
      if model.keyRefused {
        Text("That key did not work. Check it and paste it again.").font(AssistantType.meta).foregroundStyle(p.danger)
      }
      HStack {
        Text(ConnectFlow.keyNote).font(AssistantType.meta).foregroundStyle(p.secondary)
        Spacer(minLength: 8)
        if model.savingKey {
          ShimmerText(text: "Saving…")
        } else {
          solidButton(model.flow.button, action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: AssistantMetrics.cardWide)
    .assistantCard(p, radius: AssistantMetrics.signInRadius)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Composio key")
  }
  private func save() {
    let pasted: String = key
    key = ""
    guard !pasted.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    model.saveKey(pasted)
  }

  // MARK: parts

  private func solidButton(_ title: String, action: @escaping () -> Void) -> some View {
    ChatCardSolidButton(title: title, action: action)
  }
  /// A centred line (`chat-system`) once the card is done, with a check that pops on connected.
  private func line(_ words: String, check: Bool) -> some View {
    HStack(spacing: 6) {
      if check {
        BrandLogo(Brand.app(model.flow.link.app), size: 12, name: app, round: true)
        InterfaceIcon(systemName: "checkmark", size: 10).foregroundStyle(p.success)
          .transition(reduce ? AnyTransition.opacity : AnyTransition.scale.animation(Motion.pop))
      }
      Text(verbatim: words)
    }
    .font(AssistantType.meta).foregroundStyle(p.secondary)
    .padding(.vertical, 6).padding(.horizontal, 12)
    .background(p.track, in: Capsule())
    .frame(maxWidth: .infinity)
    .onAppear { AccessibilityNotification.Announcement(words).post() }
  }
}

/// A connect card's solid button (`ConnectChatCard`, `AIAppConnectCard`): `meta` on the solid
/// plate, at least 28 high.
struct ChatCardSolidButton: View {
  let title: String
  let action: () -> Void
  @Environment(\.palette) private var p
  var body: some View {
    Button(action: action) {
      Text(title).font(AssistantType.meta).foregroundStyle(p.onSolid)
        .padding(.horizontal, 14).frame(minHeight: 28)
        .background(p.solid, in: Capsule())
    }.buttonStyle(AssistantPressStyle()).fixedSize()
  }
}

/// After 30 seconds of waiting: "Did the window close? Open it again."
private struct WindowClosedLine: View {
  let openedAt: Date?
  let reopen: () -> Void
  @State private var late = false
  @Environment(\.palette) private var p
  var body: some View {
    Group {
      if late {
        HStack(spacing: 4) {
          Text("Did the window close?").foregroundStyle(p.secondary)
          Button(action: reopen) { Text("Open it again").foregroundStyle(p.accent).linkTarget() }.buttonStyle(.pressable)
        }.font(AssistantType.meta)
      }
    }
    .task(id: openedAt) {
      late = false
      guard let openedAt else { return }
      let left: TimeInterval = 30 - Date().timeIntervalSince(openedAt)
      if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
      late = !Task.isCancelled
    }
  }
}
