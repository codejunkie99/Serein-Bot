import AppKit
import Combine
import SereinCore
import SwiftUI

/// Connecting an AI app from Serein (F10): one button starts that app's own job at once. It runs
/// the install when the app is missing, then the sign-in, through `HarnessActions` (the command
/// for the app's state, then `run`), and the sheet says what happens in plain lines. The embedded
/// terminal stays behind Show details. Nothing here types a password or reads one.
@MainActor final class SereinConnect: ObservableObject {
  static let shared = SereinConnect()
  /// `check`: Serein's own look at the app did not finish, so no install, sign-in or update ran.
  enum Step: Equatable { case check, install, signIn, update }
  enum Phase: Equatable {
    /// Finding out whether the app is installed and signed in.
    case checking
    case installing
    case signingIn
    /// Installed, but too old for Serein's requests (`HarnessSnapshot.tooOld`): its own update runs.
    case updating
    case connected
    /// A step did not finish. `missing`: the tools an install needs that this Mac lacks (npm,
    /// Homebrew), known before anything ran.
    case failed(Step, missing: [String] = [])
    var failed: Bool { if case .failed = self { return true } else { return false } }
  }
  struct Flow: Equatable {
    let driver: HarnessDriver
    var phase: Phase
    /// An install ran in this flow, so its line stays (ticked) above the sign-in.
    var installs = false
    /// An update ran in this flow, so its line stays (ticked) above the rest.
    var updates = false
    /// The Mac app this AI app was found in rather than installed (Codex in the ChatGPT app).
    var app: String?
    /// Why the failed step's job did not finish, in the job's words ("Exited with code 1.").
    var reason: String?
  }
  @Published private(set) var flow: Flow?
  /// Conversational setup keeps the same connection job inside the chat instead of a sheet.
  @Published private(set) var inline = false
  /// “Other AI apps…”: the full list (`AgentSetupStep`).
  @Published var showOthers = false
  private var jobWatch: AnyCancellable?
  private var requestID: UUID?
  /// This flow turned on the setup mode of `HarnessActions` (the terminal stays in the sheet, not
  /// in a window of its own); it turns it off again when it ends.
  private var claimedSetup = false
  var presented: Bool { !inline && (flow != nil || showOthers) }
  /// Held messages wait while an app installs or signs in here: one that has just installed may
  /// count as found before its sign-in is known, and a message sent then would fail. Once the
  /// flow ends (connected, or a step failed and you may connect another way), the usual rule
  /// holds: an AI app that is found and not signed out (`AgentModel.canThink`).
  var releasesHeld: Bool {
    guard let flow else { return true }
    return flow.phase == .connected || flow.phase.failed
  }

