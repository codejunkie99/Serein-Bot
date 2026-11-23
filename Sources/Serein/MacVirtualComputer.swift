import AppKit
import Darwin
import Foundation
import SereinCore
import Virtualization

/// A real macOS guest. Serein owns its native display/input and first-boot setup. The signed
/// guest bridge handles only guest text/URLs; no guest screen-control permissions are needed.
/// No host home, personal folder, clipboard or device is shared.
/// The first version keeps the Mac between tasks; it offers no Linux shell/file/reset tools.
@MainActor final class MacVirtualComputer: NSObject, ComputerBackend, NativeScreen, VZVirtualMachineDelegate {
  let capabilities = ComputerCapabilities.macOS
  private(set) var machine: VZVirtualMachine?
  private let folder: URL
  private let internet: () -> Bool
  private let progress: (String?) -> Void
  private let stopped: () -> Void
  private let admission: () -> String?
  private let personAllowed: () -> Bool
  private let personActed: (String) -> Void
  private let setupChanged: (MacSetupPhase) -> Void
  private(set) var display: MacNativeDisplay?
  private(set) var isReady = false
  private(set) var setupPhase = MacSetupPhase.preparing
  private var setupAgreementApproved = false
  #if arch(arm64)
  private var installer: VZMacOSInstaller?
  #endif
  /// True while macOS is installing. The installer type exists only on Apple silicon.
  private var isInstalling: Bool {
    #if arch(arm64)
    installer != nil
    #else
    false
    #endif
  }
  private var readiness: Task<Void, Never>?
  /// The guest's helper answered at least once since the last wait began (any build).
  private var heardFromGuest = false
  /// The last wait ended without one answer: the helper is not running inside the Mac. It starts
  /// only when that Mac boots, and a quit keeps the Mac's memory, so only a restart brings it back.
  private(set) var guestSilent = false
  /// The helper answers, but as an older build than this Serein ships. Saved memory keeps the old
  /// helper running, and helpers before this fix never notice the update, so a restart (where the
  /// helper's first check installs the new copy) is the only way out.
  private(set) var guestOutdated = false
  /// The card offers Restart, and ComputerHost restarts once by itself, for either cause.
  var needsRestart: Bool { guestSilent || guestOutdated }
  /// This start brought back saved memory rather than booting. A helper silent in it stays silent
  /// however long Serein waits; only a real restart starts it again (ComputerHost does that once).
  private(set) var restoredFromSave = false
  /// The one restart Serein made by itself for a silent restored Mac, so it never loops.
  var restartedForSilence = false
  /// How long the card says "Connecting" before it offers Restart, and how long Serein keeps
  /// listening after that for a Mac that answers late.
  static let connectWait: TimeInterval = 180
  static let keepListening: TimeInterval = 15 * 60
  static let silentMessage = "Serein’s Mac stopped answering. Restart it to reconnect; its files are kept."
  static let outdatedMessage = "Serein’s Mac needs a restart to finish updating. Its files are kept."
  /// The helper looks for an update every 30 seconds; past this it is not going to take one.
  static let outdatedWait: TimeInterval = 45
  private var mailbox: MacMailbox?
  private var lockFD: Int32 = -1
  private var expectedBuild = ""
  private var canSave = false
  /// The running Mac has a network card; saved memory is tagged with it (resumeTag).
  private var bootedOnline = false
  /// Setup finished just now on one of its offline boots while the network is on. The Mac is not
  /// handed to anyone yet: ComputerHost restarts it once so its first session is online too, or
  /// calls `readyOffline` when it can't.
  private(set) var wantsOnlineBoot = false
  private var acting = false
  private let fm = FileManager.default

  struct Record: Codable {
    var cpu: Int
    var memory: UInt64
    var installed: Bool
    var osMajor: Int?
    var hasStarted: Bool?
    var automaticAccount: Bool?
    var managedSetup: Bool?
    var prepared: Bool?
    var offlineSetupVersion: Int?
    var needsAccountProvisioning: Bool { (osMajor ?? 0) >= 27 && hasStarted != true }
    /// Only used at the recognized initial account page; never at a login/password screen.
    var needsSetupAccount: Bool { installed && prepared != true && automaticAccount != true }
  }
  init(folder: URL, internet: @escaping () -> Bool, progress: @escaping (String?) -> Void, stopped: @escaping () -> Void,
       admission: @escaping () -> String?, personAllowed: @escaping () -> Bool,
       personActed: @escaping (String) -> Void, setupChanged: @escaping (MacSetupPhase) -> Void) {
    self.folder = folder; self.internet = internet; self.progress = progress; self.stopped = stopped
    self.admission = admission
    self.personAllowed = personAllowed; self.personActed = personActed; self.setupChanged = setupChanged
  }
  deinit { if lockFD >= 0 { close(lockFD) } }
  private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
  private var record: Record? { (try? Data(contentsOf: file("machine.json"))).flatMap { try? JSONDecoder().decode(Record.self, from: $0) } }
  var isInstalled: Bool { record?.installed == true && fm.fileExists(atPath: file("disk.img").path) }
  var hasCompletedSetup: Bool { record?.prepared == true }
  var isRunning: Bool { machine?.state == .running }

