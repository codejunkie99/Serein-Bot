import AppKit
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

/// Serein's computer in a task's view, while the task holds or waits for it: one line, "Working in
/// Scout's computer · Show" or, in line, "Waiting for Scout's computer · 2nd in line · “Plan a
/// trip” is using it · Show" (ComputerWait), whose Show opens the assistant's inspector on
/// Computer, where the screen is. The Outbox and clipboard cards stay in the chat.
struct ComputerSection: View {
  let thread: String
  @ObservedObject private var host = ComputerHost.shared
  var body: some View {
    // Each line watches its own computer, so it comes, moves up the line and goes as that
    // computer's lease, queue, control and reset change.
    ForEach(host.computers.keys.sorted(), id: \.self) { id in
      if let computer = host.computers[id] { ComputerWorkingLine(computer: computer, thread: thread) }
    }
  }
}
private struct ComputerWorkingLine: View {
  @ObservedObject var computer: ComputerHost.Computer
  let thread: String
  @ObservedObject private var host = ComputerHost.shared
  @Environment(\.palette) var p
  var body: some View {
    let tasks = host.tasks(ofThread: thread)
    let name = host.assistantName(computer.id)
    if computer.holder.map(tasks.contains) == true {
      line("Working in \(name)'s computer", name: name)
    } else if let wait = host.wait(computer, tasks: tasks) {
      line(wait.line(assistant: name), name: name)
    }
  }
  private func line(_ words: String, name: String) -> some View {
    HStack(spacing: 6) {
      InterfaceIcon(systemName: "desktopcomputer", size: 12).foregroundStyle(p.faint).accessibilityHidden(true)
      Text(verbatim: words).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
        .help(words)
      Text("·").font(UIStyle.meta).foregroundStyle(p.secondary).accessibilityHidden(true)
      Button("Show") { AssistantInspector.shared.show(computer.id, tab: .activity) }
        .buttonStyle(.pressable).font(UIStyle.metaStrong).foregroundStyle(p.accent).fixedSize()
        .help("Show \(name)'s screen").accessibilityLabel("Show \(name)'s computer")
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .contain).accessibilityLabel(words)
  }
}

/// The computer's live screen in Activity or its own window. Controls sit over the screen;
/// setup guidance and advanced options stay on demand instead of surrounding the desktop.
struct ComputerPanel: View {
  @ObservedObject var computer: ComputerHost.Computer
  let inWindow: Bool
  var initialSetup = false
  @ObservedObject private var host = ComputerHost.shared
  @Environment(\.palette) var p
  @State private var watching = true
  @State private var dropping = false
  @State private var showingSetupHelp = false
  @ObservedObject private var network = NetworkMonitor.shared