  /// Connect Claude Code, Connect Codex, and the header's connect pill.
  func start(_ driver: HarnessDriver, inline: Bool = false) {
    // A preview never installs, signs in or updates an AI app: its flows come from `previewInline`.
    guard !RunMode.previewing else { return }
    let request = UUID()
    requestID = request
    jobWatch = nil
    self.inline = inline
    showOthers = false
    flow = Flow(driver: driver, phase: .checking)
    claim()
    Task { [weak self] in
      await HarnessRegistry.shared.refresh(driver, includeDisabled: true, force: true)
      guard let self, self.requestID == request, self.flow?.driver == driver else { return }
      self.step()
    }
  }
  /// Runs what the app needs next: the install, the sign-in, an update when it is too old for
  /// Serein, or nothing (it is connected).
  private func step() {
    guard var flow else { return }
    let registry = HarnessRegistry.shared
    let snapshot = registry.snapshots[flow.driver]
    let action = HarnessPrimaryAction.of(snapshot)
    // A newer release alone leaves the app usable; one too old for Serein would refuse every
    // request, so it updates before it counts as connected.
    let tooOld = snapshot?.tooOld == true
    switch action {
    case .ready, .update where !tooOld:
      if !registry.instance(flow.driver).enabled { registry.setEnabled(flow.driver, true) }
      if !flow.installs { flow.app = BundledCLI.app(snapshot?.path) }
      flow.phase = .connected
      SereinRouter.agent?.syncHarnesses()
      // Signed in: what was held for it goes now (after the app list has caught up).
      DispatchQueue.main.async { RelayOrchestrator.shared?.releaseHeld() }
    case .install, .signIn, .update:
      let step: Step = action == .install ? .install : action == .signIn ? .signIn : .update
      let actions = HarnessActions.shared
      let missing = step == .install ? HarnessActions.missingInstallTools(flow.driver) : []
      if step == .update, let running = registry.floorUpdate(flow.driver) {
        // Its automatic update is already running: wait for that rather than start another.
        flow.phase = .updating
        flow.updates = true
        let request = requestID
        let driver = flow.driver
        Task { @MainActor [weak self] in
          await running.value
          guard let self, self.requestID == request, self.flow?.driver == driver else { return }
          self.step()
        }
      } else if !missing.isEmpty {
        // Nothing here can install it: say what is missing rather than run a command that fails.
        flow.phase = .failed(.install, missing: missing)
      } else if let command = actions.command(for: flow.driver, action: action), let job = actions.run(command, driver: flow.driver) {
        if step != .install && !flow.installs { flow.app = BundledCLI.app(snapshot?.path) }
        flow.phase = step == .install ? .installing : step == .signIn ? .signingIn : .updating
        if step == .install { flow.installs = true }
        if step == .update { flow.updates = true }
        watch(job)
      } else {
        flow.phase = .failed(step)
      }
    case .checking:
      flow.phase = .failed(Self.ran(flow.phase))
    }
    self.flow = flow
  }
  private func watch(_ job: HarnessJob) {
    let request = requestID
    let driver = flow?.driver
    jobWatch = job.$state.receive(on: RunLoop.main).sink { [weak self] state in
      guard let self, self.requestID == request, var flow = self.flow, flow.driver == driver else { return }
      switch state {
      case .running, .cancelled: return
      case .succeeded: self.step()
      case .failed(let why):
        flow.phase = .failed(Self.ran(flow.phase))
        flow.reason = why
        self.flow = flow
      }
    }
  }
  /// The step a phase was running, for its failed line.
  nonisolated static func ran(_ phase: Phase) -> Step {
    switch phase {
    case .installing: return .install
    case .signingIn: return .signIn
    case .updating: return .update
    case .failed(let step, _): return step
    case .checking, .connected: return .check
    }
  }
  /// Done, Cancel or Close: anything still running stops, and the sheet goes.
  func dismiss() {
    requestID = nil
    jobWatch = nil
    if flow != nil { HarnessActions.shared.close() }
    flow = nil
    showOthers = false
    inline = false
    release()
    // Connected another way while the sheet was up (Settings › AI apps, a terminal): what was
    // held goes now.
    DispatchQueue.main.async { RelayOrchestrator.shared?.releaseHeld() }
  }
  func showOtherApps() {
    requestID = nil
    inline = false
    jobWatch = nil
    if flow != nil { HarnessActions.shared.close() }
    flow = nil
    release()
    showOthers = true
  }
  private func claim() {
    guard !HarnessActions.shared.setupVisible else { return }
    HarnessActions.shared.setupVisible = true
    claimedSetup = true
  }
  private func release() {
    guard claimedSetup else { return }
    claimedSetup = false
    HarnessActions.shared.setupVisible = false
  }
  /// A local chat fixture: no probing, install, sign-in or terminal is started.
  func previewInline(_ driver: HarnessDriver, phase: Phase = .signingIn) {
    guard RunMode.previewing else { return }
    inline = true
    showOthers = false
    flow = Flow(driver: driver, phase: phase)
  }
  /// `--ui-serein-no-ai-connecting [signin|done|failed|missing|update|found]`: the sheet partway
  /// through installing Claude Code, signing in, connected, with the install failed, with Codex
  /// unable to install (no npm or Homebrew), updating a Claude Code too old for Serein, or with
  /// Codex found in the ChatGPT app and connected; `--ui-serein-other-apps
  /// [installing|missing]`: the full list, checked (Cursor installed and not signed in, the rest not
  /// installed), with OpenCode installing, or on a Mac without npm or Homebrew. In memory;
  /// nothing runs.
  func preview() {
    let arguments = CommandLine.arguments
    guard arguments.contains("--ui-preview") else { return }
    if arguments.contains("--ui-serein-other-apps") {
      let mode = arguments.drop(while: { $0 != "--ui-serein-other-apps" }).dropFirst().first
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        let registry = HarnessRegistry.shared
        var snapshots: [HarnessDriver: HarnessSnapshot] = [:]
        for instance in registry.settings.instances {
          var s = HarnessSnapshot(instance: instance)
          s.checkedAt = Date()
          if instance.driver == .cursor {
            s.installed = true
            s.version = "2026.01.01"
            s.signedIn = false
            s.path = "/usr/local/bin/cursor-agent"
          }
          (s.status, s.message) = HarnessSnapshot.summarize(s, name: instance.name)
          snapshots[instance.driver] = s
        }
        registry.installPreview(snapshots, settings: registry.settings)
        if mode == "installing" { HarnessBusy.preview = HarnessBusy(driver: .opencode, kind: .install) }
        if mode == "missing" { HarnessActions.previewMissing = ["npm", "brew"] }
        // With `--ui-serein-connect-menu`, the same Mac under the header's menu instead.
        self.showOthers = !arguments.contains("--ui-serein-connect-menu")
      }
      return
    }
    guard arguments.contains("--ui-serein-no-ai-connecting") else { return }
    let flow: Flow
    switch arguments.drop(while: { $0 != "--ui-serein-no-ai-connecting" }).dropFirst().first {
    case "signin": flow = Flow(driver: .claude, phase: .signingIn, installs: true)
    case "done": flow = Flow(driver: .claude, phase: .connected, installs: true)
    case "failed": flow = Flow(driver: .claude, phase: .failed(.install), installs: true)
    case "missing": flow = Flow(driver: .codex, phase: .failed(.install, missing: ["npm", "brew"]))
    case "update": flow = Flow(driver: .claude, phase: .updating, updates: true)
    case "found": flow = Flow(driver: .codex, phase: .connected, app: "ChatGPT")
    default: flow = Flow(driver: .claude, phase: .installing, installs: true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      self.flow = flow
    }
  }

