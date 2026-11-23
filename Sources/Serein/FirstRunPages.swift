import AppKit
import SereinCore
import SwiftUI

extension FirstRunPage {
  /// The page this launch opens on on startup; nil opens the app. A Mac whose setup is finished, or whose
  /// person skipped the setup chat, opens the app, as the setup chat's own first-run rule did.
  @MainActor static func opening() -> FirstRunPage? {
    if RunMode.previewing {
      FirstRunPreview.grant()
      return FirstRunPreview.page
    }
    guard !RunMode.automated, !RunMode.stress, let relay = RelayOrchestrator.shared else { return nil }
    return page(setupFinished: !SetupProgress.needsFirstRun() || !SereinChatSetup.shared.needsInitialSetup(relay),
      saved: UserDefaults.standard.string(forKey: savedKey).flatMap(FirstRunPage.init(rawValue:)))
  }
  /// Checks and previews keep nothing.
  @MainActor static func remember(_ page: FirstRunPage?) {
    if !RunMode.automated { save(page, .standard) }
  }
}

/// One page in the first run's column.
struct FirstRunPageView: View {
  let page: FirstRunPage
  let relay: RelayOrchestrator
  let go: (FirstRunPage) -> Void
  let finish: () -> Void
  let deferred: () -> Void

  private var back: (() -> Void)? {
    guard let before = page.back() else { return nil }
    return { go(before) }
  }

  var body: some View {
    Group {
      switch page {
      case .connect: FirstRunConnect(relay: relay, back: back, next: { go(.mac) }, deferred: deferred)
      case .mac: FirstRunMac(back: back, finish: finish)
      }
    }
    .transition(.opacity)
  }
}

private struct FirstRunHeading: View {
  let title: String
  let words: String
  @Environment(\.palette) private var p
  var body: some View {
    VStack(spacing: 8) {
      Text(title).font(UIStyle.font(24, weight: .semibold)).tracking(-0.3).foregroundStyle(p.ink)
        .accessibilityAddTraits(.isHeader)
      Text(words).font(UIStyle.reading).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .multilineTextAlignment(.center).padding(.bottom, 24)
  }
}

/// The rows' plate.
private struct FirstRunCard<Content: View>: View {
  @ViewBuilder var content: Content
  @Environment(\.palette) private var p
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    VStack(spacing: 0) { content }
      .padding(.vertical, 4)
      .background(p.card, in: shape)
      .overlay(shape.strokeBorder(p.line, lineWidth: 1))
  }
}

private struct FirstRunMainButton: View {
  let words: String
  var lit = true
  var busy = false
  let run: () -> Void
  @Environment(\.palette) private var p
  var body: some View {
    Button(action: run) {
      ZStack {
        Text(words).opacity(busy ? 0 : 1)
        if busy { ProgressView().controlSize(.small).environment(\.colorScheme, p.isDark ? .light : .dark) }
      }
    }
    .buttonStyle(FirstRunButtonStyle(lit: lit || busy, height: UIStyle.wide(44))).disabled(!lit || busy)
    .accessibilityLabel(words)
  }
}

// MARK: connect

/// The AI app Serein thinks with: pick one, connect it in place, and Next pins it on Serein.
private struct FirstRunConnect: View {
  @ObservedObject var relay: RelayOrchestrator
  let back: (() -> Void)?
  let next: () -> Void
  let deferred: () -> Void
  @ObservedObject private var registry = HarnessRegistry.shared
  @ObservedObject private var connect = SereinConnect.shared
  @ObservedObject private var network = NetworkMonitor.shared
  @State private var picked: HarnessDriver?
  @State private var more = FirstRunPreview.seed == "more"
  @State private var pinning = false
  @State private var deferError: String?
  @Environment(\.palette) private var p

  private var choices: [WelcomeChoice] { Welcome.choices(snapshots: registry.snapshots, settings: registry.settings) }
  private var rows: [WelcomeChoice] {
    let menu = Welcome.connectMenu(snapshots: registry.snapshots, settings: registry.settings)
    let shown = menu.here + menu.other
    guard let picked, !shown.contains(where: { $0.driver == picked }), let extra = choices.first(where: { $0.driver == picked })
    else { return shown }
    return shown + [extra]
  }
  /// The person's pick, else the app being connected, else the first ready app.
  private var current: HarnessDriver? {
    picked ?? connect.flow?.driver ?? rows.first { ready($0.driver) }?.driver ?? rows.first?.driver
  }
  private var offline: Bool { !network.online || FirstRunPreview.seed == "offline" }
  /// The card `switchRoute` raises when the pick costs differently from Serein's current app; the chat it would
  /// show in is behind these pages.
  private var payCard: RelayOrchestrator.Approval? {
    relay.approvals.first { $0.effect == .pay && $0.button == "Switch" } ?? FirstRunPreview.payCard
  }

