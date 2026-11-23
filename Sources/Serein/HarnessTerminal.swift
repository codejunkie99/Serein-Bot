import AppKit
import Darwin
import SereinCore
import SwiftUI

// MARK: - PTY

/// One program on a pseudo-terminal (forkpty), for a harness's own install, sign-in or update
/// command. The child leads its own session and process group, so Cancel ends everything it
/// started. Output is only displayed; nothing is logged or stored, and Serein never writes
/// anything the user did not type.
@MainActor final class PTYSession: ObservableObject {
  @Published private(set) var screen = TerminalScreen(width: 100)
  @Published private(set) var running = false
  let launch: PTYLaunch
  private var master: Int32 = -1
  private(set) var pid: pid_t = 0
  private var reader: DispatchSourceRead?
  private var exitWatch: DispatchSourceProcess?
  var onExit: ((Int32) -> Void)?

  init(launch: PTYLaunch) { self.launch = launch }

  /// `environment` is the base (login PATH, user's extra variables); the launch's own variables
  /// win over it.
  func start(environment: [String: String], cwd: String = NSHomeDirectory()) throws {
    guard !running, pid == 0 else { return }
    var env = environment
    for (k, v) in launch.environment { env[k] = v }
    env.removeValue(forKey: "CLAUDECODE")
    // C strings are prepared before fork: the child only calls async-signal-safe functions.
    let argv = ([launch.path] + launch.arguments).map { strdup($0) } + [nil]
    let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    let path = strdup(launch.path)
    let dir = strdup(cwd)
    defer {
      argv.forEach { free($0) }
      envp.forEach { free($0) }
      free(path)
      free(dir)
    }
    var size = winsize(ws_row: 30, ws_col: UInt16(screen.width), ws_xpixel: 0, ws_ypixel: 0)
    var fd: Int32 = -1
    let child = forkpty(&fd, nil, nil, &size)
    if child < 0 { throw SereinError.invalid("Could not open a terminal (\(errno)).") }
    if child == 0 {
      _ = chdir(dir)
      _ = execve(path, argv, envp)
      _exit(127)
    }
    pid = child
    master = fd
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    running = true
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
    source.setEventHandler { [weak self] in
      var buffer = [UInt8](repeating: 0, count: 16_384)
      let n = read(fd, &buffer, buffer.count)
      if n > 0 {
        let chunk = Array(buffer[0..<n])
        DispatchQueue.main.async { self?.screen.feed(chunk) }
      } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
        // The slave side closed (EIO): the program and its children are done with the terminal.
        DispatchQueue.main.async { self?.reader?.cancel() }
      }
    }
    source.setCancelHandler { close(fd) }
    reader = source
    source.resume()
    let watch = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
    watch.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.reap() }
    }
    exitWatch = watch
    watch.resume()
  }

  private func reap() {
    guard pid > 0 else { return }
    var status: Int32 = 0
    let r = waitpid(pid, &status, WNOHANG)
    guard r == pid else { return }
    exitWatch?.cancel()
    exitWatch = nil
    // Anything still in the group (a helper the program started) ends with it.
    kill(-pid, SIGHUP)
    let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
    running = false
    // Let the last output drain, then close the terminal.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.reader?.cancel() }
    onExit?(code)
  }

  func write(_ bytes: [UInt8]) {
    guard running, master >= 0, !bytes.isEmpty else { return }
    bytes.withUnsafeBufferPointer { p in
      var offset = 0
      while offset < p.count {
        let n = Darwin.write(master, p.baseAddress! + offset, p.count - offset)
        if n <= 0 { break }
        offset += n
      }
    }
  }
  func write(_ text: String) { write(Array(text.utf8)) }

  /// Ends the program's whole process group: hang-up and terminate, then kill after a second.
  func terminate() {
    guard pid > 0, running else { return }
    let group = pid
    kill(-group, SIGHUP)
    kill(-group, SIGTERM)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, self.running else { return }
      kill(-group, SIGKILL)
      kill(group, SIGKILL)
    }
  }
}

// MARK: - Jobs

/// One install, sign-in or update command for a harness, running in the embedded terminal.
@MainActor final class HarnessJob: ObservableObject, Identifiable {
  enum State: Equatable { case running, succeeded, failed(String), cancelled }
  let id = UUID()
  let driver: HarnessDriver
  let command: HarnessCommand
  let session: PTYSession
  @Published private(set) var state: State = .running
  init(driver: HarnessDriver, command: HarnessCommand, launch: PTYLaunch) {
    self.driver = driver
    self.command = command
    session = PTYSession(launch: launch)
  }
  fileprivate func finish(_ state: State) { self.state = state }
}

