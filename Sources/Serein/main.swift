import Cocoa
import Combine
import CoreText
import SereinCore
import SereinEngines
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var browser: BrowserModel!
  var agent: AgentModel!
  var preview: UIPreview?
  private var textSizeWatch: AnyCancellable?
  /// While the window is closed and only work keeps Serein running, this watches for the end of
  /// that work, then quits.
  private var workWatch: AnyCancellable?
  /// File › Stop Everything; its key follows the Stop everything shortcut in Settings › Assistants › Ask from any app.
  private var stopEverythingItem: NSMenuItem?
  /// The last window is closing: the quit that follows asks nothing.
  var closingLastWindow = false
  /// The main window's close question was answered with Close anyway, so the quit that follows
  /// the last window closing asks nothing more.
  var closeAnswered = false
  /// Addresses that came before the browser existed: macOS gives the link that started the app
  /// to the delegate before applicationDidFinishLaunching.
  /// Watches every window closing, so the last one decides whether Serein quits.
  private var closeWatch: NSObjectProtocol?
  func applicationDidFinishLaunching(_ notification: Notification) {
    // AppKit asks applicationShouldTerminateAfterLastWindowClosed only once no window is visible,
    // and the hidden windows PageAX parks agent pages in count as visible. So closing a window
    // decides too, once it is gone.
    closeWatch = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let closing = note.object as? NSWindow, closing.styleMask.contains(.titled), !(closing is NSPanel) else { return }
      MainActor.assumeIsolated {
        DispatchQueue.main.async {
          // Only when a hidden agent page keeps AppKit from asking; otherwise AppKit's own
          // callback decides, and deciding twice could ask the request question twice.
          guard let self, NSApp.windows.contains(where: { PageAX.isHost($0) && $0.isVisible }),
            !self.userWindowOpen(excluding: closing), self.afterLastWindow() else { return }
          NSApp.terminate(nil)
        }
      }
    }
    #if DEBUG
    if CommandLine.arguments.contains("--verify") {
      checkMessagePieces()
    }
    #endif
    do {
      preview = try UIPreview.configuration()
      preview?.installDefaults()
    } catch {
      FileHandle.standardError.write(Data("Serein UI preview: \(error.localizedDescription)\n".utf8))
      exit(2)
    }
    AppearanceController.shared.start(override: preview?.appearance)
    UserDefaults.standard.register(defaults: ["serein.sleepMinutes": 30])
    if let fonts = Bundle.assets.url(forResource: "Fonts", withExtension: nil),
      let urls = try? FileManager.default.contentsOfDirectory(
        at: fonts, includingPropertiesForKeys: nil)
    {
      for url in urls where ["otf", "ttf"].contains(url.pathExtension.lowercased()) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
    #if DEBUG
    // After the main window, so the gallery ends up in front of it.
    if CommandLine.arguments.contains("--component-gallery") {
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        ComponentGallery.open()
      }
    }
    #endif
    let root = preview?.root ??
      ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Serein/Library")
    // One Serein for each library: a second copy would write the same session, history and
    // thread files, and the last one to write would win.
    if ProcessInfo.processInfo.environment["SEREIN_SINGLE_INSTANCE"] == "1" {
      if !ManagedLocalServer.start(directory: root, singleInstance: true) {
        FileHandle.standardError.write(Data("The managed local server did not start.\n".utf8))
        exit(3)
      }
    }
    guard LibraryLock.take(root) else {
      FileHandle.standardError.write(Data("Another Serein is using this library.\n".utf8))
      let other = NSRunningApplication.runningApplications(
        withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
      ).first { $0 != NSRunningApplication.current }
      other?.activate()
      // Not through terminate: that would mark a clean exit for the copy that still runs.
      exit(3)
    }
    // CLIs a crashed or quit Serein left running end now; a running Serein's are left alone.
    ProcessGroup.endLeftovers()
    Task { await Engines.shared.sweepLeftovers() }
    Engines.shared.endGroupsOnSIGTERM()
    // Every switch and consent that loosens a gate lives in the Library, which no harness can
    // reach (GateSettings): read it before anything asks, and move the old UserDefaults values
    // in once. Previews, checks and the stress driver keep theirs in memory.
    if RelayOrchestrator.persists {
      GateSettings.shared.open(root: root)
      GateSettings.shared.migrate(GateKeys.all, maps: GateKeys.maps, from: .standard)
    }
    // Decoded beside the browser's setup rather than after it (AgentModel.launchThreads).
    AgentModel.readThreadsEarly(root: root)
    do { browser = try BrowserModel(root: root) } catch {
      NSAlert(error: error).runModal()
      NSApp.terminate(nil)
      return
    }
    UsageStats.shared.start(browser: browser)
    RouteUsage.shared.start(library: browser.library)
    PluginHost.shared.configure(library: browser.library)
    #if DEBUG
    let relayCheck = CommandLine.arguments.contains("--verify-relay") || CommandLine.arguments.contains("--verify-plugins")
    let e2eCheck = CommandLine.arguments.contains("--verify-e2e")
    #else
    // Checks and probes exist only in debug builds; a release build ignores their flags.
    let relayCheck = false
    let e2eCheck = false
    #endif
    agent = AgentModel(browser: browser, discoverProviders: preview == nil && !RunMode.stress && !relayCheck && !e2eCheck)
    browser.intelligenceAgent = agent
    SereinRouter.attach(browser: browser, agent: agent)
    SereinRouter.bringWindowForward = { [weak self] in self?.showWindow() }
    if preview == nil, !RunMode.stress, !e2eCheck { ExternalSessionStore.shared.start() }
    if preview == nil, !RunMode.stress { OutsideAgents.start(root: root, browser: browser) }
    // Every preview, release builds included: Serein's column with no shortcuts and no menu bar
    // item. `--ui-relay` adds a synthetic chat, run, steps and approval.
    if preview != nil {
      RelayController.previewing = true
      RelayController.start(agent: agent, browser: browser)
    }
    if let preview {
      do { try preview.seed(browser: browser, agent: agent) } catch {
        FileHandle.standardError.write(Data("Serein UI preview: \(error.localizedDescription)\n".utf8))
        exit(2)
      }
      if RelayOrchestrator.previewSeeded { RelayController.shared?.relay.previewSeed() }
      RelayController.shared?.relay.previewTeam()
      // Held messages (no AI app, offline, written long ago), the ⌥Space bar, and the connect sheet.
      RelayController.shared?.relay.previewHeld()
      RelayController.shared?.previewBar()
      ScreenSignals.shared.preview()
      SereinConnect.shared.preview()
      agent.flow.previewReadyToast()
      // The finish toast's preview hides Serein too, and shows its own toast instead.
      if CommandLine.arguments.contains("--ui-serein-hidden"), !CommandLine.arguments.contains("--ui-serein-toast") {
        SereinRouter.showHiddenToast(duration: nil)
      }
      if CommandLine.arguments.contains("--ui-relay-call") { RelayController.shared?.callMode = true }
      // The card that floats over System Settings, alone at the bottom of the main screen.
      if CommandLine.arguments.contains("--ui-mac-access-drag-card") {
        MacAccessGuide.show(.accessibility, palette: Palette.current, stays: true)
      }
    } else if !e2eCheck {
      SessionDiscoveryModel.shared.attach(browser)
    }
    SessionExtras.shared.attach(browser)
    TaskRecordings.shared.attach(browser)
    StepPictures.shared.attach(browser)
    TaskShelf.shared.attach(browser, hub: agent.hub)
    ComputerHost.shared.attach(browser, hub: agent.hub)
    RecipeBook.shared.attach(browser.library)
    ShortcutBook.shared.attach(browser.library)
    TodoBook.shared.attach(browser.library, hub: agent.hub)
    SiteBook.shared.attach(browser.library)
    // With wake words on the dictation model loads beside the launch; otherwise on the first dictation.
    if !RunMode.automated, !RunMode.stress, SpeechEngine.warmsAtLaunch(wakeWords: WakeListener.enabled) {
      Task { await SpeechEngine.shared.warm() }
    }
    if preview == nil, !RunMode.stress, !e2eCheck { ProjectActivityStore.shared.attach(browser) }
    // Relay: the orchestrator answers its own run's tools; the panel, menu bar item and shortcuts
    // appear only once it is turned on in Settings › Relay.
    if preview == nil, !RunMode.stress, !CommandLine.arguments.contains(where: { $0.hasPrefix("--verify") && !["--verify-relay", "--verify-plugins", "--verify-relay-live", "--verify-first-read-live", "--verify-session-report", "--verify-connectors-live", "--verify-e2e", "--verify-session-status"].contains($0) }) {
      RelayController.start(agent: agent, browser: browser)
      if let relay = RelayController.shared?.relay {
        GuideCenter.shared.bootstrap(
          transcriptNotEmpty: relay.transcript.contains {
            ($0.role == "you" || $0.role == "user") && RelayAutomatic.kind(of: $0.text) == nil
          },
          barEnabled: UserDefaults.standard.bool(forKey: RelayOrchestrator.enabledKey),
          barUsed: UserDefaults.standard.bool(forKey: SereinGuide.barUsedKey),
          approvalsUserSet: UserDefaults.standard.bool(forKey: ApprovalLevel.userSetKey))
      }
      RelayController.shared?.openThread = { [weak self] id in self?.showThread(id) }
      RelayController.shared?.openSettings = { [weak self] in self?.showSettings($0) }
      RelayController.shared?.openWindow = { [weak self] in self?.showWindow() }
      // Keep the Mac awake while tasks run (Settings › General, off by default); never in checks.
      if RelayOrchestrator.persists, let relay = RelayController.shared?.relay { MacAwake.shared.start(relay: relay) }
      // Serein's texts about the sessions on this Mac; checks and previews never watch real ones.
      if RelayOrchestrator.persists, let relay = RelayController.shared?.relay { SessionStatusTexts.shared.attach(relay) }
      #if DEBUG
      // Development: open the panel at launch (the shortcut needs a person at the keyboard).
      if CommandLine.arguments.contains("--show-relay") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { RelayController.shared?.show() }
      }
      #endif
    }
    #if DEBUG
    if preview != nil, CommandLine.arguments.contains("--ui-outside-agents") {
      OutsideAgents.start(root: browser.library.root, browser: browser)
      OutsideAgents.shared?.previewSeed()
    }
    #endif
    let size = preview?.size ?? NSSize(width: 1360, height: 860)
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.backgroundColor = Palette.dynamic(\.background)
    window.title = "Serein"
    // Closing the window can keep Serein running (⌥Space, the menu bar switch, or work still
    // going); the window opens again from the Dock or the menu bar, so it must outlive its close.
    window.isReleasedWhenClosed = false
    // windowShouldClose: closing it with only a request coming up asks first (SessionExtras).
    window.delegate = self
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.minSize = NSSize(width: 1030, height: 680)
    // A preview keeps the size it asked for.
    if preview == nil {
      textSizeWatch = TextSizeController.shared.$generation.sink { [weak self] _ in
        DispatchQueue.main.async { self?.fitMinimumSize() }
      }
    }
    let host = NSHostingView(rootView: FirstRun(app: ReferenceShell(browser: browser, agent: agent))
      .overlay { relayPreview }
      .overlay { if preview != nil && CommandLine.arguments.contains("--ui-serein-quit-guard") { QuitGuardPreview() } }
      .overlay { if preview != nil && CommandLine.arguments.contains("--ui-serein-close-guard") { QuitGuardPreview(closing: true) } }
      .font(UIStyle.font(13))
      .environment(\.sereinReducedEffects, preview?.reducedEffects == true))
    host.sizingOptions = []
    host.frame = NSRect(origin: .zero, size: size)
    host.autoresizingMask = [.width, .height]
    window.contentView = host
    window.setContentSize(size)
    // Previews must come up at the requested size, never at a restored frame.
    if preview != nil { window.isRestorable = false }
    window.center()
    // A fresh install opens filling the screen's visible frame (zoomed, not full screen); later launches keep
    // the frame the person left.
    if preview == nil, RelayOrchestrator.persists {
      if !window.setFrameUsingName("Serein main window"), let screen = window.screen ?? NSScreen.main {
        window.setFrame(screen.visibleFrame, display: false)
      }
      window.setFrameAutosaveName("Serein main window")
    }
    // A background preview goes behind every window, so a click meant for another app never
    // lands in it; the capture reads it by window number. `--background` is the same for a launch
    // by `serein-agent`: Serein opens behind the agent's app and does not take the keyboard.
    let background = CommandLine.arguments.contains("--ui-background") || CommandLine.arguments.contains("--background")
    if background { window.orderBack(nil) } else { window.makeKeyAndOrderFront(nil) }
    WindowChrome.shared.attach(window)
    // A stress run, and a preview with `--ui-background`, work behind whatever the user is doing:
    // the capture reads the window by number, so it never needs the keyboard.
    if !RunMode.stress && !background { NSApp.activate(ignoringOtherApps: true) }
    menu()
    if let preview {
      Task { await preview.presentAndCapture(window: window, browser: browser, agent: agent) }
    }
    PushToTalk.shared.install(browser: browser, agent: agent)
    Updates.shared.activeTasks = { [weak agent] in agent?.hub.active.count ?? 0 }
    if preview == nil, !RunMode.stress, !e2eCheck { Updates.shared.start() }
    if RunMode.stress { StressDriver.start(browser: browser) }
    #if DEBUG
    // Checks, benches and probes: debug builds only. `--probe-harnesses` turns harnesses on and
    // would change a release user's settings.
    if CommandLine.arguments.contains("--verify") {
      Task { await SmokeTest.run(browser: browser, agent: agent, window: window) }
    }
    if let i = CommandLine.arguments.firstIndex(of: "--bench"), i + 1 < CommandLine.arguments.count {
      Task { await Bench.run(browser: browser, agent: agent, file: CommandLine.arguments[i + 1]) }
    }
    if let i = CommandLine.arguments.firstIndex(of: "--bench-first"), i + 1 < CommandLine.arguments.count {
      Task { await Bench.first(browser: browser, agent: agent, file: CommandLine.arguments[i + 1]) }
    }
    if CommandLine.arguments.contains("--probe-harnesses") {
      // Turns every harness on in this (test) library and prints what detection found. Runs
      // only version, sign-in and model-list probes: no prompt, no model call, no update.
      Task {
        let registry = HarnessRegistry.shared
        for driver in HarnessDriver.allCases where !registry.instance(driver).enabled {
          var instance = registry.instance(driver)
          instance.enabled = true
          registry.update(instance)
        }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        await registry.refreshAll()
        let lines = HarnessDriver.allCases.map { d -> String in
          let s = registry.snapshots[d]
          let offered = HarnessPolicy.offeredModes(driver: d, capabilities: s?.capabilities ?? .base(d))
          let files = ModelSources.files(d, environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
          let real = s?.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? "-"
          return "\(d.displayName): installed=\(s?.installed == true) version=\(s?.version ?? "-") latest=\(s?.latestVersion ?? "-") signedIn=\(s?.signedIn.map(String.init) ?? "unknown") update=\(s?.needsUpdate == true) models=\(registry.models(Provider(d)).count) offered=\(offered.joined(separator: ","))\n    cli=\(real) updateCommand=\(HarnessCommands.update(d).display) modelFile=\(files.models ?? "-") latestFile=\(files.latest ?? "-")"
        }
        let report = lines.joined(separator: "\n")
        print(report)
        try? (report + "\n").write(
          to: browser.library.root.appendingPathComponent("harnesses.txt"), atomically: true, encoding: .utf8)
        exit(report.contains("FAIL") ? 1 : 0)
      }
    }
    if CommandLine.arguments.contains("--probe-setup") {
      // What the automatic part of setup would bring on this Mac. Reads no cookie, key or tab.
      Task {
        print((await SetupRun.plan()).joined(separator: "\n"))
        exit(0)
      }
    }
    if CommandLine.arguments.contains("--probe-capabilities") {
      // What each harness has installed in the user's real setup (and, with `--project <folder>`,
      // that project's): skills, slash commands and MCP servers. Names and short descriptions only.
      Task {
        let args = CommandLine.arguments
        let project = args.firstIndex(of: "--project").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let report = HarnessDriver.allCases.flatMap { HarnessCatalog.describe(HarnessCatalog.read($0, project: project)) }
          .joined(separator: "\n")
        print(report)
        try? (report + "\n").write(
          to: browser.library.root.appendingPathComponent("capabilities.txt"), atomically: true, encoding: .utf8)
        exit(0)
      }
    }
    if CommandLine.arguments.contains("--verify-relay-live") {
      // Relay on the user's real Claude Code; consumes their usage. Run only on request.
      Task { [browser, agent] in
        guard let browser, let agent else { return }
        var report: String
        do { report = try await SmokeTest.relayLive(browser: browser, agent: agent).joined(separator: "\n") } catch {
          report = "FAIL: " + error.localizedDescription
        }
        print(report)
        exit(report.contains("FAIL") ? 1 : 0)
      }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--verify-session-report"), index + 3 < CommandLine.arguments.count {
      // `--verify-session-report <claude|codex> <session id> <log> [project folder] [minutes]`: the
      // finished-session report built from that real transcript, printed, with its reel when a
      // project folder is given (git and the media written in the last `minutes`, default 60);
      // no provider usage. Its reel's copies land in the library's chat-images.
      let args = Array(CommandLine.arguments[(index + 1)...(index + 3)])
      Task { @MainActor [browser] in
        guard let browser, let driver = HarnessDriver(rawValue: args[0]) else { exit(2) }
        // Codex chats are read through its app server: wait for Serein to find Codex.
        for _ in 0..<120 where driver == .codex && HarnessRegistry.shared.executable(Provider(.codex)) == nil {
          try? await Task.sleep(for: .milliseconds(500))
        }
        let rest = Array(CommandLine.arguments[(index + 4)...].prefix { !$0.hasPrefix("--") })
        let cwd = rest.first
        let minutes = rest.dropFirst().first.flatMap(Double.init) ?? 60
        var session = ExternalSession(id: args[0] + ":" + args[1], driver: driver, title: "", cwd: cwd, state: .open, updatedAt: Date())
        session.log = args[2]
        ExternalSessionStore.shared.update([session])
        let event = SessionStatusTracker.Event(
          kind: .finished, sessionID: session.id, app: driver.displayName, folder: "lab",
          startedAt: Date().addingTimeInterval(-minutes * 60))
        let report = await SessionStatusTexts.report(event, browser: browser)
        print("REPORT: " + (report?.text ?? "none"))
        if let reel = report?.reel {
          print("REEL: " + reel.summary)
          for file in reel.files { print("REEL FILE: \(file.path) +\(file.added) -\(file.removed)") }
          for media in reel.media { print("REEL MEDIA: \(media.kind.rawValue) \(media.name) -> \(media.path)") }
        }
        exit(report == nil ? 1 : 0)
      }
    }
    if CommandLine.arguments.contains("--verify-connectors-live") {
      // Each one-click app's server and sign-in found the way Connect finds them (network reads
      // only: no sign-in, no tools, nothing installed).
      Task { @MainActor in
        var failed = 0
        for connector in ConnectorCatalog.all {
          do {
            // A Composio app signs in at Composio, not at its own server.
            if case .composio(let app) = connector.signIn {
              print("PASS: \(connector.name) connects through Composio (\(app))")
              continue
            }
            let draft = try await PluginHost.shared.draft(connector.url)
            // A key app's server answers, and refuses a call without a token.
            let ok = connector.signIn.key == nil ? draft.canSignIn && draft.auth == .oauth : draft.auth == .token
            if !ok { failed += 1 }
            let how = connector.signIn.key.map { "takes a \($0.name)" } ?? "signs in at \(draft.signInHost ?? "?")"
            print((ok ? "PASS: " : "FAIL: ") + "\(connector.name) \(how)")
          } catch {
            failed += 1
            print("FAIL: \(connector.name): \(error.localizedDescription)")
          }
        }
        print(failed == 0 ? "RESULT: all passed" : "RESULT: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
      }
    }
    if CommandLine.arguments.contains("--verify-first-read-live") {
      // Get to know you and a check-in on the person's real AI app, over synthetic chats; consumes
      // their usage. Run only on request.
      Task { [browser, agent] in
        guard let browser, let agent else { return }
        var report: String
        do { report = try await SmokeTest.firstReadLive(browser: browser, agent: agent).joined(separator: "\n") } catch {
          report = "FAIL: " + error.localizedDescription
        }
        print(report)
        exit(report.contains("\nFAIL") || report.hasPrefix("FAIL") ? 1 : 0)
      }
    }
    if CommandLine.arguments.contains("--verify-completion-live") {
      // Explicit opt-in: one tool-free provider request over supplied test evidence.
      Task { [agent] in
        guard let agent else { exit(1) }
        do { print(try await SmokeTest.completionLive(agent: agent).joined(separator: "\n")); exit(0) }
        catch { print("FAIL: " + error.localizedDescription); exit(1) }
      }
    }
    if CommandLine.arguments.contains("--verify-goals-sites") {
      Task { [browser, agent] in
        guard let browser, let agent else { exit(1) }
        do { print(try await SmokeTest.goalsSitesPersistence(browser: browser, agent: agent).joined(separator: "\n")); exit(0) }
        catch { print("FAIL: " + error.localizedDescription); exit(1) }
      }
    }
    if CommandLine.arguments.contains("--verify-session-status") {
      // Serein's status texts through the real chat, with synthetic sessions; no provider usage.
      Task { [browser] in
        guard let browser, let relay = RelayController.shared?.relay else { exit(1) }
        var report: String
        do { report = try await SmokeTest.sessionStatusDelivery(browser: browser, relay: relay).joined(separator: "\n") }
        catch { report = "FAIL: " + error.localizedDescription }
        print(report)
        exit(report.contains("FAIL") ? 1 : 0)
      }
    }
    if relayCheck {
      // Relay's orchestration through the real MCP helper and socket (fake CLI; no provider usage).
      Task { [browser, agent] in
        guard let browser, let agent else { return }
        var report: String
        do {
          if CommandLine.arguments.contains("--verify-plugins") {
            var lines = try await SmokeTest.plugins(browser: browser, agent: agent)
            lines += try await SmokeTest.oauthLive()
            report = lines.joined(separator: "\n")
          } else {
            report = try await SmokeTest.relay(browser: browser, agent: agent).joined(separator: "\n")
          }
        } catch { report = "FAIL: " + error.localizedDescription }
        print(report)
        try? (report + "\n").write(
          to: browser.library.root.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
        exit(report.contains("FAIL") ? 1 : 0)
      }
    }
    if e2eCheck {
      // One end-to-end pass over the branch's features (scripts/e2e.py): a fake CLI through the
      // real MCP helper and socket, loopback fixtures and real cards; no provider usage.
      Task { [browser, agent] in
        guard let browser, let agent else { return }
        var report: String
        do {
          report = try await SmokeTest.e2e(browser: browser, agent: agent).joined(separator: "\n")
        } catch { report = "FAIL: " + error.localizedDescription }
        print(report)
        try? (report + "\n").write(
          to: browser.library.root.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
        exit(report.contains("FAIL") ? 1 : 0)
      }
    }
    if CommandLine.arguments.contains("--verify-avatar") || CommandLine.arguments.contains("--verify-avatar-cost") {
      // Relay's hologram in its real web view (no provider usage, no network); `-cost` measures
      // its processor time in every state.
      Task { [browser, agent] in
        var report: String
        do {
          report = try await (CommandLine.arguments.contains("--verify-avatar-cost")
            ? SmokeTest.avatarCost(browser: browser, agent: agent) : SmokeTest.avatar())
            .joined(separator: "\n")
        } catch { report = "FAIL: " + error.localizedDescription }
        print(report)
        if let browser {
          try? (report + "\n").write(
            to: browser.library.root.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
        }
        exit(report.contains("FAIL") ? 1 : 0)
      }
    }
    if CommandLine.arguments.contains("--verify-harnesses") {
      // Only the harness readiness checks (fake CLIs; no provider usage).
      Task { [browser, agent] in
        guard let browser, let agent else { return }
        var report: String
        do {
          report = try await SmokeTest.harnessReadiness(browser: browser, agent: agent).joined(separator: "\n")
        } catch { report = "FAIL: " + error.localizedDescription }
        print(report)
        try? (report + "\n").write(
          to: browser.library.root.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
        exit(report.contains("FAIL") ? 1 : 0)
      }
    }
    #endif
  }
  func applicationWillTerminate(_ notification: Notification) {
    RelayOrchestrator.shared?.research.shutdown()
    // Plain reminders still to come fire from macOS while Serein is closed.
    RelayOrchestrator.shared?.handOffReminders()
    // A scheduled run waiting for an AI app's usage limit is listed as missed, not kept.
    RelayOrchestrator.shared?.missHeldRuns()
    // The Mac may sleep again as soon as Serein is gone.
    MacAwake.shared.release()
    ManagedLocalServer.close()
    UsageStats.shared.finish()
    agent?.cancel()
    // Before the browser tasks end: a recording still running is dropped, unsaved ones due go.
    TaskRecordings.shared.quit()
    // Step pictures follow the same time: under Until quit they go now.
    StepPictures.shared.quit()
    // Downloads stop and files nobody kept are deleted, before the browser tasks end.
    TaskShelf.shared.quit()
    // Serein's computers stop (their home volumes stay), before the browser tasks end.
    ComputerHost.shared.quit()
    browser?.shutdown()
    // A chats write still waiting (Library.saveSoon) lands before the app goes.
    SaveCoalescer.shared.flushAll()
    SessionExtras.shared.markCleanExit()
  }
  /// The smallest window is 1030 by 680 points at a text size of 100%. The sidebar and every
  /// label grow with larger text, so the smallest window grows too, up to the size of the
  /// screen; a window that is now too small grows to it.
  func fitMinimumSize() {
    guard let window else { return }
    let scale = max(1, UIStyle.textScale)
    let room = window.screen?.visibleFrame.size ?? NSSize(width: 1030, height: 680)
    let least = NSSize(
      width: max(1030, min((1030 * scale).rounded(), room.width)),
      height: max(680, min((680 * scale).rounded(), room.height)))
    window.minSize = least
    var frame = window.frame
    guard frame.width < least.width || frame.height < least.height else { return }
    frame.size = NSSize(width: max(frame.width, least.width), height: max(frame.height, least.height))
    window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
  }
  /// Previews of what floats over other apps, drawn over the window (release builds too): the
  /// panel (`--ui-relay-panel`), and the ⌥Space bar with its reply card (`--ui-serein-bar-*`).
  @ViewBuilder private var relayPreview: some View {
    if preview != nil, let controller = RelayController.shared {
      if CommandLine.arguments.contains("--ui-relay-panel") {
        RelayPreviewLayer(controller: controller)
      } else if SereinBarPreviewLayer.active {
        SereinBarPreviewLayer(controller: controller)
      }
    }
  }
  /// ⌘J, File › Show Serein Beside / Show Serein Full / Back to Your Tab: Serein full ⇄ beside
  /// (from hidden, beside turns on). The title and what it does come from `SereinLayout`
  /// (validateMenuItem reads the same answer). It never changes ⌥Space.
  @objc func toggleRelayColumn() { SereinRouter.toggleFullBeside() }
  /// File › Stop Everything: Serein's reply and every task it started stop, and its reminders and
  /// alerts pause until the user resumes. Works with ⌥Space off.
  @objc func stopEverything() { RelayController.shared?.killSwitch() }
  /// Something would stop if Serein quit: its own reply, or any task.
  var assistantWorking: Bool {
    (RelayOrchestrator.shared?.working ?? false) || (RelayOrchestrator.shared?.research.isWorking ?? false)
      || !(agent?.hub.active.isEmpty ?? true)
  }
  /// The key of File › Stop Everything follows the Stop everything shortcut in Settings.
  func refreshStopEverythingKey() {
    guard let item = stopEverythingItem else { return }
    let text = UserDefaults.standard.string(forKey: RelayOrchestrator.killKey) ?? RelayHotKey.killSwitch
    guard let key = RelayHotKey.menuKey(text) else {
      item.keyEquivalent = ""
      return
    }
    var mask: NSEvent.ModifierFlags = []
    if key.modifiers & 0x100 != 0 { mask.insert(.command) }
    if key.modifiers & 0x200 != 0 { mask.insert(.shift) }
    if key.modifiers & 0x800 != 0 { mask.insert(.option) }
    if key.modifiers & 0x1000 != 0 { mask.insert(.control) }
    item.keyEquivalent = key.key
    item.keyEquivalentModifierMask = mask
  }
  /// The window closing quits Serein unless something keeps it: ⌥Space or the menu bar switch,
  /// or work that would stop (it keeps running in the Dock until that work ends). Checks end
  /// themselves; hiding their windows never quits them.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    afterLastWindow()
  }
  /// The last window is gone: true when Serein should quit now. Work that would stop keeps it
  /// running until that work ends; ⌥Space or the menu bar switch keep it running for good.
  private func afterLastWindow() -> Bool {
    if RunMode.automated { return false }
    if RelayOrchestrator.enabled || RelayOrchestrator.menuBar { return false }
    if assistantWorking {
      watchWorkThenQuit()
      return false
    }
    return quitAfterLastWindow()
  }
  /// The window closed while work ran: quit once it ends, unless a window came back or a switch
  /// now keeps Serein running.
  private func watchWorkThenQuit() {
    guard workWatch == nil, let agent else { return }
    let sending = RelayOrchestrator.shared?.$sending.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()
    // A run that ends changes neither the list nor `sending`; its record is written, which bumps
    // the hub's revision.
    workWatch = Publishers.CombineLatest3(agent.hub.$runs, agent.hub.$revision, sending)
      .receive(on: RunLoop.main).sink { [weak self] _ in
      // Read on the next turn: the published values change just before they are stored.
      DispatchQueue.main.async {
        guard let self, self.workWatch != nil, !self.assistantWorking else { return }
        self.workWatch = nil
        guard !self.userWindowOpen(), !RelayOrchestrator.enabled, !RelayOrchestrator.menuBar else { return }
        _ = self.quitAfterLastWindow()
        NSApp.terminate(nil)
      }
    }
  }
  /// The menu bar item's "Show Serein Window".
  func showWindow() {
    RelayController.shared?.hide(deferring: false, review: false)
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag, let window { window.makeKeyAndOrderFront(nil) }
    return true
  }
  /// Serein's window on a chat, by the rule per kind (SereinRouter): Serein's own chat in the
  /// Serein surface, a task it started beside the main view, any other chat as a task tab.
  func showThread(_ id: String) {
    RelayController.shared?.hide(deferring: false, review: false)
    SereinRouter.open(threadID: id)
    browser?.showSettings = false
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func showSettings(_ section: String) {
    RelayController.shared?.hide(deferring: false, review: false)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    // Apps, connections and plugins are managed in the Marketplace: an old link opens its place there.
    if let place = SettingsCategory.moved(section) {
      browser?.openMarketplace(place)
      return
    }
    UserDefaults.standard.set(section, forKey: "serein.settingsSection")
    browser?.showSettings = true
  }
  func menu() {
    let bar = NSMenu()
    let appItem = NSMenuItem()
    bar.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(withTitle: "About Serein", action: #selector(about), keyEquivalent: "").target =
      self
    appMenu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",")
      .target = self
    appMenu.addItem(
      withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""
    ).target = self
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit Serein", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let fileItem = NSMenuItem()
    bar.addItem(fileItem)
    let file = NSMenu(title: "File")
    fileItem.submenu = file
    file.addItem(withTitle: "Close", action: #selector(closeFront), keyEquivalent: "w").target = self
    file.addItem(withTitle: "Ask Serein", action: #selector(ask), keyEquivalent: "e").target =
      self
    file.addItem(withTitle: "Search", action: #selector(search), keyEquivalent: "k").target = self
    // Show Serein Beside, Show Serein Full or Back to Your Tab (validateMenuItem).
    file.addItem(withTitle: "Show Serein Beside", action: #selector(toggleRelayColumn), keyEquivalent: "j").target = self
    let stop = file.addItem(withTitle: "Stop Everything", action: #selector(stopEverything), keyEquivalent: "")
    stop.target = self
    stopEverythingItem = stop
    refreshStopEverythingKey()
    file.addItem(withTitle: "Toggle Sidebar", action: #selector(wall), keyEquivalent: "\\").target =
      self
    let editItem = NSMenuItem()
    bar.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    editItem.submenu = edit
    for (name, action, key) in [
      ("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
    ] { edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key) }
    installBrowserMenus(bar)
    installWorkflowMenus(bar)
    GuidanceMenu.shared.install(in: bar)
    NSApp.mainMenu = bar
  }
  @objc func about() {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Serein", .applicationVersion: Updates.version,
      .credits: NSAttributedString(
        string: "A personal assistant for your Mac.\nIndependent implementation. Local development build."
      ),
    ])
  }
  @objc func settings() { browser.showSettings = true }
  @objc func checkForUpdates() { Updates.shared.check() }
  /// ⌘W: a page a task handed you while it shows in the main window, otherwise the window in front.
  @objc func closeFront() {
    if NSApp.keyWindow === window, let tab = BrowserContext.activeTab {
      browser.close(tab, remember: false)
    } else {
      NSApp.keyWindow?.performClose(nil)
    }
  }
  /// ⌘E, File › Ask Serein: Serein's chat, focused.
  @objc func ask() {
    NotificationCenter.default.post(name: Notification.Name("SereinAsk"), object: nil)
  }
  @objc func wall() {
    NotificationCenter.default.post(name: Notification.Name("SereinWall"), object: nil)
  }
  /// ⌘K, File › Search: the Search palette over the main window, or away again. Not under a sheet
  /// (a sign-in or a review), which would cover it.
  @objc func search() {
    guard window.attachedSheet == nil else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    SearchPaletteCenter.shared.open.toggle()
  }
}
/// The lock on a library folder. It ends with the process, so a crash leaves nothing behind,
/// and the programs Serein starts do not take it with them.
enum LibraryLock {
  private static var descriptor: Int32 = -1
  static func take(_ root: URL) -> Bool {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    // A folder that cannot hold a lock does not stop the launch.
    guard file >= 0 else { return true }
    if flock(file, LOCK_EX | LOCK_NB) != 0 {
      let taken = errno == EWOULDBLOCK
      close(file)
      return !taken
    }
    descriptor = file
    return true
  }
}
// Scrollbars are a thumb over the content, with no track or border beside it, even with a mouse
// attached. A registered default: choosing “Always” in System Settings still wins.
UserDefaults.standard.register(defaults: ["AppleShowScrollBars": "WhenScrolling"])
// Only a normal launch opens the person's library (LaunchMode). The system's own temp folder,
// not TMPDIR, so no environment value moves the line.
let libraryAllowed: Bool = {
  func real(_ path: String) -> String? {
    realpath(path, nil).map { defer { free($0) }; return String(cString: $0) }
  }
  var userTemp = [CChar](repeating: 0, count: Int(PATH_MAX))
  let temporary = [confstr(_CS_DARWIN_USER_TEMP_DIR, &userTemp, userTemp.count) > 0 ? real(String(cString: userTemp)) : nil, real("/tmp")]
  let library = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"].flatMap(real)
  return RunMode.mode.mayOpen(library: library, temporary: temporary.compactMap { $0 })
}()
func refuseLibrary() -> Never {
  FileHandle.standardError.write(
    Data("Checks, previews and stress runs need SEREIN_DATA_DIR set to a folder in the system's temp folders: they never open a library someone uses.\n".utf8))
  exit(2)
}
// The checks below run before the app starts. One handed a library gets only a temp one; one handed
// none makes its own (`--verify-assistant-core` as the docs run it), and the app's start refuses it.
if ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"] != nil, !libraryAllowed { refuseLibrary() }
#if DEBUG
/// The application of a check run. A check ends itself, by calling `exit` with its result. A quit
/// that reaches it first (⌘Q, Dock › Quit, a Quit Apple event) would end the process with status
/// 0 and no result, which reads as a pass, so the check fails instead.
final class CheckApplication: NSApplication {
  /// Set by the one check that ends through a normal quit (`--verify`), once its report is written.
  var finished = false
  override func terminate(_ sender: Any?) {
    if finished { return super.terminate(sender) }
    fputs("FAIL: Serein was asked to quit before its checks finished. Run them again.\n", stderr)
    exit(1)
  }
}
let app = RunMode.checking ? CheckApplication.shared : NSApplication.shared
#else
let app = NSApplication.shared
#endif
#if DEBUG
if let flag = CommandLine.arguments.firstIndex(of: "--verify-sigterm-probe"), CommandLine.arguments.count > flag + 2 {
  sigtermProbe(root: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), sleep: URL(fileURLWithPath: CommandLine.arguments[flag + 2]))
}
if let flag = CommandLine.arguments.firstIndex(of: "--verify-mac-offline"), CommandLine.arguments.count > flag + 1 {
  app.setActivationPolicy(.accessory)
  Task { @MainActor in
    do {
      try await checkOfflineMac(folder: URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true),
                               acceptsLicense: CommandLine.arguments.contains("--accept-macos-license"))
      exit(0)
    } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if let flag = CommandLine.arguments.firstIndex(of: "--verify-mac-network"), CommandLine.arguments.count > flag + 2 {
  app.setActivationPolicy(.accessory)
  Task { @MainActor in
    do {
      try await checkMacNetwork(folder: URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true),
                                shots: URL(fileURLWithPath: CommandLine.arguments[flag + 2], isDirectory: true))
      exit(0)
    } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if let flag = CommandLine.arguments.firstIndex(of: "--own-setup-profile") {
  // The sandbox profile Grok, Gemini CLI or Pi runs under: `--own-setup-profile <driver> <library>
  // <workspace> [closed paths…]`, the extra paths for checks.
  let words = Array(CommandLine.arguments[(flag + 1)...])
  guard words.count >= 3, let driver = HarnessDriver(rawValue: words[0]) else {
    fputs("usage: --own-setup-profile <driver> <library> <workspace> [closed paths…]\n", stderr)
    exit(2)
  }
  print(AgentFileGuard.ownSetupProfile(
    home: FileManager.default.homeDirectoryForCurrentUser, driver: driver, library: URL(fileURLWithPath: words[1]),
    workspace: URL(fileURLWithPath: words[2]), extra: Array(words.dropFirst(3))), terminator: "")
  exit(0)
}
if CommandLine.arguments.contains("--verify-helpers") || CommandLine.arguments.contains("--verify-helpers-live") {
  // Helper requests: fake CLIs (no provider call), or real CLIs timed with `-live`.
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkHelpers(live: CommandLine.arguments.contains("--verify-helpers-live")); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
#if DEBUG
if let at = CommandLine.arguments.firstIndex(of: "--verify-live-engines") {
  // Real signed-in CLIs through the app's own turn path, only with SEREIN_LIVE=1 (EngineLiveChecks).
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await EngineLiveChecks.run(Array(CommandLine.arguments[(at + 1)...])); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
#endif
if CommandLine.arguments.contains("--verify-opencode-intelligence") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    let failure: String?
    do { try await checkLiveOpenCodeIntelligence(); failure = nil } catch { failure = error.localizedDescription }
    await Engines.shared.shutdown()
    if let failure { fputs("FAIL: \(failure)\n", stderr); exit(1) }
    exit(0)
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-agent-start-performance") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkAgentStartPerformance(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-repl") {
  app.setActivationPolicy(.accessory)
  Task { @MainActor in
    do { try await checkRepl(); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-commands") {
  app.setActivationPolicy(.accessory)
  Task { @MainActor in
    do { try await checkComposerCommands(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-speech-engine") {
  // The real dictation model on a spoken file: no microphone, no sound, no window.
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkSpeechEngine(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if let at = CommandLine.arguments.firstIndex(of: "--verify-direct-http"),
  CommandLine.arguments.count == at + 3, let port = Int(CommandLine.arguments[at + 1]) {
  app.setActivationPolicy(.accessory)
  Task {
    do { try await DirectHTTPProbe.run(port: port, capabilityFile: CommandLine.arguments[at + 2]); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if let at = CommandLine.arguments.firstIndex(of: "--probe-providers") {
  app.setActivationPolicy(.accessory)
  let port = CommandLine.arguments.dropFirst(at + 1).first.flatMap { Int($0) }
  Task { @MainActor in
    do { try await ProviderProbe.run(port: port); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-page-recording") {
  app.setActivationPolicy(.accessory)
  Task { @MainActor in
    do { try await checkPageRecording(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-browser-observations") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkBrowserObservations(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--probe-external-sessions") {
  // What "In other apps" would show now: the processes found and the sessions read from them.
  var executables = [HarnessDriver: String]()
  for d in HarnessDriver.allCases {
    if let path = HarnessRegistry.locate(d, override: nil, shellPath: nil) { executables[d] = path }
  }
  let processes = HarnessProcessDiscovery.snapshot(executables: executables)
  for p in processes {
    print("process pid=\(p.pid) parent=\(p.parent) driver=\(HarnessProcessDiscovery.driver(p).map(\.rawValue) ?? "-") args=\(p.arguments) cwd=\(p.cwd ?? "-") logs=\(p.logs.count)")
  }
  var reader = ExternalSessionReader()
  for s in reader.snapshot(processes: processes, executables: executables) {
    print("session \(s.id) state=\(s.state.rawValue) title=\(s.title) cwd=\(s.cwd ?? "-")")
  }
  // The Agents list's past sessions: a full first read, then an unchanged second read.
  var history = SessionHistory()
  let home = NSHomeDirectory()
  for pass in ["full", "again"] {
    let started = Date()
    history.refresh(nil, roots: SessionHistory.Roots(home: home, environment: ProcessInfo.processInfo.environment), known: [], hidden: HelperFolder.hidden)
    let counts = Dictionary(grouping: history.sessions, by: \.provider).mapValues(\.count)
    print("history \(pass): \(counts) files=\(history.entries.count) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
  }
  let placed = Dictionary(grouping: history.sessions.filter { !$0.cwd.isEmpty }, by: \.provider).mapValues(\.count)
  print("history with a folder: \(placed); helper folder sessions: \(history.sessions.filter { $0.cwd.contains("serein-helper") }.count)")
  exit(0)
}
if CommandLine.arguments.contains("--verify-linked-codex") {
  // A real Codex chat followed by a Serein thread; two one-word model calls (LinkedSessionChecks).
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkLinkedCodex(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-cloud-apply") {
  // A Codex Cloud diff written to a project only after a confirm and a clean check (CodexCloudChecks).
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkCloudApply(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
#if DEBUG
if let at = CommandLine.arguments.firstIndex(of: "--verify-pay-live") {
  // One real task turn whose shell meets the payment guard (EngineLivePay).
  Task {
    do { try await EngineLivePay.run(Array(CommandLine.arguments[(at + 1)...])); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  dispatchMain()
}
if let at = CommandLine.arguments.firstIndex(of: "--verify-acp-live") {
  // Two real turns through Engines with an installed ACP CLI (EngineLiveACP).
  Task {
    do { try await EngineLiveACP.run(Array(CommandLine.arguments[(at + 1)...])); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  dispatchMain()
}
#endif
#if DEBUG
if CommandLine.arguments.contains("--verify-e2b-create") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await E2BCreateChecks.run(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
#endif
if CommandLine.arguments.contains("--verify-assistant-core") {
  // The pure rules behind assistants that do what the person types; no window, no model (AssistantCoreChecks).
  do { try AssistantCoreChecks.run(); exit(0) }
  catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
}
// Bounded model checkers over the team reducers; no window, no files (SereinCore/Formal).
if CommandLine.arguments.contains("--verify-formal") { exit(FormalCheck.run(CommandLine.arguments) ? 0 : 1) }
if CommandLine.arguments.contains("--verify-research") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await ResearchChecks.run(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-call-voice") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await CallSpeechChecks.run(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-linked-stores") {
  // Pi and Grok chats followed by a Serein thread; no model call (LinkedStoreChecks).
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkLinkedStores(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-linked-real") {
  // Real Pi and Grok chats continued from Serein; two model calls each.
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkLinkedReal(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-linked-claude") {
  // A real Claude Code chat followed by a Serein thread; four one-word model calls (LinkedSessionChecks).
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkLinkedClaude(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-session-watch") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkSessionLogWatcher(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-model-watch") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkModelSourceWatcher(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-steady-page") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkSteadyPagePerformance(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-text-performance") {
  app.setActivationPolicy(.prohibited)
  MainActor.assumeIsolated {
    do { try checkTextPerformance(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
}
if CommandLine.arguments.contains("--verify-background-performance") {
  app.setActivationPolicy(.prohibited)
  MainActor.assumeIsolated {
    do { try checkBackgroundPerformance(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
}
if CommandLine.arguments.contains("--verify-secure-card") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do {
      let cards = try await checkSecureCards()
      exit(try await checkTakeoverCards() && cards ? 0 : 1)
    }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-no-stall") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { exit(try await checkNoStall() ? 0 : 1) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-pagekit") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkPageKitPerformanceContracts(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-transcript-performance") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkTranscriptUpdates(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-transcript-window") {
  app.setActivationPolicy(.regular)
  Task { @MainActor in
    do { try await checkTranscriptWindow(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-message-hover") {
  app.setActivationPolicy(.regular)
  Task { @MainActor in
    do { try await checkMessageHoverControls(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-text-interactions") {
  app.setActivationPolicy(.regular)
  Task { @MainActor in
    do {
      try await checkTextInteractions()
      print("PASS: native text interaction checks")
      exit(0)
    } catch {
      fputs("FAIL: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
  app.run()
  exit(1)
}
// One live Jev request through Serein's own code; needs SEREIN_JEV_KEY. Costs one decision.
if CommandLine.arguments.contains("--probe-fast-steps") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { print(try await FastSteps.probe()); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if let i = CommandLine.arguments.firstIndex(of: "--probe-ax"), i + 1 < CommandLine.arguments.count {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await PageAX.probe(CommandLine.arguments[i + 1]); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if let i = CommandLine.arguments.firstIndex(of: "--probe-page"), i + 1 < CommandLine.arguments.count {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await probePage(CommandLine.arguments[i + 1], labels: Array(CommandLine.arguments.dropFirst(i + 2))); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-fixture-proxy") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do {
      _ = try await checkFixtureProxy()
      FileHandle.standardOutput.write(Data("PASS: native task read the proxy-only fixture response\n".utf8))
      exit(0)
    } catch {
      FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-outside-agents") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkOutsideAgents(); exit(0) }
    catch { FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8)); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-security") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkAgentContextPrivacy(); exit(0) }
    catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-onboarding") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    await checkBrowserOnboarding()
    FileHandle.standardOutput.write(Data("PASS: onboarding import, cancellation reconciliation and deduplicated retry contracts\n".utf8))
    exit(0)
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-project-discovery") {
  MainActor.assumeIsolated {
    app.setActivationPolicy(.prohibited)
    checkProjectAutoDiscovery()
  }
  FileHandle.standardOutput.write(Data("PASS: agent history lists 2 projects and Other folders (3) with no user action\n".utf8))
  exit(0)
}
if CommandLine.arguments.contains("--verify-external-sessions") {
  MainActor.assumeIsolated {
    app.setActivationPolicy(.prohibited)
    checkExternalSessionDisplay()
  }
  FileHandle.standardOutput.write(Data("PASS: external session counts, project markers, completion cleanup and read-only display\n".utf8))
  exit(0)
}
if CommandLine.arguments.contains("--verify-tab-drag") {
  MainActor.assumeIsolated {
    app.setActivationPolicy(.prohibited)
    checkSidebarTabDrag()
  }
  FileHandle.standardOutput.write(Data("PASS: sidebar and horizontal drag axes, gap indicators, cancellation, committed orders, tab moves and group order\n".utf8))
  exit(0)
}
if CommandLine.arguments.contains("--verify-passwords") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    await checkPasswordCapture()
    FileHandle.standardOutput.write(Data("PASS: password capture eligibility, private memory store and generated fill\n".utf8))
    exit(0)
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-dark-pages") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    await checkDarkPages()
    FileHandle.standardOutput.write(Data("PASS: dark pages invert light pages, also with no background, and keep dark ones\n".utf8))
    exit(0)
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-sandbox-helper") {
  // The browser helper and the harnesses under the Grok/Pi sandbox; no window, no model (SandboxChecks).
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkSandboxHelper(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-chat-pictures") {
  // Screenshots and Markdown pictures in a chat; no window, no provider (ChatPictureChecks).
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkChatPictures(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-transcript-actions") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    do { try await checkTranscriptActivities(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  app.run()
  exit(1)
}
if CommandLine.arguments.contains("--verify-popups") {
  app.setActivationPolicy(.prohibited)
  Task { @MainActor in
    await checkPopups()
    FileHandle.standardOutput.write(Data("PASS: popups keep window.opener, close themselves, keep the private store; agent tabs open none\n".utf8))
    exit(0)
  }
  app.run()
  exit(1)
}
#endif
if !libraryAllowed { refuseLibrary() }
if RunMode.stress, !StressDriver.usesTestLibrary {
  FileHandle.standardError.write(
    Data("--stress needs SEREIN_DATA_DIR set to a temporary folder that holds an empty file named .serein-stress: it never runs on a library that someone uses.\n".utf8))
  exit(2)
}
MainActor.assumeIsolated { TextSizeController.load() }
let delegate = MainActor.assumeIsolated { AppDelegate() }
// A bench run stays out of the Dock and does not take the front.
app.setActivationPolicy(CommandLine.arguments.contains { $0.hasPrefix("--bench") } ? .accessory : .regular)
app.delegate = delegate
app.run()