  private var name: String { host.assistantName(computer.id) }
  private var preparing: Bool {
    computer.state == .starting && computer.setupLine != nil
      || (initialSetup && [.none, .paused, .stopped].contains(computer.state))
  }
  private var ratio: CGFloat { CGFloat(computer.screenWidth) / CGFloat(max(1, computer.screenHeight)) }
  private var preparationLine: String {
    if let line = computer.setupLine { return line }
    if initialSetup {
      if !network.known { return "Checking the connection…" }
      if !network.online { return "Waiting for an internet connection." }
      if network.metered { return "Waiting for a connection without a data limit." }
    }
    return "Preparing the computer…"
  }
  private var controlLine: String {
    switch computer.control {
    case .assistant: return "\(name) has control"
    case .pending: return "Taking over after this step"
    case .person: return "You have control"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if initialSetup, case .error(let words) = computer.state {
          VStack(spacing: 10) {
            Text(words).font(UIStyle.meta).foregroundStyle(p.secondary)
              .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await host.resumeInitialSetup(computer) } }.buttonStyle(PrimaryButton())
          }.padding(16).frame(maxWidth: .infinity).aspectRatio(ratio, contentMode: .fit).background(p.card)
        } else if computer.place == .macOS, computer.macSetup == .agreement {
          VStack(spacing: 14) {
            Text("A private Mac for Serein").font(UIStyle.metaStrong)
            Text("Serein will create its account and connect automatically.")
              .font(UIStyle.meta).foregroundStyle(p.secondary)
            Link("Review Apple’s macOS Software License Agreement", destination: URL(string: ComputerPolicy.macOSLicenseURL)!)
              .font(UIStyle.meta).foregroundStyle(p.ink)
            Button("Agree and continue") { (computer.machine as? MacVirtualComputer)?.approveSetupAgreement() }
              .buttonStyle(PrimaryButton())
          }.padding(24).frame(maxWidth: .infinity).aspectRatio(ratio, contentMode: .fit).background(p.card)
        } else if preparing || (initialSetup && computer.place == .macOS && computer.macSetup != .ready) {
          VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(verbatim: preparationLine)
              .font(UIStyle.meta).foregroundStyle(p.secondary).multilineTextAlignment(.center)
          }.padding(16).frame(maxWidth: .infinity).aspectRatio(ratio, contentMode: .fit)
            .background(p.card)
        } else {
          screen
        }
      }
      .overlay(alignment: .topTrailing) { controls.padding(8) }
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      // Grok's canvas: a hairline while watching, a 2-point blue frame while the person has control.
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(dropping ? p.accent : computer.control == .person ? p.focus : p.line,
            lineWidth: dropping || computer.control == .person ? 2 : 0.5)
          .allowsHitTesting(false))
      .shadow(color: inWindow ? .black.opacity(0.35) : .clear, radius: 35, y: 22)
      if inWindow { controlBar }
      macPreparation
    }
    .accessibilityElement(children: .contain).accessibilityLabel("\(name)'s computer")
    .accessibilityValue("\(computer.place == .macOS && computer.state == .running && computer.macSetup != .ready ? "Setting up" : computer.state.label), \(controlLine)")
    .onAppear { if watching { host.watch(computer, true) } }
    .onDisappear { if watching { host.watch(computer, false) } }
    .alert("Finish Mac setup", isPresented: $showingSetupHelp) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(computer.setupLine ?? MacComputerPolicy.setupLine)
    }
  }

  @ViewBuilder private var macPreparation: some View {
    if computer.place == .macOS, computer.state == .running, computer.macSetup != .ready, computer.macSetup != .agreement,
      let message = computer.macSetup.message {
      VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            if !computer.macSetup.needsPerson { ProgressView().controlSize(.mini) }
            Text(verbatim: message).font(UIStyle.meta).foregroundStyle(p.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }.frame(maxWidth: .infinity, alignment: .leading)
          if case .needsPerson = computer.macSetup {
            let mac = computer.machine as? MacVirtualComputer
            let silent = mac?.needsRestart == true
            Button(silent ? "Restart Serein’s Mac" : "Continue setup") {
              if silent { Task { await host.restartMac(computer) } } else { mac?.continueAutomaticSetup() }
            }
              .buttonStyle(.plain).font(UIStyle.metaStrong).foregroundStyle(p.ink).padding(.vertical, 4)
          }
      }.frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inWindow ? 16 : 0).padding(.top, inWindow ? 4 : 0).padding(.bottom, inWindow ? 12 : 0)
    }
  }

  /// The viewer bar under the screen in the window: watching with Take control, or in control
  /// with Hand back. The 2-point ring round the screen, not a coloured dot, marks the hold.
  @ViewBuilder private var controlBar: some View {
    if !preparing && !initialSetup && computer.state == .running {
      ControlPill(
        holder: computer.control, heldName: "\(name)'s computer", hint: " \u{00B7} Take control to use the mouse and keyboard",
        take: { host.takeOver(computer) }, handBack: { host.handBack(computer) }
      )
      .frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 20)
    }
  }

  private var controls: some View {
    HStack(spacing: 0) {
      // In the window the bar under the screen takes and hands back control.
      if !preparing && !initialSetup && !(inWindow && computer.state == .running) {
        Button {
          if computer.control == .assistant { host.takeOver(computer) }
          else { host.handBack(computer) }
        } label: {
          InterfaceIcon(systemName: computer.control == .assistant ? "hand.raised" : "arrow.uturn.backward", size: 12)
            .frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
          .help(computer.control == .assistant ? "Take over the computer" : "Hand back to \(name)")
          .accessibilityLabel(computer.control == .assistant ? "Take over \(name)'s computer" : "Hand \(name)'s computer back")
        if !inWindow {
          Button { ComputerWindow.show(computer) } label: {
            InterfaceIcon(systemName: "arrow.up.left.and.arrow.down.right", size: 12)
              .frame(width: 28, height: 28).contentShape(Rectangle())
          }.buttonStyle(.plain).help("Open in a window").accessibilityLabel("Expand \(name)'s computer")
        }
      }
      Menu {
        if initialSetup || preparing || (computer.place == .macOS && computer.state == .running && computer.macSetup != .ready) {
          Button("Cancel setup") { Task { await host.cancelSetup(computer) } }
        } else {
          if computer.state == .running {
            Button("Pause") { Task { await host.pause(computer) } }
          } else {
            Button("Open computer") { Task { await host.resume(computer) } }
          }
          if computer.place != .macOS && computer.place != .builtIn {
            Button(watching ? "Stop watching" : "Watch") {
              watching.toggle(); host.watch(computer, watching)
            }
          }
          if computer.place == .macOS, computer.setupLine != nil {
            Button("Setup help…") { showingSetupHelp = true }
          }
          Button("Computer settings…") { TeamSheets.openSettings(TeamSheets.settingsPage(.computer)) }
        }
      } label: {
        InterfaceIcon(systemName: "ellipsis", size: 12).frame(width: 28, height: 28).contentShape(Rectangle())
      }.menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .help("Computer controls").accessibilityLabel("Controls for \(name)'s computer")
    }
    .fixedSize(horizontal: true, vertical: true)
    .foregroundStyle(p.ink)
    .background(p.card.opacity(0.96), in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
    .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).strokeBorder(p.line))
  }

  @ViewBuilder private var screen: some View {
    if !inWindow, computer.inOwnWindow {
      // Keep the interactive display in its expanded window and the sidebar compact.
      Button { ComputerWindow.show(computer) } label: {
        ZStack {
          Rectangle().fill(p.codePanel)
          InterfaceIcon(systemName: "arrow.up.left.and.arrow.down.right", size: 24).foregroundStyle(p.secondary)
        }.aspectRatio(ratio, contentMode: .fit).frame(maxWidth: .infinity).contentShape(Rectangle())
      }.buttonStyle(.plain).help("Show the computer window").accessibilityLabel("Show \(name)'s computer window")
    } else {
      liveScreen
    }
  }
  private var liveScreen: some View {
    ZStack {
      Rectangle().fill(Color.black.opacity(0.85))
      if watching, computer.control == .person, let display = (computer.machine as? MacVirtualComputer)?.display {
        NativeMacScreen(display: display)
      } else if watching, let machine = (computer.machine as? VirtualMachineComputer)?.machine {
        VirtualMachineScreen(computer: computer, machine: machine)
      } else if computer.state == .paused || computer.state == .stopped || computer.state == .none {
        Button { Task { await host.resume(computer) } } label: {
          InterfaceIcon(systemName: "play.fill", size: 24).foregroundStyle(Color.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Open the computer").accessibilityLabel("Open \(name)'s computer")
      } else if computer.screen != nil, watching {
        ComputerScreenView(computer: computer)
      } else {
        Text(verbatim: computer.state == .running ? "Connecting…" : computer.state.label)
          .font(UIStyle.meta).foregroundStyle(Color.white.opacity(0.7)).multilineTextAlignment(.center).padding(16)
      }
    }
    .aspectRatio(ratio, contentMode: .fit).frame(maxWidth: .infinity)
    .accessibilityLabel("The screen of \(computer.own?.target.text ?? name + "'s computer")")
    .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
      guard computer.place != .macOS, let provider = providers.first else { return false }
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
        guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
        Task { @MainActor in await ComputerHost.shared.dropFile(url, into: computer) }
      }
      return true
    }
  }
}

