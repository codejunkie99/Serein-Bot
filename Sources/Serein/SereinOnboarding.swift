import AVFoundation
import Combine
import SereinCore
import Speech
import SwiftUI
import UserNotifications

/// First launch, before anything else: one full-window page at a time, as Hex's onboarding has it.
/// A centred title, one plain sentence and a card; Back and Continue at the foot with page dots.
/// Everything is optional. macOS does the asking, and each row shows what macOS says now, read
/// again every second, so a switch flipped in System Settings shows here at once. Using your Mac's
/// apps stays off unless the person allows it on its own page.
struct SereinOnboarding: View {
  var startAt: SereinOnboardingPage = .welcome
  let finish: () -> Void
  @State private var page: SereinOnboardingPage = .welcome
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  static let finishedKey = "serein.onboarding.finished"

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 24)
      SereinOnboardingPageView(page: page)
        .id(page)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
        .frame(maxWidth: 480)
        .padding(.horizontal, 32)
      Spacer(minLength: 24)
      footer.padding(.bottom, 28)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(p.background)
    .onAppear { page = startAt }
  }

  private var footer: some View {
    VStack(spacing: 16) {
      HStack(spacing: 8) {
        if page != .welcome, page != .ready {
          Button("Back") { move(-1) }.buttonStyle(OnboardingButton(primary: false))
        }
        Button(page.next) { page == .ready ? finish() : move(1) }
          .buttonStyle(OnboardingButton(primary: true))
          .keyboardShortcut(.defaultAction)
      }
      HStack(spacing: 6) {
        ForEach(SereinOnboardingPage.allCases) { each in
          Capsule().fill(each == page ? p.ink : p.ink.opacity(0.2))
            .frame(width: each == page ? 16 : 6, height: 6)
        }
      }.accessibilityElement().accessibilityLabel("Step \(page.index + 1) of \(SereinOnboardingPage.allCases.count)")
      if page != .ready {
        Button("Skip setup") { finish() }.buttonStyle(.plain)
          .font(UIStyle.meta).foregroundStyle(p.faint)
      }
    }
  }
  private func move(_ by: Int) {
    let all = SereinOnboardingPage.allCases
    guard let next = all[safe: page.index + by] else { return }
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { page = next }
  }
}

