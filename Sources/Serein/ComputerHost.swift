import AppKit
import Combine
import CoreServices
import Foundation
import SereinCore

/// Serein's computer (ComputerPolicy): one Linux desktop per assistant, in a hardened container
/// started through the local Docker socket (DockerComputer), in a virtual machine Serein runs
/// itself (VirtualMachineComputer, the default without Docker) or, when the person picks it for
/// that assistant, on E2B or Daytona under their own account (E2BComputer, DaytonaComputer,
/// HostedComputer), or on their own computer over SSH (OwnComputer.swift: Serein's container
/// there, or the machine as it is). Every way it is reached only over command streams
/// (ComputerLink), with its web traffic judged by Serein's own proxy (ComputerProxy) unless it uses
/// its own internet (a hosted computer the person gave its provider's, or their own machine as it
/// is, where every act asks). The `computer_*` tools come here from BrowserModel.perform; steps
/// inside the computer need no
/// card, and the three things that cross to this Mac (a file out through the Outbox, text out to
/// the clipboard, a file in by the person's drag) each go through ApprovalDoor.answer and a
/// card. One task holds a computer at a time; the person can watch, take over and hand back.
@MainActor final class ComputerHost: ObservableObject {
  static let shared = ComputerHost()
  static let folder = "computers"

  /// Who may act inside the computer now (ComputerHold.Holder, pure and checked).
  typealias Control = ComputerHold.Holder
  enum State: Equatable {
    case none, starting, running, paused, stopped
    case error(String)
    var label: String {
      switch self {
      case .none: return "Not started"
      case .starting: return "Starting"
      case .running: return "Running"
      case .paused: return "Paused"
      case .stopped: return "Stopped"
      case .error(let text): return "Problem: " + text
      }
    }
  }
  /// What the proxy's threads need about the assistant, kept where they can read it without
  /// the main actor: refreshed on every tool call, and the computer's list of sites on every
  /// change to it, so the next connection meets the new list.
  final class ProxyFacts {
    private let lock = NSLock()
    private var never: [String] = []
    private var name = "this assistant"
    private var sites = ComputerAllowlist()
    func update(never: [String], name: String) {
      lock.lock(); defer { lock.unlock() }
      self.never = never
      self.name = name
    }
    func update(sites: ComputerAllowlist) {
      lock.lock(); defer { lock.unlock() }
      self.sites = sites
    }
    var current: (never: [String], name: String, sites: ComputerAllowlist) {
      lock.lock(); defer { lock.unlock() }
      return (never, name, sites)
    }
  }
  struct HostLine: Identifiable, Equatable {
    var id = UUID()
    var at = Date()
    var host: String
    var refusal: String?
  }

  /// One assistant's computer, as the panel and settings observe it.
  @MainActor final class Computer: ObservableObject, Identifiable {
    let id: String
    @Published var state: State = .none
    @Published var control: Control = .assistant
    @Published var screen: NSImage?
    @Published var holder: String?
    @Published var queue: [String] = []
    @Published var hosts: [HostLine] = []
    @Published var mode: ComputerPolicy.Mode = .throwaway
    @Published var hasCheckpoint = false
    @Published var busy = false
    /// What the built-in computer's first setup or start is doing now; nil otherwise.
    @Published var setupLine: String?
    /// App-owned Mac preparation, distinct from whether the VM is powered on.
    @Published var macSetup = MacSetupPhase.preparing
    /// Its own window (ComputerWindow) is open: the live screen shows there only.
    @Published var inOwnWindow = false
    /// Where it runs (Settings › Serein's computer), and, on a hosted place, its settings and record.
    @Published var place: ComputerPlace = .docker
    /// Apple's normal NAT for the virtual Mac, off until the person accepts its widening card.
    @Published var macInternet = MacComputerPolicy.networkByDefault
    @Published var hosted = HostedSettings()
    /// Settings › Serein's computer › Only these sites: the list Serein's proxy holds it to.
    @Published var sites = ComputerAllowlist()
    /// Settings › Serein's computer › Keep step pictures for this machine: only asked of the
    /// person's own machine used as it is (`showsPersonalScreen`), off until they turn it on.
    @Published var keepsStepPictures = false
    /// `place` is in the saved record (picked, or kept at its first start), not a default.
    var placeKept = false
    /// On the person's own machine: how Serein reaches it and how far the assistant may go there.
    @Published var own: OwnSettings?
    /// This computer's host showed another host key than the one the person trusted, so steps to
    /// this host answer `Boundary.hostKey` until they check the new one (Settings › Serein's
    /// computer). Kept per computer, so other hosts run (R21).
    @Published var keyChanged = false
    /// Remove did not reach the person's own machine: Settings offers Forget Without Removing.
    @Published var removeFailed = false
    /// "Up to 2 GB and 1 CPU on studio": the caps A desktop for Serein runs with there, once known.
    @Published var capsLine: String?
    /// The latest screen picture's size in pixels: always 1280×800 on Serein's own computers; the
    /// person's own machine's helper scales its screen to fit 1280 a side.
    @Published var screenWidth = ComputerPolicy.screenWidth
    @Published var screenHeight = ComputerPolicy.screenHeight
    /// The backend for `place`, made on first use (ComputerHost.machine(for:)).
    var machine: ComputerBackend?
    /// The network a hosted computer's helper was started with: its environment says where the
    /// browser and commands go, so links from another setting are closed and opened again.
    var linksNetwork: HostedNetwork?
    /// A new hosted computer's checkpoint was not put back yet (the restore, or deleting the
    /// computer after it failed, did not finish): the next start restores it, and no checkpoint
    /// is saved over it from the empty home meanwhile.
    var restoreOwed = false
    /// Viewers that want the screen now (panels and the window); polling runs while any does.
    var watchers = 0
    var helper = HelperChannel()
    var shell: HelperChannel?
    var proxy: ProxyMux?
    /// Cua Driver as the screen (DriverScreen), while `CuaDriverPolicy` is on and the built-in
    /// computer carries it; opened on the first screen op, and closed with the other links.
    var driver: DriverScreen?
    var driverOpening: Task<DriverScreen, Error>?
    let facts = ProxyFacts()
    var lastUsed = Date()
    /// What the person did while they had control, told to the assistant at hand back.
    var personSteps: [String] = []
    /// What the model has seen since the screen last changed hands (StepGuard).
    var steps = StepGuard()
    /// The person asked to take control (ComputerHost+Box); screen steps wait while it is open.
    @Published var ask: PersonAsk?
    /// The screen the steps go through: the helper or Cua Driver (ComputerHost+Box).
    @Published var screenPath = ScreenPath.helper
    /// Its last start found this build's pinned Cua Driver inside (ComputerPins.carriesDriver).
    var carriesDriver = false
    /// The person's last input while they hold control, and when the last view of the screen
    /// closed (nil while one shows): `ComputerHold.lapse` ends the hold from these.
    var heldInputAt = Date()
    var viewClosedAt: Date?
    var holdWatch: Task<Void, Never>?
    var poller: Task<Void, Never>?
    /// A start-up in flight; every other caller waits for it instead of starting a second one.
    var starting: Task<Void, Error>?
    /// A Throwaway reset between two tasks: nobody holds the computer while it runs. Published,
    /// as is `resetOwed`, for the waiting line's "being cleared" (ComputerWait).
    @Published var resetting = false
    /// A Throwaway reset is due but waits for Hand back (never under the person's hands); nobody
    /// may hold the computer until it ran.
    @Published var resetOwed = false
    /// When the last owed reset failed; a refused lease retries it at most every 30 seconds.
    var resetFailedAt: Date?
    /// Serein's own chat used this Throwaway computer: its task spans turns, so the reset waits
    /// until that task ends or the computer goes idle.
    var chatTask: String?
    /// Hosts already written to the holding task's steps; refusals are written every time.
    var notedHosts = Set<String>()
    /// A step's picture is on its way from the helper (`picture(after:)`).
    var picturing = false
    /// Detached jobs (`computer_run` with `detach`): running, waiting to be reported, and the last
    /// few that ended; saved in `computers/state.json` so a relaunch still reports them.
    @Published var jobs: [ComputerJob] = []
    /// Polls the running jobs while the computer runs (`watchJobs`).
    var jobWatch: Task<Void, Never>?
    /// The folder on this Mac shared read-only with this computer (its resolved path), if any.
    @Published var sharedFolder: String?
    /// The person's notes for this computer, as saved (`computers/<id>/notes.txt`).
    @Published var notes = ""
    /// A built-in computer whose helper stayed another than the pinned one after a fresh boot: only
    /// setting it up again fixes that, so its starts refuse at once until it is deleted.
    var pinsRefused: String?
    init(id: String) { self.id = id }
  }

  @Published private(set) var backend: DockerSocket.Found?
  @Published private(set) var backendProblem: String?
  @Published private(set) var imageSize: Int64?
  /// The image there was built from other pins than this Serein's (its `serein.computer.pins`
  /// label, ComputerPins): every Docker computer refuses to start until Rebuild.
  @Published private(set) var imageStale = false
  /// The arch of the built image when it carries this copy's Cua Driver for it (its label).
  private(set) var imageDriverArch: CuaDriverRelease.Arch?
  @Published private(set) var buildLines: [String] = []
  @Published private(set) var building = false
  @Published private(set) var computers: [String: Computer] = [:]
  @Published var notice: String?
  private var buildCancel: DockerCancel?
  private weak var browser: BrowserModel?
  private weak var hub: AgentHub?
  private var runWatch: AnyCancellable?
  private var taskWatch: AnyCancellable?
  private var clock: Task<Void, Never>?
  private var setupObservers = Set<AnyCancellable>()
  private var initialMacAttempted = false
  private struct Saved: Codable {
    /// Keep step pictures for this machine, per assistant; absent before step pictures.
    var stepPictures: [String: Bool]?
    var modes: [String: ComputerPolicy.Mode]
    /// Absent in a record from before hosted computers: every computer then runs on Docker.
    var places: [String: ComputerPlace]?
    var hosted: [String: HostedSettings]?
    /// Absent before own computers.
    var own: [String: OwnSettings]?
    /// The read-only shared folder, per assistant; absent before shared folders.
    var shared: [String: String]?
    /// Detached jobs, per assistant; absent before detached jobs.
    var jobs: [String: [ComputerJob]]?
    /// Absent before Only these sites.
    var sites: [String: ComputerAllowlist]?
  }

  var root: URL? { browser?.library.root.appendingPathComponent(Self.folder, isDirectory: true) }
  private var engine: DockerEngine? { backend.map { DockerEngine(socketPath: $0.path) } }
  var backendName: String? { backend?.name }