/// The screen picture, and the person's input to it while they hold control: clicks, scrolls
/// and keys are turned into the helper's pointer and key operations at the picture's pixels.
struct ComputerScreenView: NSViewRepresentable {
  @ObservedObject var computer: ComputerHost.Computer
  func makeNSView(context: Context) -> ScreenNSView {
    let view = ScreenNSView()
    view.computer = computer
    return view
  }
  func updateNSView(_ view: ScreenNSView, context: Context) {
    view.computer = computer
    view.image = computer.screen
    view.interactive = computer.control == .person
    view.needsDisplay = true
  }

  final class ScreenNSView: NSView {
    weak var computer: ComputerHost.Computer?
    var image: NSImage?
    var interactive = false { didSet { if !interactive, window?.firstResponder === self { window?.makeFirstResponder(nil) } } }
    override var acceptsFirstResponder: Bool { interactive }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
      guard let image else { return }
      image.draw(in: drawnRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
    /// The picture's size in the computer's pixels (ComputerHost.Computer.screenWidth).
    private var pixels: (width: Int, height: Int) {
      (max(1, computer?.screenWidth ?? ComputerPolicy.screenWidth), max(1, computer?.screenHeight ?? ComputerPolicy.screenHeight))
    }
    /// Where the picture sits in the view, kept to its own proportions.
    private var drawnRect: NSRect {
      let width = CGFloat(pixels.width), height = CGFloat(pixels.height)
      let scale = min(bounds.width / width, bounds.height / height)
      let size = NSSize(width: width * scale, height: height * scale)
      return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    /// The computer's pixel under a point in the view, or nil outside the picture.
    private func pixel(_ event: NSEvent) -> (Int, Int)? {
      let point = convert(event.locationInWindow, from: nil)
      let rect = drawnRect
      guard rect.width > 0, rect.contains(point) else { return nil }
      let size = pixels
      let x = Int((point.x - rect.minX) / rect.width * CGFloat(size.width))
      let y = Int((point.y - rect.minY) / rect.height * CGFloat(size.height))
      return (max(0, min(size.width - 1, x)), max(0, min(size.height - 1, y)))
    }
    private func click(_ event: NSEvent, button: String) {
      guard interactive, let computer, let spot = pixel(event) else { return }
      window?.makeFirstResponder(self)
      ComputerHost.shared.personInput(
        computer, op: "click", ["x": spot.0, "y": spot.1, "button": button, "double": event.clickCount == 2],
        step: event.clickCount == 2 ? "double-clicked" : "clicked")
    }
    override func mouseDown(with event: NSEvent) { click(event, button: "left") }
    override func rightMouseDown(with event: NSEvent) { click(event, button: "right") }
    override func otherMouseDown(with event: NSEvent) { click(event, button: "middle") }
    override func scrollWheel(with event: NSEvent) {
      guard interactive, let computer, let spot = pixel(event) else { return }
      let notches = Int(abs(event.scrollingDeltaY).rounded(.up))
      guard notches > 0 else { return }
      let direction: String = event.scrollingDeltaY > 0 ? "up" : "down"
      let amount: Int = min(notches, 10)
      ComputerHost.shared.personInput(
        computer, op: "scroll", ["x": spot.0, "y": spot.1, "direction": direction, "amount": amount], step: "scrolled")
    }
    /// Keys in xdotool's words: ⌘ becomes ctrl, as the desktop inside expects.
    private static let special: [UInt16: String] = [
      36: "Return", 48: "Tab", 49: "space", 51: "BackSpace", 53: "Escape", 117: "Delete", 123: "Left", 124: "Right",
      125: "Down", 126: "Up", 115: "Home", 119: "End", 116: "Prior", 121: "Next", 76: "KP_Enter",
    ]
    override func keyDown(with event: NSEvent) {
      guard interactive, let computer else { return }
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      var modifiers: [String] = []
      if flags.contains(.command) || flags.contains(.control) { modifiers.append("ctrl") }
      if flags.contains(.option) { modifiers.append("alt") }
      var held: [String] = modifiers
      if flags.contains(.shift) { held.append("shift") }
      if let name = Self.special[event.keyCode] {
        let key = (held + [name]).joined(separator: "+")
        ComputerHost.shared.personInput(computer, op: "key", ["key": key], step: "pressed \(name)")
        return
      }
      guard let text = event.charactersIgnoringModifiers, !text.isEmpty else { return }
      if !modifiers.isEmpty, let letter = text.lowercased().unicodeScalars.first, letter.isASCII, CharacterSet.alphanumerics.contains(letter) {
        let key = (held + [String(letter)]).joined(separator: "+")
        ComputerHost.shared.personInput(computer, op: "key", ["key": key], step: "pressed \(key)")
        return
      }
      guard let typed = event.characters, !typed.isEmpty, modifiers.isEmpty else { return }
      ComputerHost.shared.personInput(computer, op: "type", ["text": typed], step: "typed")
    }
  }
}

/// The detachable window: the same panel for one computer, kept open until closed.
@MainActor final class ComputerWindow: NSObject, NSWindowDelegate {
  private static var current: ComputerWindow?
  private let window: NSWindow
  private let computer: ComputerHost.Computer
  private let initialSetup: Bool

