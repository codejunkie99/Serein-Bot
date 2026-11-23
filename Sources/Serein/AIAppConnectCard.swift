import SereinCore
import SwiftUI

/// An AI app that cannot answer yet, in the chat (board 19), in the parts of an app's connect card
/// (`ConnectChatCard`): Serein's line, the app's mark at 32, its next step ("Sign in to Claude
/// Code", "Install Claude Code", "Update Claude Code") over one line on what happens, and one
/// solid button. The button starts that app's own Connect job (`SereinConnect`), the same for every
/// harness; its sheet keeps the terminal behind Show details. While the job runs the card waits
/// ("Waiting for {App}…"); a step that did not finish says so in `danger` with Try again. "Or use
/// another AI app" opens Serein's model picker for the assistant, where a pick follows the usual
/// rules for a move that can change who pays. Once the app can answer, the card is the line
/// "{App} is connected", and the message it holds goes (`RelayOrchestrator.releaseHeld`), or
/// waits for Continue when it was written over 30 minutes ago. Nothing here reads or types a
/// password.
struct AIAppConnectCard: View {
  let provider: Provider
  @ObservedObject var agent: AgentModel
  /// The assistant whose model "Or use another AI app" changes.
  var assistant: String? = nil
  /// Continue, on a card that holds a message (`ConnectCards`); nil for held messages, which go by
  /// themselves or wait for Send now.
  var onContinue: (() -> Void)? = nil
  @ObservedObject private var connect = SereinConnect.shared
  @ObservedObject private var registry = HarnessRegistry.shared
  @State private var picking = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects

  private var name: String { provider.name }
  /// The Connect job, while it is this app's.
  private var flow: SereinConnect.Flow? {
    guard let flow = connect.flow, flow.driver == provider.driver else { return nil }
    return flow
  }
  private var waiting: Bool {
    guard let flow else { return false }
    return !flow.phase.failed && flow.phase != .connected
  }
  /// The step the card is about: the running or failed job's, else the app's next step.
  private var step: HarnessPrimaryAction {
    switch flow?.phase {
    case .installing?, .failed(.install, _)?: return .install
    case .signingIn?, .failed(.signIn, _)?: return .signIn
    case .updating?, .failed(.update, _)?: return .update
    default: return HarnessPrimaryAction.of(registry.snapshot(provider))
    }
  }
  private var title: String { HarnessParse.signInTitle(name, action: step) }

  var body: some View {
    let ready: Bool = agent.canThink(provider)
    VStack(alignment: .leading, spacing: 8) {
      if ready {
        if let onContinue { readyRow(onContinue) } else { connectedLine }
      } else {
        Text("I need an AI app to answer you.").font(AssistantType.body).foregroundStyle(p.ink)
        appRow
        others
      }
    }
    .frame(maxWidth: AssistantMetrics.cardWide, alignment: .leading)
    .animation(Motion.swapping(systemReduceMotion || previewReducedEffects), value: ready)
    .modifier(PrimaryCardKey(key: "aiapp:" + provider.rawValue, active: !ready && !waiting, press: start))
    // Ready by a sign-in or by another app picked here (no check of the app follows a pick):
    // what waits for it goes now.
    .onChange(of: ready) { _, now in if now { RelayOrchestrator.shared?.releaseHeld() } }
  }

  private func start() {
    if let driver = provider.driver { SereinConnect.shared.start(driver) } else { TeamSheets.openSettings(("Agents", "Settings › AI apps")) }
  }

  // MARK: the app's row: the step, the wait, a failure