  // MARK: copy

  static func installing(_ name: String) -> String { "Installing \(name). This takes about a minute." }
  static func updating(_ name: String) -> String { "Updating \(name). This version is too old for Serein." }
  static func updated(_ name: String) -> String { "\(name) is up to date." }
  static func signIn(_ driver: HarnessDriver) -> String {
    if HarnessCommands.signsInInTerminal(driver, version: HarnessRegistry.shared.snapshots[driver]?.version) {
      return "Sign in to \(driver.displayName) below. Answer its questions there."
    }
    if let account = account(driver) { return "A page opens in your browser. Sign in with your \(account) account there." }
    return "A page opens in your browser. Sign in there."
  }
  /// The account an app signs in with: Claude for Claude Code, ChatGPT for Codex.
  static func account(_ driver: HarnessDriver) -> String? {
    driver == .claude ? "Claude" : driver == .codex ? "ChatGPT" : nil
  }
  static func installed(_ name: String) -> String { "\(name) is installed." }
  static func found(_ name: String, in app: String) -> String { "\(name) comes with the \(app) app on this Mac." }
  static func signedIn(_ driver: HarnessDriver) -> String {
    // True whether the sign-in just happened or was done before (Codex in the ChatGPT app).
    account(driver).map { "You’re signed in with your \($0) account." } ?? "You’re signed in to \(driver.displayName)."
  }
  static func connected(_ name: String) -> String { "\(name) is connected." }
  /// The failed line: what is missing when nothing could run, otherwise which step did not finish
  /// and its job's reason.
  nonisolated static func failure(_ name: String, step: SereinConnect.Step, missing: [String], reason: String? = nil) -> String {
    missing.isEmpty ? failed(name, step: step, reason: reason) : AgentSetup.missingToolsLine(name: name, tools: missing)
  }
  nonisolated static func failed(_ name: String, step: SereinConnect.Step, reason: String? = nil) -> String {
    let line: String
    switch step {
    case .check: line = "Serein could not check \(name) on this Mac."
    case .install: line = "\(name) did not install."
    case .signIn: line = "\(name) did not sign in."
    case .update: line = "\(name) did not update."
    }
    return [line, reason].compactMap { $0 }.joined(separator: " ")
  }
  /// “Other AI apps…”: the footer's line for an app's job, in the same words. `ready`: the app
  /// is signed in now (an install may find it signed in already).
  static func jobLine(_ driver: HarnessDriver, kind: HarnessCommand.Kind, state: HarnessJob.State, ready: Bool) -> String {
    let name = driver.displayName
    switch (state, kind) {
    case (.running, .install): return installing(name)
    case (.running, .signIn): return signIn(driver)
    case (.running, _): return "Updating \(name)…"
    case (.succeeded, .install): return ready ? connected(name) : "\(name) is installed. Sign in next."
    case (.succeeded, .signIn): return connected(name)
    case (.succeeded, _): return "\(name) is up to date."
    case (_, .install): return failed(name, step: .install) + " Show details to see why."
    case (_, .signIn): return failed(name, step: .signIn) + " Show details to see why."
    case (_, _): return "\(name) did not update. Show details to see why."
    }
  }
  /// The row's word while its app's job runs, in place of its button.
  static func busyWord(_ kind: HarnessCommand.Kind) -> String {
    switch kind {
    case .install: return "Installing…"
    case .signIn: return "Signing in…"
    default: return "Updating…"
    }
  }
}