  static func show(_ computer: ComputerHost.Computer, initialSetup: Bool = false) {
    if let current, current.computer === computer, !initialSetup || current.initialSetup {
      current.window.makeKeyAndOrderFront(nil)
      return
    }
    current?.window.close()
    let next = ComputerWindow(computer: computer, initialSetup: initialSetup)
    current = next
    next.window.center()
    next.window.makeKeyAndOrderFront(nil)
  }

  static func closeInitialSetup(_ computer: ComputerHost.Computer, showComputer: Bool = false) {
    guard let current, current.computer === computer, current.initialSetup else { return }
    current.window.close()
    if showComputer { AssistantInspector.shared.show(computer.id, tab: .activity) }
  }

  private init(computer: ComputerHost.Computer, initialSetup: Bool) {
    self.computer = computer
    self.initialSetup = initialSetup
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.title = initialSetup ? "Set up Serein" : "Serein's computer · " + ComputerHost.shared.assistantName(computer.id)
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 520, height: 400)
    window.backgroundColor = Palette.dynamic(\.background)
    window.delegate = self
    let host = NSHostingView(rootView: ComputerWindowRoot(computer: computer, initialSetup: initialSetup))
    host.sizingOptions = []
    window.contentView = host
    computer.inOwnWindow = true
  }