  var body: some View {
    VStack(spacing: 0) {
      FirstRunHeading(title: "Connect an AI app",
        words: "Choose the AI app Serein should use, or set it up later. If you need to sign in, you’ll do that with the provider.")
      HStack {
        Text("AI apps on this Mac").font(UIStyle.metaStrong).foregroundStyle(p.secondary)
        Spacer()
        Button("Check again") { Task { await registry.refreshAll(includeDisabled: true) } }.buttonStyle(QuietButton())
      }
      .padding(.bottom, 8)
      FirstRunCard {
        ForEach(Array(rows.enumerated()), id: \.element.id) { at, choice in
          if at > 0 { Divider().overlay(p.line) }
          row(choice)
        }
      }
      Button("More AI apps") { more = true }.buttonStyle(QuietButton()).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
      if offline {
        Text("I cannot reach the internet. I will look again when you are back online.")
          .font(UIStyle.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
      }
      if let payCard { pay(payCard).padding(.top, 12) }
      FirstRunMainButton(words: "Next", lit: current.map(ready) == true && payCard == nil, busy: pinning, run: pin)
        .padding(.top, 16)
      Text("You can change this for each assistant later.").font(UIStyle.meta).foregroundStyle(p.faint).padding(.top, 12)
      if payCard == nil && !pinning && !connect.inline {
        Button("Set up later") {
          let setup = SereinChatSetup.shared
          if setup.deferFirstRun(relay) {
            deferred()
          } else {
            deferError = setup.error ?? "Finish the current setup choice and try again."
          }
        }.buttonStyle(QuietButton())
        if let deferError { Text(deferError).role(.meta).accessibilityAddTraits(.updatesFrequently) }
      }
      if let back { Button("Back", action: back).buttonStyle(QuietButton()).padding(.top, 4) }
    }
    .sheet(isPresented: $more) {
      MoreAIApps(choices: choices) { driver in
        pick(driver)
        more = false
      }
    }
    // Launch checks only the chosen AI apps; the rest wait for a screen to ask (HarnessRegistry.deferred).
    // This page lists them all, so it asks, or their rows would read Checking… until Check again.
    .task { registry.probeDeferred() }
    // A finished sign-in or install leaves the row ready, with no Done to press.
    .onChange(of: connect.flow) { _, flow in
      guard let flow, flow.driver == current, flow.phase == .connected, !RunMode.previewing else { return }
      connect.dismiss()
    }
  }

  @ViewBuilder private func row(_ choice: WelcomeChoice) -> some View {
    let driver = choice.driver
    let on = driver == current
    let title = SereinConnect.account(driver) ?? choice.name
    // "Claude Max plan" under the title Claude reads "Max plan".
    let plan = registry.snapshots[driver]?.account.map { $0.hasPrefix(title + " ") ? String($0.dropFirst(title.count + 1)) : $0 }
    let detail = [title == choice.name ? nil : choice.name, plan].compactMap { $0 }.joined(separator: " · ")
    VStack(alignment: .leading, spacing: 10) {
      Button { pick(driver) } label: {
        HStack(spacing: 12) {
          Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.system(size: 14))
            .foregroundStyle(on ? p.ink : p.faint)
          ModelMonogram(provider: Provider(driver), size: 22).frame(width: 32, height: 32)
            .background(p.track, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          VStack(alignment: .leading, spacing: 2) {
            Text(title).font(UIStyle.bodyStrong).foregroundStyle(p.ink)
            if !detail.isEmpty { Text(detail).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1) }
          }
          Spacer(minLength: 12)
          AppStatePill(state: HarnessPrimaryAction.of(registry.snapshots[driver]), busy: working(driver))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain).accessibilityElement(children: .combine).accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
      if on { action(driver).padding(.leading, 26) }
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
  }

  private func working(_ driver: HarnessDriver) -> Bool {
    guard let flow = connect.flow, flow.driver == driver else { return false }
    return [.checking, .installing, .updating, .signingIn].contains(flow.phase)
  }
  /// Under the picked row: its connect flow, or the one step it needs.
  @ViewBuilder private func action(_ driver: HarnessDriver) -> some View {
    let state = HarnessPrimaryAction.of(registry.snapshots[driver])
    if connect.flow?.driver == driver, connect.inline {
      SereinConnectSheet(agent: relay.agent, inline: true)
    } else if [.install, .signIn, .update].contains(state) {
      Button(state.label) { connect.start(driver, inline: true) }.buttonStyle(PrimaryButton()).disabled(offline)
    } else if state == .ready, !registry.instance(driver).enabled {
      // Installed and signed in but turned off: connecting turns it on. A preview (`connect-off`)
      // turns it on in memory only and shows the connected step.
      Button("Connect") {
        if RunMode.previewing { FirstRunPreview.turnOn(driver) } else { connect.start(driver, inline: true) }
      }
      .buttonStyle(PrimaryButton())
    }
  }

  private func pay(_ card: RelayOrchestrator.Approval) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(card.title).font(UIStyle.bodyStrong).foregroundStyle(p.ink)
      Text(card.detail).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Spacer()
        Button(card.decline) { card.answer(.no) }.buttonStyle(QuietButton())
        Button(card.button) { card.answer(.yes) }.buttonStyle(PrimaryButton())
      }
    }
    .padding(16)
    .background(p.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.warning, lineWidth: 1))
  }

  private func ready(_ driver: HarnessDriver) -> Bool {
    // A preview's apps are fixtures the agent never found, so only their snapshot counts.
    guard !RunMode.previewing else {
      return registry.instance(driver).enabled
        && (registry.snapshots[driver].map { $0.installed && $0.signedIn != false && !$0.tooOld } ?? false)
    }
    return SereinChatSetup.shared.harnessReady(driver, relay: relay)
  }
  private func pick(_ driver: HarnessDriver) {
    if let flow = connect.flow, flow.driver != driver, connect.inline { connect.dismiss() }
    picked = driver
  }
  /// Pins the app's default route on Serein. A pick that costs differently asks first, on this page.
  private func pin() {
    guard let driver = current, !pinning else { return }
    // A preview never changes a setting.
    guard !RunMode.previewing else { return next() }
    guard let main = relay.team.mainProfileID,
      let route = relay.agent.routes(Provider(driver), models: [""]).first(where: \.selectable) else { return }
    pinning = true
    Task {
      let pinned = await relay.switchRoute(route, for: main)
      pinning = false
      if pinned { next() }
    }
  }
}