/// The sheet over Serein's window while an AI app connects: “Connecting Claude Code”, then one
/// plain line per step, the terminal behind Show details, and Try again when a step fails.
struct SereinConnectSheet: View {
  @ObservedObject var connect = SereinConnect.shared
  @ObservedObject private var actions = HarnessActions.shared
  let agent: AgentModel
  var inline = false
  @State private var details = false
  @Environment(\.palette) private var p

  var body: some View {
    Group {
      if let flow = connect.flow {
        connecting(flow)
      } else {
        others
      }
    }.environment(\.palette, p)
  }

  private func connecting(_ flow: SereinConnect.Flow) -> some View {
    let name = flow.driver.displayName
    return VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        HarnessGlyph(provider: Provider(flow.driver), size: 18, tinted: true).frame(width: 22, height: 22)
        // The title names the app; the ticked line under it says it is connected.
        Text(flow.phase == .connected || flow.phase.failed ? name : "Connecting \(name)").role(.section)
          .accessibilityAddTraits(.isHeader)
      }
      VStack(alignment: .leading, spacing: 10) {
        switch flow.phase {
        case .checking:
          line("Checking \(name) on this Mac…", state: .working)
        case .installing:
          line(SereinConnect.installing(name), state: .working)
        case .signingIn:
          if flow.installs { line(SereinConnect.installed(name), state: .done) }
          if let app = flow.app { line(SereinConnect.found(name, in: app), state: .done) }
          line(SereinConnect.signIn(flow.driver), state: .working)
        case .updating:
          line(SereinConnect.updating(name), state: .working)
        case .connected:
          // Finished steps say what was done; only a working step says what happens.
          if flow.installs { line(SereinConnect.installed(name), state: .done) }
          if let app = flow.app { line(SereinConnect.found(name, in: app), state: .done) }
          if flow.updates { line(SereinConnect.updated(name), state: .done) }
          line(SereinConnect.signedIn(flow.driver), state: .done)
          line(SereinConnect.connected(name), state: .done)
        case .failed(let step, let missing):
          if flow.installs && step != .install { line(SereinConnect.installed(name), state: .done) }
          if flow.updates && step != .update { line(SereinConnect.updated(name), state: .done) }
          line(SereinConnect.failure(name, step: step, missing: missing, reason: flow.reason), state: .failed)
          // The ways forward: Codex also comes with the ChatGPT app (found by itself once it is
          // installed), and Claude Code installs with curl, which every Mac has.
          if !missing.isEmpty && flow.driver == .codex {
            Text("The latest ChatGPT app for Mac includes Codex. Install it, then choose Connect Codex again.")
              .role(.meta).fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
          }
          if !missing.isEmpty && flow.driver != .claude {
            Text("Claude Code needs nothing extra. Connect it instead, with your Claude account.")
              .role(.meta).fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
          }
        }
      }
      // An app that signs in in its own terminal asks its questions there, so it shows by itself.
      if details || Self.answersInTerminal(flow) {
        if let job = actions.job {
          HarnessTerminalPane(job: job) { connect.dismiss() }.frame(height: 340)
        } else {
          Text("Nothing has run yet.").role(.meta)
        }
      }
      HStack(spacing: 10) {
        // Nothing ran when a needed tool is missing, so there is nothing to show.
        if !Self.missing(flow.phase) && !Self.answersInTerminal(flow) {
          Button(details ? "Hide details" : "Show details") { details.toggle() }
            .buttonStyle(QuietButton()).fixedSize()
            .help("What \(name) prints while it installs and signs in")
        }
        Spacer(minLength: 0)
        switch flow.phase {
        case .connected:
          Button("Done") { connect.dismiss() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
        case .failed where !inline && Self.missing(flow.phase) && flow.driver != .claude:
          // Try again would fail the same way until npm or Homebrew is installed.
          Button("Close") { connect.dismiss() }.buttonStyle(QuietButton())
          Button("Connect Claude Code") { connect.start(.claude) }.buttonStyle(PrimaryButton())
            .keyboardShortcut(.defaultAction)
            .help("Install Claude Code if it is missing, then sign in with your Claude account")
        case .failed:
          Button("Close") { connect.dismiss() }.buttonStyle(QuietButton())
          Button("Try again") { connect.start(flow.driver, inline: inline) }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
        default:
          Button("Cancel") { connect.dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        }
      }
    }.padding(inline ? 0 : 24)
      .frame(width: inline ? nil : (details || Self.answersInTerminal(flow) ? 640 : 460), alignment: .leading)
      .frame(maxWidth: inline ? .infinity : nil, alignment: .leading)
      // The raised surface every sheet has, so its edge shows over the dimmed window in dark.
      .background(inline ? Color.clear : p.raised)
      .onChange(of: flow.phase) { _, phase in
        let words: String
        switch phase {
        case .connected: words = SereinConnect.connected(name)
        case .failed(let step, let missing): words = SereinConnect.failure(name, step: step, missing: missing, reason: flow.reason)
        default: return
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
      }
  }

  private static func answersInTerminal(_ flow: SereinConnect.Flow) -> Bool {
    flow.phase == .signingIn
      && HarnessCommands.signsInInTerminal(flow.driver, version: HarnessRegistry.shared.snapshots[flow.driver]?.version)
  }
  /// A failure found before anything ran: the install needs a tool this Mac does not have.
  private static func missing(_ phase: SereinConnect.Phase) -> Bool {
    if case .failed(_, let missing) = phase { return !missing.isEmpty }
    return false
  }

  private enum LineState { case working, done, failed }
  private func line(_ words: String, state: LineState) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Group {
        switch state {
        case .working: ProgressView().controlSize(.mini)
        case .done: InterfaceIcon(systemName: "checkmark", size: 11).foregroundStyle(p.success)
        case .failed: InterfaceIcon(systemName: "exclamationmark.triangle", size: 11).foregroundStyle(p.warning)
        }
      }.frame(width: 14).accessibilityHidden(true)
      Text(words).font(UIStyle.body).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
    }.accessibilityElement(children: .combine)
  }

  /// “Other AI apps…”: every AI app on this Mac, each with its own Install or Sign in. While one
  /// installs or signs in, the footer says so (Show details opens the terminal above it) and
  /// reads Cancel; Done once nothing runs.
  private var others: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Other AI apps").role(.title).accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 24).padding(.top, 22)
      AgentSetupStep(agent: agent, fromSerein: true, listCap: details && actions.job != nil ? 240 : 560)
      // An app that signs in inside its own terminal shows it while that runs: nothing opens
      // in the browser, and its questions wait there.
      if let job = actions.job, details || (job.command.kind == .signIn && job.state == .running
          && HarnessCommands.signsInInTerminal(job.driver, version: HarnessRegistry.shared.snapshots[job.driver]?.version)) {
        HarnessTerminalPane(job: job) {
          actions.close()
          details = false
        }.frame(height: 280).padding(.horizontal, 24).padding(.bottom, 12)
      }
      Rectangle().fill(p.line).frame(height: 1)
      SereinOtherAppsFooter(details: $details) { connect.dismiss() }.padding(16)
    }.frame(width: 620).fixedSize(horizontal: false, vertical: true).background(p.raised)
  }
}