  func windowWillClose(_ notification: Notification) {
    computer.inOwnWindow = false
    if Self.current === self { Self.current = nil }
  }
}

/// The window's content in the person's palette, as other windows of their own are.
private struct ComputerWindowRoot: View {
  let computer: ComputerHost.Computer
  let initialSetup: Bool
  @ObservedObject private var appearance = AppearanceController.shared
  var body: some View {
    ComputerPanel(computer: computer, inWindow: true, initialSetup: initialSetup).environment(\.palette, appearance.palette)
  }
}

/// The tasks waiting for a computer, one line each (ComputerWait), in its inspector tab.
struct ComputerQueueLines: View {
  @ObservedObject var computer: ComputerHost.Computer
  @ObservedObject private var host = ComputerHost.shared
  @Environment(\.palette) var p
  var body: some View {
    if !computer.queue.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(computer.queue, id: \.self) { task in
          if let wait = host.wait(computer, tasks: [task]) {
            Text(verbatim: wait.line(task: host.taskTitle(task))).font(UIStyle.meta).foregroundStyle(p.secondary)
              .lineLimit(2).fixedSize(horizontal: false, vertical: true)
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension ComputerHost {
  /// Where the first of `tasks` waiting in line for this computer stands, nil when none waits:
  /// the person's control first (Hand back moves the line), then a reset, then the holding task.
  func wait(_ computer: Computer, tasks: Set<String>) -> ComputerWait? {
    guard let index = computer.queue.firstIndex(where: tasks.contains) else { return nil }
    let holder: ComputerWait.Holder
    if computer.control == .person {
      holder = .person
    } else if computer.resetting || computer.resetOwed {
      holder = .clearing
    } else if let task = computer.holder {
      holder = .task(taskTitle(task))
    } else {
      holder = .free
    }
    return ComputerWait(place: index + 1, holder: holder)
  }
  /// The tasks of a thread's runs, for its view's line.
  func tasks(ofThread thread: String) -> Set<String> {
    guard let relay = RelayOrchestrator.shared else { return [] }
    return Set(relay.agent.hub.runs.filter { $0.spec.threadID == thread }.map(\.taskID))
  }
}

/// Under the screen in the inspector's Computer tab, awake or asleep: the computer's detached jobs
/// (each with its state, and Stop job while it runs), the person's notes for it (assistants read
/// them, never write them) and the one folder of this Mac it may read (read-only, where its place
/// can mount one). Each change here is the person's own; sharing a folder still asks on its card.
struct ComputerExtras: View {
  @ObservedObject var computer: ComputerHost.Computer
  let name: String
  @ObservedObject private var host = ComputerHost.shared
  @Environment(\.palette) var p
  @State private var draft = ""
  @State private var loaded = false
  @State private var noteError: String?
  @State private var more = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if !computer.jobs.isEmpty { jobs }
      // Notes and the shared folder stay one click away, closed, so the computer itself leads.
      DisclosureGroup(isExpanded: $more) {
        VStack(alignment: .leading, spacing: 16) {
          notes
          folder
        }.padding(.top, 10)
      } label: {
        Text("Notes and shared folder").font(UIStyle.meta).foregroundStyle(p.secondary)
      }.tint(p.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      guard !loaded else { return }
      draft = computer.notes
      loaded = true
    }
  }

  private func heading(_ title: String) -> some View {
    Text(title).font(UIStyle.metaStrong).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
  }

  private var jobs: some View {
    VStack(alignment: .leading, spacing: 6) {
      heading("Detached jobs")
        .help(computer.place.capabilities.paid
              ? "The computer still pauses when idle, so it costs nothing then; a running job waits and carries on when it is next woken. \(name) is told in its chat when one ends."
              : "A running job keeps the computer awake until it ends (at most \(Int(ComputerJobs.timeLimit / 3600)) hours). \(name) is told in its chat when one ends.")
      // Running minutes move on their own: the lines redraw once a minute.
      TimelineView(.periodic(from: .now, by: 60)) { context in
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(computer.jobs.reversed())) { job in
            let status = ComputerJobs.status(job, now: context.date, computerRunning: computer.state == .running)
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 1) {
                // The job's name is the command an assistant wrote: shown as it is, never as markup.
                Text(verbatim: job.name).font(UIStyle.monoMeta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
                Text(verbatim: status).font(UIStyle.micro).foregroundStyle(p.secondary)
              }
              Spacer(minLength: 4)
              if job.running, computer.state == .running {
                Button("Stop job") { Task { await host.stopJob(job.id, in: computer) } }.buttonStyle(QuietButton())
                  .help("End this job and everything it started inside \(name)'s computer")
                  .accessibilityLabel("Stop job \(job.name)")
              }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Job \(job.name), \(status)")
          }
        }
      }
    }
  }

  private var notes: some View {
    VStack(alignment: .leading, spacing: 6) {
      heading("Notes")
        .help("What \(name) should know about this computer: what is installed, where things are. \(name) reads them as notes, not instructions, and cannot change them.")
      TextEditor(text: $draft).font(UIStyle.monoMeta).scrollContentBackground(.hidden)
        .frame(height: 96).padding(6)
        .background(p.background, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(p.borderStrong))
        .onChange(of: draft) { _, _ in noteError = nil }
        .accessibilityLabel("Notes for \(name)'s computer")
      HStack(spacing: 8) {
        let bytes = ComputerNotes.normalized(draft).utf8.count
        Text(verbatim: "\(bytes) of \(ComputerNotes.limit) bytes")
          .font(UIStyle.micro).foregroundStyle(bytes > ComputerNotes.limit ? p.danger : p.secondary)
        Spacer(minLength: 4)
        Button("Revert") { draft = computer.notes }.buttonStyle(QuietButton()).disabled(draft == computer.notes)
          .help("Go back to the saved notes")
        Button("Save") { noteError = host.saveNotes(draft, for: computer) }.buttonStyle(QuietButton())
          .disabled(draft == computer.notes || bytes > ComputerNotes.limit)
          .help("Save the notes; \(name) reads them from its next turn")
          .accessibilityLabel("Save the notes for \(name)'s computer")
      }
      if let noteError { Text(verbatim: noteError).font(UIStyle.micro).foregroundStyle(p.danger) }
    }
  }

  private var folder: some View {
    VStack(alignment: .leading, spacing: 6) {
      let sharing: String = computer.place == .docker ? " \(ComputerSharedFolder.dockerSharing)" : ""
      heading("Shared folder")
        .help("Mounted read-only at \(ComputerSharedFolder.mountPoint), not copied: \(name) can read it and cannot change it. What \(name) makes comes back only through the Outbox card. The computer restarts when this changes, which ends its running detached jobs." + sharing)
      if let refusal = ComputerSharedFolder.placeRefusal(computer.place) {
        Text(verbatim: refusal).font(UIStyle.micro).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 8) {
          Text(verbatim: computer.sharedFolder ?? "None").font(UIStyle.meta).foregroundStyle(computer.sharedFolder == nil ? p.secondary : p.ink)
            .lineLimit(1).truncationMode(.middle).help(computer.sharedFolder ?? "")
          Spacer(minLength: 4)
          Button(computer.sharedFolder == nil ? "Choose Folder…" : "Change…") { choose() }.buttonStyle(QuietButton())
            .help("Pick one folder on this Mac that \(name)'s computer may read, read-only")
            .accessibilityLabel(computer.sharedFolder == nil ? "Choose a folder to share with \(name)'s computer" : "Change the folder shared with \(name)'s computer")
          if computer.sharedFolder != nil {
            Button("Stop Sharing") { Task { await host.setSharedFolder(nil, for: computer) } }.buttonStyle(QuietButton())
              .accessibilityLabel("Stop sharing the folder with \(name)'s computer")
          }
        }
      }
    }
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Share"
    panel.message = "Choose one folder that \(name)'s computer may read. It is mounted read-only."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await host.setSharedFolder(url, for: computer) }
  }
}

