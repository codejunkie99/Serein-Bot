import SereinCore
import SwiftUI

/// Serein's empty chat with no AI app connected (F10): what Serein needs, and one button per AI
/// app that starts its install or sign-in right away (`SereinConnect`). Full: centred under the
/// title, as the examples are; beside: flush left in the column.
struct SereinConnectCard: View {
  let full: Bool
  @Environment(\.palette) private var p
  var body: some View {
    VStack(alignment: full ? .center : .leading, spacing: 10) {
      Text("Connect an AI app to get started").font(UIStyle.font(16, weight: .medium)).accessibilityAddTraits(.isHeader)
      // The accounts people already have, not just the tools' names: Codex is ChatGPT's.
      Text("Serein thinks with an AI app on your Mac. Claude Code uses your Claude account, and Codex your ChatGPT account. It takes about a minute.")
        .font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { buttons }
        VStack(alignment: full ? .center : .leading, spacing: 8) { buttons }
      }.padding(.top, 4)
      Button { SereinConnect.shared.showOtherApps() } label: {
        Text("Other AI apps…").font(UIStyle.meta).foregroundStyle(p.accent)
      }.buttonStyle(.pressable).fixedSize()
        .help("Every AI app Serein can think with")
      Text("Serein installs it and opens a sign-in page in your browser. You never type a password into Serein.")
        .font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    }.multilineTextAlignment(full ? .center : .leading)
      .frame(maxWidth: full ? 520 : nil).frame(maxWidth: full ? .infinity : nil)
      .padding(.vertical, 16)
      .accessibilityElement(children: .contain)
  }
  @ViewBuilder private var buttons: some View {
    // Each app's mark in the button's own ink, as sign-in buttons carry theirs.
    Button { SereinConnect.shared.start(.claude) } label: { Self.label("Connect Claude Code", .claude) }
      .buttonStyle(PrimaryButton()).fixedSize()
      .help("Install Claude Code if it is missing, then sign in with your Claude account")
    Button { SereinConnect.shared.start(.codex) } label: {
      Self.label("Connect Codex", .codex).font(UIStyle.font(12, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2)
    }.buttonStyle(QuietButton())
      .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
      .fixedSize()
      .help("Install Codex if it is missing, then sign in with your ChatGPT account")
  }
  private static func label(_ title: String, _ provider: Provider) -> some View {
    HStack(spacing: 6) {
      InterfaceIcon(systemName: HarnessGlyph.symbol(provider), size: 12).accessibilityHidden(true)
      Text(title)
    }
  }
}