/// The “Other AI apps…” footer: the line for what runs (or ran), Show details, and Cancel while
/// it runs or Done.
private struct SereinOtherAppsFooter: View {
  @Binding var details: Bool
  let close: () -> Void
  @ObservedObject private var actions = HarnessActions.shared
  var body: some View {
    if let job = actions.job {
      JobFooter(job: job, details: $details, close: close)
    } else if let busy = HarnessBusy.preview {
      row(driver: busy.driver, kind: busy.kind, state: .running)
    } else {
      row(driver: nil, kind: .install, state: .succeeded)
    }
  }
  private struct JobFooter: View {
    @ObservedObject var job: HarnessJob
    @Binding var details: Bool
    let close: () -> Void
    var body: some View {
      SereinOtherAppsFooter.content(driver: job.driver, kind: job.command.kind, state: job.state, details: $details, close: close)
    }
  }
  private func row(driver: HarnessDriver?, kind: HarnessCommand.Kind, state: HarnessJob.State) -> some View {
    Self.content(driver: driver, kind: kind, state: state, details: $details, close: close)
  }
  @ViewBuilder static func content(driver: HarnessDriver?, kind: HarnessCommand.Kind, state: HarnessJob.State,
                                   details: Binding<Bool>, close: @escaping () -> Void) -> some View {
    HStack(spacing: 10) {
      if let driver {
        HarnessJobLine(driver: driver, kind: kind, state: state)
        Button(details.wrappedValue ? "Hide details" : "Show details") { details.wrappedValue.toggle() }
          .buttonStyle(QuietButton()).fixedSize()
          .help("What \(driver.displayName) prints while it installs and signs in")
      }
      Spacer(minLength: 0)
      if let driver, state == .running {
        Button("Cancel", action: close).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
          .help(kind == .signIn ? "Stop signing in to \(driver.displayName) and close" : "Stop installing \(driver.displayName) and close")
      } else {
        Button("Done", action: close).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
      }
    }
  }
}