/// Starts harness commands in the PTY and re-probes when they exit. A sign-in that ends with the
/// harness ready turns it on.
@MainActor final class HarnessActions: ObservableObject {
  static let shared = HarnessActions()
  @Published var job: HarnessJob?
  /// Apps an install here just put on this Mac that are not signed in yet. Serein does not count
  /// them as ready to think until they are (`AgentModel.canThink`), so a held message waits.
  @Published private(set) var needsSignIn: Set<HarnessDriver> = []
  /// The setup step shows the pane inline; Settings uses a sheet only when setup is not open.
  @Published var setupVisible = false

  func command(for driver: HarnessDriver, action: HarnessPrimaryAction) -> HarnessCommand? {
    switch action {
    case .install: return HarnessCommands.install(driver, hasTool: Self.hasTool)
    case .signIn: return HarnessCommands.signIn(driver, version: HarnessRegistry.shared.snapshots[driver]?.version)
    case .update:
      return HarnessCommands.update(
        driver, installedAt: HarnessRegistry.shared.snapshots[driver]?.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    case .ready, .checking: return nil
    }
  }
  /// The tools an install needs that this Mac lacks (`AgentSetup.missingInstallTools`), looked up
  /// on the login shell's PATH too, where nvm, asdf and the like put npm. Empty until that PATH
  /// is known, so a tool found only there never reads as missing.
  static func missingInstallTools(_ driver: HarnessDriver) -> [String] {
    if let gone = previewMissing { return AgentSetup.missingInstallTools(provider: driver.setupKey) { !gone.contains($0) } }
    guard let shell = HarnessRegistry.shared.shellPath else { return [] }
    let dirs = LoginShellPath.searchPath(
      shell: shell, inherited: ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory())
    return AgentSetup.missingInstallTools(provider: driver.setupKey) { name in
      dirs.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
    }
  }
  /// `--ui-serein-other-apps missing`: npm and Homebrew read as missing, in memory.
  nonisolated(unsafe) static var previewMissing: [String]?
  nonisolated static func hasTool(_ name: String) -> Bool {
    let dirs = LoginShellPath.searchPath(
      shell: nil, inherited: ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory())
    return dirs.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
  }

  /// Runs `command` in a fresh PTY. Only one runs at a time; starting another cancels the first.
  @discardableResult func run(_ command: HarnessCommand, driver: HarnessDriver) -> HarnessJob? {
    job?.session.terminate()
    let registry = HarnessRegistry.shared
    let executable = registry.snapshots[driver]?.path
    guard let launch = HarnessCommands.launch(command, executable: executable, loginShell: Self.loginShell)
    else { return nil }
    let job = HarnessJob(driver: driver, command: command, launch: launch)
    let env = HarnessRegistry.environment(
      executable: executable ?? launch.path, driver: driver, shellPath: registry.shellPath,
      extra: registry.instance(driver).safeEnvironment)
    job.session.onExit = { [weak job] code in
      guard let job else { return }
      Task { @MainActor in await HarnessActions.shared.finished(job, code: code) }
    }
    do {
      try job.session.start(
        environment: env, cwd: command.folder.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory())
    } catch {
      job.finish(.failed(error.localizedDescription))
    }
    self.job = job
    if command.kind == .signIn { recheck(job, before: HarnessPrimaryAction.of(registry.snapshots[driver])) }
    // Settings is a sheet on the browser window, so a sign-in page opened there cannot be used.
    // The terminal gets its own window and the sheet closes.
    if !setupVisible {
      BrowserContext.browser?.showSettings = false
      HarnessTerminalWindow.show()
    }
    return job
  }

  /// The sign-in page, in a window the sheet is not covering. During setup the flow itself is
  /// the sheet, so the page opens in a separate window and the flow stays.
  func openSignInPage(_ url: URL) {
    NSWorkspace.shared.open(url)
  }

  /// Checks the app again while its sign-in runs; once it can answer, the job ends and `finished`
  /// settles it as signed in.
  private func recheck(_ job: HarnessJob, before: HarnessPrimaryAction) {
    Task { @MainActor [weak self, weak job] in
      let start = Date()
      while Date().timeIntervalSince(start) < HarnessPrimaryAction.signInRecheckLimit {
        try? await Task.sleep(nanoseconds: UInt64(HarnessPrimaryAction.signInRecheckEvery * 1_000_000_000))
        guard let self, let job, self.job === job, job.state == .running else { return }
        let registry = HarnessRegistry.shared
        await registry.refresh(job.driver, includeDisabled: true)
        guard job.state == .running else { return }
        if HarnessPrimaryAction.signedInWhileRunning(before: before, now: .of(registry.snapshots[job.driver])) {
          return job.session.terminate()
        }
      }
    }
  }

  private func finished(_ job: HarnessJob, code: Int32) async {
    // Cancelled, or already settled (it could not start).
    guard job.state == .running else { return }
    // A resumed session is the user's own work in the CLI; when it ends, nothing to check.
    if job.command.kind == .resume { return job.finish(code == 0 ? .succeeded : .failed("Exited with code \(code).")) }
    let registry = HarnessRegistry.shared
    await registry.refresh(job.driver, includeDisabled: true, force: true)
    let action = HarnessPrimaryAction.of(registry.snapshots[job.driver])
    let done: Bool
    switch job.command.kind {
    case .install: done = action != .install && action != .checking
    case .signIn: done = action == .ready || action == .update
    case .update: done = code == 0 && action != .update
    case .resume: done = true
    }
    if job.command.kind == .install && action == .signIn { needsSignIn.insert(job.driver) }
    if action == .ready || action == .update { needsSignIn.remove(job.driver) }
    if done {
      if !registry.instance(job.driver).enabled { registry.setEnabled(job.driver, true) }
      job.finish(.succeeded)
    } else {
      job.finish(.failed(code == 0 ? "Finished, but \(registry.instance(job.driver).name) is not ready yet." : "Exited with code \(code)."))
    }
  }

  func cancel() {
    guard let job else { return }
    if job.state == .running {
      job.finish(.cancelled)
      job.session.terminate()
    }
  }
  /// Closing the pane ends anything still running.
  func close() {
    cancel()
    job = nil
    HarnessTerminalWindow.hide()
  }
  /// The window's close button. The window is already going, so it is not closed again.
  func endedByWindow() {
    cancel()
    job = nil
  }
  /// The same command in Terminal.app, for anything the embedded pane cannot show.
  func openInTerminal(_ job: HarnessJob) {
    TerminalLauncher.run(job.command.setupCommand)
    cancel()
  }
  static var loginShell: String {
    ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
  }
}

// MARK: - Pane

/// The embedded terminal: the exact command first, live output, keystrokes passed through to
/// the program (arrow keys, Return, Control-C, paste), a link button for browser sign-in, and
/// Open in Terminal / Cancel / Done.
struct HarnessTerminalPane: View {
  @ObservedObject var job: HarnessJob
  @ObservedObject var session: PTYSession
  var onClose: () -> Void
  @FocusState private var focused: Bool
  @Environment(\.palette) var p