  private var appRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        ModelMonogram(provider: provider, size: 32)
        words.frame(minWidth: 0, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
        trailing
      }
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 12) {
          ModelMonogram(provider: provider, size: 32)
          words.frame(maxWidth: .infinity, alignment: .leading)
        }
        trailing.frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding(.vertical, 12).padding(.horizontal, 14)
    .assistantCard(p)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
  private var words: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: title).font(AssistantType.name).foregroundStyle(p.ink)
      if let failure {
        Text(verbatim: failure).font(AssistantType.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
          .onAppear { AccessibilityNotification.Announcement(failure).post() }
      } else {
        Text(verbatim: detail).font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
  /// Why the last step did not finish, in the connect sheet's words with its job's reason, or nil.
  private var failure: String? {
    guard case .failed(let failed, let missing)? = flow?.phase else { return nil }
    if !missing.isEmpty { return "This Mac needs \(missing.joined(separator: " or ")) to install \(name)." }
    return SereinConnect.failed(name, step: failed, reason: flow?.reason)
  }
  private var detail: String {
    switch flow?.phase {
    case .signingIn?:
      return provider.driver.map { HarnessCommands.signsInInTerminal($0, version: HarnessRegistry.shared.snapshots[$0]?.version) } == true
        ? "Answer its questions in the window that opened." : "Finish in the browser window that opened."
    case .installing?: return "Installing it on this Mac. The sign-in comes next."
    case .updating?: return "Updating it on this Mac."
    case .checking?: return "Checking \(name) on this Mac."
    default: break
    }
    switch step {
    case .install: return "Installs it on this Mac, then opens its sign-in."
    case .update: return "Updates it on this Mac, so Serein can use it."
    default: return "Opens \(name)'s own sign-in in your browser. Serein never sees your password."
    }
  }
  @ViewBuilder private var trailing: some View {
    if waiting {
      ShimmerText(text: waitWords)
    } else if failure != nil {
      ChatCardSolidButton(title: "Try again", action: start)
    } else {
      ChatCardSolidButton(title: Self.button(step), action: start)
    }
  }
  private var waitWords: String {
    switch flow?.phase {
    case .installing?: return "Installing \(name)…"
    case .updating?: return "Updating \(name)…"
    case .checking?: return "Checking \(name)…"
    default: return "Waiting for \(name)…"
    }
  }
  static func button(_ step: HarnessPrimaryAction) -> String {
    switch step {
    case .install: return "Install"
    case .signIn: return "Sign in"
    case .update: return "Update"
    case .checking, .ready: return "Connect"
    }
  }

  // MARK: another AI app

  /// "Or use another AI app", with the marks of up to three others: Serein's model picker for the
  /// assistant, in a popover.
  private var others: some View {
    Button { picking.toggle() } label: {
      HStack(spacing: 6) {
        Text("Or use").foregroundStyle(p.secondary)
        HStack(spacing: -4) {
          ForEach(Self.others(excluding: provider), id: \.self) { driver in
            ModelMonogram(provider: Provider(driver), size: 16)
          }
        }
        Text("another AI app").foregroundStyle(p.accent)
      }
      .font(AssistantType.meta).linkTarget()
    }
    .buttonStyle(.pressable).fixedSize()
    .padding(.leading, 4)
    .accessibilityLabel("Use another AI app")
    // Above the link: the card sits on the composer, and a picker opening down runs off the window.
    .popover(isPresented: $picking, arrowEdge: .top) {
      ModelPickerView(agent: agent, chat: nil, assistant: assistant) { picking = false }
        .frame(width: KeelPicker.width, height: KeelPicker.height)
        .background(KeelPicker.surface(p.isDark))
        .environment(\.palette, p)
    }
  }
  /// Up to three other AI apps for the row's marks: those on this Mac first, in driver order.
  @MainActor static func others(excluding provider: Provider) -> [HarnessDriver] {
    let registry = HarnessRegistry.shared
    let rest: [HarnessDriver] = HarnessDriver.allCases.filter { $0 != provider.driver }
    let installed: [HarnessDriver] = rest.filter { registry.snapshots[$0]?.installed == true }
    return Array((installed + rest.filter { !installed.contains($0) }).prefix(3))
  }

  // MARK: connected

  private func readyRow(_ carryOn: @escaping () -> Void) -> some View {
    HStack(spacing: 12) {
      ModelMonogram(provider: provider, size: 32)
      Text(verbatim: "\(name) is connected").font(AssistantType.name).foregroundStyle(p.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
      ChatCardSolidButton(title: "Continue", action: carryOn)
        .help("Send your message again, as a new message")
    }
    .padding(.vertical, 12).padding(.horizontal, 14)
    .assistantCard(p)
  }
  /// The centred line (`chat-system`) once the app can answer, with a check.
  private var connectedLine: some View {
    let words = "\(name) is connected"
    return HStack(spacing: 6) {
      ModelMonogram(provider: provider, size: 12)
      InterfaceIcon(systemName: "checkmark", size: 10).foregroundStyle(p.success)
      Text(verbatim: words)
    }
    .font(AssistantType.meta).foregroundStyle(p.secondary)
    .padding(.vertical, 6).padding(.horizontal, 12)
    .background(p.track, in: Capsule())
    .frame(maxWidth: .infinity)
    .onAppear { AccessibilityNotification.Announcement(words).post() }
  }
}