/// Where an AI app stands, in the same words on the connect page and in More AI apps.
private struct AppStatePill: View {
  let state: HarnessPrimaryAction
  var busy = false
  @Environment(\.palette) private var p

  var body: some View {
    if busy || state == .checking {
      ProgressView().controlSize(.small)
    } else {
      let words = switch state {
      case .install: "Not installed"
      case .signIn: "Signed out"
      case .update: "Update available"
      case .ready, .checking: "Connected"
      }
      Text(words).font(UIStyle.micro).foregroundStyle(state == .ready ? p.success : p.secondary)
        .padding(.horizontal, 8).frame(height: 20).background(p.track, in: Capsule()).fixedSize()
    }
  }
}

/// Every AI app Serein can think with, searchable. A pick selects its row on the connect page.
private struct MoreAIApps: View {
  let choices: [WelcomeChoice]
  let pick: (HarnessDriver) -> Void
  @ObservedObject private var registry = HarnessRegistry.shared
  @State private var search = ""
  @FocusState private var searching: Bool
  @Environment(\.palette) private var p
  @Environment(\.dismiss) private var dismiss

  private var shown: [WelcomeChoice] {
    let words = search.trimmingCharacters(in: .whitespaces)
    guard !words.isEmpty else { return choices }
    return choices.filter {
      $0.name.localizedCaseInsensitiveContains(words) || (SereinConnect.account($0.driver) ?? "").localizedCaseInsensitiveContains(words)
    }
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      VStack(alignment: .leading, spacing: 12) {
        Text("More AI apps").font(UIStyle.font(17, weight: .semibold)).foregroundStyle(p.ink)
        TextField("Search", text: $search).textFieldStyle(.plain).font(UIStyle.reading)
          .padding(.horizontal, 12).frame(height: UIStyle.wide(36))
          .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: UIStyle.rowRadius, style: .continuous).strokeBorder(p.borderStrong, lineWidth: 1))
          .accessibilityLabel("Search AI apps").focused($searching).onAppear { searching = true }
        ScrollView {
          VStack(spacing: 0) {
            ForEach(shown) { choice in
              Button { pick(choice.driver) } label: {
                HStack(spacing: 12) {
                  ModelMonogram(provider: Provider(choice.driver), size: 20).frame(width: 28, height: 28)
                    .background(p.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                  Text(choice.name).font(UIStyle.bodyStrong).foregroundStyle(p.ink)
                  Spacer(minLength: 12)
                  AppStatePill(state: HarnessPrimaryAction.of(registry.snapshots[choice.driver]))
                }
                .padding(.vertical, 8).contentShape(Rectangle())
              }
              .buttonStyle(.plain).accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
            }
            if shown.isEmpty {
              Text("No AI app by that name.").font(UIStyle.meta).foregroundStyle(p.secondary).padding(.vertical, 8)
            }
          }
        }
      }
      Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
        .buttonStyle(GhostChromeStyle()).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
    }
    .padding(20).frame(width: UIStyle.wide(420), height: UIStyle.wide(440))
    .background(p.raised)
  }
}