  init(job: HarnessJob, onClose: @escaping () -> Void) {
    self.job = job
    session = job.session
    self.onClose = onClose
  }

  var title: String {
    let name = HarnessRegistry.shared.instance(job.driver).name
    switch job.command.kind {
    case .install: return "Install \(name)"
    case .signIn: return "Sign in to \(name)"
    case .update: return "Update \(name)"
    case .resume: return "\(name) session"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        HarnessGlyph(provider: Provider(job.driver), size: 16, tinted: true).frame(width: 20, height: 20)
        Text(title).role(.section)
        Spacer()
        statusLabel
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Serein is running this command for you").role(.micro)
        Text(job.command.display).font(UIStyle.monoMeta).textSelection(.enabled)
          .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
          .background(p.background, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      }
      terminal
      Text(hint).role(.meta).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        if let link = TerminalScreen.links(session.screen.text).last {
          Button("Open Sign-in Page") { HarnessActions.shared.openSignInPage(link) }
            .buttonStyle(PrimaryButton())
            .help(link.absoluteString)
        }
        Button("Open in Terminal") { HarnessActions.shared.openInTerminal(job) }
          .help("Run the same command in Terminal instead.")
        Spacer()
        if job.state == .running {
          Button("Cancel") { HarnessActions.shared.cancel() }.keyboardShortcut(.cancelAction)
        } else {
          Button("Done") { onClose() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
        }
      }
    }.padding(16)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .overlay(RoundedRectangle(cornerRadius: UIStyle.panelRadius).stroke(p.line))
      .onAppear { focused = true }
  }

  var hint: String {
    switch job.state {
    case .running:
      return job.command.kind == .signIn
        ? "Open the sign-in page and finish it in Serein, then come back to this window. Serein never sees your password."
        : "Type here to answer its questions. Serein never sees your password."
    case .succeeded:
      return job.command.kind == .install ? "Installed. Sign in next if it asks." : "Done. It is ready to use."
    case .failed(let message): return message + " You can try again or use Open in Terminal."
    case .cancelled: return "Cancelled. Nothing else is running."
    }
  }