  func start() async throws -> Bool {
    guard VirtualMachineComputer.supported, VirtualMachineComputer.entitled else {
      throw SereinError.invalid("The virtual Mac needs an Apple silicon Mac and a signed Serein build.")
    }
    if let vm = machine {
      if vm.state == .running { return false }
      if vm.state == .paused { try await vm.resume(); connectDisplay(vm); return false }
      guard vm.state == .stopped || vm.state == .error else { throw SereinError.invalid("The virtual Mac is busy. Try again in a moment.") }
      machine = nil
    }
    let helper = MacRestoreImage.shared.helper
    do { try MacGuestIdentity(referenceURL: helper).validate(helper) }
    catch { throw SereinError.invalid("This copy of Serein can’t start its Mac. Reinstall Serein to repair it.") }
    guard let executable = Bundle(url: helper)?.executableURL else { throw SereinError.invalid("This Serein build is missing its Mac guest app.") }
    expectedBuild = ComputerPins.sha256(try Data(contentsOf: executable, options: .mappedIfSafe))
    try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if lockFD < 0 {
      let fd = open(file("runtime.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw SereinError.invalid("The virtual Mac's storage cannot be opened.") }
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw SereinError.invalid("This virtual Mac is already open in another Serein process.") }
      lockFD = fd
    }
    let fresh = !isInstalled
    var authorization: MacSetupAuthorization?
    if fresh || (record?.prepared != true && record?.offlineSetupVersion != MacOfflineSetup.version) {
      // Reuse an explicit agreement saved on this Mac.
      setupAgreementApproved = ComputerPolicy.acceptedMacOSLicense()
      if !setupAgreementApproved { setSetup(.agreement) }
      while !setupAgreementApproved {
        try Task.checkCancellation()
        guard ComputerPolicy.isEnabled() else { throw CancellationError() }
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      setSetup(.preparing)
      let operation = Task.detached(priority: .userInitiated) { [weak self] in
        try MacSetupAuthorization.authorize(approvalNeeded: {
          Task { @MainActor [weak self] in self?.progress("Allow Serein in System Settings › Login Items & Extensions to finish automatic setup.") }
        })
      }
      authorization = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
    defer { try? authorization?.close() }
    try Task.checkCancellation()
    guard ComputerPolicy.isEnabled() else { throw CancellationError() }
    if fresh {
      let network = NetworkMonitor.shared
      guard !network.known || (network.online && !network.metered) else {
        throw SereinError.invalid("Connect without a data limit, then continue Mac setup. No macOS download was started.")
      }
      try await install()
    }
    try Task.checkCancellation()
    if record?.prepared != true, record?.offlineSetupVersion != MacOfflineSetup.version {
      guard let authorization else { throw SereinError.invalid("Authorize the Mac installer before preparing its disk.") }
      try await prepareOffline(helper: helper, authorization: authorization)
    }
    guard let record else { throw SereinError.invalid("The virtual Mac's configuration is missing.") }
    let online = record.prepared == true && internet()
    let config = try configuration(record, online: online)
    #if arch(arm64)
    canSave = (try? config.validateSaveRestoreSupport()) != nil
    #else
    canSave = false
    #endif
    let vm = VZVirtualMachine(configuration: config)
    vm.delegate = self
    machine = vm
    mailbox = try MacMailbox(file("exchange"), create: true)
    progress("Starting macOS…")
    // Saved memory from another Serein build would bring its old helper back, and a restored guest
    // keeps its old view of the shared tools folder, so that helper never sees the new copy. Boot
    // fresh instead: the disk and files are kept, only what was unsaved in its apps is lost. So does
    // memory saved with the other network setting: it cannot be restored onto these devices.
    bootedOnline = online
    wantsOnlineBoot = false
    let savedBuild = (try? Data(contentsOf: file("resume.build"))).map { String(decoding: $0, as: UTF8.self) }
    if fm.fileExists(atPath: file("resume.vzvmsave").path), savedBuild != Self.resumeTag(build: expectedBuild, online: online) {
      try? fm.removeItem(at: file("resume.vzvmsave"))
    }
    try? fm.removeItem(at: file("resume.build"))
    do {
      restoredFromSave = fm.fileExists(atPath: file("resume.vzvmsave").path)
      if restoredFromSave {
        #if arch(arm64)
        try await vm.restoreMachineStateFrom(url: file("resume.vzvmsave"))
        try await vm.resume()
        try fm.removeItem(at: file("resume.vzvmsave"))
        #else
        throw SereinError.invalid("The virtual Mac needs an Apple silicon Mac and a signed Serein build.")
        #endif
      } else {
        var booted = record
        if record.needsAccountProvisioning, let options = try MacGuestProvisioning.startOptions(storage: folder) {
          progress("Setting up Serein's Mac…")
          try await vm.start(options: options)
          booted.automaticAccount = true
        } else { try await vm.start() }
        booted.hasStarted = true
        try write(JSONEncoder().encode(booted), to: file("machine.json"))
      }
    } catch {
      if vm.canStop { try? await vm.stop() }
      machine = nil
      throw error
    }
    connectDisplay(vm)
    return fresh
  }

  private func prepareOffline(helper: URL, authorization: MacSetupAuthorization) async throws {
    guard var record, record.installed, record.managedSetup == true else {
      throw SereinError.invalid("This older Mac is not managed by Serein. Its files were left untouched.")
    }
    setSetup(.account)
    let backup = file("before-offline-setup-v1")
    if !fm.fileExists(atPath: backup.path) {
      try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      // Copy-on-write backup preserves the complete disk/identity pair, including an old
      // incomplete VM. Never repurpose a running guest's disk or discard its saved state.
      guard clonefile(file("disk.img").path, backup.appendingPathComponent("disk.img").path, 0) == 0 else {
        throw SereinError.invalid("The virtual Mac could not be backed up before automatic setup. Its disk was left untouched.")
      }
      for name in ["machine.json", "hardware.bin", "identity.bin", "auxiliary.bin"] {
        try fm.copyItem(at: file(name), to: backup.appendingPathComponent(name))
      }
      if fm.fileExists(atPath: file("resume.vzvmsave").path) {
        try fm.moveItem(at: file("resume.vzvmsave"), to: backup.appendingPathComponent("resume.vzvmsave"))
      }
      try write(Data("complete".utf8), to: backup.appendingPathComponent("backup-complete"))
    }
    guard fm.fileExists(atPath: backup.appendingPathComponent("backup-complete").path) else {
      throw SereinError.invalid("The Mac setup backup is incomplete. The existing computer was left untouched.")
    }
    if record.hasStarted != true && record.automaticAccount != true {
      progress("Preparing the macOS disk…")
      let initial = VZVirtualMachine(configuration: try configuration(record, online: false))
      machine = initial
      try await initial.start()
      do { try await Task.sleep(nanoseconds: 30_000_000_000) }
      catch { if initial.canStop { try? await initial.stop() }; machine = nil; throw error }
      // This is an unused first boot, before any account/work is present. Stop the VM so
      // its disk can be mounted exclusively; no input or screenshot is involved.
      try await initial.stop()
      machine = nil
      record.hasStarted = true
      try write(JSONEncoder().encode(record), to: file("machine.json"))
    }
    let password = try MacGuestProvisioning.password(storage: folder, migrateLegacy: record.automaticAccount == true)
    let folder = self.folder
    progress("Configuring Serein’s private account…")
    let operation = Task.detached(priority: .userInitiated) {
      try MacOfflineProvisioning.prepare(folder: folder, helper: helper, password: password, authorization: authorization)
    }
    try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    record.offlineSetupVersion = MacOfflineSetup.version
    record.automaticAccount = true
    try write(JSONEncoder().encode(record), to: file("machine.json"))
    try Task.checkCancellation()
  }

  private func install() async throws {
    #if arch(arm64)
    let imageURL = try await MacRestoreImage.shared.image(progress: progress)
    try Task.checkCancellation()
    let image = try await VZMacOSRestoreImage.image(from: imageURL)
    guard let requirements = image.mostFeaturefulSupportedConfiguration else { throw SereinError.invalid("This macOS installer cannot run on this Mac.") }
    let settings: Record
    if let partial = record {
      guard !partial.installed,
        try Data(contentsOf: file("hardware.bin")) == requirements.hardwareModel.dataRepresentation
      else { throw SereinError.invalid("An existing virtual Mac uses different hardware. Its files were left untouched.") }
      settings = partial
    } else {
      // A directory without a record is not silently overwritten after an interrupted creation.
      guard !fm.fileExists(atPath: file("disk.img").path) else { throw SereinError.invalid("A virtual Mac disk already exists without its configuration. It was left untouched.") }
      let memory = max(4 * 1_073_741_824, requirements.minimumSupportedMemorySize)
      let cpu = max(requirements.minimumSupportedCPUCount, min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
      guard memory <= ProcessInfo.processInfo.physicalMemory / 2 else { throw SereinError.invalid("This virtual Mac needs more than half of this Mac's memory. It was not installed.") }
      settings = Record(cpu: cpu, memory: memory, installed: false, managedSetup: true)
      try write(requirements.hardwareModel.dataRepresentation, to: file("hardware.bin"))
      try write(VZMacMachineIdentifier().dataRepresentation, to: file("identity.bin"))
      _ = try VZMacAuxiliaryStorage(creatingStorageAt: file("auxiliary.bin"), hardwareModel: requirements.hardwareModel, options: [])
      let fd = open(file("disk.img").path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw SereinError.invalid("The virtual Mac disk could not be created.") }
      let sized = ftruncate(fd, off_t(MacComputerPolicy.diskBytes)) == 0
      close(fd)
      guard sized else { throw SereinError.invalid("There is not enough space for the virtual Mac disk.") }
      try write(JSONEncoder().encode(settings), to: file("machine.json"))
    }
    let vm = VZVirtualMachine(configuration: try configuration(settings, online: false))
    let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: imageURL)
    self.installer = installer
    let progress = self.progress
    let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { value, _ in
      let percent = Int(value.fractionCompleted * 100)
      Task { @MainActor in progress("Installing macOS · \(percent)%") }
    }
    defer { observation.invalidate(); self.installer = nil }
    progress("Installing macOS…")
    try await installer.install()
    var installed = settings
    installed.installed = true
    installed.osMajor = image.operatingSystemVersion.majorVersion
    try write(JSONEncoder().encode(installed), to: file("machine.json"))
    #else
    throw SereinError.invalid("The virtual Mac needs an Apple silicon Mac and a signed Serein build.")
    #endif
  }

  /// What `resume.build` holds: saved memory restores only into the same helper build and the same
  /// network devices. An offline tag is the bare build, as older Serein builds wrote it.
  nonisolated static func resumeTag(build: String, online: Bool) -> String { online ? build + " network" : build }
  private func configuration(_ record: Record, online: Bool) throws -> VZVirtualMachineConfiguration {
    #if arch(arm64)
    let config = VZVirtualMachineConfiguration()
    config.bootLoader = VZMacOSBootLoader()
    config.cpuCount = record.cpu
    config.memorySize = record.memory
    let platform = VZMacPlatformConfiguration()
    guard let hardware = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: file("hardware.bin"))), hardware.isSupported,
      let identity = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: file("identity.bin")))
    else { throw SereinError.invalid("The virtual Mac's hardware is not supported on this Mac.") }
    platform.hardwareModel = hardware
    platform.machineIdentifier = identity
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: file("auxiliary.bin"))
    config.platform = platform
    let disk = try VZDiskImageStorageDeviceAttachment(url: file("disk.img"), readOnly: false)
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 2560, heightInPixels: 1600, pixelsPerInch: 220)]
    config.graphicsDevices = [graphics]
    config.keyboards = [VZUSBKeyboardConfiguration()]
    config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    // Apple's normal NAT, on by default once setup is finished (MacComputerPolicy.networkByDefault)
    // unless the person turned it off; setup's own boots stay offline. The Linux desktop's proxy
    // and site rules are separate and unchanged.
    if online {
      let network = VZVirtioNetworkDeviceConfiguration()
      network.attachment = VZNATNetworkDeviceAttachment()
      config.networkDevices = [network]
    }
    try fm.createDirectory(at: file("exchange"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let filesystem = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
    filesystem.share = VZMultipleDirectoryShare(directories: [
      "control": VZSharedDirectory(url: file("exchange"), readOnly: false),
      "tools": VZSharedDirectory(url: MacRestoreImage.shared.tools, readOnly: true),
    ])
    config.directorySharingDevices = [filesystem]
    try config.validate()
    return config
    #else
    throw SereinError.invalid("The virtual Mac needs an Apple silicon Mac and a signed Serein build.")
    #endif
  }

  private func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private var setupHelp: String {
    setupPhase.message ?? MacComputerPolicy.setupLine
  }
  func cancelSetup() {
    #if arch(arm64)
    installer?.progress.cancel()
    #endif
    readiness?.cancel()
    isReady = false
  }
  func openStream(_ command: [String], stdin: Bool, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void) async throws -> ComputerStream {
    throw SereinError.invalid(MacComputerPolicy.unsupportedTool)
  }
  func runOnce(_ command: [String], input: URL?, sink: @escaping (Data) -> Void) async throws -> Int {
    throw SereinError.invalid(MacComputerPolicy.unsupportedTool)
  }
  func pause() async throws {
    guard let vm = machine, vm.state == .running else { return }
    readiness?.cancel()
    // A Mac whose helper is not answering is never saved: its saved memory would bring the dead
    // helper back on every start. It shuts down instead, so the next start is a real boot.
    let connected = isReady
    isReady = false
    if !canSave || !connected {
      try await shutDown(vm)
      machine = nil
      display?.close(); display = nil
      return
    }
    try await vm.pause()
    do {
      if fm.fileExists(atPath: file("resume.part.vzvmsave").path) { try fm.removeItem(at: file("resume.part.vzvmsave")) }
      #if arch(arm64)
      try await vm.saveMachineStateTo(url: file("resume.part.vzvmsave"))
      #else
      throw SereinError.invalid("The virtual Mac needs an Apple silicon Mac and a signed Serein build.")
      #endif
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file("resume.part.vzvmsave").path)
      if fm.fileExists(atPath: file("resume.vzvmsave").path) { try fm.removeItem(at: file("resume.vzvmsave")) }
      try fm.moveItem(at: file("resume.part.vzvmsave"), to: file("resume.vzvmsave"))
      try? write(Data(Self.resumeTag(build: expectedBuild, online: bootedOnline).utf8), to: file("resume.build"))
      try await vm.stop()
      machine = nil
      display?.close(); display = nil
    } catch {
      try? await vm.resume()
      startAutomaticSetup()
      throw error
    }
  }
  /// `force`: a guest whose helper stopped answering cannot confirm macOS's own shut-down
  /// question, so after a short polite wait the Mac is powered off, as holding its power button
  /// would. Its disk and files are kept; only what was unsaved in its apps is lost.
  func restart() async throws { try await restart(force: false) }
  func restart(force: Bool) async throws {
    guard !isInstalling else { throw SereinError.invalid("Wait for macOS installation to finish before restarting the virtual Mac.") }
    if machine == nil, fm.fileExists(atPath: file("resume.vzvmsave").path) { _ = try await start() }
    readiness?.cancel()
    if let vm = machine {
      if vm.state == .paused { try await vm.resume() }
      if vm.state == .running { try await shutDown(vm, force: force) }
      else if vm.state != .stopped { throw SereinError.invalid("The virtual Mac is busy. Shut it down from its Apple menu, then try again.") }
      machine = nil
      display?.close(); display = nil
    }
    if fm.fileExists(atPath: file("resume.vzvmsave").path) { try fm.removeItem(at: file("resume.vzvmsave")) }
  }
  private func shutDown(_ vm: VZVirtualMachine, force: Bool = false) async throws {
    if try await shutDownFromGuest(vm) { return }
    try vm.requestStop()
    let deadline = Date().addingTimeInterval(force ? 10 : 45)
    while vm.state != .stopped, Date() < deadline { try await Task.sleep(nanoseconds: 250_000_000) }
    if force, vm.state != .stopped, vm.canStop { try await vm.stop() }
    guard vm.state == .stopped else { throw SereinError.invalid("The virtual Mac is waiting to shut down. Finish any prompt inside it, then try again.") }
  }
  /// macOS answers the virtual power button with a "shut down?" question, and nobody may be there
  /// to answer it (it only shuts down by itself after 60 seconds, past the wait below). A connected
  /// helper asks loginwindow for a normal shut down without that question, so apps still quit and
  /// the disk is closed cleanly. False when the guest is still running afterwards (an app asking to
  /// save, say); the caller then uses the power button as before.
  private func shutDownFromGuest(_ vm: VZVirtualMachine) async throws -> Bool {
    guard isReady || wantsOnlineBoot, let mailbox, vm.state == .running else { return false }
    let request = MacGuestRequest(action: "run", arguments: ["command": Self.guestShutDown, "timeout": "10"], timeout: 12)
    // The helper is quit by the shut down it asked for, so its answer may never come.
    _ = try? await mailbox.call(request)
    let deadline = Date().addingTimeInterval(Self.guestShutDownWait)
    while vm.state != .stopped, Date() < deadline { try await Task.sleep(nanoseconds: 250_000_000) }
    return vm.state == .stopped
  }
  /// kAEShutDown ('shut'). Not 'rsdn' (kAEShowShutdownDialog), which only shows the same question.
  static let guestShutDown = "osascript -e 'tell application \"loginwindow\" to «event aevtshut»'"
  static let guestShutDownWait: TimeInterval = 60
  func delete() async throws {
    guard !isInstalling else { throw SereinError.invalid("Cancel the macOS installation before removing this computer.") }
    try await restart()
    if fm.fileExists(atPath: folder.path) { try fm.trashItem(at: folder, resultingItemURL: nil) }
  }
  func stopForQuit(paused: Bool) {
    readiness?.cancel()
    #if arch(arm64)
    if let installer { installer.progress.cancel(); return }
    #endif
    guard let vm = machine, vm.canStop else { return }
    vm.stop { _ in }
    machine = nil
    display?.close(); display = nil
  }

  private func connectDisplay(_ vm: VZVirtualMachine) {
    display?.close()
    display = MacNativeDisplay(machine: vm, personAllowed: personAllowed, personActed: personActed)
    startAutomaticSetup()
  }
  private func setSetup(_ phase: MacSetupPhase) {
    setupPhase = phase
    isReady = phase == .ready
    if isReady, var record, record.prepared != true {
      record.prepared = true
      do { try write(JSONEncoder().encode(record), to: file("machine.json")) }
      catch {
        isReady = false
        setupPhase = .needsPerson("Serein could not save its Mac’s setup. Check the storage and continue setup.")
        progress(setupPhase.message); setupChanged(setupPhase)
        return
      }
    }
    progress(phase.message)
    setupChanged(phase)
  }
  /// The app owns preparation. No agent is started or given tools until the signed bridge
  /// has answered and the native display is available.
  private func startAutomaticSetup() {
    readiness?.cancel()
    guard let display else { return }
    heardFromGuest = false
    guestSilent = false
    guestOutdated = false
    setSetup(.connecting)
    readiness = Task { @MainActor [weak self] in
      do {
        // A cold boot on a busy Mac can take longer than the wait the person is shown. Past it
        // the card says so (with Restart), but Serein keeps listening: a Mac that answers late
        // still becomes ready by itself.
        let started = Date()
        var told = false
        var outdatedSince: Date?
        while Date().timeIntervalSince(started) < Self.keepListening {
          try Task.checkCancellation()
          if let since = outdatedSince, Date().timeIntervalSince(since) >= Self.outdatedWait, let self {
            self.guestOutdated = true
            self.setSetup(.needsPerson(Self.outdatedMessage))
            return
          }
          if !told, Date().timeIntervalSince(started) >= Self.connectWait, let self {
            told = true
            self.guestSilent = !self.heardFromGuest
            self.setSetup(.needsPerson(self.guestSilent ? Self.silentMessage
              : "Serein’s Mac did not finish connecting. Continue setup to retry; its files are kept."))
          }
          guard let self, ComputerPolicy.isEnabled(), self.isRunning else { return }
          let answer: [String: String]?
          do { answer = try await self.status(); outdatedSince = nil }
          catch is OutdatedGuest { answer = nil; outdatedSince = outdatedSince ?? Date() }
          catch { answer = nil }
          if let status = answer {
            if status["nativeHost"] != "true" {
              _ = try? await self.mailbox?.call(MacGuestRequest(action: "native_host", timeout: 2))
            } else if (self.record?.offlineSetupVersion == nil || (status["setupComplete"] == "true"
              && status["offlineSetupVersion"] == String(MacOfflineSetup.version) && status["sessionUser"] == "serein")),
              let image = try? display.image(), MacNativeDisplay.hasContent(image) {
              self.finishSetup()
              return
            }
          }
          try await Task.sleep(nanoseconds: told ? 2_000_000_000 : 500_000_000)
        }
        guard let self, !told else { return }
        self.guestSilent = !self.heardFromGuest
        self.setSetup(.needsPerson(self.guestSilent ? Self.silentMessage
          : "Serein’s Mac did not finish connecting. Continue setup to retry; its files are kept."))
      }
      catch is CancellationError {}
      catch {
        self?.setSetup(.needsPerson("Serein could not finish Mac setup automatically. Continue setup to retry."))
      }
    }
  }
  /// Ready, unless setup finished just now on one of its offline boots and the network is on (the
  /// default): then the Mac is marked set up and waits for ComputerHost's one restart, so its
  /// next boot, and the person's first session, has the network. With the person's Off, no restart.
  private func finishSetup() {
    guard var record, record.prepared != true, !bootedOnline, internet() else { setSetup(.ready); return }
    record.prepared = true
    do { try write(JSONEncoder().encode(record), to: file("machine.json")) } catch { setSetup(.ready); return }
    wantsOnlineBoot = true
    setSetup(.connecting)
    progress("Restarting Serein’s Mac with its network…")
  }
  /// The restart for the network could not run: the Mac is ready offline now, online from its next start.
  func readyOffline() {
    guard wantsOnlineBoot else { return }
    wantsOnlineBoot = false
    setSetup(.ready)
  }
  func pauseAutomaticSetup() {
    guard !isReady else { return }
    readiness?.cancel()
    setSetup(.needsPerson("Setup is paused while you use the Mac. Continue automatic setup when you’re ready."))
  }
  /// Called only by the native agreement choice. No agent tool can authorize a license.
  func approveSetupAgreement() {
    guard ComputerPolicy.isEnabled(), setupPhase == .agreement else { return }
    GateSettings.shared.set(true, forKey: ComputerPolicy.macOSLicenseKey)
    setupAgreementApproved = true
  }
  func continueAutomaticSetup() {
    guard !isReady, isRunning else { return }
    startAutomaticSetup()
  }
  func preview() throws -> Data {
    guard let display, isRunning else { throw SereinError.invalid("The virtual Mac is not running.") }
    display.wake()
    return try display.png()
  }
  /// The helper answered as a different build than the one this Serein ships.
  private struct OutdatedGuest: LocalizedError {
    var errorDescription: String? { "Serein is reconnecting its virtual Mac’s text connection." }
  }
  private func status() async throws -> [String: String] {
    guard let mailbox, machine?.state == .running else { throw SereinError.invalid("The virtual Mac is not running.") }
    let values = try await mailbox.call(MacGuestRequest(action: "status", timeout: 2)).values
    heardFromGuest = true
    guard values["build"] == expectedBuild else { throw OutdatedGuest() }
    return values
  }
  #if DEBUG
  func verificationStatus() async throws -> [String: String] { try await status() }
  var verificationDisplay: String { display?.verificationState ?? "no renderer" }
  func verificationPowerOff() async throws {
    guard folder.lastPathComponent.hasPrefix("serein-offline-check-"), GateSettings.shared.fileURL == nil,
      hasCompletedSetup, !isInstalling, let vm = machine, vm.canStop else {
      throw SereinError.invalid("Power-cycle verification requires a prepared, dedicated test Mac.")
    }
    readiness?.cancel(); isReady = false
    try await vm.stop()
    machine = nil
    display?.close(); display = nil
  }
  #endif
  func screen(_ op: String, _ arguments: [String: Any]) async throws -> [String: Any] {
    guard let capability = admission() else { throw SereinError.invalid("The task no longer has control of the virtual Mac.") }
    guard isReady, let display, machine?.state == .running else { throw SereinError.invalid(setupHelp) }
    guard !acting else { throw SereinError.invalid("Wait for the previous virtual Mac step to finish.") }
    acting = true
    defer { acting = false }
    try await Task.sleep(nanoseconds: 300_000_000)
    try Task.checkCancellation()
    guard admission() == capability, machine?.state == .running, self.display === display else {
      throw SereinError.invalid("The task's access to the virtual Mac changed. Look again before continuing.")
    }
    switch op {
    case "screenshot":
      if display.wake() { try await Task.sleep(nanoseconds: 300_000_000) }
      guard admission() == capability else { throw SereinError.invalid("The task no longer has control of the virtual Mac.") }
      return ["png": try display.png().base64EncodedString()]
    case "click":
      guard let x = (arguments["x"] as? NSNumber)?.doubleValue, let y = (arguments["y"] as? NSNumber)?.doubleValue else {
        throw SereinError.invalid("The click must name a point in the latest virtual Mac screenshot.")
      }
      try await display.click(x: x, y: y, button: arguments["button"] as? String ?? "left", twice: arguments["double"] as? Bool ?? false,
        allowed: { self.admission() == capability })
    case "key":
      guard let key = arguments["key"] as? String else { throw SereinError.invalid("Provide a virtual Mac key.") }
      try display.key(key)
    case "scroll":
      guard let x = (arguments["x"] as? NSNumber)?.doubleValue, let y = (arguments["y"] as? NSNumber)?.doubleValue,
        let direction = arguments["direction"] as? String else { throw SereinError.invalid("Provide a point and scroll direction.") }
      try display.scroll(x: x, y: y, direction: direction, amount: max(1, min(30, (arguments["amount"] as? NSNumber)?.intValue ?? 3)))
    case "type", "open_url":
      guard let mailbox, let state = try? await status(), state["nativeHost"] == "true" else {
        guard admission() == capability else { throw SereinError.invalid("The task no longer has control of the virtual Mac.") }
        startAutomaticSetup()
        throw SereinError.invalid("Serein is reconnecting its Mac's text connection. Try again when setup finishes.")
      }
      guard admission() == capability else { throw SereinError.invalid("The task no longer has control of the virtual Mac.") }
      var args: [String: String] = [:]
      if op == "type" {
        guard let text = arguments["text"] as? String, text.utf8.count <= 32768 else {
          throw SereinError.invalid("Provide at most 32 KiB of text for the virtual Mac.")
        }
        args["text"] = text
      } else {
        guard let raw = arguments["url"] as? String, let url = URL(string: raw),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else {
          throw SereinError.invalid("Provide a website address for the virtual Mac.")
        }
        args["url"] = raw
      }
      do {
        _ = try await mailbox.call(MacGuestRequest(action: op == "type" ? "clipboard" : "open_url", arguments: args, timeout: 15))
      } catch {
        try Task.checkCancellation()
        guard admission() == capability else { throw SereinError.invalid("The task no longer has control of the virtual Mac.") }
        startAutomaticSetup()
        throw SereinError.invalid("Serein is reconnecting its Mac’s text connection. Its app handles this automatically.")
      }
      try Task.checkCancellation()
      guard admission() == capability else { throw SereinError.invalid("The task no longer has control of the virtual Mac.") }
      if op == "type" { try display.key("Cmd+v") }
    default: throw SereinError.invalid(MacComputerPolicy.unsupportedTool)
    }
    return [:]
  }
  /// Shell and files on the virtual Mac (MacGuestShell): asked of the guest app through the
  /// mailbox, as the task holding the Mac. A guest too old to know the action says so.
  func shell(_ op: String, _ arguments: [String: String], timeout: Int) async throws -> [String: String] {
    guard admission() != nil else { throw SereinError.invalid("The task no longer has control of the virtual Mac.") }
    guard isReady, let mailbox, machine?.state == .running else { throw SereinError.invalid(setupHelp) }
    do {
      return try await mailbox.call(MacGuestRequest(action: op, arguments: arguments, timeout: TimeInterval(timeout))).values
    } catch is MacMailboxTimeout {
      throw SereinError.invalid("Serein's virtual Mac did not answer within \(timeout) seconds.")
    } catch let failure as MacGuestFailure {
      throw SereinError.invalid(failure.message)
    }
  }
  /// A file from the virtual Mac for the Outbox: the guest copies it into the exchange, and it is
  /// read once and removed.
  func fileOut(_ path: String) async throws -> (name: String, data: Data) {
    let values = try await shell("file_out", ["path": path], timeout: 120)
    guard let out = values["out"], let mailbox else { throw SereinError.invalid("The virtual Mac sent no file.") }
    defer { mailbox.remove(out) }
    guard let data = try mailbox.read(out, limit: Int(MacGuestShell.fileLimit)) else {
      throw SereinError.invalid("The virtual Mac sent no file.")
    }
    return (values["name"] ?? "File", data)
  }
  nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    Task { @MainActor in
      guard self.machine === virtualMachine else { return }
      self.readiness?.cancel(); self.machine = nil; self.isReady = false
      self.display?.close(); self.display = nil; self.stopped()
    }
  }
  nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { guestDidStop(virtualMachine) }
}