/// Messages Serein holds (F10, F12): your bubble with its chip (“Waiting to send”, or “Sends when
/// you are back online”; “Not sent” once it is too old to send by itself), then Serein's own
/// line: why it waits, or, written more than 30 minutes ago, “You asked this earlier” with Send
/// now and Discard. After a held message goes, the line says so once. The orchestrator wakes the
/// view once when a message turns 30 minutes old (no clock runs). A turn the AI app's usage limit
/// stopped shows in its own chat only, with “<App>'s limit resets at 14:20. Serein will continue
/// then.” (or no time, when the app named none) and Continue now, Use another AI app… and Cancel.
struct SereinHeldRows: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject private var network = NetworkMonitor.shared
  @ObservedObject private var agent: AgentModel
  /// A Connect that installs or signs in an app holds messages until it finishes, so the row
  /// reads “Waiting to send” until the message really goes (`AgentModel.canThink`).
  @ObservedObject private var connect = SereinConnect.shared
  @Environment(\.palette) private var p
  init(relay: RelayOrchestrator) {
    self.relay = relay
    agent = relay.agent
  }
  var body: some View {
    let connected = SereinSurface.connected(agent) && !SereinChatSetup.shared.requiresChoice(relay)
    let online = SereinSurface.online(network.online)
    ForEach(relay.heldHere) { item in
      let next = HeldMessage.next(item.message, connected: connected, online: online, now: Date())
      HStack {
        Spacer(minLength: 80)
        VStack(alignment: .trailing, spacing: 4) {
          Text(item.message.text).textSelection(.enabled).padding(.horizontal, 12).padding(.vertical, 8)
            .background(p.bubble, in: RoundedRectangle(cornerRadius: UIStyle.bubbleRadius))
          // What happens next: it waits (and why), or, written long ago, it was not sent.
          HStack(spacing: 5) {
            InterfaceIcon(systemName: next == .stale ? "xmark.circle" : item.message.reason == .offline ? "wifi.slash" : "clock", size: 10)
            Text(HeldMessage.chip(next)).font(UIStyle.meta).lineLimit(1)
          }.foregroundStyle(p.secondary).padding(.horizontal, 8).frame(height: 22)
            .overlay(Capsule().strokeBorder(p.line))
            .accessibilityElement(children: .combine)
        }
      }
      systemLine(item, next: next)
    }
    if let notice = relay.heldNotice {
      Text(notice).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
  /// Connect, as the header's connect pill offers it: a choice, never an install by itself.
  private func connectMenu(label: String, help: String) -> some View {
    Menu {
      let menu = SereinConnect.menuChoices
      // A system menu row is one line of words, so each says its app and its next step.
      ForEach(menu.here + menu.other) { choice in
        Button(SereinConnect.nextStep(choice).map { "\(choice.name) · \($0)" } ?? choice.name) {
          SereinConnect.shared.start(choice.driver)
        }
      }
      Divider()
      Button("Other AI Apps…") { SereinConnect.shared.showOtherApps() }
    } label: {
      Text(label).font(UIStyle.metaStrong).foregroundStyle(p.accent)
    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .help(help)
      .accessibilityLabel("\(label). \(help)")
  }
  /// Serein's own words, not a model's: a quiet line with the petal. Its actions follow the words
  /// on the same line when it fits; otherwise they sit on a line of their own under them.
  @ViewBuilder private func systemLine(_ item: RelayOrchestrator.Held, next: HeldMessage.Next) -> some View {
    switch next {
    case .stale:
      systemLine(HeldMessage.staleLine(item.message.text)) {
        action("Send now", help: "Ask Serein this now") { relay.sendHeld(item.id) }
        Text("·").font(UIStyle.meta).foregroundStyle(p.secondary).accessibilityHidden(true)
        action("Discard", help: "Do not send this") { relay.discardHeld(item.id) }
      }
    case .wait(.usageLimit):
      // The app and the time come from the app's own answer (UsageLimit), never a guess.
      systemLine(UsageLimit.line(app: relay.limitApp(item), resetsAt: item.message.resetsAt, waits: item.waits,
                                 again: item.retried, now: Date())) {
        action("Continue now", help: "Send this again now") { relay.continueHeld(item.id) }
        Text("·").font(UIStyle.meta).foregroundStyle(p.secondary).accessibilityHidden(true)
        if relay.elsewhereOffered[item.id] == "" {
          // Nothing else can answer: connecting one moves this message to it (`releaseHeld`).
          connectMenu(label: "Connect another AI app", help: "Connect another AI app or model to continue now")
        } else {
          action("Use another AI app…", help: "Continue on another AI app. A move that could cost you asks first") {
            relay.continueElsewhere(item.id, byPerson: true)
          }
        }
        Text("·").font(UIStyle.meta).foregroundStyle(p.secondary).accessibilityHidden(true)
        action("Cancel", help: "Do not send this") { relay.discardHeld(item.id) }
      }
    case .wait(let reason):
      // Connect is a choice, as the header's connect pill is: never an install by itself.
      systemLine(HeldMessage.waitingLine(reason)) {
        if reason == .noAI {
          connectMenu(label: "Connect", help: "Choose an AI app to connect")
        }
      }
    case .send:
      systemLine(HeldMessage.sendingLine(item.message.reason)) { EmptyView() }
    }
  }
  private func systemLine<Actions: View>(_ words: String, @ViewBuilder actions: () -> Actions) -> some View {
    let actions = actions()
    let text = Text(words).font(UIStyle.meta).foregroundStyle(p.ink)
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        SereinMark(size: 11).accessibilityHidden(true)
        text.fixedSize()
        actions
        Spacer(minLength: 0)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          SereinMark(size: 11).accessibilityHidden(true)
          text.fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        HStack(spacing: 8) { actions }.padding(.leading, 19)
      }
    }.padding(.vertical, 2)
      .accessibilityElement(children: .contain)
  }
  private func action(_ title: String, help: String, _ run: @escaping () -> Void) -> some View {
    Button(action: run) { Text(title).font(UIStyle.metaStrong).foregroundStyle(p.accent) }
      .buttonStyle(QuietButton()).fixedSize().help(help)
  }
}
