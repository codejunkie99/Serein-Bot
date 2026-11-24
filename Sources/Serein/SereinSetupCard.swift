import SereinCore
import SwiftUI

/// A single optional control offered in Serein's conversation. The agent chooses a topic;
/// only the person can activate the control, with the same confirmations as Settings.
struct SereinSetupCard: View {
  /// Snapshot a single conversation control without touching the person's preferences.
  static func seedPreview(in relay: RelayOrchestrator) {
    let args = CommandLine.arguments
    guard !RelayOrchestrator.persists, args.contains("--ui-preview"),
      let index = args.firstIndex(of: "--ui-setup-offer"), index + 1 < args.count,
      let topic = SereinSetup.Topic(rawValue: args[index + 1]) else { return }
    relay.offerSetup(topic)
  }

  let topic: SereinSetup.Topic
  let offeredIn: String
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var controller: RelayController
  @Environment(\.palette) private var p
  @AppStorage(RelayOrchestrator.enabledKey) private var barEnabled = false
  @AppStorage(RelayOrchestrator.summonKey) private var shortcut = RelayHotKey.summon
  @GateStorage(ScreenTrail.enabledKey) private var following = false
  @GateStorage(MacFiles.wholeMacKey) private var readsFiles = true
  @ObservedObject private var speech = SpeechModelDownload.shared
  @State private var asksOpen = false
  @State private var shortcutRevision = 0
  /// What is left to do after a yes macOS did not take (Open at login, the microphone for “Serein”).
  @State private var problem: String?