  func attach(_ browser: BrowserModel, hub: AgentHub) {
    self.browser = browser
    self.hub = hub
    if let root {
      try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
      // The Outbox is emptied at launch: a file nobody answered for belongs to no card now.
      try? FileManager.default.removeItem(at: root.appendingPathComponent("outbox"))
      BuiltInImage.shared.attach(folder: root.appendingPathComponent(VirtualMachinePolicy.imageFolderName, isDirectory: true))
    }
    // A computer with a detached job still running or not yet reported is loaded now, so the job's
    // end is still told in its chat after a relaunch (`deliverJobMessages`, from `sweep`).
    for (id, jobs) in browser.library.load(Saved.self, from: Self.folder + "/state.json")?.jobs ?? [:]
    where jobs.contains(where: { $0.running || !$0.reported }) {
      let loaded = computer(for: id)
      // Quit stopped a container (on this Mac, or a desktop on the person's machine) with every
      // process in it: its jobs are already gone, and their message goes now, not at the next Wake.
      if loaded.place == .docker || loaded.place == .ownDesktop { endJobs(loaded, .lost) }
    }
    // Read after the change lands: a published value's sink runs before it is stored.
    runWatch = hub.$runs.sink { [weak self] _ in Task { @MainActor in self?.sweep() } }
    taskWatch = browser.$tasks.sink { [weak self] _ in Task { @MainActor in self?.sweep() } }
    clock = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        await self?.pauseIdle()
        // A job's message that waited for a busy chat goes once that chat is idle at a tick.
        self?.deliverJobMessages()
      }
    }
    // The engine is probed only while the switch is on; Settings › Serein's computer probes too.
    if ComputerPolicy.isEnabled() { Task { await refreshBackend() } }
    // First-run preparation belongs to setup, before the assistant needs a computer. Wait for
    // an actual unmetered path; the monitor's initial defaults must not start a large download.
    let network = NetworkMonitor.shared
    Publishers.CombineLatest3(network.$known, network.$online, network.$metered)
      .sink { [weak self] _ in Task { @MainActor in await self?.prepareInitialMac() } }
      .store(in: &setupObservers)
    NotificationCenter.default.publisher(for: GateSettings.changed)
      .sink { [weak self] _ in Task { @MainActor in await self?.prepareInitialMac() } }
      .store(in: &setupObservers)
  }

  func prepareInitialMac() async {
    let network = NetworkMonitor.shared
    guard !initialMacAttempted, ComputerPolicy.isEnabled(), ComputerPolicy.setsItselfUp(),
      VirtualMachineComputer.supported, VirtualMachineComputer.entitled,
      network.known, network.online, !network.metered, let root
    else { return }
    let computer = computer(for: RelayTeam.mainID)
    guard computer.place == .macOS, computer.state != .running, computer.starting == nil,
      computer.holder == nil, !computer.busy
    else { return }
    initialMacAttempted = true
    // Quietly, in the background: no window, and no folder picker when the disk is too full.
    guard MacRestoreImage.shared.chooseStorage(defaultFolder: root.appendingPathComponent("macOS", isDirectory: true), asks: false) else {
      GateSettings.shared.set(false, forKey: ComputerPolicy.autoSetUpKey)
      ComputerWindow.closeInitialSetup(computer)
      return
    }
    guard ComputerPolicy.isEnabled(), computer.place == .macOS else { return }
    await resumeInitialSetup(computer)
  }

  /// Showing setup is not permission to start a large restore download on a metered path.
  func resumeInitialSetup(_ computer: Computer) async {
    guard ComputerPolicy.isEnabled(), ComputerPolicy.setsItselfUp(), computer.place == .macOS else { return }
    let network = NetworkMonitor.shared
    guard ready(computer) || (network.known && network.online && !network.metered) else {
      initialMacAttempted = false
      return
    }
    await resume(computer)
  }

  /// First-run setup waits for the private Mac, without changing existing computer choices.
  func initialMacSetupComputer() -> Computer? {
    guard !RunMode.automated, !RunMode.previewing, !RunMode.stress, root != nil,
      ComputerPolicy.isEnabled(), ComputerPolicy.setsItselfUp(),
      VirtualMachineComputer.supported, VirtualMachineComputer.entitled else { return nil }
    let computer = computer(for: RelayTeam.mainID)
    guard computer.place == .macOS,
      (machine(for: computer) as? MacVirtualComputer)?.hasCompletedSetup != true else { return nil }
    return computer
  }

  // MARK: backend and image

  /// Looks for an engine socket and asks it for the image. Safe to call again from Settings.
  func refreshBackend() async {
    let found = DockerSocket.find()
    backend = found
    guard let found else {
      backendProblem = nil
      imageSize = nil
      return
    }
    let engine = DockerEngine(socketPath: found.path)
    do {
      let ping = try await Task.detached { try engine.request("GET", "/_ping", timeout: 5) }.value
      guard ping.ok else { throw DockerError(text: ping.message) }
      backendProblem = nil
      imageSize = await inspectImage(engine)
    } catch {
      backendProblem = error.localizedDescription
      imageSize = nil
    }
  }
  private func inspectImage(_ engine: DockerEngine) async -> Int64? {
    let reply = try? await Task.detached { try engine.request("GET", "/images/\(ComputerPolicy.imageTag)/json", timeout: 10) }.value
    guard let reply, reply.ok else {
      imageStale = false
      return nil
    }
    let labels = (reply.dictionary["Config"] as? [String: Any])?["Labels"] as? [String: Any]
    imageDriverArch = Self.driverArch(image: reply.dictionary, labels: labels)
    imageStale = labels?[ComputerPins.labelKey] as? String != ComputerPins.labelValue
    return (reply.dictionary["Size"] as? NSNumber)?.int64Value
  }
  var imageBuilt: Bool { imageSize != nil }

  /// The build context: Serein's own Dockerfile, helper and start script from the app's resources.
  nonisolated private static func buildContext(_ arch: CuaDriverRelease.Arch?) throws -> Data {
    TarArchive.make(try recipeFiles() + (try arch.map(Self.boxDriverFiles) ?? []))
  }
  /// One file of the computer's recipe from the app's resources, read whole: the helper, the
  /// start script and Cua Driver's files only when they match the pins this build was made with
  /// (ComputerPins.pin(forResource:)), so nothing changed since is copied into any computer.
  nonisolated static func shippedFile(_ name: String, _ kind: String?) throws -> Data {
    guard let url = Bundle.assets.url(forResource: name, withExtension: kind, subdirectory: "Computer") else {
      throw SereinError.invalid("The computer's build files are missing from this copy of Serein.")
    }
    let data = try Data(contentsOf: url)
    if let pin = ComputerPins.pin(forResource: name), ComputerPins.sha256(data) != pin {
      throw SereinError.invalid(ComputerPins.changedCopy)
    }
    return data
  }
  /// Whether this copy of Serein ships Cua Driver (scripts/cua-driver.sh put the pinned binary in
  /// the app's `Computer` resources at build time; a build without it has no driver path).
  nonisolated static var driverShipped: Bool {
    Bundle.assets.url(forResource: CuaDriverRelease.binaryResource, withExtension: nil, subdirectory: "Computer") != nil
  }
  /// Cua Driver's binary, licence and notices for the built-in computer's seed, each checked
  /// against its pin (a changed one throws `ComputerPins.changedCopy`), or nil when this copy
  /// ships no driver. The binary is about 56 MB: call it off the main actor.
  nonisolated static func shippedDriver() throws -> VirtualMachineSeed.DriverFiles? {
    guard driverShipped else { return nil }
    let binary = try shippedFile(CuaDriverRelease.binaryResource, nil)
    let license = try shippedFile(CuaDriverRelease.licenseResource, "txt")
    let notices = try shippedFile(CuaDriverRelease.noticesResource, "md")
    let crateNotices = try shippedFile(CuaDriverRelease.crateNoticesResource, "md")
    return (binary, license, notices, crateNotices)
  }

  /// Builds (or rebuilds) the image from the shipped Dockerfile, showing the engine's lines.
  func buildImage() {
    guard !building, let engine else { return }
    building = true
    buildLines = ["Building Serein's computer. The base image is pinned by digest; the desktop and browser are installed on top at pinned versions from Debian's snapshot archive, then Serein's pinned helper."]
    let cancel = DockerCancel()
    buildCancel = cancel
    Task {
      do {
        let arch = await Task.detached { Self.engineArch(engine) }.value
        let context = try await Task.detached { try Self.buildContext(arch) }.value
        let labels = jsonString(Self.imageLabels(arch))
          .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let path = "/build?t=\(ComputerPolicy.imageTag)&dockerfile=Dockerfile&forcerm=1&rm=1&labels=\(labels)"
        final class Failure { var text: String? }
        let failure = Failure()
        let status = try await Task.detached {
          try engine.stream("POST", path, body: context, contentType: "application/x-tar", cancel: cancel) { line in
            let text = (line["stream"] as? String ?? line["status"] as? String ?? "")
              .trimmingCharacters(in: .whitespacesAndNewlines)
            if let error = line["error"] as? String { failure.text = error }
            guard !text.isEmpty else { return }
            Task { @MainActor in
              ComputerHost.shared.buildLines = Array((ComputerHost.shared.buildLines + [text]).suffix(200))
            }
          }
        }.value
        if cancel.isCancelled { throw SereinError.invalid("Cancelled.") }
        if let failed = failure.text { throw SereinError.invalid(failed) }
        guard (200..<300).contains(status) else { throw SereinError.invalid("The engine refused the build (HTTP \(status)).") }
        imageSize = await inspectImage(engine)
        guard imageSize != nil else { throw SereinError.invalid("The build ended but the image is not there.") }
        buildLines.append("Done. Serein's computer is built.")
      } catch {
        buildLines.append(cancel.isCancelled ? "Cancelled. Removing what was built so far." : "Failed: " + error.localizedDescription)
        await removePartialLayers(engine)
        if cancel.isCancelled { buildLines.append("Nothing of the cancelled build is left.") }
      }
      building = false
      buildCancel = nil
    }
  }
  func cancelBuild() { buildCancel?.cancel() }
  /// Layers a cancelled or failed build left behind carry the image's label; only those go.
  private func removePartialLayers(_ engine: DockerEngine) async {
    let prune: [String: [String]] = ["dangling": ["true"], "label": ["\(ComputerPolicy.label)=image"]]
    let filters = jsonString(prune)
      .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    _ = try? await Task.detached { try engine.request("POST", "/images/prune?filters=\(filters)", timeout: 60) }.value
  }
  /// Deletes the image after every computer is stopped and removed.
  func deleteImage() async {
    guard let engine else { return }
    for computer in computers.values where computer.place == .docker { await delete(computer) }
    let reply = try? await Task.detached { try engine.request("DELETE", "/images/\(ComputerPolicy.imageTag)?force=true", timeout: 60) }.value
    if let reply, !reply.ok { notice = "The image could not be deleted: " + reply.message }
    imageSize = await inspectImage(engine)
  }

  // MARK: computers

  func computer(for assistantID: String) -> Computer {
    if let known = computers[assistantID] { return known }
    let computer = Computer(id: assistantID)
    let saved = browser?.library.load(Saved.self, from: Self.folder + "/state.json")
    if let saved {
      computer.mode = saved.modes[assistantID] ?? .throwaway
      computer.hosted = saved.hosted?[assistantID] ?? HostedSettings()
      computer.own = saved.own?[assistantID]
      computer.keepsStepPictures = saved.stepPictures?[assistantID] ?? false
      computer.sharedFolder = saved.shared?[assistantID]
      computer.jobs = saved.jobs?[assistantID] ?? []
      computer.sites = saved.sites?[assistantID] ?? ComputerAllowlist()
    }
    computer.notes = notesText(assistantID) ?? ""
    computer.facts.update(sites: computer.sites)
    let own = root?.appendingPathComponent(assistantID, isDirectory: true)
    let fm = FileManager.default
    computer.placeKept = saved?.places?[assistantID] != nil
    computer.place = saved?.places?[assistantID] ?? defaultPlace(assistantID)
    computer.macInternet = MacComputerPolicy.networkOn(
      stored: GateSettings.shared.dictionary(forKey: MacComputerPolicy.internetKey)?[assistantID] as? Bool)
    if computer.place == .macOS { computer.mode = .keep }
    if computer.place != .macOS, let own {
      computer.hasCheckpoint = fm.fileExists(atPath: own.appendingPathComponent("checkpoint.tar").path)
        || fm.fileExists(atPath: own.appendingPathComponent("checkpoint.img").path)
    }
    computers[assistantID] = computer
    return computer
  }
  func setMode(_ mode: ComputerPolicy.Mode, for computer: Computer) {
    guard computer.place != .macOS, computer.place != .unavailable else { return }
    computer.mode = mode
    updateSaved { $0.modes[computer.id] = mode }
  }
  /// Keep step pictures for this machine (Settings › Serein's computer).
  func setKeepsStepPictures(_ on: Bool, for computer: Computer) {
    computer.keepsStepPictures = on
    updateSaved { saved in
      var all = saved.stepPictures ?? [:]
      all[computer.id] = on
      saved.stepPictures = all
    }
  }
  // MARK: notes and the shared folder

  /// The person's notes for an assistant's computer as saved, or nil: none, over the cap, or not a
  /// plain file (a link is not followed). RelayPrompt.volatile reads them through ComputerNotes.prompt.
  func notesText(_ assistantID: String) -> String? {
    guard let root else { return nil }
    let file = root.appendingPathComponent(assistantID + "/" + ComputerNotes.fileName)
    guard let data = SafeFileRead.regularFile(file.path, limit: ComputerNotes.limit + 1), data.count <= ComputerNotes.limit
    else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
  /// Save in the inspector's Computer tab, the only way notes are written: at most
  /// `ComputerNotes.limit` bytes, 0600 in the computer's Library folder (0700); empty notes remove
  /// the file. Returns why they were not saved, or nil.
  func saveNotes(_ raw: String, for computer: Computer) -> String? {
    let text = ComputerNotes.normalized(raw)
    if let refusal = ComputerNotes.refusal(text) { return refusal }
    guard let browser, let root else { return "Serein's Library is not ready." }
    let folder = root.appendingPathComponent(computer.id, isDirectory: true)
    let fm = FileManager.default
    do {
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try? fm.removeItem(at: folder.appendingPathComponent(ComputerNotes.fileName))
        computer.notes = ""
        return nil
      }
      try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
      try browser.library.saveText(text, to: Self.folder + "/" + computer.id + "/" + ComputerNotes.fileName)
      computer.notes = text
      return nil
    } catch {
      return "The notes could not be saved: " + error.localizedDescription
    }
  }

  /// The home folder and the Library in their physical spelling (realpath: the disk's own case,
  /// `/private` kept), as the shared folder's rules compare them.
  private var homePath: String { AgentFileGuard.physicalPath(FileManager.default.homeDirectoryForCurrentUser.path) }
  private var libraryPath: String? { browser.map { AgentFileGuard.physicalPath($0.library.root.path) } }
  /// The folder to mount when this computer starts: the person's pick, only where its place mounts
  /// one, still a folder at the same resolved path (a link put in its place since is not followed)
  /// and still allowed by ComputerSharedFolder's rules; nil otherwise.
  private func sharedPath(_ computer: Computer) -> String? {
    guard ComputerSharedFolder.placeRefusal(computer.place) == nil, let path = computer.sharedFolder, let library = libraryPath
    else { return nil }
    var directory: ObjCBool = false
    guard AgentFileGuard.physicalPath(path) == path,
      FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
      ComputerSharedFolder.refusal(path, home: homePath, library: library) == nil
    else { return nil }
    return path
  }
  /// Share a folder of this Mac with this computer, read-only, or stop sharing it (nil), from the
  /// inspector's Computer tab. Only Docker and the built-in computer mount one; the folder must
  /// pass ComputerSharedFolder's rules; and the person answers a person-only card (`sharedFolder`,
  /// ApprovalDoor.answer then confirmAnswer) that names the folder and says what the assistant can
  /// read. A running computer then restarts, so its next start mounts the change (Docker makes the
  /// container again around the same home volume; the built-in computer boots without its saved
  /// pause); detached jobs end with it.
  func setSharedFolder(_ url: URL?, for computer: Computer) async {
    if let refusal = ComputerSharedFolder.placeRefusal(computer.place) {
      notice = refusal
      return
    }
    guard let library = libraryPath else { return }
    let inUse = "\(assistantName(computer.id))'s computer is in use. Change its shared folder once its tasks are done."
    guard computer.holder == nil, !computer.busy, computer.queue.isEmpty, !computer.resetting else {
      notice = inUse
      return
    }
    var path: String?
    if let url {
      let resolved = AgentFileGuard.physicalPath(url.path)
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: resolved, isDirectory: &directory), directory.boolValue else {
        notice = "That is not a folder."
        return
      }
      if let refusal = ComputerSharedFolder.refusal(resolved, home: homePath, library: library) {
        notice = refusal
        return
      }
      guard resolved != computer.sharedFolder else { return }
      path = resolved
    } else {
      guard computer.sharedFolder != nil else { return }
    }
    let name = assistantName(computer.id)
    let shown = path ?? computer.sharedFolder ?? ""
    let folderName = URL(fileURLWithPath: shown).lastPathComponent
    // The restart ends running detached jobs; the card says so.
    let jobs = computer.jobs.contains(where: \.running)
    do {
      if path != nil {
        try await askPerson(
          .sharedFolder, ComputerSharedFolder.addTitle(folder: folderName, assistant: name),
          ComputerSharedFolder.addDetail(path: shown, assistant: name, jobs: jobs), button: "Share",
          declined: "The user declined; nothing is shared.", task: nil)
      } else {
        try await askPerson(
          .sharedFolder, ComputerSharedFolder.removeTitle(folder: folderName, assistant: name),
          ComputerSharedFolder.removeDetail(path: shown, assistant: name, jobs: jobs), button: "Stop Sharing",
          declined: "The user declined; the folder is still shared.", task: nil)
      }
    } catch {
      notice = AgentPrivacy.redact(error.localizedDescription)
      return
    }
    // A task may have taken the computer while the card waited: its work is never cut short.
    guard computer.holder == nil, !computer.busy, !computer.resetting else {
      notice = inUse
      return
    }
    recordSharedFolder(path, for: computer)
    await restartForMount(computer)
    notice = path.map { "\(name)'s computer can read \($0) at \(ComputerSharedFolder.mountPoint) from its next start." }
      ?? "\(name)'s computer no longer has \(shown)."
  }
  private func recordSharedFolder(_ path: String?, for computer: Computer) {
    computer.sharedFolder = path
    updateSaved { saved in
      var all = saved.shared ?? [:]
      all[computer.id] = path
      saved.shared = all
    }
  }
  /// The mount is made when a computer starts: one that is on goes off now. Docker stops the
  /// container (its next start makes it again with the new mount; a paused one is made again then
  /// too); the built-in computer stops and drops its saved pause, whose devices no longer match.
  private func restartForMount(_ computer: Computer) async {
    guard computer.state == .running || computer.state == .paused, let machine = computer.machine else { return }
    endJobs(computer, .reset)
    computer.poller?.cancel()
    computer.poller = nil
    closeLinks(computer)
    guard computer.state == .running || computer.place == .builtIn else { return }
    do {
      try await machine.restart()
      computer.state = .stopped
      computer.screen = nil
    } catch {
      notice = "Serein's computer could not restart: " + AgentPrivacy.redact(error.localizedDescription)
    }
  }
  /// A computer that moves, or is deleted, no longer has the folder: no card, since the person
  /// confirmed the move or the Delete.
  private func forgetSharedFolder(_ computer: Computer) {
    guard computer.sharedFolder != nil else { return }
    recordSharedFolder(nil, for: computer)
  }

  /// One change to the saved record; the computers not loaded yet keep what they had.
  private func updateSaved(_ change: (inout Saved) -> Void) {
    var saved = browser?.library.load(Saved.self, from: Self.folder + "/state.json") ?? Saved(modes: [:])
    change(&saved)
    try? browser?.library.save(saved, to: Self.folder + "/state.json")
  }
  private func updateHosted(_ id: String, _ change: (inout HostedSettings) -> Void) {
    guard let computer = computers[id] else { return }
    change(&computer.hosted)
    let hosted = computer.hosted
    updateSaved { saved in
      var all = saved.hosted ?? [:]
      all[id] = hosted
      saved.hosted = all
    }
  }
  /// The own-computer record (nil forgets it).
  private func updateOwn(_ id: String, _ change: (inout OwnSettings?) -> Void) {
    guard let computer = computers[id] else { return }
    change(&computer.own)
    let own = computer.own
    updateSaved { saved in
      var all = saved.own ?? [:]
      all[id] = own
      saved.own = all
    }
  }
  /// An own computer's access level (Watch only or Can act), from Settings › Serein's computer.
  func setOwn(_ computer: Computer, _ change: (inout OwnSettings) -> Void) {
    updateOwn(computer.id) { own in
      guard var settings = own else { return }
      change(&settings)
      own = settings
    }
  }
  /// Where an assistant's computer runs, without making its record (RelayOrchestrator.offeredComputer).
  func place(of assistantID: String) -> ComputerPlace {
    if let known = computers[assistantID] { return known.place }
    return browser?.library.load(Saved.self, from: Self.folder + "/state.json")?.places?[assistantID] ?? defaultPlace(assistantID)
  }
  /// Until the person picks (or a start records it): Docker when it is installed, else the
  /// built-in computer, which also stays the place of an assistant that already has one. Docker
  /// counts when it is installed, running or not, or when this assistant has a Docker checkpoint,
  /// so an engine that is not running at launch never moves a computer. An install whose computer
  /// sets itself up goes to the built-in one, which needs nothing from the person; Docker needs its
  /// image built first.
  private func defaultPlace(_ assistantID: String) -> ComputerPlace {
    let own = root?.appendingPathComponent(assistantID, isDirectory: true)
    let fm = FileManager.default
    let dockerCheckpoint = own.map { fm.fileExists(atPath: $0.appendingPathComponent("checkpoint.tar").path) } ?? false
    let builtInExists = own.map { fm.fileExists(atPath: $0.appendingPathComponent(VirtualMachinePolicy.diskName).path) } ?? false
    if !dockerCheckpoint, !builtInExists, VirtualMachineComputer.supported { return .macOS }
    return ComputerPlace.defaultPlace(
      dockerFound: (DockerSocket.installed() && !ComputerPolicy.setsItselfUp()) || dockerCheckpoint,
      builtInExists: builtInExists)
  }
  /// The machine's name as the person gave it, or where the computer runs.
  func placeName(_ computer: Computer) -> String { computer.own?.target.text ?? computer.place.label }
  /// A hosted computer's settings from Settings › Serein's computer. A new internet setting is
  /// never left half-applied on a running computer: it pauses, and its next start applies the
  /// setting and has the provider confirm it before anything runs.
  func setHosted(_ computer: Computer, _ change: (inout HostedSettings) -> Void) async {
    let before = computer.hosted
    updateHosted(computer.id, change)
    let after = computer.hosted
    guard before.providerInternet != after.providerInternet || before.allowlist != after.allowlist
      || before.listOnly != after.listOnly,
      computer.place.capabilities.paid
    else { return }
    // A start in flight confirms the old setting: it ends first, then the computer pauses.
    _ = try? await computer.starting?.value
    if computer.state == .running { await pause(computer) }
  }
  /// Whether Only these sites applies: the computer's web traffic goes through Serein's proxy
  /// (Docker, built-in, a desktop on the person's machine, a hosted one through this Mac).
  func sitesApply(_ computer: Computer) -> Bool {
    computer.place.capabilities.carriesProxy && !(computer.place.capabilities.paid && computer.hosted.providerInternet)
  }
  /// Settings › Serein's computer › Only these sites. A change that lets the computer reach more
  /// (the list off, a site added while it is on) waits for the Widening card; one that narrows
  /// applies at once. The proxy meets the new list on its next connection.
  func changeSites(_ computer: Computer, _ edit: ComputerAllowlist.Edit) async {
    guard await allowWidening(computer.sites, edit, computer: computer, provider: nil, limit: ComputerAllowlist.maxSites),
      // Applied to the list as it is now, so a change made while the card waited stays.
      let next = computer.sites.applying(edit)
    else { return }
    computer.sites = next
    computer.facts.update(sites: next)
    let id = computer.id
    updateSaved { saved in
      var all = saved.sites ?? [:]
      all[id] = next
      saved.sites = all
    }
  }
  /// A hosted computer's provider-internet list (HostedRow), under the same Widening rules; the
  /// provider enforces it, so the computer pauses and its next start has the provider confirm it.
  func changeHostedSites(_ computer: Computer, _ edit: ComputerAllowlist.Edit) async {
    guard computer.place.capabilities.paid,
      await allowWidening(computer.hosted.providerList, edit, computer: computer, provider: computer.place.label,
                          limit: HostedNetwork.maxAllow)
    else { return }
    await setHosted(computer) { settings in
      if let next = settings.providerList.applying(edit, limit: HostedNetwork.maxAllow) { settings.providerList = next }
    }
  }
  /// Settings › Serein's computer › Memory (`ComputerPolicy.memoryKey`, the computers on Docker)
  /// and the built-in computer's Memory (`VirtualMachinePolicy.memoryKey`). Raising a cap above
  /// `current`, its value now, asks on the Widening card first; lowering it applies at once.
  func setMemory(_ next: Int, key: String, current: Int, which: String) async {
    if let card = ComputerPolicy.memoryCard(from: current, to: next, which: which) {
      do {
        try await askPerson(
          .widening, card.title, card.detail, button: "Allow", declined: "You kept the memory as it was.",
          refused: "Giving Serein's computer more memory needs the person's answer on a card, and nobody is here to give it.",
          task: nil)
      } catch {
        notice = error.localizedDescription
        return
      }
    }
    GateSettings.shared.set(next, forKey: key)
  }
  /// The Widening card (ApprovalGate `widening`, person-only) for a change that lets a computer
  /// reach more; true when the change may apply: it narrows, or the person allowed it.
  private func allowWidening(
    _ list: ComputerAllowlist, _ edit: ComputerAllowlist.Edit, computer: Computer, provider: String?, limit: Int
  ) async -> Bool {
    guard list.applying(edit, limit: limit) != nil else {
      if case .add(let raw) = edit { notice = list.addProblem(raw, limit: limit) }
      return false
    }
    guard let card = list.card(edit, assistant: assistantName(computer.id), provider: provider, limit: limit) else { return true }
    do {
      try await askPerson(
        .widening, card.title, card.detail, button: "Allow", declined: "You kept the list as it was.",
        refused: "Letting Serein's computer reach more needs the person's answer on a card, and nobody is here to give it.",
        task: nil)
      return true
    } catch {
      notice = error.localizedDescription
      return false
    }
  }
  /// Moves an assistant's computer to another place. The current computer is deleted first
  /// (Settings confirms with what is lost); nothing moves across, and a delete the old place did
  /// not confirm keeps the computer where it is. Leaving the person's own machine also forgets it:
  /// its record and the host key Serein kept for it. True once it moved.
  @discardableResult
  func setPlace(_ place: ComputerPlace, for computer: Computer) async -> Bool {
    guard place != .unavailable else { notice = ComputerPlace.unavailableReason; return false }
    guard place != computer.place else { return true }
    guard !computer.resetting else { notice = "Wait for the checkpoint or reset to finish before moving the computer."; return false }
    if place == .macOS, computer.place == .builtIn { return await useVirtualMac(computer) }
    guard computer.holder == nil, !computer.busy, computer.queue.isEmpty else {
      notice = "\(assistantName(computer.id))'s computer is in use. Move it once its tasks are done."
      return false
    }
    // A computer on Docker is deleted there before it moves, so Docker must be running.
    if computer.place == .docker {
      await refreshBackend()
      guard engine != nil else {
        notice = "Start Docker first, so Serein can delete \(assistantName(computer.id))'s computer there before it moves."
        return false
      }
    }
    let leaving = computer.place
    if leaving == .unavailable {
      dropLocal(computer)
    } else if !(await delete(computer)) { return false }
    if leaving.isOwn { forgetOwnRecord(computer) }
    moved(computer, to: place)
    return true
  }
  /// Changing from the old Linux desktop keeps its disk; a virtual Mac has separate storage.
  @discardableResult func useVirtualMac(_ computer: Computer) async -> Bool {
    guard computer.place == .builtIn, computer.holder == nil, !computer.busy, computer.queue.isEmpty else {
      notice = "Finish the current computer task before switching to macOS."
      return false
    }
    let starting = computer.starting
    starting?.cancel()
    do { try await computer.machine?.pause() }
    catch { notice = error.localizedDescription; return false }
    _ = try? await starting?.value
    closeLinks(computer)
    computer.poller?.cancel(); computer.poller = nil
    computer.screen = nil; computer.setupLine = nil; computer.hasCheckpoint = false
    computer.state = .none
    moved(computer, to: .macOS)
    computer.mode = .keep
    notice = nil
    return true
  }

  /// A real restart of Serein's Mac (no saved memory), for a guest whose helper stopped
  /// answering: the helper starts again when that Mac boots. Its disk and files are kept.
  func restartMac(_ computer: Computer) async {
    guard computer.place == .macOS, computer.holder == nil, !computer.busy, computer.starting == nil else { return }
    do {
      try await (computer.machine as? MacVirtualComputer)?.restart(force: true)
      computer.state = .stopped
      computer.screen = nil
      await resume(computer)
    } catch { notice = "Serein's Mac could not restart: " + AgentPrivacy.redact(error.localizedDescription) }
  }
  /// Setup finished on one of its offline boots while the network is on: one clean restart gives
  /// the first session its network. If it can't run, the Mac is ready offline, online from its next start.
  private func bootOnline(_ computer: Computer) async {
    guard computer.place == .macOS, let mac = computer.machine as? MacVirtualComputer, mac.wantsOnlineBoot else { return }
    guard computer.holder == nil, !computer.busy, computer.starting == nil else { mac.readyOffline(); return }
    do { try await mac.restart() } catch { mac.readyOffline(); return }
    computer.state = .stopped
    computer.screen = nil
    await resume(computer)
  }
  /// A chat that read the person's private things may use this computer: their own machine
  /// (every act asks), or Serein's own Mac (part of Serein).
  func takesPrivateChats(_ computer: Computer) -> Bool {
    computer.place == .ownMachine
      || (computer.place == .macOS && MacComputerPolicy.takesPrivateChats(internet: computer.macInternet))
  }
  private func heldPrivate(_ computer: Computer) -> Bool {
    GateSettings.shared.dictionary(forKey: MacComputerPolicy.heldPrivateKey)?[computer.id] as? Bool == true
  }
  private func markHeldPrivate(_ computer: Computer) {
    guard !heldPrivate(computer) else { return }
    var values = GateSettings.shared.dictionary(forKey: MacComputerPolicy.heldPrivateKey) ?? [:]
    values[computer.id] = true
    _ = GateSettings.shared.update(values, forKey: MacComputerPolicy.heldPrivateKey)
  }
  func setMacInternet(_ on: Bool, for computer: Computer) async {
    guard computer.place == .macOS, computer.macInternet != on,
      computer.holder == nil, !computer.busy, computer.starting == nil else { return }
    do {
      if on {
        try await askPerson(
          .widening, "Allow the virtual Mac to use the network?",
          "The virtual Mac restarts with Apple's normal networking. It can reach the internet, this Mac and the local network. Serein cannot enforce site lists on this connection. Your files and clipboard stay separate."
            + (heldPrivate(computer) ? MacComputerPolicy.heldPrivateWarning : ""),
          button: "Allow Network", declined: "The virtual Mac stays offline.", task: nil)
      }
      try await computer.machine?.restart()
      var values = GateSettings.shared.dictionary(forKey: MacComputerPolicy.internetKey) ?? [:]
      values[computer.id] = on
      guard GateSettings.shared.update(values, forKey: MacComputerPolicy.internetKey) else {
        throw SereinError.invalid("The virtual Mac's network choice could not be saved.")
      }
      computer.macInternet = on
      computer.state = .stopped
      await resume(computer)
    } catch { notice = error.localizedDescription }
  }
  /// The record and the host key Serein kept for the person's own machine.
  private func forgetOwnRecord(_ computer: Computer) {
    try? ownLink(computer)?.store(nil)
    updateOwn(computer.id) { $0 = nil }
    computer.keyChanged = false
    computer.removeFailed = false
  }
  private func moved(_ computer: Computer, to place: ComputerPlace) {
    // The switch was given for the machine left behind: the next one starts without pictures.
    if computer.keepsStepPictures { setKeepsStepPictures(false, for: computer) }
    // So was the shared folder, which the new place may not even mount.
    forgetSharedFolder(computer)
    // So is an open provider internet: the next place starts held to its list (only narrows).
    if !computer.hosted.listOnly { updateHosted(computer.id) { $0.listOnly = true } }
    computer.place = place
    computer.placeKept = true
    computer.machine = nil
    if place == .macOS { computer.mode = .keep; computer.hasCheckpoint = false }
    updateSaved { saved in
      var all = saved.places ?? [:]
      all[computer.id] = place
      saved.places = all
    }
  }
  /// Forget Without Removing, after a Remove the machine did not confirm (it is gone for good, or
  /// will not connect): Serein drops its record, the host key and what it keeps on this Mac, and
  /// the computer goes back to its default place (`homePlace`). What Serein put on the machine may
  /// stay there (Settings names it, `lossList`).
  func forgetOwn(_ computer: Computer) {
    guard computer.place.isOwn else { return }
    guard computer.holder == nil, !computer.busy, computer.queue.isEmpty else {
      notice = "\(assistantName(computer.id))'s computer is in use. Forget it once its tasks are done."
      return
    }
    computer.poller?.cancel()
    computer.poller = nil
    closeLinks(computer)
    dropLocal(computer)
    forgetOwnRecord(computer)
    moved(computer, to: homePlace(computer))
  }
  /// Where a computer goes when the person's own machine is removed or forgotten: Docker when it
  /// is installed, else the built-in computer (33b's default). This computer's own folder is not
  /// counted: a checkpoint there belongs to the own computer, not to Docker.
  func homePlace(_ computer: Computer) -> ComputerPlace {
    ComputerPlace.defaultPlace(dockerFound: DockerSocket.installed(), builtInExists: false)
  }
  /// Connect your own…: the assistant's computer moves to the person's machine (its current one
  /// is deleted first, as any move), and the first start runs at once, so the host key card (and,
  /// for the machine as it is, the helper's install card) show while the person is here.
  func connectOwn(_ computer: Computer, as place: ComputerPlace, to target: SSHTarget) async {
    guard place.isOwn, !computer.place.isOwn else { return }
    guard await setPlace(place, for: computer) else { return }
    updateOwn(computer.id) { $0 = OwnSettings(target: target) }
    notice = "Connecting to \(target.text)…"
    await resume(computer)
    if computer.state == .running { notice = "\(assistantName(computer.id))'s computer is connected to \(target.text)." }
  }
  /// A copy of Serein's recipe (Dockerfile, helper, start script, and Cua Driver for x86_64 when
  /// this copy ships it) in the Library, for E2B's own tool to build the template from, or the
  /// image a Daytona snapshot is made from: those tools write beside the recipe, and the signed
  /// app's own folder must never be written. Older copies are replaced.
  func recipeFolder() -> URL? {
    guard let root else { return nil }
    let folder = root.appendingPathComponent("template", isDirectory: true)
    let fm = FileManager.default
    do {
      // shortcut: E2B and Daytona run x86_64 only, so the recipe carries that driver; add the
      // template's arch here if either offers arm64.
      let files = try Self.recipeFiles() + Self.boxDriverFiles(.amd64)
      try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
      for (name, data, _) in files {
        let target = folder.appendingPathComponent(name)
        try? fm.removeItem(at: target)
        try data.write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      }
      return folder
    } catch {
      notice = "The recipe could not be copied: " + error.localizedDescription
      return nil
    }
  }
  private func macFolder(_ computer: Computer) -> URL? {
    MacRestoreImage.shared.root.flatMap { MacComputerPolicy.directory(root: $0, assistantID: computer.id) }
  }
  /// The computer's backend for where it runs, made once; Docker's needs an engine.
  func machine(for computer: Computer) -> ComputerBackend? {
    guard computer.place != .unavailable else { return nil }
    if let known = computer.machine { return known }
    let made: ComputerBackend
    switch computer.place {
    case .macOS:
      guard let folder = macFolder(computer) else { return nil }
      made = MacVirtualComputer(
        folder: folder, internet: { [weak computer] in computer?.macInternet == true },
        progress: { [weak computer] line in computer?.setupLine = line },
        stopped: { [weak computer] in computer?.state = .stopped },
        admission: { [weak self, weak computer] in
          guard let self, let computer, ComputerPolicy.isEnabled(), computer.control == .assistant,
            computer.place == .macOS,
            let id = computer.holder, let browser = self.browser, let context = browser.tasks[id], !context.finished,
            browser.taskAssistant(id)?.open == true, browser.assistantRefusal(.computer, taskID: id) == nil,
            !browser.readPersonal(task: id) || self.takesPrivateChats(computer)
          else { return nil }
          return context.capability.token
        },
        personAllowed: { [weak computer] in
          guard let computer else { return false }
          return ComputerPolicy.isEnabled() && computer.control == .person && computer.state == .running
        },
        personActed: { [weak self, weak computer] step in
          if let computer { self?.personActed(computer, step: step) }
        },
        setupChanged: { [weak self, weak computer] phase in
          guard let computer else { return }
          computer.macSetup = phase
          // Serein owns account creation and keeps its setup display at full resolution.
          // Guest approvals get the live Mac; tasks wait for the verified connection.
          computer.control = phase.needsPerson ? .person : .assistant
          if phase == .ready { ComputerWindow.closeInitialSetup(computer, showComputer: true) }
          if let mac = computer.machine as? MacVirtualComputer, mac.wantsOnlineBoot {
            Task { @MainActor [weak self] in await self?.bootOnline(computer) }
          }
          // Saved memory with a dead helper, or a helper too old to take this build's update:
          // waiting cannot help, so Serein restarts it once.
          if case .needsPerson = phase, let mac = computer.machine as? MacVirtualComputer,
            (mac.guestSilent && mac.restoredFromSave) || mac.guestOutdated, !mac.restartedForSilence
          {
            mac.restartedForSilence = true
            self?.notice = mac.guestOutdated ? "Restarting Serein’s Mac to finish updating it. Its files are kept."
              : "Restarting Serein’s Mac so it can reconnect. Its files are kept."
            Task { @MainActor [weak self] in await self?.restartMac(computer) }
          }
        })
    case .docker:
      guard engine != nil else { return nil }
      made = DockerComputer(
        assistantID: computer.id, engine: { [weak self] in self?.engine },
        shared: { [weak self, weak computer] in computer.flatMap { self?.sharedPath($0) } },
        driverArch: { [weak self] in self?.imageDriverArch })
    case .builtIn:
      guard let root else { return nil }
      made = VirtualMachineComputer(
        folder: root.appendingPathComponent(computer.id, isDirectory: true), image: { BuiltInImage.shared.base },
        setupRules: setupRules(for: computer), progress: { [weak computer] line in computer?.setupLine = line },
        shared: { [weak self, weak computer] in
          computer.flatMap { self?.sharedPath($0) }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        })
    case .e2b:
      let id = computer.id
      made = E2BComputer(
        sandboxID: computer.hosted.sandboxID, previousID: computer.hosted.checkpointSourceID, createAttempt: computer.hosted.e2bCreateAttempt, spent: computer.hosted.spent, account: .shared,
        saveIDs: { [weak self] current, previous, attempt in
          guard let self, let computer = self.computers[id], let library = self.browser?.library else {
            throw SereinError.invalid("The E2B computer's identity could not be saved.")
          }
          let path = Self.folder + "/state.json"
          let existing = library.load(Saved.self, from: path)
          guard existing != nil || !FileManager.default.fileExists(atPath: library.root.appendingPathComponent(path).path) else {
            throw SereinError.invalid("Serein could not read the saved computer settings.")
          }
          var saved = existing ?? Saved(modes: [:])
          var hosted = computer.hosted
          hosted.sandboxID = current
          hosted.checkpointSourceID = previous
          hosted.e2bCreateAttempt = attempt
          var all = saved.hosted ?? [:]
          all[id] = hosted
          saved.hosted = all
          try library.save(saved, to: path)
          computer.hosted = hosted
        },
        saveSpent: { [weak self] spent in self?.updateHosted(id) { $0.spent = spent } })
    case .unavailable: return nil
    case .ownDesktop, .ownMachine:
      guard let own = computer.own, let link = ownLink(computer) else { return nil }
      if computer.place == .ownMachine {
        made = OwnMachineComputer(
          link: link, helper: { Bundle.assets.url(forResource: "serein-helper", withExtension: "py", subdirectory: "Computer") },
          note: { [weak self] line in self?.notice = line })
      } else {
        let target = own.target.text
        guard let desktop = OwnDesktopComputer(
          assistantID: computer.id, link: link,
          context: { try Self.buildContext(nil) },
          progress: { line in
            // The machine's own build output: shown as plain text, without control characters.
            let shown = String(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(200).map(Character.init))
            guard !shown.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            Task { @MainActor in ComputerHost.shared.notice = "On \(target): " + AgentPrivacy.redact(shown) }
          },
          caps: { [weak computer] memoryMB, cpus in
            computer?.capsLine = OwnDesktop.capsLine(memoryMB: memoryMB, cpus: cpus, target: target)
          })
        else { return nil }
        made = desktop
      }
    case .daytona:
      let id = computer.id
      made = DaytonaComputer(
        sandboxID: computer.hosted.sandboxID, spent: computer.hosted.spent, account: .shared,
        saveID: { [weak self] sandbox in self?.updateHosted(id) { $0.sandboxID = sandbox } },
        saveSpent: { [weak self] spent in self?.updateHosted(id) { $0.spent = spent } })
    }
    computer.machine = made
    return made
  }
  func assistantName(_ id: String) -> String { RelayOrchestrator.shared?.profileName(id) ?? "An assistant" }
  /// How Serein reaches the person's own machine for this computer, with Serein's known_hosts
  /// file in the Library (`computers/ssh`, 0700).
  private func ownLink(_ computer: Computer) -> SSHLink? {
    guard let own = computer.own, let root else { return nil }
    return SSHLink(target: own.target, assistantID: computer.id, folder: root.appendingPathComponent("ssh", isDirectory: true))
  }
  /// The host key the person trusted for this computer's machine, for Settings.
  func trustedKey(_ computer: Computer) -> SSHHostKey? { ownLink(computer)?.storedKey }

  /// Starts the computer if it is not running, then its helper and proxy links. Throws in
  /// plain words when its place is not set up (no engine or image, no provider key). One start-up at a
  /// time per computer: a second caller (a tool call, Resume, Reset, a drop) waits for the first.
  /// `task` is the task that asked, for a hosted computer's first-use card.
  func ensureRunning(_ computer: Computer, task: String? = nil) async throws {
    if computer.place == .unavailable { throw SereinError.invalid(ComputerPlace.unavailableReason) }
    if let starting = computer.starting {
      try await starting.value
      return
    }
    let start = Task { try await self.startUp(computer, task: task) }
    computer.starting = start
    defer { computer.starting = nil }
    try await start.value
  }
  /// The built-in computer isn't set up and something asked for it: on a new install the first
  /// need starts the download (BuiltInSetup). Only an assistant's own task counts as a need; a
  /// start with no task (Resume, a drop) never begins a download by itself. Returns what to say.
  private func setUpBuiltIn(task: String?) -> String {
    let image = BuiltInImage.shared
    let network = NetworkMonitor.shared
    let decision = BuiltInSetup.decide(
      setsItselfUp: ComputerPolicy.setsItselfUp(), working: image.working, share: image.fraction,
      unattended: task.map { browser?.isUnattended(task: $0) ?? true } ?? true, failed: image.automaticFailed,
      online: network.online, metered: network.metered, freeBytes: image.freeBytes)
    switch decision {
    case .answer(let words): return words
    case .start:
      image.setUp(automatic: true)
      return BuiltInSetup.downloading(share: nil)
    }
  }
  private func startUp(_ computer: Computer, task: String?) async throws {
    let machine: ComputerBackend
    switch computer.place {
    case .macOS:
      guard let mac = self.machine(for: computer) as? MacVirtualComputer else {
        throw SereinError.invalid("Set up the virtual Mac from the computer panel first.")
      }
      guard task == nil || mac.isInstalled else {
        throw SereinError.invalid("The virtual Mac needs its one-time setup. Open the computer panel and choose Set up macOS.")
      }
      if !mac.isRunning { computer.state = .starting }
      do {
        _ = try await mac.start()
        computer.lastUsed = Date()
        computer.state = .running
        rememberPlace(computer)
        return
      } catch {
        computer.state = .error(error.localizedDescription)
        throw error
      }
    case .docker:
      // Docker may have started after Serein, or the image been built since the last look.
      if engine == nil || backendProblem != nil || !imageBuilt { await refreshBackend() }
      guard engine != nil else { throw SereinError.invalid(ComputerPolicy.noBackend) }
      if let problem = backendProblem { throw SereinError.invalid("The container engine is not answering: " + problem) }
      guard imageBuilt else { throw SereinError.invalid(ComputerPolicy.noImage) }
      guard let docker = self.machine(for: computer) else { throw SereinError.invalid(ComputerPolicy.noBackend) }
      machine = docker
    case .builtIn:
      guard VirtualMachineComputer.supported else { throw SereinError.invalid(VirtualMachinePolicy.unsupported) }
      guard ready(computer) else { throw SereinError.invalid(setUpBuiltIn(task: task)) }
      guard let builtIn = self.machine(for: computer) else { throw SereinError.invalid(VirtualMachinePolicy.notSetUp) }
      // Set up by a Serein without the boot step that installs the pinned helper: no start can fix
      // it, so it is refused before it starts, and a saved pause stays as it was.
      if let whole = builtIn as? VirtualMachineComputer, whole.isSetUp, !whole.hasBootStep {
        throw SereinError.invalid(ComputerPins.olderBuiltIn)
      }
      machine = builtIn
    case .ownDesktop, .ownMachine:
      guard let own = self.machine(for: computer) as? OwnBackend, let settings = computer.own else {
        throw SereinError.invalid(
          "\(assistantName(computer.id))'s computer is set to run on the user's own machine, but none is connected. The user connects one in Settings › Serein's computer.")
      }
      // Nothing runs there before the person trusted its host key, and, as it is, its helper.
      // A changed key blocks this host only: the task carries on with other hosts (R21).
      if computer.keyChanged { throw Boundary.hostKey(host: own.link.name).blocked! }
      try await trustHostKey(computer, own.link, task: task)
      if computer.place == .ownMachine { try await consentInstall(computer, target: settings.target.text, task: task) }
      machine = own
    case .unavailable: throw SereinError.invalid(ComputerPlace.unavailableReason)
    case .e2b, .daytona:
      guard ready(computer), let hosted = self.machine(for: computer) as? HostedComputer else {
        throw SereinError.invalid(HostedCard.noKey(computer.place.label))
      }
      switch HostedNetwork.decide(
        hosted.capabilities, providerInternet: computer.hosted.providerInternet, allowlist: computer.hosted.allowlist,
        listOnly: computer.hosted.listOnly)
      {
      case .refuse(let reason): throw SereinError.invalid(reason)
      case .use(let network): hosted.network = network
      }
      // The provider's own state decides whether this start creates or wakes it, so the schedule
      // rule is checked there too, not only against what Serein last saw.
      let unattended = task.map { browser?.isUnattended(task: $0) ?? true } ?? false
      hosted.mayWake = !unattended || computer.hosted.fromSchedules
      if computer.state != .running { try await consent(computer, network: hosted.network, task: task) }
      machine = hosted
    }
    // A computer whose pins failed in a way only the person can fix (Reset after a new template or
    // snapshot) is not woken again to fail again.
    if let refused = computer.pinsRefused { throw SereinError.invalid(refused) }
    // Every call comes through here; a computer already running was checked when it started.
    let wasRunning = computer.state == .running
    if computer.state != .running && computer.state != .paused { computer.state = .starting }
    do {
      let fresh = try await machine.start()
      // Owed from the moment a new computer exists, so no path that fails after this (the pins,
      // the links, the probe) leaves it to be used later with an empty home in place of the checkpoint.
      if fresh && machine.capabilities.resetMakesNew { computer.restoreOwed = true }
      // What Serein copied in is the build it pins, or nothing of the assistant's runs there.
      if !wasRunning { try await checkPins(machine, computer, fresh: fresh) }
      if try await ensureLinks(machine, computer) { try await proveSealed(machine, computer, fresh: fresh) }
      // A hosted computer made new (first use, or after a reset) starts from the checkpoint.
      let e2b = machine as? E2BComputer
      if (fresh || computer.restoreOwed || e2b?.previousID != nil) && machine.capabilities.resetMakesNew {
        computer.restoreOwed = true
        do {
          try await restoreCheckpoint(machine, computer)
        } catch {
          // Keep a failed E2B replacement paused for another attempt with the same ID.
          closeLinks(computer)
          if let e2b, e2b.previousID != nil || e2b.createAttempt != nil { try? await e2b.pause() } else { try? await machine.restart() }
          throw error
        }
        try await e2b?.finishReplacement()
        computer.restoreOwed = false
      }
      computer.state = .running
      computer.setupLine = nil
      rememberPlace(computer)
      computer.keyChanged = false
      // Jobs from before a pause or a relaunch are looked at again now that the computer runs.
      watchJobs(computer)
    } catch {
      computer.setupLine = nil
      if (error as? OwnLinkError)?.failure == .keyChanged { computer.keyChanged = true }
      computer.state = .error(error.localizedDescription)
      throw SereinError.invalid("Serein's computer could not start: " + error.localizedDescription)
    }
  }
  /// A place chosen by default is kept once a computer started there, so finding Docker later
  /// never moves it.
  private func rememberPlace(_ computer: Computer) {
    guard !computer.placeKept else { return }
    computer.placeKept = true
    let place = computer.place
    updateSaved { saved in
      var all = saved.places ?? [:]
      all[computer.id] = place
      saved.places = all
    }
  }

  /// The pinned runtime (ComputerPins): every start reads the SHA-256 of each file Serein copied in
  /// (the helper, and the start script where the recipe's image has one) with the computer's own
  /// python3 and refuses the start when one is not this build's. The built-in computer restored
  /// from a saved pause runs the helper of its last boot, so it gets one fresh boot first: its boot
  /// installs the helper from the seed disk Serein writes before each start (one set up before that
  /// boot step is refused in `startUp` before it starts).
  private func checkPins(_ machine: ComputerBackend, _ computer: Computer, fresh: Bool) async throws {
    guard var refusal = try await pinRefusal(machine, computer) else { return }
    if computer.place == .builtIn {
      closeLinks(computer)
      endJobs(computer, .reset)
      try await machine.restart()
      _ = try await machine.start()
      guard let again = try await pinRefusal(machine, computer) else { return }
      refusal = again
      computer.pinsRefused = again
    }
    // Nothing runs there unchecked: the computer goes off. A hosted one made in this start is
    // deleted (its restore is already owed); an older one pauses, since a reset there would delete
    // it, and stays refused until the person resets it from a new template or snapshot.
    closeLinks(computer)
    if fresh || !machine.capabilities.resetMakesNew {
      try? await machine.restart()
    } else {
      try? await machine.pause()
      computer.pinsRefused = refusal
    }
    throw SereinError.invalid(refusal)
  }
  private func pinRefusal(_ machine: ComputerBackend, _ computer: Computer) async throws -> String? {
    computer.carriesDriver = false
    let place = computer.place, files = Self.pinnedFiles(machine, place)
    final class Listing: @unchecked Sendable {
      let lock = NSLock()
      var data = Data()
    }
    let listing = Listing()
    _ = try await machine.runOnce(ComputerPins.checkCommand(ComputerPins.checked(files, place: place)), input: nil) { piece in
      listing.lock.lock()
      if listing.data.count < 8_192 { listing.data.append(piece) }
      listing.lock.unlock()
    }
    listing.lock.lock(); defer { listing.lock.unlock() }
    let text = String(decoding: listing.data, as: UTF8.self)
    computer.carriesDriver = ComputerPins.carriesDriver(listing: text)
    return ComputerPins.refusal(listing: text, files: files, place: place)
  }

  /// The first connection to the person's own machine: its host key is fetched without signing in
  /// (SSHLink.scan) and its fingerprint shown on a person-only card (`hostKey`: never Autopilot,
  /// refused when nobody is there). Only Trust writes it to Serein's known_hosts file; from then on
  /// ssh refuses any other key, and nothing replaces the stored one without the same card.
  private func trustHostKey(_ computer: Computer, _ link: SSHLink, task: String?) async throws {
    // This Mac is never the person's own machine, also for a key trusted before this check.
    let thisMac = ThisMacHostKeys.keys()
    if let stored = link.storedKey, thisMac.contains(stored) { throw SereinError.invalid(ThisMacHostKeys.refusal) }
    guard link.storedKey == nil else { return }
    let key = try await link.scan()
    if thisMac.contains(key) { throw SereinError.invalid(ThisMacHostKeys.refusal) }
    try await askPerson(
      .hostKey, OwnCard.hostKeyTitle(target: link.name), OwnCard.hostKeyDetail(target: link.name, key: key, was: nil),
      button: "Trust", declined: OwnCard.declinedKey, task: task)
    try link.store(key)
    computer.keyChanged = false
  }
  /// Settings' Check the New Key: the key the machine shows now, against the one the person
  /// trusted; a different one goes on the same card with both fingerprints, and only Trust
  /// replaces it.
  func checkNewKey(_ computer: Computer) async {
    guard let own = machine(for: computer) as? OwnBackend else { return }
    let link = own.link
    do {
      let key = try await link.scan()
      if ThisMacHostKeys.keys().contains(key) { throw SereinError.invalid(ThisMacHostKeys.refusal) }
      let check = SSHHostKeys.compare(stored: link.storedKey.map { [$0] } ?? [], offered: key)
      guard check != .same else {
        computer.keyChanged = false
        notice = "\(link.name) shows the host key you trusted."
        return
      }
      var was: String?
      if case .changed(let old) = check { was = old }
      try await askPerson(
        .hostKey, OwnCard.hostKeyTitle(target: link.name), OwnCard.hostKeyDetail(target: link.name, key: key, was: was),
        button: "Trust", declined: OwnCard.declinedKey, task: nil)
      try link.store(key)
      computer.keyChanged = false
      notice = "Serein trusts \(link.name)'s host key \(key.fingerprint)."
    } catch {
      notice = AgentPrivacy.redact(error.localizedDescription)
    }
  }
  /// The helper's install card for the person's own machine as it is: every file and its path
  /// (OwnHelperManifest), once per wording. `ownInstall` is person-only: it asks, except in a task
  /// at Proactive.
  private func consentInstall(_ computer: Computer, target: String, task: String?) async throws {
    let detail = OwnHelperManifest.cardDetail(target: target)
    guard computer.own?.acceptedInstall != detail else { return }
    let asked = try await askPerson(
      .ownInstall, OwnHelperManifest.cardTitle(target: target), detail, button: "Install", declined: OwnCard.declinedInstall,
      task: task)
    if asked { updateOwn(computer.id) { $0?.acceptedInstall = detail } }
  }
  /// One person-only card (ApprovalDoor.answer, then confirmAnswer): in the task's thread, or
  /// Serein's chat when the person started it from Settings. Throws unless the answer is yes; with
  /// `refused` when the gate refuses (nobody is there). False when a task at Proactive runs it
  /// with no card: then nobody said yes, so nothing records the card as accepted.
  @discardableResult
  private func askPerson(
    _ effect: ApprovalGate.Effect, _ title: String, _ detail: String, button: String, declined: String,
    refused: String = OwnCard.needsPerson, task: String?
  ) async throws -> Bool {
    let relay = task.flatMap { id in browser?.relayTask(id, browser?.tasks[id]) } ?? RelayOrchestrator.shared
    let unattended = task.map { browser?.isUnattended(task: $0) ?? true } ?? false
    let today = RelayOrchestrator.standing(relay, present: !unattended)
    let standing = task.flatMap { id in browser?.standing(task: id, else: today) } ?? today
    let decision = try ApprovalDoor.answer(
      .init(.effect(effect), standing, taskID: task),
      facts: .init(
        secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
        runsAnything: false, ref: "")
    ).decision()
    if decision == .auto { return false }
    guard let relay else { throw SereinError.invalid(refused) }
    let thread = task.flatMap { browser?.threadID(forTask: $0) } ?? relay.threadID
    let human = await relay.confirmAnswer(title, detail, button: button, thread: thread, effect: effect)
    guard human == .yes else { throw SereinError.invalid(human == .no ? declined : ActionAdmission.needsPerson) }
    return true
  }

  /// The first-use card of a hosted computer: once per assistant and per card wording (a new
  /// internet setting asks again). `hostedStart` follows the level: no card at Allow all and
  /// Auto, a card at Manual, deferred when nobody is there.
  private func consent(_ computer: Computer, network: HostedNetwork, task: String?) async throws {
    let provider = computer.place.label
    let detail = HostedCard.detail(place: computer.place, network: network)
    guard computer.hosted.acceptedCard != detail else { return }
    let asked = try await askPerson(
      .hostedStart, HostedCard.title(assistant: assistantName(computer.id), provider: provider), detail, button: "Start",
      declined: HostedCard.declined(provider), refused: HostedCard.needsPerson(provider), task: task)
    if asked { updateHosted(computer.id) { $0.acceptedCard = detail } }
  }

  /// The helper and the proxy shim, each a command kept open as a stream. Waits until the
  /// desktop inside says it is ready. A computer on its own internet (a hosted one on its
  /// provider's, the person's own machine as it is) has no shim: nothing of its traffic comes
  /// through this Mac.
  /// True when it opened a new helper.
  @discardableResult
  private func ensureLinks(_ machine: ComputerBackend, _ computer: Computer) async throws -> Bool {
    let hosted = machine as? HostedComputer
    var opened = false
    if let hosted, computer.helper.isOpen, computer.linksNetwork != hosted.network { closeLinks(computer) }
    if !computer.helper.isOpen {
      let helper = HelperChannel()
      helper.onEnd = { [weak computer] in
        Task { @MainActor in
          guard let computer, computer.state == .running else { return }
          computer.state = .stopped
        }
      }
      helper.attach(try await machine.openStream(machine.helperCommand, stdin: true, onStdout: helper.sink, onEnd: helper.ender))
      computer.helper = helper
      computer.linksNetwork = hosted?.network
      // The desktop takes a few seconds on first start; the helper answers once X is up. A link
      // that ended, or a helper that says why it cannot see a desktop, fails at once.
      var ready = false
      for _ in 0..<60 where !ready {
        guard helper.isOpen else {
          let why = helper.stderrLines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "no reason was given"
          throw SereinError.invalid("The link to the computer's helper closed: " + AgentPrivacy.redact(String(why.prefix(200))))
        }
        if let answer = try? await helper.call("ping", timeout: 5) {
          if answer["ready"] as? Bool == true {
            ready = true
            continue
          }
          if let why = answer["why"] as? String { throw SereinError.invalid(AgentPrivacy.redact(String(why.prefix(400)))) }
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
      guard ready else { throw SereinError.invalid("The desktop inside did not come up in time.") }
      opened = true
    }
    let throughThisMac = hosted.map { $0.network.usesProxy } ?? machine.capabilities.carriesProxy
    if throughThisMac, computer.proxy?.isOpen != true {
      let mux = ProxyMux(rules: proxyRules(for: computer))
      mux.attach(try await machine.openStream(["python3", "-I", "/opt/serein/helper.py", "--proxy"], stdin: true, onStdout: mux.sink, onEnd: mux.ender))
      computer.proxy = mux
      try await proveProxyPort(computer)
    }
    _ = try? await shellLink(computer)  // the desktop's terminals get their shells through it
    return opened
  }

  /// A hosted computer whose provider says its own internet is off proves it from inside, each
  /// time its helper starts: a direct connection that gets through (or a probe that cannot run)
  /// deletes a new computer and pauses an older one, and it is not used. The probe runs inside the
  /// untrusted computer, so it is trusted only as a check on a computer whose block Serein did not
  /// just change (Daytona never moves one in place to through this Mac; a Reset makes a new one).
  /// A new Daytona computer held to a list proves the same way that sites off the list
  /// (`HostedNetwork.canaries`) are out of reach; only a new one, before the checkpoint restore
  /// and any agent code, since a process inside could forge the answer on an older one.
  private func proveSealed(_ machine: ComputerBackend, _ computer: Computer, fresh: Bool) async throws {
    guard let hosted = machine as? HostedComputer else { return }
    var args: [String: Any] = [:]
    switch hosted.network {
    case .throughThisMac: break
    case .provider(let allow):
      guard fresh, computer.place == .daytona else { return }
      args["hosts"] = HostedNetwork.canaries(off: allow)
    case .providerOpen: return
    }
    let probe = try? await computer.helper.call("direct", args, timeout: 30)
    // A helper that ignored the hosts it was given checked something else: as good as none.
    let checkedAll = (args["hosts"] as? [String]).map { probe?["checked"] as? Int == $0.count } ?? true
    guard probe?["open"] as? Bool == false, checkedAll else {
      closeLinks(computer)
      if fresh { try? await machine.restart() } else { try? await machine.pause() }
      let provider = computer.place.label
      throw SereinError.invalid(
        probe == nil || !checkedAll ? HostedCard.oldHelper(provider)
          : hosted.network == .throughThisMac ? HostedCard.notSealed(provider) : HostedCard.notHeld(provider))
    }
  }

  /// Ends the helper, proxy and driver streams; their end must not mark the computer stopped.
  func closeLinks(_ computer: Computer) {
    computer.helper.onEnd = nil
    computer.helper.close()
    computer.shell?.close()
    computer.proxy?.close()
    computer.helper = HelperChannel()
    (computer.shell, computer.proxy) = (nil, nil)
    computer.driverOpening?.cancel()
    computer.driverOpening = nil
    computer.driver?.close()
    computer.driver = nil
  }

  /// The proxy's rules for one computer: the person's site rules, the assistant's own Never sites
  /// and the computer's list of sites (Only these sites) before the lookup, and every host logged
  /// to the holding task's step timeline with the reason of any refusal.
  private func proxyRules(for computer: Computer) -> ComputerProxy.Rules {
    let assistantID = computer.id
    let facts = computer.facts
    return ComputerProxy.Rules(
      hostRefusal: { host, port in
        let known = facts.current
        return ComputerNetworkPolicy.hostRefusal(
          host, port: port, assistantNever: known.never, assistant: known.name, sites: known.sites)
      },
      log: { host, refusal in
        Task { @MainActor in ComputerHost.shared.logHost(host, refusal: refusal, computer: assistantID) }
      })
  }
  /// The proxy's rules while a built-in computer is set up: Debian's package archive only, then the same
  /// site rules and private-range refusals as ever, every host logged.
  private func setupRules(for computer: Computer) -> ComputerProxy.Rules {
    let assistantID = computer.id
    return ComputerProxy.Rules(
      hostRefusal: { host, port in
        VirtualMachinePolicy.setupRefusal(host, port: port) ?? ComputerNetworkPolicy.hostRefusal(host, port: port)
      },
      log: { host, refusal in
        Task { @MainActor in ComputerHost.shared.logHost(host, refusal: refusal, computer: assistantID) }
      })
  }
  private func logHost(_ raw: String, refusal: String?, computer id: String) {
    guard let computer = computers[id] else { return }
    // The name the computer sent, shown only when it is a plain host: a NUL or other odd
    // characters never reach the timeline or the panel.
    let name = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    let host = ComputerNetworkPolicy.plainHost(name) ? String(name.prefix(253)) : "a malformed address"
    computer.hosts = Array((computer.hosts + [HostLine(host: host, refusal: refusal)]).suffix(40))
    guard let task = computer.holder, let browser else { return }
    // Each host once per task; every refusal is written, so the person sees what was stopped.
    guard refusal != nil || computer.notedHosts.insert(host).inserted else { return }
    var step = AgentStep(tool: "computer_net", label: "Reached \(host) from Serein's computer")
    if let refusal {
      step.label = "Serein's computer tried \(host)"
      step.failed = refusal
    }
    browser.agentTabs.note(step, task: task)
  }

  /// Screen and input: Cua Driver where the computer carries it (DriverScreen), else the backend's
  /// own calls where it has them (Daytona's, NativeScreen), otherwise the helper's ops of the same
  /// names over its stream.
  /// `driver: false` keeps Cua Driver out (the live view's poller: its picture binds no click).
  func screenCall(_ computer: Computer, _ op: String, _ arguments: [String: Any] = [:], timeout: Int = 30, driver: Bool = true)
    async throws -> [String: Any]
  {
    if driver, let screen = try await driverScreen(computer) { return try await screen.screen(op, arguments) }
    // A picture of a computer that carries Cua Driver is only ever a masked one (DriverScreen.look).
    if driver, op == "screenshot", computer.carriesDriver, computer.machine?.driverCommand != nil { throw SereinError.invalid(Self.noPicture) }
    if let native = computer.machine as? NativeScreen { return try await native.screen(op, arguments) }
    return try await computer.helper.call(op, arguments, timeout: timeout)
  }
  /// The rule a screen picture from this computer meets (ScreenPicture.rule): Cua Driver's may
  /// be smaller than the screen.
  private func pictureRule(_ computer: Computer) -> ScreenPicture.Rule {
    ScreenPicture.rule(isolated: computer.place.capabilities.isolated, driver: computer.driver?.isOpen == true)
  }

  /// A hosted computer's cost as its provider reports it, for Settings (ReportsUsage).
  func refreshUsage(_ computer: Computer) async {
    guard computer.place.capabilities.paid, computer.hosted.sandboxID != nil else { return }
    await (machine(for: computer) as? ReportsUsage)?.refreshUsage()
  }

  // MARK: the tools

  /// A `computer_*` call from BrowserModel.perform: the switch, the task's assistant and its places, its
  /// turn (one call per computer at a time, helper paths too), then in that turn the one-task lease, who has
  /// control, StepGuard and the helper. No card for steps inside; the two that leave go through ApprovalGate below.
  func call(_ name: String, _ a: [String: Any], task id: String, browser: BrowserModel) async throws -> [String: Any] {
    guard ComputerPolicy.isEnabled() else { throw SereinError.invalid(ComputerPolicy.offMessage) }
    // The person's own tasks act for no assistant, and a hand-off whose record is gone fails closed.
    guard let found = browser.taskAssistant(id), found.open else { throw SereinError.invalid(ComputerPolicy.notAssistant) }
    guard hub?.runs.last(where: { $0.taskID == id })?.spec.speaksFirstElsewhere != true else {
      throw SereinError.invalid("An assistant speaking first answers in words only, so it cannot use Serein's computer.")
    }
    let profile = found.profile
    let computer = computer(for: profile.id)
    if computer.place == .macOS, !MacComputerPolicy.tools.contains(name) {
      throw SereinError.invalid(MacComputerPolicy.unsupportedTool)
    }
    // A chat that read the person's mail, messages, Mac apps or connected apps, and anything it
    // started or handed over, stays out of the computer: what it types or opens there can leave
    // through the proxy (BrowserModel.readPersonal, which fails closed). The person's own machine
    // as it is is the exception, as their Mac is: every act there asks.
    // Serein's own Mac is the other exception: it is part of Serein, by the person's choice
    // (MacComputerPolicy.takesPrivateChats). Its disk is marked when such a chat used it.
    let readPersonal = browser.readPersonal(task: id)
    guard !readPersonal || takesPrivateChats(computer) else {
      throw SereinError.invalid(Connections.personalReadComputerRefusal)
    }
    if readPersonal, computer.place == .macOS { markHeldPrivate(computer) }
    if let refusal = browser.assistantRefusal(.computer, taskID: id) { throw SereinError.invalid(refusal) }
    if computer.place == .macOS, computer.state == .running, computer.macSetup != .ready {
      throw SereinError.invalid(computer.macSetup.message ?? MacComputerPolicy.setupLine)
    }
    // The person's own machine as it is: Watch only unless they let this assistant act there,
    // and nothing but watching while nobody is here (OwnMachinePolicy).
    if computer.place == .ownMachine, let refusal = OwnMachinePolicy.refusal(
      tool: name, access: computer.own?.access ?? .watchOnly, unattended: browser.isUnattended(task: id), assistant: profile.name,
      machine: placeName(computer))
    {
      throw SereinError.invalid(refusal)
    }
    // A detached job runs on by itself after the turn: only in a computer of Serein's own, never
    // on the person's machine as it is (whose normalized arguments below would drop the flag).
    if name == "computer_run", let detach = a["detach"], (detach as? Bool) != false,
      let refusal = ComputerJobs.placeRefusal(computer.place, machine: placeName(computer))
    {
      throw SereinError.invalid(refusal)
    }
    // On the person's own machine the card and the helper read the same normalized arguments
    // (OwnCard.arguments), so the card names exactly the act performed.
    var args = a
    if computer.place == .ownMachine {
      guard let normalized = OwnCard.arguments(tool: name, a) else { throw SereinError.invalid(OwnCard.unshowable) }
      args = normalized
    }
    computer.facts.update(never: RelayOrchestrator.shared?.effectiveScope(profile)?.neverSites ?? [], name: profile.name)
    // A paid computer is never started by a run nobody started by hand, unless the person said so.
    if let refusal = HostedSpending.startRefusal(
      paid: computer.place.capabilities.paid, running: computer.state == .running, unattended: browser.isUnattended(task: id),
      allowedUnattended: computer.hosted.fromSchedules, provider: computer.place.label, assistant: profile.name)
    {
      throw SereinError.invalid(refusal)
    }
    while computer.busy { try await Task.sleep(nanoseconds: 50_000_000) }
    try lease(computer, task: id)
    guard computer.control == .assistant else { throw SereinError.invalid(ComputerPolicy.personHasControl) }
    if let refusal = computer.steps.refusal(tool: name, asking: computer.ask != nil) { throw SereinError.invalid(refusal) }
    // This step's entry in the timeline (BrowserModel.handle wrote it), for its picture.
    let pictureStep = StepPicturePolicy.takes(personalScreen: computer.place.showsPersonalScreen, keepForMachine: computer.keepsStepPictures)
      ? browser.agentTabs.runs[id]?.steps.last(where: { $0.tool == name })?.id : nil
    computer.busy = true
    defer {
      computer.busy = false
      if computer.control == .pending { grantControl(computer) }
      // A hand-on that waited for this step runs now.
      sweep()
    }
    try await ensureRunning(computer, task: id)
    computer.lastUsed = Date()
    if computer.place == .ownMachine {
      if let asked = try await allowOwnStep(name, args, task: id, computer: computer, browser: browser) { return asked }
      // What the person's own machine shows or holds is theirs: the chat is marked before it is
      // read, as a Mac app's window is (BrowserModel.notePersonalRead), so Serein's own computers
      // stay closed to it.
      if OwnMachinePolicy.readsMachine.contains(name), !browser.notePersonalRead(task: id) {
        throw SereinError.invalid(BrowserModel.personalMarkFailed)
      }
    }
    var result = try await perform(name, args, task: id, computer: computer, browser: browser, pictureStep: pictureStep)
    // The screenshot step kept its own picture. Any other step's is taken after it returned, and
    // only where the screen is on this Mac: elsewhere the next step would wait behind it.
    if let pictureStep, name != "computer_screenshot", computer.place == .docker || computer.place == .builtIn,
      !browser.secureCards.open.contains(where: { $0.box?.assistantID == computer.id }) {
      picture(after: computer, step: pictureStep, task: id)
    }
    computer.steps.ran(name, args, into: &result)
    return result
  }

  /// One task holds a computer; others wait in order and are told where they stand.
  private func lease(_ computer: Computer, task id: String) throws {
    guard computer.place != .unavailable else { throw SereinError.invalid(ComputerPlace.unavailableReason) }
    // Only Serein's chat may come back to the home it kept across turns: any other task waits for
    // the reset it owes, as a task in line would.
    if computer.mode == .throwaway, computer.place.capabilities.isolated, computer.holder == nil, let chat = computer.chatTask,
      chat != id
    {
      computer.chatTask = nil
      computer.resetOwed = true
    }
    if computer.resetting || computer.resetOwed {
      // An owed reset that is not running (just owed, or failed before) is tried again.
      if computer.resetOwed, !computer.resetting,
        computer.resetFailedAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true
      {
        Task { await self.settle(computer) }
      }
      if !computer.queue.contains(id) { computer.queue.append(id) }
      throw SereinError.invalid(
        "Serein's computer is in use: it is being reset after another task. Try again in a minute, or do something else first.")
    }
    if computer.holder == nil || computer.holder == id {
      if computer.holder != id {
        computer.notedHosts = []
        computer.steps = StepGuard()
        computer.ask = nil
        computer.driver?.forgetPicture()
      }
      computer.holder = id
      computer.queue.removeAll { $0 == id }
      return
    }
    if !computer.queue.contains(id) { computer.queue.append(id) }
    let place = (computer.queue.firstIndex(of: id) ?? 0) + 1
    throw SereinError.invalid(
      "Serein's computer is in use by another task (“\(taskTitle(computer.holder ?? ""))”). This task is \(place) in line; try again in a minute, or do something else first.")
  }
  func taskTitle(_ task: String) -> String {
    String((hub?.runs.last { $0.taskID == task }?.spec.title ?? "a task").prefix(60))
  }

  /// `pictureStep` is the step whose picture a screenshot keeps (StepPictures), nil for none.
  func perform(
    _ name: String, _ a: [String: Any], task id: String, computer: Computer, browser: BrowserModel, pictureStep: String?
  ) async throws -> [String: Any] {
    if let box = try await performBox(name, a, task: id, computer: computer, browser: browser) { return box }
    let helper = computer.helper
    func fenced(_ text: String) -> String { PageFence.fence(UntrustedText.escape(UntrustedText.capped(AgentPrivacy.redact(text)))) }
    switch name {
    case "computer_screenshot":
      let shot = try await screenCall(computer, "screenshot", timeout: 20)
      try refuseSecrets(shot, computer: computer)
      guard shot["tree"] == nil else { throw SereinError.invalid(DriverScreen.noPicture) }
      // Bytes from inside the computer reach the image decoders only as a PNG of its screen size.
      guard let base64 = shot["png"] as? String, let sourcePNG = Data(base64Encoded: base64),
        let size = Self.screenSize(sourcePNG, rule: pictureRule(computer))
      else {
        throw SereinError.invalid("The computer sent no picture.")
      }
      guard let png = computer.carriesDriver ? sourcePNG : await BoxPictureMask.screenedPNG(sourcePNG) else {
        throw SereinError.invalid(DriverScreen.shown)
      }
      if let image = NSImage(data: png) {
        computer.screen = image
        computer.screenWidth = size.width
        computer.screenHeight = size.height
      }
      if let pictureStep { StepPictures.shared.keep(png, step: pictureStep, task: id) }
      if let saved = browser.saveChatPicture(png) { browser.onTaskPicture?(id, saved) }
      if computer.steps.unchanged(png: png, now: Date()) { return ComputerTools.unchanged(since: computer.steps.sentAgo(Date())) }
      let picture = Self.transportPicture(png)
      return ["content": [
        ["type": "image", "mimeType": picture.kind, "data": picture.data.base64EncodedString()],
        ["type": "text", "text": "\(size.width)×\(size.height) pixels; computer_click and computer_scroll take x and y in these pixels."],
      ]]
    case "computer_click":
      // Fixed answers: nothing the helper writes reaches the model unfenced.
      _ = try await screenCall(computer, "click", ["x": a["x"] ?? 0, "y": a["y"] ?? 0, "button": a["button"] ?? "left", "double": a["double"] ?? false])
      return ["clicked": true]
    case "computer_type":
      // 12 ms a character: 8,000 characters stay inside the helper's 120-second limit.
      guard let text = a["text"] as? String, !text.isEmpty, text.count <= 8_000 else {
        throw SereinError.invalid("text is required, up to 8000 characters. Type longer text in parts.")
      }
      _ = try await screenCall(computer, "type", ["text": text], timeout: 150)
      return ["typed": text.count]
    case "computer_key":
      let key = a["key"] as? String ?? ""
      _ = try await screenCall(computer, "key", ["key": key])
      return ["pressed": key]
    case "computer_scroll":
      _ = try await screenCall(computer, "scroll", ["x": a["x"] ?? 0, "y": a["y"] ?? 0, "direction": a["direction"] ?? "down", "amount": a["amount"] ?? 3])
      return ["scrolled": true]
    case "computer_open_url":
      guard let raw = a["url"] as? String, let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
        ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty
      else { throw SereinError.invalid("url must be an https or http address.") }
      // Judged here as the proxy will judge it, so a refused site never even opens a tab.
      let known = computer.facts.current
      if let refusal = ComputerNetworkPolicy.hostRefusal(host, port: url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443),
                                                         assistantNever: known.never, assistant: known.name,
                                                         sites: sitesApply(computer) ? known.sites : ComputerAllowlist()) {
        throw SereinError.invalid(refusal)
      }
      if computer.place == .macOS {
        _ = try await screenCall(computer, "open_url", ["url": url.absoluteString])
      } else {
        _ = try await helper.call("open_url", ["url": url.absoluteString])
      }
      return ["opened": host]
    case "computer_run":
      guard let command = a["command"] as? String, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw SereinError.invalid("command is required.")
      }
      if let detach = a["detach"] {
        guard let flag = detach as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
          throw SereinError.invalid("detach is true or false.")
        }
        if flag.boolValue {
          if computer.place == .macOS { throw SereinError.invalid(MacGuestShell.detachRefusal) }
          return try await startJob(command, task: id, computer: computer, browser: browser)
        }
      }
      if computer.place == .macOS, let mac = computer.machine as? MacVirtualComputer {
        let answer = try await mac.shell("run", ["command": command, "timeout": String(MacGuestShell.timeout)],
          timeout: MacGuestShell.timeout + 10)
        let output: String = fenced(answer["output"] ?? "")
        let code: Int = answer["code"].flatMap { Int($0) } ?? -1
        let cut: Bool = answer["cut"] == "true"
        return ["output": output, "code": code, "cut": cut, "untrusted": true]
      }
      let answer = try await shellLink(computer).call("run", ["command": command], timeout: ComputerPolicy.commandTimeout + 10)
      return ["output": fenced(answer["output"] as? String ?? ""), "code": answer["code"] ?? -1, "cut": answer["cut"] ?? false, "untrusted": true]
    case "computer_tree":
      var args: [String: Any] = [:]
      if let window = a["window"] {
        // A window name the person could read: a short String with nothing a card cannot show.
        guard let name = window as? String, name.count <= 200, name.isEmpty || ComputerPolicy.clipboardShowable(name) else {
          throw SereinError.invalid("window must be a window's name, up to 200 characters.")
        }
        if !name.isEmpty { args["window"] = name }
      }
      if let depth = a["depth"] { args["depth"] = depth }
      let tree = try await screenCall(computer, "tree", args, timeout: 40)
      let windows = computer.carriesDriver ? tree : try await screenCall(computer, "windows")
      try refuseSecrets(tree, computer: computer)
      let windowRows = windows["windows"] as? [[String: Any]] ?? []
      let titles = windowRows.compactMap { $0["title"] as? String }
      let treeText = tree["tree"] as? String ?? ""
      var visibleText = titles
      if !computer.carriesDriver {
        // Native/helper trees include a trailing x,y width×height on each row. Those
        // coordinates are generated by the helper and are not part of the field label.
        visibleText += windowRows.compactMap { $0["id"] as? String }
        let labels = treeText.replacingOccurrences(
          of: #"(?m) -?\d+,-?\d+ -?\d+x-?\d+(?: \[focused\])?[ \t]*$"#, with: "", options: .regularExpression)
        visibleText += labels.components(separatedBy: .newlines)
      }
      let partial = !computer.carriesDriver && (args["window"] != nil || args["depth"] != nil || tree["privacy_complete"] as? Bool != true)
      let ambiguous = partial || (!visibleText.isEmpty && BoxPictureMask.showsText(visibleText))
      if ambiguous && FilledValues.shared.hasValues {
        throw SereinError.invalid("Private text may be visible in these windows. Use computer_ask_person to have the person hide it and then retry computer_tree.")
      }
      let windowList: Any
      if ambiguous {
        windowList = titles.map { ["title": AgentPrivacy.hidingDigits($0)] }
      } else {
        windowList = windows["windows"] ?? []
      }
      let botCheck = botCheckLead(tree, task: id, computer: computer, browser: browser)
      // Driver reads retain their synthetic element refs. Native text includes raw
      // coordinates and labels together, so suppress both on an ambiguous read.
      let display = ambiguous && !computer.carriesDriver ? AgentPrivacy.hidingDigits(treeText) : treeText
      return [
        "windows": fenced(jsonString(windowList)), "tree": botCheck + fenced(display),
        "cut": tree["cut"] ?? false, "untrusted": true,
      ]
    case "computer_read_file":
      guard let path = a["path"] as? String, !path.isEmpty else { throw SereinError.invalid("path is required.") }
      if computer.place == .macOS, let mac = computer.machine as? MacVirtualComputer {
        let start = max(0, (a["start"] as? NSNumber)?.intValue ?? 0)
        let answer = try await mac.shell("read_file", ["path": path, "start": String(start)], timeout: 30)
        let text: String = fenced(answer["text"] ?? "")
        var result: [String: Any] = ["text": text, "untrusted": true]
        if let next: Int = answer["next_start"].flatMap({ Int($0) }) { result["next_start"] = next }
        return result
      }
      let answer = try await shellLink(computer).call("read_file", ["path": path, "start": a["start"] ?? 0])
      var result: [String: Any] = ["text": fenced(answer["text"] as? String ?? ""), "untrusted": true]
      if let next = answer["next_start"] as? Int { result["next_start"] = next }
      return result
    case "computer_send_file":
      return try await sendFile(a, task: id, computer: computer, browser: browser)
    case "computer_send_text":
      return try await sendText(a, task: id, computer: computer, browser: browser)
    default:
      throw SereinError.invalid("Unknown computer tool")
    }
  }

  // MARK: detached jobs

  /// `computer_run` with `detach`: the command runs on inside the computer after this turn, in its
  /// own session with its output in a capped file there (the helper's `job_start`), and `watchJobs`
  /// reports its end in this task's chat. Only in a computer of Serein's own; at most
  /// `ComputerJobs.limit` at once.
  private func startJob(_ command: String, task id: String, computer: Computer, browser: BrowserModel) async throws
    -> [String: Any]
  {
    if let refusal = ComputerJobs.placeRefusal(computer.place, machine: placeName(computer)) { throw SereinError.invalid(refusal) }
    guard command.count <= 8_000 else { throw SereinError.invalid("command is at most 8000 characters.") }
    let paid = computer.place.capabilities.paid
    // A job keeps a paid computer billing: a run nobody started by hand starts none, unless the
    // person let that assistant's schedules use the computer.
    if paid, browser.isUnattended(task: id), !computer.hosted.fromSchedules {
      throw SereinError.invalid(
        "\(computer.place.label) bills while a detached job runs, so a run nobody started by hand does not start one.")
    }
    guard computer.jobs.filter(\.running).count < ComputerJobs.limit else {
      throw SereinError.invalid(
        "Serein's computer already runs \(ComputerJobs.limit) detached jobs. Wait for one to end, or ask the user to stop one in its Computer tab.")
    }
    // Its message goes to the chat that started it, never to another (a Main chat may be marked).
    guard let thread = browser.threadID(forTask: id) else { throw SereinError.invalid(ComputerPolicy.notAssistant) }
    let job = ComputerJob(id: UUID().uuidString.lowercased(), name: ComputerJobs.name(command), thread: thread, startedAt: Date())
    _ = try await shellLink(computer).call("job_start", ["job": job.id, "command": command])
    computer.jobs.append(job)
    saveJobs(computer)
    watchJobs(computer)
    MacAwake.shared.refresh()
    // Fixed words only: nothing the helper wrote reaches the model unfenced.
    let reset = computer.mode == .throwaway ? " This computer is Throwaway, so the job also ends when it is reset after this task." : ""
    let cost = paid
      ? " This computer runs on \(computer.place.label) and costs money while it runs; it pauses when idle and the job waits." : ""
    let hours: Int = Int(ComputerJobs.timeLimit / 3600)
    let note: String = "It keeps running after this turn, up to \(hours) hours. Serein posts one message in this chat when it ends; no turn starts by itself. Read its output so far with computer_read_file." + reset + cost
    return [
      "started": job.name, "output_file": ComputerJobs.logPath(job.id),
      "note": note,
    ]
  }
  /// While a job runs and the computer is on, its state is read every ten seconds; the watch ends
  /// when no job runs or the computer stops, and a start (`startUp`) or a new job begins it again.
  private func watchJobs(_ computer: Computer) {
    guard computer.jobWatch == nil, computer.jobs.contains(where: \.running) else { return }
    computer.jobWatch = Task { [weak self, weak computer] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        guard let self, let computer, computer.state == .running, computer.jobs.contains(where: \.running) else { break }
        await self.pollJobs(computer)
      }
      computer?.jobWatch = nil
    }
  }
  /// One look at the running jobs, only while the helper answers nothing else (it answers one
  /// request at a time) and no reset runs. What comes back is the computer's word: ComputerJobs.ended
  /// reads only its typed fields.
  private func pollJobs(_ computer: Computer) async {
    let running = computer.jobs.filter(\.running)
    guard !running.isEmpty, computer.helper.isOpen, computer.helper.idle, !computer.resetting else { return }
    guard let answer = try? await shellLink(computer).call("job_status", ["ids": running.map(\.id)], timeout: 15),
      let entries = answer["jobs"] as? [String: Any]
    else { return }
    for job in running {
      let entry = entries[job.id] as? [String: Any]
      guard let found = ComputerJobs.ended(entry, startedAt: job.startedAt, now: Date()) else { continue }
      // Still running past its time by the clock: it is stopped before it is reported, so nothing
      // keeps running untracked.
      if entry?["running"] as? Bool == true {
        _ = try? await shellLink(computer).call("job_stop", ["job": job.id], timeout: 15)
      }
      endJob(job.id, found.end, tail: found.tail, in: computer)
    }
  }
  /// A job ended: it is kept with how it ended and the end of its output, and its message goes out.
  private func endJob(_ id: String, _ end: ComputerJob.End, tail: String?, in computer: Computer) {
    guard let index = computer.jobs.firstIndex(where: { $0.id == id && $0.running }) else { return }
    computer.jobs[index].end = end
    computer.jobs[index].tail = tail.map { String($0.suffix(8_000)) }
    saveJobs(computer)
    deliverJobMessages()
    MacAwake.shared.refresh()
  }
  /// Detached jobs running in computers on this Mac (Docker and the built-in one), which idle
  /// sleep would suspend mid-job: Keep the Mac awake counts them (`MacAwake.refresh`).
  var localJobsRunning: Int {
    computers.values.filter { [.docker, .builtIn].contains($0.place) }.reduce(0) { $0 + $1.jobs.filter(\.running).count }
  }
  /// Every running job of a computer ends with it: a reset, a restart or Delete.
  private func endJobs(_ computer: Computer, _ end: ComputerJob.End) {
    for job in computer.jobs where job.running { endJob(job.id, end, tail: nil, in: computer) }
  }
  /// Stop job in the inspector's Computer tab: the person's own act, so no card. The job's whole
  /// process group inside is ended (TERM, then KILL), and it is reported as stopped.
  func stopJob(_ id: String, in computer: Computer) async {
    guard computer.jobs.contains(where: { $0.id == id && $0.running }) else { return }
    guard computer.state == .running, computer.helper.isOpen else {
      notice = "Start \(assistantName(computer.id))'s computer first, so Serein can stop the job inside it."
      return
    }
    do {
      _ = try await shellLink(computer).call("job_stop", ["job": id], timeout: 15)
      endJob(id, .stopped, tail: nil, in: computer)
    } catch {
      notice = "The job could not be stopped: " + AgentPrivacy.redact(error.localizedDescription)
    }
  }
  /// Each ended job's one message, into its chat once that chat is not working (a turn in flight
  /// would write over it); never a turn of its own. `sweep` calls this again when runs change. A
  /// chat that is gone takes no message: the job is only noted in Activity.
  private func deliverJobMessages() {
    guard let relay = RelayOrchestrator.shared else { return }
    for computer in computers.values {
      var changed = false
      for (index, job) in computer.jobs.enumerated() where !job.running && !job.reported {
        let text = ComputerJobs.message(job, computer: "\(assistantName(computer.id))'s computer")
        switch relay.agent.postNotice(text, into: job.thread) {
        case true?: break
        case false?: continue
        case nil: relay.note("A detached job in \(assistantName(computer.id))'s computer ended; its chat is gone", .auto)
        }
        computer.jobs[index].reported = true
        changed = true
      }
      if changed { saveJobs(computer) }
    }
  }
  /// The jobs a computer keeps (ComputerJobs.trimmed), in memory and in the saved record.
  private func saveJobs(_ computer: Computer) {
    computer.jobs = ComputerJobs.trimmed(computer.jobs)
    let jobs = computer.jobs
    updateSaved { saved in
      var all = saved.jobs ?? [:]
      all[computer.id] = jobs.isEmpty ? nil : jobs
      saved.jobs = all
    }
  }

  /// A step's picture once the step returned (StepPictures, masked: stepPicture), dropped while the
  /// helper answers anything else or the last picture is on its way; the next step may wait behind
  /// it, so only computers on this Mac (call's docker and builtIn) take it.
  private func picture(after computer: Computer, step: String, task: String) {
    guard !computer.picturing, computer.helper.idle else { return }
    computer.picturing = true
    Task {
      let png = await stepPicture(computer)
      computer.picturing = false
      if let png { StepPictures.shared.keep(png, step: step, task: task) }
    }
  }

  /// On the person's own machine, nothing is looked at while a password manager is in front or
  /// among the apps a tree walked: the helper names the front app with every screenshot and tree
  /// (and every app the tree walked), and the Mac's own list decides (RelayAutonomy.holdsSecrets).
  /// A front app the helper could not tell fails closed. The answer, picture and all, is dropped.
  private func refuseSecrets(_ answer: [String: Any], computer: Computer) throws {
    guard computer.place == .ownMachine else { return }
    guard answer["front_known"] as? Bool == true else {
      throw SereinError.invalid(
        "Serein could not tell which app is in front on \(placeName(computer)), so it did not look. On a Mac, allow Automation for System Events for the SSH session.")
    }
    func secret(_ entry: [String: Any]) -> Bool {
      let app = String((entry["app"] as? String ?? "").prefix(200))
      let bundle = String((entry["bundle"] as? String ?? "").prefix(200))
      return RelayAutonomy.holdsSecrets(app: app, bundleID: bundle.isEmpty ? nil : bundle)
    }
    let walked = (answer["apps"] as? [[String: Any]] ?? []).prefix(50)
    if secret(answer) {
      throw SereinError.invalid("A password manager is in front on \(placeName(computer)); Serein did not look.")
    }
    if walked.contains(where: secret) {
      throw SereinError.invalid("A password manager has a window the tree would read on \(placeName(computer)); Serein did not look.")
    }
    // More apps than the helper lists: one it did not name could hold secrets.
    if OwnMachinePolicy.appsCut(answer) {
      throw SereinError.invalid(
        "The tree on \(placeName(computer)) would read windows of more than 50 apps; Serein did not look. Name a window to read.")
    }
  }
  /// The size of a screen picture, at most 8 MB, read from its PNG signature and IHDR by hand, so
  /// nothing else the computer sends ever reaches ImageIO (ScreenPicture, pure): exactly 1280×800
  /// from Serein's own computers through the helper, at most 1280 a side from the person's own
  /// machine (its helper scales to fit) and from Cua Driver. Off the main actor: it reads only
  /// its arguments and ComputerPolicy's constants.
  nonisolated static func screenSize(_ png: Data, rule: ScreenPicture.Rule) -> (width: Int, height: Int)? {
    ScreenPicture.size(png, rule: rule)
  }
  /// A PNG under the helper's transport limit, as a JPEG when it has to be (BrowserModel's rule).
  static func transportPicture(_ png: Data) -> (data: Data, kind: String) {
    var picture = png
    var kind = "image/png"
    if picture.count >= 1_200_000, let bitmap = NSBitmapImageRep(data: png) {
      for quality in [0.85, 0.6, 0.35] where picture.count >= 1_200_000 {
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { break }
        (picture, kind) = (jpeg, "image/jpeg")
      }
    }
    return (picture, kind)
  }

  /// One act on the person's own machine as it is (ApprovalDoor.answer, `.ownMachine`): it asks on a card
  /// that says exactly what it does there (OwnCard.step, from the normalized arguments `a`), and
  /// runs without one only in a task at Proactive. Watching needs no card; the Outbox and
  /// clipboard tools decide on their own. A step that takes the person's password goes, at every
  /// level, to a person card they do themselves (the answer it returns); the model never types it.
  private func allowOwnStep(
    _ name: String, _ a: [String: Any], task id: String, computer: Computer, browser: BrowserModel
  ) async throws -> [String: Any]? {
    guard !OwnMachinePolicy.watchTools.contains(name), !OwnMachinePolicy.ownCardTools.contains(name) else { return nil }
    let relay = browser.relayTask(id, browser.tasks[id])
    let text = (a["text"] ?? a["command"]) as? String
    let answer = ApprovalDoor.answer(
      .init(
        .ownMachine(tool: name, key: a["key"] as? String, text: text),
        browser.standing(task: id, else: RelayOrchestrator.standing(relay, present: true)), taskID: id),
      facts: .init(
        secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
        runsAnything: false, ref: "")
    )
    if answer == .blocked(.secret), let shared = RelayOrchestrator.shared {
      return browser.raiseStep(.root(machine: placeName(computer), command: text ?? ""), task: id, relay: shared)
    }
    if try answer.decision() == .auto { return nil }
    guard let askRelay = relay ?? RelayOrchestrator.shared else { throw SereinError.invalid(ActionAdmission.needsPerson) }
    guard let card = OwnCard.step(tool: name, machine: placeName(computer), arguments: a) else {
      throw SereinError.invalid(OwnCard.unshowable)
    }
    let human = await askRelay.confirmAnswer(
      card.title, card.detail, button: "Allow once", thread: browser.threadID(forTask: id), more: card.more,
      moreName: name == "computer_run" ? "the command" : "the text", moreOpen: card.more != nil,
      picture: name == "computer_click" || name == "computer_scroll" ? computer.screen : nil)
    guard human == .yes else { throw SereinError.invalid(human == .no ? OwnCard.declinedStep : ActionAdmission.needsPerson) }
    guard browser.tasks[id]?.finished == false else { throw SereinError.invalid("The task ended while awaiting approval") }
    // The person took over while the card waited: their hands, not the assistant's.
    guard computer.control == .assistant else { throw SereinError.invalid(ComputerPolicy.personHasControl) }
    return nil
  }

  // MARK: leaving the computer (ApprovalGate)

  /// Files out: the file is read from the computer into the Outbox (a private folder, 0600),
  /// checked as a task download is (type allowlist, first bytes, never anything that runs), and
  /// offered on a card. Keep copies it to Downloads with the downloaded-file mark; Decline
  /// deletes it. Follows the task's level; unattended at Manual its card is deferred.
  private func sendFile(_ a: [String: Any], task id: String, computer: Computer, browser: BrowserModel) async throws -> [String: Any] {
    guard let path = a["path"] as? String, !path.isEmpty else { throw SereinError.invalid("path is required.") }
    let relay = browser.relayTask(id, browser.tasks[id])
    let scheduled = browser.isUnattended(task: id)
    let decision = try ApprovalDoor.answer(
      .init(.effect(.fileOut), browser.standing(task: id, else: RelayOrchestrator.standing(relay, present: !scheduled)), taskID: id),
      facts: .init(
        secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
        runsAnything: false, ref: "")
    ).decision()
    guard let askRelay = relay ?? RelayOrchestrator.shared, let root else { throw SereinError.invalid(ActionAdmission.needsPerson) }
    let data: Data
    let rawName: String
    if computer.place == .macOS, let mac = computer.machine as? MacVirtualComputer {
      (rawName, data) = try await mac.fileOut(path)
    } else {
      let answer = try await shellLink(computer).call("file_out", ["path": path], timeout: 120)
      guard let base64 = answer["data"] as? String, let decoded = Data(base64Encoded: base64), let name = answer["name"] as? String
      else { throw SereinError.invalid("The computer sent no file.") }
      (rawName, data) = (name, decoded)
    }
    let name = SafeFileName.clean(rawName, fallback: "File")
    guard Int64(data.count) <= ComputerPolicy.fileOutLimit else {
      throw SereinError.invalid("\(name) is larger than \(Bytes.file(ComputerPolicy.fileOutLimit)), the most the Outbox takes.")
    }
    if let reason = TaskDownloadPolicy.refusal(name: name, mimeType: nil) { throw SereinError.invalid(reason) }
    if let reason = TaskDownloadPolicy.contentRefusal(name: name, head: data.prefix(4096), executable: false) {
      throw SereinError.invalid(reason)
    }
    let outbox = root.appendingPathComponent("outbox", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: outbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let staged = outbox.appendingPathComponent(UUID().uuidString + "." + TaskDownloadPolicy.fileExtension(name))
    try data.write(to: staged, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
    defer { try? fm.removeItem(at: staged) }
    let size = Bytes.file(Int64(data.count))
    // Listed in the assistant's Library while its card waits, and gone once it is answered.
    let offer = AssistantLibrary.shared.offered(name, size: size, owner: computer.id, thread: browser.threadID(forTask: id))
    defer { AssistantLibrary.shared.answered(offer) }
    // A task at Proactive keeps it with no card (ApprovalDoor.answer).
    let human: ApprovalGate.HumanAnswer = await decision == .auto ? .yes : askRelay.confirmAnswer(
      "Outbox: keep \(name) from Serein's computer?",
      "\(assistantName(computer.id)) offers \(name) (\(size)). \(ApprovalGate.askLine(.fileOut)) It is not opened; Keep puts it in Downloads marked as downloaded, Decline deletes it.",
      button: "Keep", thread: browser.threadID(forTask: id), effect: .fileOut)
    guard human == .yes else {
      throw SereinError.invalid(human == .no ? "The user declined keeping \(name). It was deleted from the Outbox." : ActionAdmission.needsPerson)
    }
    guard browser.tasks[id]?.finished == false else { throw SereinError.invalid("The task ended while awaiting approval") }
    let target = try Self.keep(staged, name: name)
    AssistantLibrary.shared.kept(target, owners: [computer.id])
    browser.agentTabs.relabelLast(task: id, tool: "computer_send_file", "Kept \(name) from Serein's computer in Downloads")
    return ["kept": target.lastPathComponent, "where": "the user's Downloads folder"]
  }
  /// The Keep of the Outbox card: a copy in Downloads under a free name (TaskShelf's), 0600,
  /// with the downloaded-file mark. A copy that cannot be marked is removed, never left unmarked.
  static func keep(_ staged: URL, name: String) throws -> URL {
    guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
      throw SereinError.invalid("The Downloads folder could not be found.")
    }
    let fm = FileManager.default
    guard let target = try TaskShelf.intoDownloads(name, in: downloads, { try fm.copyItem(at: staged, to: $0) }) else {
      throw SereinError.invalid("\(name) could not be kept: too many files share its name.")
    }
    do {
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      try TaskShelf.quarantine(target)
    } catch {
      try? fm.removeItem(at: target)
      throw error
    }
    DownloadCenter.shared.kept(target)
    return target
  }

  /// Clipboard out: the card shows the exact text (redacted as every agent text is), and that
  /// shown text is what goes on the clipboard. Follows the task's level; unattended at Manual its
  /// card is deferred.
  private func sendText(_ a: [String: Any], task id: String, computer: Computer, browser: BrowserModel) async throws -> [String: Any] {
    guard let sent = a["text"] as? String, !sent.isEmpty else { throw SereinError.invalid("text is required.") }
    // Line endings first, so every check below and the card see the text that is copied.
    let raw = ComputerPolicy.clipboardText(sent)
    // Bytes first: a few thousand characters can still be megabytes of stacked combining marks.
    guard raw.utf8.count <= ComputerPolicy.clipboardLimit * 4 else {
      throw SereinError.invalid("The text is too large to show on a card (over \(ComputerPolicy.clipboardLimit * 4) bytes). Nothing was copied.")
    }
    guard raw.count <= ComputerPolicy.clipboardLimit else {
      throw SereinError.invalid("The text is longer than \(ComputerPolicy.clipboardLimit) characters. Send less.")
    }
    let relay = browser.relayTask(id, browser.tasks[id])
    let decision = try ApprovalDoor.answer(
      .init(
        .effect(.clipboardOut),
        browser.standing(task: id, else: RelayOrchestrator.standing(relay, present: !browser.isUnattended(task: id))),
        taskID: id),
      facts: .init(
        secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
        runsAnything: false, ref: "")
    ).decision()
    guard let askRelay = relay ?? RelayOrchestrator.shared else { throw SereinError.invalid(ActionAdmission.needsPerson) }
    let shown = AgentPrivacy.redact(raw)
    // Only what the card draws may be copied (ComputerPolicy.clipboardShowable).
    guard ComputerPolicy.clipboardShowable(shown) else {
      throw SereinError.invalid(
        "The text holds characters a card cannot show (control characters, or invisible formatting such as bidi or zero-width marks), so the user could not see exactly what would be copied. Nothing was copied.")
    }
    // The whole text in the card's open, scrolling box: nothing is copied that was not shown.
    // A task at Proactive copies it with no card; the checks above still hold.
    let human: ApprovalGate.HumanAnswer = await decision == .auto ? .yes : askRelay.confirmAnswer(
      "Copy text from Serein's computer to your clipboard?",
      ApprovalGate.askLine(.clipboardOut) + " \(shown.count) characters, shown below.",
      button: "Copy", thread: browser.threadID(forTask: id), more: shown, moreName: "the text", moreOpen: true,
      effect: .clipboardOut)
    guard human == .yes else {
      throw SereinError.invalid(human == .no ? "The user declined copying the text. Nothing was copied." : ActionAdmission.needsPerson)
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(shown, forType: .string)
    return ["copied": shown.count, "note": "The text is on the user's clipboard."]
  }

  /// Files in: the person dropped a file on the computer's view. The drag is theirs, and the
  /// card confirms it below Allow all; the file is checked like a download and lands on
  /// the computer's desktop. Never from an agent.
  func dropFile(_ url: URL, into computer: Computer) async {
    guard let relay = RelayOrchestrator.shared else { return }
    let name = SafeFileName.clean(url.lastPathComponent, fallback: "File")
    do {
      let decision = try ApprovalDoor.answer(
        .init(.effect(.fileIn), relay.standing(present: true)),
        facts: .init(
          secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
          runsAnything: false, ref: "")
      ).decision()
      if let reason = TaskDownloadPolicy.refusal(name: name, mimeType: nil) { throw SereinError.invalid(reason) }
      guard let data = SafeFileRead.regularFile(url.path, limit: Int(ComputerPolicy.fileOutLimit) + 1),
        Int64(data.count) <= ComputerPolicy.fileOutLimit
      else { throw SereinError.invalid("\(name) could not be read, or is larger than \(Bytes.file(ComputerPolicy.fileOutLimit)).") }
      if let reason = TaskDownloadPolicy.contentRefusal(name: name, head: data.prefix(4096), executable: false) {
        throw SereinError.invalid(reason)
      }
      let human: ApprovalGate.HumanAnswer = await decision == .auto ? .yes : relay.confirmAnswer(
        "Put \(name) into Serein's computer?",
        "\(ApprovalGate.askLine(.fileIn)) \(name) (\(Bytes.file(Int64(data.count)))) lands on the computer's desktop, where \(assistantName(computer.id)) can read it.",
        button: "Put in", thread: computer.holder.flatMap { browser?.threadID(forTask: $0) } ?? relay.threadID, effect: .fileIn)
      guard human == .yes else { return }
      try await ensureRunning(computer)
      let answer = try await computer.helper.call("file_in", ["name": name, "data": data.base64EncodedString()], timeout: 120)
      notice = "Put \(name) into Serein's computer at \(answer["path"] as? String ?? "its desktop")."
      computer.personSteps.append("put the file \(name) on the desktop")
      if let task = computer.holder { browser?.agentTabs.note(AgentStep(tool: "computer_file_in", label: "You put \(name) into Serein's computer"), task: task) }
    } catch { notice = AgentPrivacy.redact(error.localizedDescription) }
  }

  // MARK: watch, take over, hand back, pause

  /// The trail row of a task's `computer_*` step opens that assistant's computer, watch-first:
  /// the screen shows and the person holds nothing until Take control.
  func showWatching(task id: String) {
    guard let profile = browser?.taskAssistant(id)?.profile else { return }
    AssistantInspector.shared.show(profile.id, tab: .activity)
  }

  /// A panel or window that shows the screen: polling runs while one is on screen.
  func watch(_ computer: Computer, _ on: Bool) {
    computer.watchers = max(0, computer.watchers + (on ? 1 : -1))
    computer.viewClosedAt = computer.watchers > 0 ? nil : computer.viewClosedAt ?? Date()
    // The built-in computer's screen is the framework's own live view: nothing to poll.
    if computer.watchers > 0, computer.poller == nil, computer.place != .builtIn {
      computer.poller = Task { [weak self, weak computer] in
        while let computer, computer.watchers > 0, !Task.isCancelled {
          await self?.refreshScreen(computer)
          let fast = computer.control == .person
          // A hosted computer's pictures come over the person's connection: half as often.
          let pace: UInt64 = computer.place == .docker || computer.place == .macOS ? 1 : 2
          try? await Task.sleep(nanoseconds: (fast ? 350_000_000 : 900_000_000) * pace)
        }
        computer?.poller = nil
      }
    }
  }
  private func refreshScreen(_ computer: Computer) async {
    if let mac = computer.machine as? MacVirtualComputer {
      guard mac.isRunning, computer.control != .person,
        let png = try? mac.preview(), let image = NSImage(data: png) else { return }
      computer.screen = image
      computer.screenWidth = ComputerPolicy.screenWidth
      computer.screenHeight = ComputerPolicy.screenHeight
      return
    }
    guard computer.state == .running, computer.helper.isOpen, !computer.busy || computer.control == .person else { return }
    guard let shot = try? await screenCall(computer, "screenshot", timeout: 10, driver: false), let base64 = shot["png"] as? String,
      let png = Data(base64Encoded: base64), let size = Self.screenSize(png, rule: pictureRule(computer)),
      let image = NSImage(data: png)
    else { return }
    computer.screen = image
    computer.screenWidth = size.width
    computer.screenHeight = size.height
  }
  /// Take over: control passes now, or when the step in flight ends; the assistant's next
  /// computer tool refuses until Hand back.
  func takeOver(_ computer: Computer) {
    guard computer.control == .assistant else { return }
    if let mac = computer.machine as? MacVirtualComputer, !mac.isReady { mac.pauseAutomaticSetup() }
    let next = ComputerHold.next(computer.control, .takeOver(stepInFlight: computer.busy))
    if next == .person { grantControl(computer) } else { computer.control = next }
  }
  private func grantControl(_ computer: Computer) {
    computer.control = .person
    computer.personSteps = []
    computer.heldInputAt = Date()
    computer.viewClosedAt = computer.watchers > 0 ? nil : Date()
    watchHold(computer)
    // The person may change the screen: no click is aimed at the assistant's last picture.
    computer.driver?.forgetPicture()
    computer.lastUsed = Date()
    if let task = computer.holder { browser?.agentTabs.note(AgentStep(tool: "take_over", label: "You took over Serein's computer"), task: task) }
    RelayOrchestrator.shared?.note("You took over Serein's computer", .user)
  }
  /// The hold ends by itself (`ComputerHold.lapse`): 5 minutes after the person's last input, or 2
  /// after the last view of the screen closed. Checked every few seconds while they hold control.
  private func watchHold(_ computer: Computer) {
    computer.holdWatch?.cancel()
    computer.holdWatch = Task { [weak self, weak computer] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard let self, let computer, computer.control == .person else { return }
        // Serein's Mac asking the person during its own setup is not a hold to time out.
        if computer.place == .macOS, computer.macSetup.needsPerson { continue }
        if let lapse = ComputerHold.lapse(lastInput: computer.heldInputAt, viewClosedAt: computer.viewClosedAt, now: Date()) {
          self.handBack(computer, line: lapse.line)
          return
        }
      }
    }
  }
  /// Hand back: the assistant resumes and its next tool answer carries what the person did.
  /// `line` is the chat's words when the hold ended by itself.
  func handBack(_ computer: Computer, line: String = "You handed Serein's computer back") {
    guard computer.control != .assistant else { return }
    if let mac = computer.machine as? MacVirtualComputer, !mac.isReady {
      computer.control = .assistant
      mac.continueAutomaticSetup()
      return
    }
    // Take over was still waiting for the step to end: the assistant never lost control.
    if computer.control == .pending {
      computer.control = .assistant
      return
    }
    let steps = computer.personSteps
    computer.control = .assistant
    computer.personSteps = []
    computer.driver?.forgetPicture()
    let what = steps.isEmpty ? "looked without changing anything" : Self.summarize(steps)
    computer.steps.handBack(summary: what)
    closeAsk(computer, handedBack: true, browser: browser)
    if let task = computer.holder { browser?.agentTabs.note(AgentStep(tool: "hand_back", label: line), task: task) }
    RelayOrchestrator.shared?.note(line, .user)
    // The holder's run ended under the person's hands: its reset runs now, then the next task in
    // line gets a fresh home and nothing to be told.
    if computer.resetOwed {
      computer.steps = StepGuard()
      Task { await self.settle(computer) }
    }
  }
  private static func summarize(_ steps: [String]) -> String {
    var counts: [(String, Int)] = []
    for step in steps {
      if let i = counts.firstIndex(where: { $0.0 == step }) { counts[i].1 += 1 } else { counts.append((step, 1)) }
    }
    return counts.map { $0.1 > 1 ? "\($0.0) (\($0.1) times)" : $0.0 }.joined(separator: ", ")
  }
  /// The person's own input while they hold control: the driver when it is open, else the helper.
  func personInput(_ computer: Computer, op: String, _ arguments: [String: Any], step: String) {
    guard computer.control == .person, computer.state == .running else { return }
    computer.lastUsed = Date()
    computer.heldInputAt = Date()
    computer.personSteps.append(step)
    Task { _ = try? await self.screenCall(computer, op, arguments, timeout: 60, driver: computer.driver?.isOpen == true) }
  }
  /// The person's own input on the built-in computer's screen, which goes straight into it
  /// (VirtualMachineScreen): only noted, for the Hand back summary and the idle clock.
  func personActed(_ computer: Computer, step: String) {
    guard computer.control == .person else { return }
    computer.lastUsed = Date()
    computer.heldInputAt = Date()
    computer.personSteps.append(step)
  }
  func pause(_ computer: Computer) async {
    guard let machine = computer.machine, computer.state == .running else { return }
    computer.poller?.cancel()
    computer.poller = nil
    // A hosted pause ends the streams anyway: they close first, and new ones open on resume.
    if !machine.capabilities.linksSurvivePause { closeLinks(computer) }
    do {
      try await machine.pause()
      computer.state = .paused
    } catch {
      notice = "Serein's computer could not be paused: " + AgentPrivacy.redact(error.localizedDescription)
    }
  }
  func resume(_ computer: Computer) async {
    notice = nil
    do {
      if computer.place == .macOS {
        guard ComputerPolicy.isEnabled() else { throw SereinError.invalid(ComputerPolicy.offMessage) }
        guard MacRestoreImage.shared.chooseStorage() else { return }
      }
      // Wake is the person's own request, not an unattended tool call. Finish the shared
      // image download first, then boot this computer without requiring a second click.
      if computer.place == .builtIn, !ready(computer) {
        guard ComputerPolicy.isEnabled() else {
          throw SereinError.invalid("Turn on Serein's computer in Settings before setting it up.")
        }
        guard VirtualMachineComputer.supported else { throw SereinError.invalid(VirtualMachinePolicy.unsupported) }
        let image = BuiltInImage.shared
        let network = NetworkMonitor.shared
        if !image.working {
          let decision = BuiltInSetup.decide(
            setsItselfUp: ComputerPolicy.setsItselfUp(), working: false, share: nil, unattended: false,
            failed: image.automaticFailed, online: network.online, metered: network.metered,
            freeBytes: image.freeBytes, requested: true)
          if case .answer(let words) = decision { throw SereinError.invalid(words) }
        }
        await image.setUp()?.value
        // The user may have disabled, removed or moved it during the download.
        guard ComputerPolicy.isEnabled(), computers[computer.id] === computer, computer.place == .builtIn else { return }
        guard image.ready else {
          throw SereinError.invalid(image.lines.last ?? VirtualMachinePolicy.notSetUp)
        }
      }
      try await ensureRunning(computer)
      // Opening a computer is watching it, Serein's Mac too: control passes only on Take control.
      if computer.watchers > 0 { watch(computer, false); watch(computer, true) }
    } catch { notice = error.localizedDescription }
  }
  private func pauseIdle() async {
    // A hosted or own computer unused for two days (this launch) is worth a word, once each.
    for (id, computer) in computers
    where [.e2b, .daytona, .ownDesktop, .ownMachine].contains(computer.place)
      && Date().timeIntervalSince(computer.lastUsed) > 2 * 86_400
    {
      RelayOrchestrator.shared?.needsRepair(
        "idle-computer-\(id)",
        "\(computer.place.label) hasn't been used for more than two days. Fix: remove it in Settings if it's no longer needed.")
    }
    // A person-controlled Mac stays awake while its desktop is open. Elsewhere watching is not
    // using: a computer nobody holds sleeps after the idle limit even while a pane
    // shows it (the inspector's Computer tab can stay open for days), and a paid one sleeps even
    // while a task holds it and its screen is shown; any other held computer sleeps only unwatched.
    for computer in computers.values where computer.state == .running
      && !(computer.place == .macOS && computer.macSetup.working)
      && !ComputerPolicy.keepsAwakeWhileViewed(place: computer.place, watchers: computer.watchers,
                                               personHasControl: computer.control == .person)
      && (computer.watchers == 0 || computer.holder == nil || computer.place.capabilities.paid) && !computer.busy
      && !computer.resetting && Date().timeIntervalSince(computer.lastUsed) > ComputerPolicy.idleLimit
      // A detached job is use on a free computer: it runs on until it ends (or its time limit). A
      // paid one pauses with its memory anyway, and the job carries on when it is next woken.
      && (computer.place.capabilities.paid || !computer.jobs.contains(where: \.running))
    {
      // The reset Serein's own chat owes runs before the computer sleeps (at Hand back if the
      // person has control).
      if computer.chatTask != nil, computer.holder == nil {
        computer.chatTask = nil
        computer.resetOwed = true
        await settle(computer)
        // The reset passed the computer to a task in line: it is in use, not idle.
        if computer.holder != nil { continue }
      }
      await pause(computer)
    }
    // A hosted computer still in use says so, or its provider pauses it on its own. One past the
    // idle limit (its pause failed) does not, so the provider's own pause still comes. Signed
    // out, none says so.
    for computer in computers.values
    where computer.state == .running && Date().timeIntervalSince(computer.lastUsed) <= ComputerPolicy.idleLimit {
      await (computer.machine as? HostedComputer)?.keepAlive()
    }
  }

  // MARK: lifecycle

  /// Runs or tasks changed: a lease whose task's run ended passes on (after a Throwaway reset),
  /// and the reset Serein's own chat owes runs once its task is gone. Control is never taken
  /// back from the person here: the next holder's tools refuse until Hand back.
  private func sweep() {
    guard let hub else { return }
    let active = Set(hub.runs.filter(\.isActive).map(\.taskID))
    for computer in computers.values {
      // Stop ends the browser task before its run: either leaves the line at once.
      computer.queue.removeAll { !active.contains($0) || browser?.tasks[$0] == nil }
      // A step in flight finishes first; `call` sweeps again when it ends.
      if computer.busy { continue }
      if let chat = computer.chatTask, browser?.tasks[chat] == nil {
        computer.chatTask = nil
        // Owed at once, so no tool call can take the lease before the reset starts.
        if computer.holder == nil {
          computer.resetOwed = true
          Task { await self.settle(computer) }
        }
      }
      guard !computer.resetting, let holder = computer.holder, !active.contains(holder) else { continue }
      Task { await self.handOn(computer, from: holder) }
    }
    // A job's message waits while its chat works; a run that ended frees it.
    deliverJobMessages()
  }
  /// The holder's run ended: a Throwaway computer is reset before anyone else may hold it, then
  /// the next task in line gets it. While nobody waits, Serein's own chat keeps its home across
  /// turns, so that reset waits until its task ends or the computer idles (`chatTask`). Under the
  /// person's hands the reset is owed and runs at Hand back.
  private func handOn(_ computer: Computer, from holder: String) async {
    guard computer.holder == holder, !computer.resetting, !computer.busy else { return }
    computer.holder = nil
    computer.notedHosts = []
    // The person's own machine is never reset: the next task in line just gets it.
    guard computer.mode == .throwaway, computer.place.capabilities.isolated, let hub else {
      passOn(computer)
      return
    }
    let active = Set(hub.runs.filter(\.isActive).map(\.taskID))
    computer.queue.removeAll { !active.contains($0) }
    if browser?.tasks[holder]?.allowRelay == true, computer.queue.isEmpty {
      computer.chatTask = holder
      return
    }
    computer.chatTask = nil
    computer.resetOwed = true
    await settle(computer)
  }
  /// Runs the reset a Throwaway computer owes, then passes the lease on. While the person has
  /// control the debt stays, and Hand back calls this again. A reset that fails keeps the debt, so
  /// nobody can hold the computer until a reset succeeds (a manual Reset settles it too).
  private func settle(_ computer: Computer) async {
    guard computer.resetOwed, computer.control == .assistant, !computer.resetting, computer.holder == nil,
      !computer.busy
    else { return }
    guard await throwawayReset(computer) else {
      computer.resetFailedAt = Date()
      notice = "Serein's computer couldn't be cleared, so no other task can use it yet. Try Reset in Settings › Serein's computer."
      return
    }
    computer.resetOwed = false
    computer.resetFailedAt = nil
    passOn(computer)
  }
  /// The lease goes to the first task in line whose run is still active.
  private func passOn(_ computer: Computer) {
    guard computer.holder == nil, !computer.resetting, !computer.resetOwed, let hub else { return }
    let active = Set(hub.runs.filter(\.isActive).map(\.taskID))
    computer.queue.removeAll { !active.contains($0) }
    if let next = computer.queue.first {
      computer.holder = next
      computer.queue.removeFirst()
    }
  }
  /// A Throwaway computer's reset between tasks (`settle` checks that the assistant has control,
  /// nobody holds it and no step is in flight); nobody can take the lease while it runs (`lease`).
  /// A stopped or paused computer is started by `clear`. True once the home is clear, or when a
  /// computer that is not Throwaway needs no reset.
  private func throwawayReset(_ computer: Computer) async -> Bool {
    guard computer.mode == .throwaway, computer.place.capabilities.isolated else { return true }
    computer.resetting = true
    let cleared = await clear(computer)
    computer.resetting = false
    return cleared
  }
  /// Reset from Settings: the home folder is emptied and the checkpoint, if any, put back. True
  /// when it was. No tool call gets the computer while it runs (`lease`), and it settles a reset
  /// that was already owed when it started.
  @discardableResult
  func reset(_ computer: Computer) async -> Bool {
    guard computer.place != .macOS else { notice = "The virtual Mac is kept between tasks; resetting it is not available yet."; return false }
    guard computer.place.capabilities.isolated else {
      notice = "Serein never resets your own machine."
      return false
    }
    guard !computer.resetting else {
      notice = "Serein's computer is already being reset."
      return false
    }
    // While a reset is owed nobody can hold the computer, so nothing is written from here to the end.
    let owedAtStart = computer.resetOwed
    computer.resetting = true
    let cleared = await clear(computer)
    computer.resetting = false
    if cleared {
      notice = resetNotice(computer)
      if owedAtStart, computer.resetOwed {
        computer.resetOwed = false
        passOn(computer)
      }
    }
    // What waited for this reset goes on: a hand-on, or a reset owed since it started.
    sweep()
    if computer.resetOwed, !owedAtStart { Task { await self.settle(computer) } }
    return cleared
  }
  /// Empties the home folder: the browser's profile and sign-ins go with it.
  private static let wipeCommand =
    "chmod -R u+rwX /home/serein 2>/dev/null; for i in 1 2 3; do find -P /home/serein -mindepth 1 -delete 2>/dev/null && "
    + "exec mkdir -m 2770 /home/serein/work; sleep 1; done; exit 1"
  /// The work of a reset, for Settings and between Throwaway tasks. A hosted computer is deleted
  /// (`resetMakesNew`). On Docker the container stops first, which
  /// ends every process inside (a background job, the browser) and empties /tmp, /var/tmp, /run and
  /// /dev/shm; it then starts again with fresh links, and the home folder is emptied (`wipeCommand`,
  /// a constant: no name inside steers it) and the checkpoint, if any, put back.
  private func clear(_ computer: Computer) async -> Bool {
    // Never the person's own machine as it is: its home folder is theirs.
    guard computer.place.capabilities.isolated, let root, let machine = self.machine(for: computer) else { return false }
    // Every way below ends every process inside, so a detached job ends with the reset.
    endJobs(computer, .reset)
    do {
      if let whole = machine as? VirtualMachineComputer {
        // The built-in computer goes back whole: its disk (and saved memory) from the checkpoint,
        // or as it was right after setup. It is left off; the next step starts it from there.
        closeLinks(computer)
        try await whole.resetToCheckpoint()
        computer.state = .stopped
        computer.screen = nil
        return true
      }
      if try await resetFromHomeCheckpoint(machine, computer, root: root) { return true }
      if machine.capabilities.resetMakesNew {
        // A hosted computer is replaced, not emptied: it is deleted with every process and file
        // in it, and the next start makes a new one with the checkpoint put back. Nothing new is
        // started (or paid for) until something uses it.
        closeLinks(computer)
        try await machine.restart()
        computer.state = .none
        computer.screen = nil
        // The next start makes a new one from the template or snapshot as it is now.
        computer.pinsRefused = nil
        return true
      }
      try await ensureRunning(computer)
      computer.lastUsed = Date()
      closeLinks(computer)
      try await machine.restart()
      computer.state = .stopped
      try await ensureRunning(computer)
      computer.lastUsed = Date()
      let shell = try await shellLink(computer)
      if shell !== computer.helper {
        let wiped = try await shell.call("run", ["command": Self.shellWipe], timeout: 70)
        guard wiped["code"] as? Int == 0 else { throw SereinError.invalid("The shell user’s home folder could not be emptied.") }
      }
      let wiped = try await computer.helper.call("run", ["command": Self.wipeCommand], timeout: 70)
      guard wiped["code"] as? Int == 0 else { throw SereinError.invalid("The home folder could not be emptied.") }
      try await restoreCheckpoint(machine, computer)
      return true
    } catch {
      notice = "The reset failed: " + AgentPrivacy.redact(error.localizedDescription)
      return false
    }
  }
  /// What Delete loses (Remove, on the person's own machine), for its confirmation.
  func lossList(_ computer: Computer) -> String {
    if computer.place == .unavailable { return "the checkpoint and computer data saved on this Mac" }
    if let own = computer.own {
      switch computer.place {
      case .ownDesktop:
        if let names = OwnDesktop.names(computer.id) {
          return OwnDesktop.removeList(container: names.container, volume: names.volume, target: own.target.text)
            + (computer.hasCheckpoint ? ", and its saved checkpoint on this Mac" : "")
            + (computer.notes.isEmpty ? "" : ", and your notes for it")
        }
      case .ownMachine:
        return OwnHelperManifest.removeList(target: own.target.text) + (computer.notes.isEmpty ? "" : ", and your notes for it")
      case .docker, .builtIn, .macOS, .e2b, .daytona, .unavailable:
        break
      }
    }
    var items = computer.place == .builtIn || computer.place == .macOS
      ? ["its whole disk: every file, app and setting in it", "its browser history and sign-ins inside the computer"]
      : ["every file in its home folder", "its browser history and sign-ins inside the computer"]
    if computer.hasCheckpoint { items.append("its saved checkpoint") }
    if !computer.notes.isEmpty { items.append("your notes for it") }
    return items.joined(separator: ", ")
  }
  /// Delete: the computer (on Docker its container and home volume; the image stays) and its
  /// checkpoint. False when the place did not confirm it: the computer and its checkpoint stay,
  /// shown in Settings, so Delete can be tried again.
  @discardableResult
  func delete(_ computer: Computer) async -> Bool {
    guard computer.place != .unavailable else { notice = ComputerPlace.unavailableReason; return false }
    guard !computer.resetting else { notice = "Wait for the checkpoint or reset to finish before deleting the computer."; return false }
    computer.poller?.cancel()
    computer.poller = nil
    computer.helper.close()
    computer.proxy?.close()
    computer.driver?.close()
    // Nothing runs on the person's own machine before they trusted its host key, so with no key
    // there is nothing there to remove (and ssh could not reach it to try).
    let untrusted = computer.place.isOwn && ownLink(computer)?.storedKey == nil
    if !untrusted, let machine = self.machine(for: computer) {
      do {
        try await machine.delete()
      } catch {
        if (error as? OwnLinkError)?.failure == .keyChanged { computer.keyChanged = true }
        if computer.place.isOwn { computer.removeFailed = true }
        let retry: String = computer.place.isOwn ? " Try Remove again, or Forget Without Removing." : " Try Delete again."
        let reason: String = AgentPrivacy.redact(error.localizedDescription)
        notice = "\(assistantName(computer.id))'s computer is still on \(placeName(computer)): \(reason)\(retry)"
        computer.state = .error("still on \(placeName(computer))")
        return false
      }
    }
    dropLocal(computer)
    return true
  }
  /// What a deleted computer leaves on this Mac: its folder (checkpoint and notes), its shared
  /// folder and its state here; its detached jobs ended with it.
  private func dropLocal(_ computer: Computer) {
    endJobs(computer, .reset)
    computer.pinsRefused = nil
    if computer.place == .macOS {
      var values = GateSettings.shared.dictionary(forKey: MacComputerPolicy.internetKey) ?? [:]
      values.removeValue(forKey: computer.id)
      GateSettings.shared.set(values, forKey: MacComputerPolicy.internetKey)
      computer.macInternet = MacComputerPolicy.networkByDefault
    }
    if computer.place != .macOS, let root {
      try? FileManager.default.removeItem(at: root.appendingPathComponent(computer.id, isDirectory: true))
    }
    computer.notes = ""
    forgetSharedFolder(computer)
    computer.hasCheckpoint = false
    computer.state = .none
    computer.screen = nil
    computer.holder = nil
    computer.queue = []
    computer.chatTask = nil
    computer.resetOwed = false
    computer.notedHosts = []
    computer.control = .assistant
  }
  /// A built-in computer is on: quitting waits for `saveForQuit`.
  var needsSaveForQuit: Bool {
    computers.values.contains { Self.savesForQuit($0) }
  }
  /// A built-in computer that is on and finished setup; one still in setup is never saved and
  /// stops at quit (`quit`), and its next start sets it up again.
  private static func savesForQuit(_ computer: Computer) -> Bool {
    if let mac = computer.machine as? MacVirtualComputer { return mac.isRunning && mac.isInstalled }
    guard let machine = computer.machine as? VirtualMachineComputer else { return false }
    return machine.isRunning && machine.isSetUp
  }
  /// Before quit (AppDelegate.applicationShouldTerminate): each built-in computer that is on saves
  /// its memory and goes off, as an idle pause does, so the next start carries on where it was.
  func saveForQuit() async {
    for computer in computers.values where Self.savesForQuit(computer) {
      computer.poller?.cancel()
      computer.poller = nil
      closeLinks(computer)
      do {
        try await computer.machine?.pause()
        computer.state = .paused
      } catch {
        notice = "Serein's computer could not save its state: " + AgentPrivacy.redact(error.localizedDescription)
      }
    }
  }
  /// Cancel during a built-in computer's first setup: it is deleted with everything it made, and
  /// so is the downloaded image when no other assistant has a built-in computer made from it.
  func cancelSetup(_ computer: Computer) async {
    if computer.place == .macOS {
      GateSettings.shared.set(false, forKey: ComputerPolicy.autoSetUpKey)
      computer.starting?.cancel()
      (computer.machine as? MacVirtualComputer)?.cancelSetup()
      _ = try? await computer.starting?.value
      let mac = computer.machine as? MacVirtualComputer
      try? await mac?.pause()
      computer.state = mac?.isInstalled == true ? .paused : .none
      computer.setupLine = nil
      notice = "macOS setup was cancelled. Its partial installation is kept for the next attempt."
      ComputerWindow.closeInitialSetup(computer)
      return
    }
    // Only a first setup: a computer that finished it is deleted through Delete, which asks first.
    guard (computer.machine as? VirtualMachineComputer)?.isSetUp == false else { return }
    let start = computer.starting
    guard await delete(computer) else { return }
    _ = try? await start?.value
    computer.state = .none
    computer.setupLine = nil
    let fm = FileManager.default
    let others = root.map { root in
      ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).contains { name in
        name != computer.id && fm.fileExists(atPath: root.appendingPathComponent(name + "/" + VirtualMachinePolicy.diskName).path)
      }
    } ?? true
    if !others { BuiltInImage.shared.remove() }
    notice = "Setup was cancelled. Nothing of it is left on this Mac."
  }
  /// At quit: every running computer stops (a container's volume stays) or, on a hosted place,
  /// pauses with its memory. Blocking, as quit is.
  func quit() {
    clock?.cancel()
    for computer in computers.values {
      computer.poller?.cancel()
      computer.helper.close()
      computer.proxy?.close()
      computer.driver?.close()
      guard computer.state == .running || computer.state == .paused, let machine = computer.machine else { continue }
      machine.stopForQuit(paused: computer.state == .paused)
    }
  }
}