enum SereinOnboardingPage: String, CaseIterable, Identifiable {
  case welcome, aiApp, loop, talk, mac, ready
  var id: String { rawValue }
  var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
  var next: String {
    switch self {
    case .welcome: return "Get started"
    case .ready: return "Start using Serein"
    default: return "Continue"
    }
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// One page: its title, its sentence and its card.
private struct SereinOnboardingPageView: View {
  let page: SereinOnboardingPage
  @Environment(\.palette) private var p
  var body: some View {
    VStack(spacing: 22) {
      OnboardingHologram(size: page == .welcome || page == .ready ? 168 : 64)
      VStack(spacing: 8) {
        Text(title).font(UIStyle.font(22, weight: .semibold)).tracking(-0.3).foregroundStyle(p.ink)
          .accessibilityAddTraits(.isHeader)
        Text(lead).font(UIStyle.font(14)).foregroundStyle(p.secondary)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
      card
    }
  }
  private var title: String {
    switch page {
    case .welcome: return "Welcome to Serein"
    case .aiApp: return "Connect an AI app"
    case .loop: return "Stay in the loop"
    case .talk: return "Talk and plan"
    case .mac: return "Use your Mac's apps"
    case .ready: return "You're all set"
    }
  }
  private var lead: String {
    switch page {
    case .welcome: return "A personal assistant on your Mac. Ask for anything, track your goals and keep an eye on sites. Setup takes about two minutes."
    case .aiApp: return "Serein thinks with an AI app you already pay for. You sign in on its own website; Serein never sees your password."
    case .loop: return "So Serein can tell you when something finishes or needs you."
    case .talk: return "Optional. Turn on what you'd like Serein to help with. You can change these any time in Settings."
    case .mac: return "Allow these once and Serein works in your apps without macOS asking again mid-task. Passwords go to a secure card you fill; the AI never sees them."
    case .ready: return "Say hello in the chat. Everything here can be changed later in Settings."
    }
  }
  @ViewBuilder private var card: some View {
    switch page {
    case .welcome, .ready: EmptyView()
    case .aiApp: OnboardingAIApps()
    case .loop: OnboardingGrants(grants: [.notifications, .login])
    case .talk: OnboardingGrants(grants: [.files, .voice, .calendar, .reminders, .contacts])
    case .mac:
      VStack(spacing: 12) {
        OnboardingGrants(grants: [.accessibility, .apps, .screen])
        OnboardingApprovals()
      }
    }
  }
}

/// Serein's live hologram, the same one its chat and details show, centred above each page's title:
/// large on the first and last pages, small on the rest. The drawn mark turns in its place while
/// the hologram loads, where it can't run, and before Serein's chat exists.
private struct OnboardingHologram: View {
  let size: CGFloat
  @Environment(\.palette) private var p
  var body: some View {
    Group {
      if let relay = RelayOrchestrator.shared {
        ChatTopHologramView(
          state: RelayPanelView.avatarState(relay: relay, listening: false, speaking: false), relay: relay,
          paused: false, needsYou: false, open: {}, disc: false, glows: true)
      } else {
        SereinHologramMark(size: size * 0.8, turning: true, glows: true)
      }
    }
    .frame(width: size, height: size)
    .shadow(color: p.accent.opacity(p.isDark ? 0.45 : 0.2), radius: size / 5)
    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: size)
    .accessibilityHidden(true)
  }
}

// MARK: AI apps

private struct OnboardingAIApps: View {
  @ObservedObject private var registry = HarnessRegistry.shared
  @ObservedObject private var connect = SereinConnect.shared
  @Environment(\.palette) private var p
  private var choices: [WelcomeChoice] {
    let all = Welcome.choices(snapshots: registry.snapshots, settings: registry.settings)
    return SereinChatSetup.accounts.compactMap { driver in all.first { $0.driver == driver } }
  }
  var body: some View {
    VStack(spacing: 10) {
      OnboardingCard {
        ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
          if index > 0 { Divider().overlay(p.line) }
          OnboardingRow(symbol: nil, logo: Provider(choice.driver),
                        title: "Use my \(SereinConnect.account(choice.driver) ?? choice.name) account",
                        detail: index == 0 ? "Recommended · connects \(choice.name)" : "Connects \(choice.name)",
                        status: status(choice), action: action(choice)) {
            SereinConnect.shared.start(choice.driver)
          }
        }
      }
      Button("I use a different AI app") { SereinConnect.shared.showOtherApps() }
        .buttonStyle(.plain).font(UIStyle.meta).foregroundStyle(p.accent)
    }
    .task { if registry.snapshots.isEmpty { await registry.refreshAll(includeDisabled: true) } }
  }
  private func busy(_ driver: HarnessDriver) -> Bool {
    guard let flow = connect.flow, flow.driver == driver else { return false }
    return !flow.phase.failed && flow.phase != .connected
  }
  private func status(_ choice: WelcomeChoice) -> OnboardingStatus {
    if busy(choice.driver) { return .working("Connecting…") }
    return choice.next == .ready ? .done("Ready") : .open
  }
  private func action(_ choice: WelcomeChoice) -> String {
    switch choice.next {
    case .install: return "Set it up"
    case .signIn: return "Sign in"
    case .ready: return "Use it"
    }
  }
}

// MARK: macOS permissions

enum OnboardingGrant: String, Identifiable {
  case notifications, login, voice, calendar, reminders, contacts, files, accessibility, apps, screen
  var id: String { rawValue }
  var title: String {
    switch self {
    case .notifications: return "Notifications"
    case .login: return "Open at login"
    case .voice: return "Talk to Serein"
    case .calendar: return "Calendar"
    case .reminders: return "Reminders"
    case .contacts: return "Contacts"
    case .files: return "Read my files"
    case .accessibility: return "Click and type in apps"
    case .apps: return "Control your apps"
    case .screen: return "See an app's window"
    }
  }
  var detail: String {
    switch self {
    case .notifications: return "When a task finishes or needs you."
    case .login: return "Reminders and check-ins run on time."
    case .voice: return "Microphone and speech, for calls. Voice stays on this Mac."
    case .calendar: return "Plan your day. Changes always ask first."
    case .reminders: return "Remember things for you. Adding one asks first."
    case .contacts: return "Find names, emails and numbers. Read only."
    case .files: return "Your posts, notes and documents, read-only. Private data stays closed."
    case .accessibility: return "macOS Accessibility, for the apps you name."
    case .apps: return "Safari, Chrome, Notes, Mail, Messages and Finder: macOS asks about each once, now, not mid-task."
    case .screen: return "macOS Screen Recording, for the app you choose."
    }
  }
  var symbol: String {
    switch self {
    case .notifications: return "bell"
    case .login: return "power"
    case .voice: return "mic"
    case .calendar: return "calendar"
    case .reminders: return "checklist"
    case .contacts: return "person.crop.circle"
    case .files: return "folder"
    case .accessibility: return "hand.point.up.left"
    case .apps: return "square.grid.2x2"
    case .screen: return "macwindow"
    }
  }