  private var isCurrent: Bool {
    relay.threadID == offeredIn && relay.setupOffersHere.contains(topic)
  }
  private var shortcutLabel: String { RelayHotKey.symbols(shortcut) }
  private var shortcutTaken: Bool {
    _ = shortcutRevision
    return controller.summonTaken
  }
  private var title: String {
    switch topic {
    case .beside: return "Keep Serein beside your work"
    case .anywhere: return "Ask Serein from any app"
    case .approvals: return "What should Serein ask about?"
    case .checkIns: return "Let Serein check in"
    case .firstRead: return "Get to know you"
    case .login: return "Keep your schedules on time"
    case .follow: return "Let Serein follow along"
    case .speech: return "Faster, more accurate dictation"
    case .files: return MacFiles.consentTitle
    case .dock: return "Keep your assistants at the edge of the screen"
    case .showAndTell: return "Show Serein what you mean"
    case .wake: return "Say “Serein” to ask"
    case .background: return "Let assistants work in the background"
    case .downloads: return "Let tasks download files"
    case .awake: return "Keep the Mac awake while tasks run"
    }
  }
  /// The cards for a plain switch: whether it is on already.
  private var switchOn: Bool {
    switch topic {
    case .dock: return AssistantDock.enabled
    case .showAndTell: return ScreenContextCapture.enabled && barEnabled
    case .wake: return WakeListener.enabled && barEnabled
    case .background: return MacBackground.enabled
    case .downloads: return TaskDownloadPolicy.isEnabled()
    case .awake: return MacAwake.enabled
    default: return false
    }
  }
  private var detail: String {
    switch topic {
    case .beside:
      return "Keep this conversation beside the pages you open. ⌘J switches between full and beside."
    case .anywhere:
      return shortcutTaken ? "Another app uses \(shortcutLabel). You can choose a different shortcut."
        : "Press \(shortcutLabel) from any app to talk with Serein. Hold it to speak."
    case .approvals:
      return "Choose how much Serein asks before acting. Sending, buying and deleting still ask."
    case .checkIns:
      return relay.proactiveLevel == .off
        ? "Serein can brief you each morning, check in every few hours, even while you're away, and finish what you asked it to. Each check-in uses some of your AI app’s usage."
        : "Check-ins are on at \(relay.proactiveLevel.title): a morning brief and a check-in every few hours, even while you're away. Change this in Settings › Serein."
    case .firstRead:
      return "Serein reads your chats with Claude Code, Codex and your other AI apps on this Mac, keeps what matters as notes you can change, and suggests apps to connect. Reading uses some of your AI app’s usage."
    case .login:
      return "Schedules run on this Mac while it is awake and Serein is open, in its window or the menu bar. Open Serein when you log in, so they keep running after a restart. With the lid closed the Mac sleeps: a run it missed waits for you with Run now and Skip."
    case .follow:
      // On means running: with ⌥Space off nothing is kept, so the card still offers the one yes.
      if following, barEnabled { return "Following along is already on. You can turn it off in Settings › Assistants › Ask from any app." }
      return (barEnabled ? "" : "Ask Serein from any app with \(shortcutLabel). ")
        + "The names of the apps and windows you were just in go to your AI app with what you ask\(barEnabled ? " from \(shortcutLabel)" : ""). Never a browser’s page or a password manager."
    case .speech:
      switch speech.state {
      case .downloading(let share): return "Downloading the speech model… \(Int(share * 100))%"
      case .checking: return "Checking the download…"
      case .done: return "Done. Dictation in English uses the speech model from now on."
      case .idle, .failed:
        if !SpeechEngine.supported { return "The speech model needs a Mac with Apple silicon." }
        if speechThere { return "The speech model is already on this Mac. Dictation in English uses it." }
        return "Serein can hear English with a speech model that runs on this Mac. It is a \(SpeechModel.bytes / 1_000_000) MB download from Hugging Face, made by NVIDIA."
      }
    case .files:
      return readsFiles ? "Reading is already on. You can turn it off in Marketplace › On this Mac."
        : MacFiles.consent + "\n\n" + MacFiles.macAsks
    case .dock, .showAndTell, .wake, .background, .downloads, .awake:
      return switchOn ? "This is already on. You can turn it off in Settings." : switchDetail
    }
  }
  /// The words of each switch's own note in Settings, with the shortcut it needs when that is off.
  private var switchDetail: String {
    let bar = barEnabled ? "" : "Ask Serein from any app with \(shortcutLabel). "
    switch topic {
    case .dock: return "Each face shows when an assistant is working or needs you. Click one to chat, or drop a file on its chat."
    case .showAndTell:
      return bar + "While you hold \(shortcutLabel) and talk, what you select or point at goes to your AI app with your words. Never a password field or a password manager."
    case .wake:
      if TalkLanguageSupport.resolved() == nil {
        return "No language on this Mac can recognize speech without the network, so Serein can't listen for its name."
      }
      return bar + "Serein listens on this Mac for its name and sends what you say next when you pause. Nothing said before “Serein” is kept."
    case .background: return "Serein acts in the app's window without moving your pointer, and still asks before each step. Some apps need the foreground."
    case .downloads: return "The first file from each site asks you. Files wait unopened until you keep them. Apps, installers, scripts and archives are always refused."
    case .awake: return "Only while a task runs or a scheduled run is about to. The display can still sleep, and closing the lid still puts the Mac to sleep."
    default: return ""
    }
  }
  private var speechThere: Bool { speech.state == .done || SpeechEngine.modelFile() != nil }
  /// Nothing to download: the model is here, or this Mac cannot run it.
  private var speechSettled: Bool { speechThere || !SpeechEngine.supported }
  private var speechProblem: String? {
    if case .failed(let reason) = speech.state { return reason + " Nothing was kept." }
    return nil
  }
  private static let speechLicense = URL(string: "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/")!
  private var actionLabel: String {
    switch topic {
    case .beside: return "Keep beside"
    case .anywhere:
      if shortcutTaken { return shortcut == "ctrl+opt+space" ? "Choose a shortcut" : "Use ⌃⌥Space" }
      return barEnabled ? "Show me" : "Turn on \(shortcutLabel)"
    case .approvals: return "Choose"
    case .checkIns: return relay.proactiveLevel == .off ? "Turn on check-ins" : "Done"
    case .firstRead: return "Read my chats"
    case .login: return "Open at login"
    case .follow: return following && barEnabled ? "Done" : "Turn on"
    case .speech:
      if speech.working { return "Cancel" }
      if speechSettled { return "Done" }
      return speechProblem == nil ? "Download" : "Try again"
    case .files: return readsFiles ? "Done" : "Allow reading"
    case .dock, .showAndTell, .background, .downloads, .awake: return switchOn ? "Done" : "Turn on"
    case .wake: return switchOn || TalkLanguageSupport.resolved() == nil ? "Done" : "Turn on"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(UIStyle.bodyStrong).foregroundStyle(p.ink)
        .accessibilityAddTraits(.isHeader)
      Text(detail).font(UIStyle.meta).foregroundStyle(p.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let problem {
        Text(problem).font(UIStyle.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
      }
      if topic == .speech {
        if let speechProblem {
          Text(speechProblem).font(UIStyle.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
        }
        Link("NVIDIA Open Model License", destination: Self.speechLicense).font(UIStyle.meta).foregroundStyle(p.accent)
      }
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        // A download under way or done has Cancel or Done, not a no.
        if !(topic == .speech && (speech.working || speechSettled)) {
          Button("Not now") { dismiss() }.buttonStyle(PillButton(kind: .quiet))
        }
        Button(actionLabel) { act() }.buttonStyle(PillButton(kind: .solid))
          .popover(isPresented: $asksOpen, arrowEdge: .bottom) { approvals }
      }
    }.padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(p.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .accessibilityElement(children: .contain)
      .disabled(!isCurrent)
      .onChange(of: relay.threadID) { asksOpen = false }
      .onChange(of: isCurrent) { if !isCurrent { asksOpen = false } }
  }

  private var approvals: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Serein asks before").font(UIStyle.bodyStrong).accessibilityAddTraits(.isHeader)
      AskBeforeControl(relay: relay, controller: controller)
      Text(ApprovalLevel.footnote(killLabel: controller.killLabel)).font(UIStyle.meta)
        .foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Keep this choice") {
          guard isCurrent else { return }
          relay.setLevel(relay.level)
          GuideCenter.shared.record(.approvalChoiceKept)
          asksOpen = false
          dismiss(declined: false)
        }.buttonStyle(PrimaryButton())
      }
    }.padding(16).frame(width: 320).environment(\.palette, p)
      .disabled(!isCurrent)
  }

  /// What the Read my chats button says for the person. “Remember” makes the notes the person's
  /// own ask (`MemoryTools.asksToRemember`), kept rather than left as ideas.
  static let firstReadRequest = "Get to know me: read my AI chats on this Mac and remember what matters about me."
  /// What the Allow reading button says for the person, so Serein carries on with their question.
  static let filesAllowedRequest = "You can read my Mac now. Look there and answer what I asked."

  private func dismiss(declined: Bool = true) {
    guard isCurrent else { return }
    // Not now on Open at login is remembered: it is not offered again (Settings keeps it).
    if topic == .login, declined { RelayOrchestrator.setSetting(true, forKey: LoginLaunch.declinedKey) }
    if topic == .follow, declined { RelayOrchestrator.setSetting(true, forKey: ScreenTrailWatch.declinedKey) }
    if topic == .speech, declined { RelayOrchestrator.setSetting(true, forKey: SpeechModelDownload.declinedKey) }
    relay.dismissSetupOffer(topic, declined: declined)
    // Not now to reading still leaves check-ins to offer, once.
    if topic == .firstRead, declined, relay.proactiveLevel == .off, !relay.dismissedSetupOffersHere.contains(.checkIns) {
      relay.offerSetup(.checkIns)
    }
  }
  private func act() {
    guard isCurrent else { return }
    switch topic {
    case .beside:
      SereinRouter.keepBeside()
      if SereinSurface.main.place == .full, SereinRouter.switchState.enabled {
        SereinRouter.toggleFullBeside()
      }
      SereinRouter.show()
      dismiss(declined: false)
    case .anywhere:
      if shortcutTaken {
        guard shortcut != "ctrl+opt+space" else {
          controller.openSettings("Keyboard")
          return
        }
        RelayOrchestrator.setSetting("ctrl+opt+space", forKey: RelayOrchestrator.summonKey)
        RelayOrchestrator.setSetting(true, forKey: RelayOrchestrator.enabledKey)
        controller.install()
      } else if barEnabled {
        controller.show()
      } else {
        RelayOrchestrator.setSetting(true, forKey: RelayOrchestrator.enabledKey)
        controller.install()
      }
      shortcutRevision += 1
      if !controller.summonTaken { dismiss(declined: false) }
    case .approvals:
      asksOpen = true
    case .checkIns:
      // The button opts into the default level, never upgrades an existing choice or changes the
      // approval policy. Showing the card alone starts no background work.
      if relay.proactiveLevel == .off { relay.proactiveLevel = .newInstallDefault }
      dismiss(declined: false)
      // Check-ins run on their own time: Open at login comes next, when it helps.
      relay.offerLoginIfUseful()
    case .firstRead:
      // The button is the person's yes to reading and their request, in words the chat shows; the
      // assistant gets to work from `sessions_overview` (its description says how).
      SessionReading.allowed = true
      dismiss(declined: false)
      relay.checkInsAfterTurn = relay.threadID
      relay.ask(Self.firstReadRequest)
    case .login:
      problem = LoginLaunch.turnOn()
      if problem == nil {
        dismiss(declined: false)
        offerNext(on: MacAwake.enabled)
      }
    case .follow:
      if !barEnabled {
        RelayOrchestrator.setSetting(true, forKey: RelayOrchestrator.enabledKey)
        controller.install()
      }
      ScreenTrailWatch.turnOn()
      dismiss(declined: false)
      if controller.summonTaken { relay.offerSetup(.anywhere) } else { offerNext(on: ScreenContextCapture.enabled) }
    case .speech:
      if speech.working {
        speech.cancel()
      } else if speechSettled {
        dismiss(declined: false)
      } else {
        speech.start()
      }
    case .files:
      // The button is the person's yes, and their word to carry on, in words the chat shows.
      guard !readsFiles else { return dismiss(declined: false) }
      readsFiles = true
      // A yes that did not hold (relay/gates.json cannot be read) leaves the card as it was.
      guard MacFiles.readsWholeMac() else { return }
      dismiss(declined: false)
      // The reply that pointed at this card finishes first; the words go after it.
      relay.ask(Self.filesAllowedRequest, interrupt: false)
    case .dock, .showAndTell, .wake, .background, .downloads, .awake:
      if switchOn || (topic == .wake && TalkLanguageSupport.resolved() == nil) { dismiss(declined: false); return }
      turnOnSwitch()
    }
  }
  /// What the switch in Settings does, from the person's yes on the card.
  private func turnOnSwitch() {
    switch topic {
    case .dock:
      RelayOrchestrator.setSetting(true, forKey: AssistantDock.enabledKey)
      controller.install()
    case .showAndTell:
      GateSettings.shared.set(true, forKey: ScreenContext.enabledKey)
      _ = MacControl.accessibilityGranted(prompt: !RunMode.automated)
      turnOnBar()
    case .wake:
      // macOS asks for speech recognition and the microphone first; a no leaves it off.
      Task {
        guard await WakeListener.requestAccess() else {
          problem = "Allow the microphone and speech recognition for Serein in System Settings › Privacy & Security."
          return
        }
        GateSettings.shared.set(true, forKey: WakeListener.enabledKey)
        turnOnBar()
      }
      return
    case .background: GateSettings.shared.set(true, forKey: MacBackgroundPolicy.enabledKey)
    case .downloads: GateSettings.shared.set(true, forKey: TaskDownloadPolicy.enabledKey)
    case .awake:
      RelayOrchestrator.setSetting(true, forKey: MacAwake.key)
      MacAwake.shared.refresh()
    default: return
    }
    dismiss(declined: false)
  }
  /// What they say or point at reaches Serein through the shortcut's bar, so that comes on too,
  /// with the shortcut card when another app holds it (as following along does).
  private func turnOnBar() {
    if !barEnabled {
      RelayOrchestrator.setSetting(true, forKey: RelayOrchestrator.enabledKey)
      controller.install()
    }
    dismiss(declined: false)
    if controller.summonTaken { relay.offerSetup(.anywhere) }
  }
  /// One more card after a yes, when it fits and was not put away here (`SereinSetup.next`).
  private func offerNext(on: Bool) {
    if let next = SereinSetup.next(after: topic, on: on, dismissed: relay.dismissedSetupOffersHere) { relay.offerSetup(next) }
  }
}