struct ControlPill: View {
  let holder: ComputerHold.Holder
  let heldName: String
  var hint = ""
  let take: () -> Void
  let handBack: () -> Void
  @Environment(\.palette) private var p

  var body: some View {
    let person = holder != .assistant
    HStack(spacing: 16) {
      HStack(spacing: 0) {
        Text(holder == .person ? "You\u{2019}re in control" : holder == .pending ? "Taking control" : "Watching")
          .fontWeight(.medium).foregroundStyle(.white)
        + Text(holder == .person ? "" : holder == .pending ? " \u{00B7} after this step" : hint)
          .foregroundStyle(.white.opacity(0.7))
      }.font(UIStyle.font(14)).lineLimit(1)
      Button(person ? (holder == .pending ? "Cancel" : "Hand back") : "Take control") {
        if person { handBack() } else { take() }
      }
      .buttonStyle(.pressable).font(UIStyle.font(14, weight: .medium)).foregroundStyle(p.ink)
      .padding(.horizontal, 14).frame(height: 32).background(p.raised, in: Capsule()).contentShape(Capsule())
      .help(person ? "Hand \(heldName) back" : "Take over \(heldName)")
      .accessibilityLabel(person ? "Hand \(heldName) back" : "Take over \(heldName)")
    }
    .padding(.leading, 18).padding(.trailing, 6).padding(.vertical, 6)
    .background(Color(hex: 0x2A2A2A).opacity(0.95), in: Capsule())
    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: UIStyle.hairline))
    .shadow(color: .black.opacity(0.4), radius: 15, y: 10)
    .accessibilityElement(children: .contain)
  }
}