  @MainActor var state: MacAccess.State {
    switch self {
    case .notifications:
      TaskNotifications.shared.refreshAuthorization()
      switch TaskNotifications.shared.authorization {
      case .authorized?, .provisional?: return .granted
      case .denied?: return .denied
      default: return .unknown
      }
    case .login: return LoginLaunch.enabled ? .granted : .unknown
    case .voice:
      let mic = AVCaptureDevice.authorizationStatus(for: .audio)
      let speech = SFSpeechRecognizer.authorizationStatus()
      if mic == .authorized && speech == .authorized { return .granted }
      return mic == .denied || speech == .denied ? .denied : .unknown
    case .calendar: return Self.connection(.calendar)
    case .reminders: return Self.connection(.reminders)
    case .contacts: return Self.connection(.contacts)
    // On only with Full Disk Access too: without it macOS still asks for Desktop, Documents and iCloud.
    case .files:
      let disk = AgentFileGuard.holdsFullDiskAccess(home: FileManager.default.homeDirectoryForCurrentUser, canOpen: FullDiskAccessNotice.canOpen)
      return MacFiles.readsWholeMac() && disk ? .granted : .unknown
    case .accessibility: return MacAccess.state(.accessibility) == .granted ? .granted : .unknown
    case .apps: return EverydayAppsAccess.state
    case .screen: return MacAccess.state(.screen) == .granted ? .granted : .unknown
    }
  }
  @MainActor private static func connection(_ connection: NativeConnection) -> MacAccess.State {
    switch NativeConnections.access(connection) {
    case .allowed: return connection.isOn() ? .granted : .unknown
    case .denied: return .denied
    case .notAsked: return .unknown
    }
  }
  /// Asks macOS from the person's click; a "no" already given opens the right System Settings pane.
  @MainActor func ask() async -> String? {
    switch self {
    case .notifications:
      if state == .denied, let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
        NSWorkspace.shared.open(url); return nil
      }
      TaskNotifications.shared.requestAuthorization()
    case .login: return LoginLaunch.turnOn()
    case .voice:
      if state == .denied, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
        NSWorkspace.shared.open(url); return nil
      }
      _ = await WakeListener.requestAccess()
    case .calendar, .reminders, .contacts:
      let connection: NativeConnection = self == .calendar ? .calendar : self == .reminders ? .reminders : .contacts
      if NativeConnections.access(connection) == .denied { NativeConnections.openSettings(connection); return nil }
      if await NativeConnections.request(connection) == .allowed { connection.setOn(true) }
    case .files:
      GateSettings.shared.set(true, forKey: MacFiles.wholeMacKey)
      MacAccess.openSettings(.fullDisk)
      return "On. Drag Serein into Full Disk Access so it can also see Desktop, Documents and iCloud."
    case .accessibility: MacAccess.ask(.accessibility)
    case .apps:
      if state == .denied { MacAccess.openSettings(.automation); return "Turn on each app under Serein in Automation." }
      await EverydayAppsAccess.askAll()
    case .screen: MacAccess.ask(.screen)
    }
    return nil
  }
}

private struct OnboardingGrants: View {
  let grants: [OnboardingGrant]
  @State private var states: [OnboardingGrant: MacAccess.State] = [:]
  @State private var notes: [OnboardingGrant: String] = [:]
  private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
  @Environment(\.palette) private var p
  var body: some View {
    OnboardingCard {
      ForEach(Array(grants.enumerated()), id: \.element) { index, grant in
        if index > 0 { Divider().overlay(p.line) }
        OnboardingRow(symbol: grant.symbol, logo: nil, title: grant.title,
                      detail: notes[grant] ?? grant.detail, status: status(grant),
                      action: states[grant] == .denied ? "Open Settings" : "Allow") {
          Task {
            notes[grant] = await grant.ask()
            refresh()
          }
        }
      }
    }
    .onAppear(perform: refresh)
    .onReceive(tick) { _ in refresh() }
  }
  private func status(_ grant: OnboardingGrant) -> OnboardingStatus {
    states[grant] == .granted ? .done("On") : .open
  }
  private func refresh() {
    for grant in grants { states[grant] = grant.state }
  }
}

