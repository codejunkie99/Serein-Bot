import AppKit
import SereinCore
import SwiftUI

/// Opens Terminal with one visible command, only after the user clicks. Serein writes the command to a
/// small `.command` file it owns and hands that to Terminal; it never runs the command itself and never
/// sees a password, because sign-in happens in Terminal.
@MainActor enum TerminalLauncher {
  static func run(_ command: SetupCommand) {
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Serein/Setup", isDirectory: true)
    let file = folder.appendingPathComponent("\(command.provider)-\(command.kind == .install ? "install" : "sign-in").command")
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try AgentSetup.script(for: command).write(to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    } catch { return }
    if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
      NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    } else {
      NSWorkspace.shared.open(file)
    }
  }
}

/// First-run setup. Each step can be skipped; progress is saved so the window can be closed and reopened.
/// The import step reuses `BrowserOnboarding` unchanged apart from its embedded chrome.
struct SetupFlow: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  var profiles: [BrowserImportProfile]? = nil
  let onFinish: () -> Void
  @State private var progress: SetupProgress
  /// The automatic part: it starts when the tour starts and works behind it.
  @ObservedObject private var run = SetupRun.shared
  /// The progress screen in place of the steps.
  @State private var showsRun: Bool
  /// The checkbox on the welcome page, and the browser it names. It starts ticked the first
  /// time only: "Run setup again" brings nothing unless the person ticks it.
  @State private var bring: Bool
  @State private var sourceName: String?
  /// The keyboard starts on the page's main button, not on the close cross.
  @FocusState private var onMainButton: Bool
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var reducedEffects
  /// Pages change with a short fade, or at once where motion is reduced.
  private var fade: Animation? { systemReduceMotion || reducedEffects ? nil : .easeOut(duration: 0.18) }

  init(
    browser: BrowserModel, agent: AgentModel, profiles: [BrowserImportProfile]? = nil,
    startAt: SetupStep? = nil, onFinish: @escaping () -> Void
  ) {
    self.browser = browser
    self.agent = agent
    self.profiles = profiles
    self.onFinish = onFinish
    var progress = profiles == nil ? SetupProgress.load() : SetupProgress()
    if let startAt { progress.current = startAt }
    _bring = State(
      initialValue: profiles != nil || !UserDefaults.standard.bool(forKey: SetupProgress.legacyImportKey))
    let run = SetupRun.shared
    // Opened again from the control at the top: the results first when nobody looked at them;
    // else the tour goes on where it was left, past the page and the steps that are behind.
    if profiles == nil, startAt == nil, run.tourLeft {
      progress.finished = false
      let automatic = run.started || UserDefaults.standard.bool(forKey: SetupProgress.automaticKey)
      let behind: Set<SetupStep> = automatic ? [.welcome, .importData, .signIns] : [.welcome]
      while !progress.finished, behind.contains(progress.current) { progress.complete() }
    }
    _progress = State(initialValue: progress)
    // Also when a row still waits for a choice: the control at the top then says so.
    _showsRun = State(initialValue: profiles == nil && run.started && (!run.seen || run.needsYou))
  }

  /// A small upright panel: setup is a few words and one decision on each page. Its size is
  /// fixed; text in it wraps, and a line that still does not fit gets smaller (to 75%).
  static let size = CGSize(width: 440, height: 560)
  private var persists: Bool { profiles == nil }
  private var step: SetupStep { progress.current }
  /// The steps the automatic part does; the tour leaves them out while it runs, and after it
  /// ended in this pass of setup (Serein can open again in the middle of the tour).
  private var covered: Set<SetupStep> {
    run.started || (persists && UserDefaults.standard.bool(forKey: SetupProgress.automaticKey))
      ? [.importData, .signIns] : []
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsRun {
        SetupEverything(
          run: run,
          tour: progress.finished || step == .welcome ? nil : {
            if run.finished { run.seen = true }
            showsRun = false
          },
          open: {
            if run.finished {
              run.seen = true
              // A choice that is still open counts as "not now"; the sign-ins held for it go.
              run.leaveChoices()
            }
            finish()
          })
      } else {
        steps
      }
    }
    .animation(fade, value: step).animation(fade, value: showsRun)
    // A sheet gives the keyboard to its first control, which is the close cross. The main
    // button takes it when a page shows (only seen with keyboard navigation on).
    .onAppear { DispatchQueue.main.async { onMainButton = true } }
    .onChange(of: step) { _, _ in DispatchQueue.main.async { onMainButton = true } }
    .overlay(alignment: .topTrailing) {
      if !showsRun { closeButton.padding(.top, step == .welcome ? 16 : 13).padding(.trailing, 16) }
    }
    .minimumScaleFactor(0.75)
    .frame(width: Self.size.width, height: Self.size.height).darkGlass(UIStyle.panelRadius)
      .foregroundStyle(p.ink)
      .font(UIStyle.body).buttonStyle(QuietButton()).controlSize(.small).tint(p.solid)
      .interactiveDismissDisabled()
      .task {
        sourceName = await SetupRun.sourceName(synthetic: profiles)
        // Captures: `--ui-setup-everything` is the progress screen, `--ui-setup-run` a step of
        // the tour with the automatic part behind it.
        if profiles != nil, CommandLine.arguments.contains("--ui-setup-everything") {
          // The preview's own agent states, so the capture shows that row with names.
          HarnessRegistry.shared.installSyntheticPreview()
          run.start(browser: browser, synthetic: profiles)
          showsRun = true
        } else if profiles != nil, CommandLine.arguments.contains("--ui-setup-run") {
          run.start(browser: browser, synthetic: profiles)
        }
      }
  }

  @ViewBuilder private var steps: some View {
      // The welcome page is one picture and a few words; it has no bar above or below.
      if step != .welcome { header }
      Group {
        switch step {
        case .welcome: welcome
        case .agent: AgentSetupStep(agent: agent)
        case .macAccess: MacAccessStep()
        case .relay: relayStep
        case .importData:
          BrowserOnboarding(browser: browser, profiles: profiles, embedded: true) { advance(done: true) }
        case .signIns: signIns
        case .defaultBrowser: EmptyView()
        case .talking: talking
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).id(step).transition(.opacity)
      if step != .importData, step != .welcome { footer }
  }

  /// The steps after the welcome page that the tour shows: the ones the bar counts.
  private var counted: [SetupStep] { SetupStep.allCases.filter { $0 != .welcome && !covered.contains($0) } }
  private var position: Int { (counted.firstIndex(of: step) ?? 0) + 1 }

  /// On the welcome page it lies on the dark film, so it is light in both appearances.
  private var closeButton: some View {
    Button { close() } label: {
      InterfaceIcon(systemName: "xmark", size: 10)
        .foregroundStyle(step == .welcome ? Color.white.opacity(0.7) : p.secondary)
        .frame(width: 24, height: 24).contentShape(Rectangle())
    }.buttonStyle(.pressable).help("Close setup. You can pick it up again from Settings.")
      .accessibilityLabel("Close setup")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 9) {
        // After the first page the logo stands to the left of each heading.
        SereinMark(size: 20)
        Text(step.title).font(UIStyle.font(16, weight: .semibold))
        Spacer()
      }.padding(.trailing, 30).frame(height: 24)
      // One thin line in parts: the steps that are behind, the one in view, the ones to come.
      HStack(spacing: 4) {
        ForEach(counted) { s in
          Capsule().fill(s == step ? p.ink : (progress.done.contains(s) ? p.accent : p.track))
            .frame(height: 2)
        }
      }.accessibilityElement().accessibilityLabel("Step \(position) of \(counted.count)")
    }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      if progress.index > 0 {
        Button("Back") {
          move {
            progress.back()
            while covered.contains(progress.current), progress.index > 0 { progress.back() }
          }
        }
      }
      // The automatic part, while it works behind the tour: a click shows all of it.
      if run.started {
        Button { showsRun = true } label: {
          HStack(spacing: 7) {
            if run.finished {
              InterfaceIcon(systemName: "checkmark.circle.fill", size: 13).foregroundStyle(p.success)
            } else {
              ActivityRing(active: true).frame(width: 12, height: 12)
            }
            Text(
              run.finished
                ? "Setup is done" : run.needsYou ? "Setup needs you" : "Setting up · \(run.settled) of \(run.items.count)")
              .font(UIStyle.meta).foregroundStyle(p.secondary)
          }
        }.help("Show what Serein brings over")
      }
      Spacer()
      if step.skippable { Button(step == .relay ? "Not now" : "Skip") { advance(done: false) } }
      Button(progress.isLast ? "Finish" : step == .relay ? "Turn on ⌥Space" : "Continue") {
        advance(done: true)
      }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).focused($onMainButton)
    }.padding(.horizontal, 20).frame(height: 48)
  }

  private func advance(done: Bool) {
    // "Turn on ⌥Space": the global shortcuts and the menu bar item. Serein works in the window either way.
    if step == .relay {
      RelayOrchestrator.enabled = done
      RelayController.shared?.install()
    }
    move {
      if done { progress.complete() } else { progress.skip() }
      // What the automatic part does is not asked again.
      while !progress.finished, covered.contains(progress.current) { progress.complete() }
    }
    if progress.finished { close() }
  }
  private func move(_ change: () -> Void) {
    change()
    if persists { progress.save() }
  }
  /// Leaving the tour while the automatic part still works shows its progress first.
  private func close() {
    if run.active, !showsRun {
      showsRun = true
      return
    }
    finish()
  }
  /// The welcome page's two ways in. Both start the automatic part when its box is ticked.
  private func begin(tour: Bool) {
    // "Run setup again": a run that ended starts over, or stays out when the box is off.
    if run.finished { run.reset() }
    if bring, sourceName != nil { run.start(browser: browser, synthetic: profiles) }
    if tour {
      advance(done: true)
    } else if run.started {
      showsRun = true
    } else {
      finish()
    }
  }
  /// Closing early counts as dismissed: setup does not return on its own, but Settings can restart it.
  private func finish() {
    // Steps that nobody did or skipped keep the control at the top, for this run of the app.
    run.tourLeft = persists && SetupStep.allCases.contains {
      $0 != .welcome && !covered.contains($0) && !progress.done.contains($0) && !progress.skipped.contains($0)
    }
    if persists {
      progress.finished = true
      progress.save()
      UserDefaults.standard.set(true, forKey: SetupProgress.legacyImportKey)
    }
    onFinish()
  }

  // MARK: Steps

  /// One idea and one choice: the assistant behind a shortcut.
  private var relayStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      // The sheet header already shows the petal, so the shortcut stands alone, as a keycap.
      Text("⌥Space").font(UIStyle.mono(20, weight: .medium)).foregroundStyle(p.ink)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(p.track, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel("Option Space")
        .padding(.top, 8)
      Text("Press ⌥Space in any app and ask. Hold it to talk.").font(UIStyle.font(18, weight: .medium))
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 10) {
        relayLine("hammer", "Takes on bigger jobs with your AI app and tells you when they are done.")
        relayLine("macwindow", "Works in your Mac apps and the web for you.")
        relayLine("bell", "Remembers what you tell it and reminds you later.")
        relayLine("hand.raised", "Always asks before sending, deleting or paying. Say “stop” to stop it.")
      }
      Spacer(minLength: 0)
      Text("Serein is in this window. ⌥Space adds it to every app and keeps Serein in the menu bar. Turn it off any time in Settings › Assistants › Ask from any app.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
  }
  private func relayLine(_ icon: String, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      InterfaceIcon(systemName: icon, size: 13).foregroundStyle(p.secondary).frame(width: 18)
      Text(text).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var welcome: some View {
    VStack(spacing: 0) {
      // The film of the Serein logo, on a loop.
      SetupArt().frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: UIStyle.headerCardRadius, style: .continuous))
        .padding(.horizontal, 10).padding(.top, 10)
        .accessibilityElement().accessibilityLabel("Serein")
      Spacer(minLength: 12)
      VStack(spacing: 10) {
        Text("Your assistant on this Mac.").font(UIStyle.font(24, weight: .medium)).tracking(-0.5)
          .lineLimit(2).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
        Text("Ask Serein anything: your calendar, the web, your files. Nothing goes to your AI app until you ask.")
          .foregroundStyle(p.secondary).multilineTextAlignment(.center).lineLimit(4)
      }.padding(.horizontal, 36)
      Spacer(minLength: 12)
      VStack(spacing: 6) {
        Button { begin(tour: true) } label: {
          Text("Get started").font(UIStyle.bodyStrong).lineLimit(1).padding(.horizontal, 22)
            .padding(.vertical, 3)
        }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).focused($onMainButton)
        Button { begin(tour: false) } label: {
          Text("Skip the tour").font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1)
        }.help("Go straight in. What Serein brings over shows its progress.")
      }
      Spacer(minLength: 12)
      // The one decision of the automatic part, and the browser it is about.
      Group {
        if let sourceName {
          VStack(spacing: 4) {
            Toggle(isOn: $bring) { Text("Bring everything from \(sourceName)").lineLimit(1) }
              .toggleStyle(.checkbox)
            Text(
              SetupSource.tellsPrivateWindows(sourceName)
                ? "Bookmarks, history and passwords come by themselves; macOS asks first. You choose the sign-ins and the tabs."
                : "Bookmarks and history come by themselves. You choose the sites for the sign-ins."
            ).role(.micro)
              .multilineTextAlignment(.center).lineLimit(2)
          }
        } else {
          Text("Every step can be skipped. You can run setup again from Settings.").role(.micro)
            .multilineTextAlignment(.center).lineLimit(2)
        }
      }.padding(.horizontal, 28).padding(.bottom, 20)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var signIns: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Bring over the sites you are already signed in to, so you do not log in again.")
        .role(.reading).foregroundStyle(p.secondary)
      Text("Serein reads a temporary copy of the cookies from Chrome, Arc, Brave or Edge. macOS asks before sharing that browser's key, you review the list of sites, and only the ones you tick are written. Nothing is chosen for you.")
        .role(.meta)
      HStack {
        Button("Bring sign-ins…") { SignInImportWindow.show() }.buttonStyle(PrimaryButton())
      }
      Text("Passwords stay in Passwords and need device authentication. Passkeys stay with your existing browser.")
        .role(.meta)
      Spacer()
    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
  }

  private var talking: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Optional. Hold a key, say it, and let go. Your words land in the field you are typing in.")
          .role(.reading).foregroundStyle(p.secondary)
        TalkingWizard()
      }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: Agent step

// AgentSetupStep lives in HarnessSetupViews.swift.



/// The shared dark glass plate, skipped when a view sits inside another plate.
struct OptionalGlass: ViewModifier {
  let on: Bool
  func body(content: Content) -> some View {
    if on { content.darkGlass(UIStyle.panelRadius) } else { content }
  }
}