// MARK: Mac

/// Mac access, optional: Open Serein works with nothing allowed.
private struct FirstRunMac: View {
  let back: (() -> Void)?
  let finish: () -> Void
  @Environment(\.palette) private var p

  var body: some View {
    VStack(spacing: 0) {
      SereinAppTile(size: 72).padding(.bottom, 16)
      FirstRunHeading(title: "Let Serein work in your apps",
        words: "Optional. Serein clicks, types and reads the window of the app you ask it to use. Passwords go to a secure card you fill; the AI never sees them.")
      MacAccessRows(grants: [.accessibility, .screen])
        .padding(16)
        .background(p.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.line, lineWidth: 1))
      FirstRunMainButton(words: "Open Serein", run: finish).padding(.top, 16)
      if let back { Button("Back", action: back).buttonStyle(QuietButton()).padding(.top, 4) }
    }
  }
}

// MARK: previews

/// `--ui-preview start --ui-onboarding <seed>`:
/// `connect` (Claude Code ready on a Max plan, Codex signed out, Gemini CLI with an update, the rest
/// not installed); `connect-none` (nothing installed); `connecting` (Claude signing in, in place);
/// `connect-failed` (Claude's install failed); `connect-missing` (Codex cannot install: no npm or Homebrew);
/// `connect-off` (only Claude Code installed, signed in but turned off, so it offers Connect);
/// `offline`; `more` (the More AI apps sheet); `pay` (the pay card); `mac`, `mac-one` (Accessibility
/// allowed), `mac-both`. In memory; nothing installs, signs in or changes a setting.
@MainActor enum FirstRunPreview {
  static let seed: String? = {
    let arguments = CommandLine.arguments
    guard RunMode.previewing, let at = arguments.firstIndex(of: "--ui-onboarding"), at + 1 < arguments.count else { return nil }
    return arguments[at + 1]
  }()
  static var page: FirstRunPage? {
    seed.map { $0.hasPrefix("mac") ? .mac : .connect }
  }
  static var payCard: RelayOrchestrator.Approval? {
    guard seed == "pay" else { return nil }
    // AssistantBoard.askRoute's words for a move onto Claude Code.
    return RelayOrchestrator.Approval(title: "Switch Serein to Claude Code (your plan)?",
      detail: "Your plan: runs on the plan you signed in to in the provider's own app. This may pay for something. Serein's chat and the tasks it starts use it. Its chat's pending approvals are declined.",
      button: "Switch", decline: "Stay", threadID: nil) { _ in }
  }

  /// The Mac page's grants, set before its rows first read them.
  static func grant() {
    switch seed {
    case "mac": MacAccess.previewGranted = []
    case "mac-one": MacAccess.previewGranted = [.accessibility]
    case "mac-both": MacAccess.previewGranted = [.accessibility, .screen]
    default: break
    }
  }