/// "Serein asks before": two of the levels Settings offers, chosen here so the person sees what
/// Serein does on its own before it does it. Choosing one is their confirmation (setLevel retires
/// the one-time notice a fresh install would otherwise show).
private struct OnboardingApprovals: View {
  @ObservedObject private var watch = GateWatch.shared
  @Environment(\.palette) private var p
  // An unreadable file gives nil: Every step.
  private var level: ApprovalLevel { ApprovalLevel.resolve(stored: GateSettings.shared.object(forKey: RelayOrchestrator.autopilotKey)) }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("On your Mac, Serein asks before").font(UIStyle.font(11.5, weight: .medium)).foregroundStyle(p.secondary)
        .padding(.leading, 4)
      OnboardingCard {
        choice(.riskyOnly, title: "Only risky steps",
               detail: "Routine clicks and typing go ahead. It asks before it sends, posts, buys, deletes or signs out.")
        Divider().overlay(p.line)
        choice(.everyStep, title: "Every step", detail: "You approve each click and each task it starts.")
      }
    }
  }
  private func choice(_ option: ApprovalLevel, title: String, detail: String) -> some View {
    let chosen = level == option
    return Button {
      if let relay = RelayOrchestrator.shared {
        relay.setLevel(option)
      } else {
        GateSettings.shared.set(option.storedValue, forKey: RelayOrchestrator.autopilotKey)
      }
    } label: {
      HStack(spacing: 12) {
        InterfaceIcon(systemName: chosen ? "largecircle.fill.circle" : "circle", size: 15)
          .foregroundStyle(chosen ? p.ink : p.secondary).frame(width: 32, height: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(UIStyle.font(13, weight: .medium)).foregroundStyle(p.ink)
          Text(detail).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title + ". " + detail)
    .accessibilityAddTraits(chosen ? [.isSelected] : [])
  }
}

// MARK: Parts

enum OnboardingStatus: Equatable {
  case open, working(String), done(String)
}

private struct OnboardingCard<Content: View>: View {
  @ViewBuilder var content: Content
  @Environment(\.palette) private var p
  var body: some View {
    VStack(spacing: 0) { content }
      .padding(.vertical, 4)
      .background(p.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.line, lineWidth: 1))
  }
}

private struct OnboardingRow: View {
  let symbol: String?
  let logo: Provider?
  let title: String
  let detail: String
  let status: OnboardingStatus
  let action: String
  let run: () -> Void
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: 12) {
      Group {
        if let logo {
          ModelMonogram(provider: logo, size: 22)
        } else if let symbol {
          InterfaceIcon(systemName: symbol, size: 14).foregroundStyle(p.ink)
        }
      }.frame(width: 32, height: 32).background(p.track, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(UIStyle.font(13, weight: .medium)).foregroundStyle(p.ink)
        Text(detail).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
      switch status {
      case .open:
        Button(action, action: run).buttonStyle(OnboardingButton(primary: false, small: true))
      case .working(let words):
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(words).font(UIStyle.meta).foregroundStyle(p.secondary)
        }
      case .done(let words):
        Label(words, systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
          .font(UIStyle.meta).foregroundStyle(p.success)
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .accessibilityElement(children: .combine)
  }
}

/// Hex's buttons: a solid capsule for the way forward, a quiet one beside it.
struct OnboardingButton: ButtonStyle {
  var primary: Bool
  var small = false
  func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, primary: primary, small: small) }
  private struct Face: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    let small: Bool
    @State private var hovered = false
    @Environment(\.palette) private var p
    var body: some View {
      configuration.label
        .font(UIStyle.font(small ? 12 : 13, weight: .medium))
        .foregroundStyle(primary ? p.onSolid : p.ink)
        .padding(.horizontal, small ? 12 : 18).frame(height: small ? 26 : 34)
        .background(primary ? p.solid : (hovered ? p.selected : p.track), in: Capsule())
        .opacity(configuration.isPressed ? 0.85 : 1)
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .contentShape(Capsule())
        .onHover { hovered = $0 }
    }
  }
}