  @ViewBuilder var statusLabel: some View {
    switch job.state {
    case .running:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Running").role(.meta)
      }
    case .succeeded:
      Label("Ready", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(p.success)
        .font(UIStyle.meta)
    case .failed:
      Text("Not finished").role(.meta).foregroundStyle(p.warning)
    case .cancelled:
      Text("Cancelled").role(.meta)
    }
  }

  var terminal: some View {
    ScrollViewReader { proxy in
      ScrollView {
        Text(session.screen.text.isEmpty ? " " : session.screen.text)
          .font(UIStyle.mono(11.5)).foregroundStyle(p.ink).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        Color.clear.frame(height: 1).id("end")
      }.onChange(of: session.screen.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
    }
    .frame(minHeight: 180, maxHeight: .infinity)
    .background(p.background, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
    .overlay(
      RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(focused ? p.borderStrong : p.line))
    .focusable(job.state == .running)
    .focused($focused)
    .focusEffectDisabled()
    .onKeyPress(phases: [.down, .repeat]) { press in
      guard job.state == .running, let bytes = Self.bytes(for: press) else { return .ignored }
      session.write(bytes)
      return .handled
    }
    .onPasteCommand(of: [.plainText]) { _ in
      if let text = NSPasteboard.general.string(forType: .string) { session.write(text) }
    }
    .onTapGesture { focused = true }
    .accessibilityLabel("Terminal output")
    .accessibilityValue(String(session.screen.text.suffix(400)))
  }

  static func bytes(for press: KeyPress) -> [UInt8]? {
    switch press.key {
    case .upArrow: return TerminalKeys.bytes(.up)
    case .downArrow: return TerminalKeys.bytes(.down)
    case .leftArrow: return TerminalKeys.bytes(.left)
    case .rightArrow: return TerminalKeys.bytes(.right)
    case .return: return TerminalKeys.bytes(.enter)
    case .tab: return TerminalKeys.bytes(.tab)
    case .delete: return TerminalKeys.bytes(.backspace)
    case .deleteForward: return TerminalKeys.bytes(.delete)
    case .escape: return TerminalKeys.bytes(.escape)
    case .home: return TerminalKeys.bytes(.home)
    case .end: return TerminalKeys.bytes(.end)
    default: break
    }
    if press.modifiers.contains(.command) { return nil }
    if press.modifiers.contains(.control), let c = press.characters.lowercased().unicodeScalars.first,
      c.value >= 0x61, c.value <= 0x7A
    {
      return [UInt8(c.value - 0x60)]
    }
    let text = press.characters
    return text.isEmpty ? nil : Array(text.utf8)
  }
}

/// The pane in its own window. A sheet would cover the browser window, and the sign-in page
/// opens there.
@MainActor final class HarnessTerminalWindow: NSObject, NSWindowDelegate {
  private static var current: HarnessTerminalWindow?
  private let window: NSWindow
  private var closing = false

  static func show() {
    if let current {
      current.window.title = title
      current.window.makeKeyAndOrderFront(nil)
      return
    }
    let controller = HarnessTerminalWindow()
    current = controller
    controller.window.title = Self.title
    if let main = NSApp.windows.first(where: { $0.titlebarAppearsTransparent && $0 !== controller.window }) {
      let frame = main.frame
      controller.window.setFrameOrigin(NSPoint(x: frame.maxX - 680, y: frame.minY + 80))
    } else {
      controller.window.center()
    }
    controller.window.makeKeyAndOrderFront(nil)
  }

  private static var title: String {
    guard let job = HarnessActions.shared.job else { return "Serein" }
    let name = HarnessRegistry.shared.instance(job.driver).name
    switch job.command.kind {
    case .install: return "Install \(name)"
    case .signIn: return "Sign in to \(name)"
    case .update: return "Update \(name)"
    case .resume: return "\(name) session"
    }
  }

  static func hide() {
    guard let current else { return }
    current.closing = true
    current.window.close()
    self.current = nil
  }

  private override init() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 656, height: 476),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    super.init()
    window.title = "Sign in"
    window.isReleasedWhenClosed = false
    window.backgroundColor = Palette.dynamic(\.background)
    window.delegate = self
    let host = NSHostingView(rootView: HarnessTerminalRoot())
    host.sizingOptions = []
    window.contentView = host
  }

  func windowWillClose(_ notification: Notification) {
    guard !closing else { return }
    closing = true
    if Self.current === self { Self.current = nil }
    HarnessActions.shared.endedByWindow()
  }
}

private struct HarnessTerminalRoot: View {
  @ObservedObject var actions = HarnessActions.shared
  var body: some View {
    Group {
      if let job = actions.job {
        HarnessTerminalPane(job: job) { actions.close() }
      }
    }.frame(width: 640, height: 460).padding(8)
  }
}