extension SereinConnect {
  /// The connect menu's apps (`Welcome.connectMenu`). `probed` is false until Serein has checked
  /// every app in it: an app on this Mac counts as not installed until its own check ends.
  static var menuChoices: (here: [WelcomeChoice], other: [WelcomeChoice], probed: Bool) {
    let registry = HarnessRegistry.shared
    let menu = Welcome.connectMenu(snapshots: registry.snapshots, settings: registry.settings)
    return (menu.here, menu.other, (menu.here + menu.other).allSatisfy { nextStep($0) != nil })
  }
  /// A row's next step, as the “Other AI apps” sheet works it out: Install, Sign in, Update, or
  /// Connect. Nil until that app is checked.
  static func nextStep(_ choice: WelcomeChoice) -> String? {
    HarnessPrimaryAction.of(HarnessRegistry.shared.snapshots[choice.driver]).menuWords
  }
  /// The same rows for a custom menu: each app's mark, its name and its next step, the apps on
  /// this Mac first.
  static func menuItems() -> [SereinMenuItem] {
    // Apps left unchecked at launch get no next step until something checks them; opening the menu does.
    // A Task, so building the menu never publishes.
    if HarnessRegistry.shared.hasUnchecked { Task { HarnessRegistry.shared.probeDeferred() } }
    let menu = menuChoices
    var items: [SereinMenuItem] = []
    if menu.probed, !menu.here.isEmpty { items.append(.header("On this Mac")) }
    items += menu.here.map { choice in .app(choice, detail: nextStep(choice)) { shared.start(choice.driver) } }
    if menu.probed, !menu.other.isEmpty { items.append(.header("Not on this Mac")) }
    items += menu.other.map { choice in .app(choice, detail: nextStep(choice)) { shared.start(choice.driver) } }
    return items + [.divider, .action("Other AI Apps…") { shared.showOtherApps() }]
  }
}