  /// The connect page's AI apps, after the preview's own start has installed its own. Loaded whatever
  /// page the preview starts on, so moving on (or Back) to the connect page finds them.
  static func apply() {
    guard let seed else { return }
    let none = ["connect-none", "connect-failed", "offline"].contains(seed)
    // connect-off: Claude Code alone, so its row is the one picked and shows Connect.
    let off = seed == "connect-off"
    installApps(none ? [] : off ? [.claude] : [.claude, .codex, .gemini], claudeSignedIn: seed != "connecting",
      off: off ? [.claude] : [])
    switch seed {
    case "connecting": SereinConnect.shared.previewInline(.claude, phase: .signingIn)
    case "connect-failed": SereinConnect.shared.previewInline(.claude, phase: .failed(.install))
    case "connect-missing": SereinConnect.shared.previewInline(.codex, phase: .failed(.install, missing: ["npm", "brew"]))
    default: break
    }
  }

  /// Connect on a turned-off app: on in this preview's memory, then the connected step. Nothing is saved.
  static func turnOn(_ driver: HarnessDriver) {
    let registry = HarnessRegistry.shared
    var settings = registry.settings
    var instance = settings.instance(driver)
    instance.enabled = true
    settings.update(instance)
    var snapshots = registry.snapshots
    if var s = snapshots[driver] {
      s.enabled = true
      (s.status, s.message) = HarnessSnapshot.summarize(s, name: instance.name)
      snapshots[driver] = s
    }
    registry.installPreview(snapshots, settings: settings)
    SereinConnect.shared.previewInline(driver, phase: .connected)
  }

  private static func installApps(_ installed: Set<HarnessDriver>, claudeSignedIn: Bool, off: Set<HarnessDriver> = []) {
    // Turned off by the person, so `HarnessSettings.normalize` keeps it off.
    let settings = HarnessSettings(instances: HarnessDriver.allCases.map {
      var instance = HarnessInstance(driver: $0, enabled: off.contains($0) ? false : nil)
      if off.contains($0) { instance.userChose = true }
      return instance
    })
    var snapshots: [HarnessDriver: HarnessSnapshot] = [:]
    for instance in settings.instances {
      var s = HarnessSnapshot(instance: instance)
      s.checkedAt = Date()
      s.installed = installed.contains(instance.driver)
      switch instance.driver {
      case .claude:
        s.version = "2.1.322"
        s.signedIn = claudeSignedIn
        s.account = claudeSignedIn ? "Claude Max plan" : nil
      case .codex:
        s.version = "0.150.0"
        s.signedIn = false
      case .gemini:
        s.version = "1.0.0"
        s.signedIn = true
        s.needsUpdate = true
        s.latestVersion = "1.1.0"
      default: break
      }
      s.path = s.installed ? "/usr/local/bin/" + instance.driver.binaries[0] : nil
      if !s.installed { (s.version, s.signedIn, s.account, s.needsUpdate) = (nil, nil, nil, false) }
      (s.status, s.message) = HarnessSnapshot.summarize(s, name: instance.name)
      snapshots[instance.driver] = s
    }
    HarnessRegistry.shared.installPreview(snapshots, settings: settings)
  }
}

private struct FirstRunButtonStyle: ButtonStyle {
  var lit: Bool
  var height: CGFloat
  func makeBody(configuration: Configuration) -> some View { Surface(configuration: configuration, lit: lit, height: height) }
  private struct Surface: View {
    let configuration: ButtonStyleConfiguration
    let lit: Bool
    let height: CGFloat
    @State private var hovered = false
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @Environment(\.reducesMotion) private var reduce
    var body: some View {
      configuration.label
        .font(UIStyle.font(14, weight: .medium)).foregroundStyle(lit ? p.onSolid : p.secondary)
        .frame(maxWidth: .infinity).frame(height: height)
        .background(lit ? p.solid.opacity(configuration.isPressed ? 0.8 : 1) : p.track, in: Capsule())
        .overlay(Capsule().strokeBorder(lit ? p.edge : p.line, lineWidth: UIStyle.hairline))
        .keyboardFocusRing(Capsule())
        .contentShape(Capsule())
        .brightness(lit && hovered && enabled ? 0.055 : 0)
        .pressFeedback(configuration.isPressed)
        .animation(reduce ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.12), value: hovered)
        .animation(Motion.swapping(reduce), value: lit)
        .onHover { hovered = $0 }
    }
  }
}
