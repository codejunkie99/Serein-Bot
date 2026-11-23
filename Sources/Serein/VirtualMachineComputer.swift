import AppKit
import Darwin
import Foundation
import Security
import SereinCore
import SwiftUI
import Virtualization

/// Serein's built-in computer (ComputerPlace.builtIn): a Debian virtual machine Serein runs
/// itself with Apple's Virtualization framework (no other software), the default when no Docker
/// engine is found. It has no network device at all; its one link to Serein is a virtio
/// socket, where the helper's link (`serein-helper.py --vsock`) accepts only this Mac and starts
/// the helper, the proxy shim or a command per connection (ExecStream over a duplicate of the
/// connection's descriptor). So every site it reaches goes through ComputerProxy, with the
/// person's site rules, the assistant's Never sites and the private-range refusals. Its files live
/// in the Library under `computers/<id>/` (0700, files 0600): a 10 GB sparse disk cloned from the
/// verified image (BuiltInImage), the cloud-init seed Serein wrote, its firmware variables and
/// machine identity, `fresh.img` (the disk right after setup, what a reset without a checkpoint
/// goes back to), and the saved memory of a pause and of the checkpoint.
@MainActor final class VirtualMachineComputer: ComputerBackend {
  let capabilities = ComputerCapabilities.builtIn
  /// The machine while it is on, for the screen (VirtualMachineScreen); nil while it is off.
  private(set) var machine: VZVirtualMachine?
  private let folder: URL
  /// The verified base image, once it is on this Mac.
  private let image: () -> URL?
  /// The proxy's rules while the computer is set up: Debian's package archive only (VirtualMachinePolicy.setupRefusal).
  private let setupRules: ComputerProxy.Rules
  /// A line for Settings and the panel while it is set up or starts; nil once it runs.
  private let progress: (String?) -> Void
  /// The person's read-only shared folder (ComputerSharedFolder), checked again whenever a machine
  /// is made; nil for none.
  private let shared: () -> URL?
  /// The memory and processors the machine on now was made with; a saved state needs the same.
  private var bootedHardware: Hardware?
  /// Whether the framework can save this machine's memory; without it a pause shuts it down cleanly.
  /// `saveMachineStateTo` and `restoreMachineStateFrom` exist only on Apple silicon.
  #if arch(arm64)
  private var canSave = true
  #else
  private var canSave = false
  #endif
  private let fm = FileManager.default

  private struct Hardware: Codable, Equatable {
    var memoryMB: Int
    var cpus: Int
  }
  private struct Identity: Codable {
    var machine: Data
    var instance: String
  }

  init(
    folder: URL, image: @escaping () -> URL?, setupRules: ComputerProxy.Rules, progress: @escaping (String?) -> Void,
    shared: @escaping () -> URL?
  ) {
    self.folder = folder
    self.image = image
    self.setupRules = setupRules
    self.progress = progress
    self.shared = shared
  }

  /// The guest is Debian for arm64, so only a Mac with Apple silicon runs it.
  nonisolated static var supported: Bool {
    #if arch(arm64)
      return VZVirtualMachine.isSupported
    #else
      return false
    #endif
  }
  /// This build carries the Virtualization entitlement. Without it the machine fails validation,
  /// so a build like `swift run` must not download an image it can't start.
  nonisolated static var entitled: Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    return SecTaskCopyValueForEntitlement(task, "com.apple.security.virtualization" as CFString, nil) as? Bool == true
  }

  private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
  private var disk: URL { file(VirtualMachinePolicy.diskName) }
  private var fresh: URL { file("fresh.img") }
  private var seed: URL { file("seed.iso") }
  private var firmware: URL { file("efi-vars") }
  private var identity: URL { file("machine.json") }
  private var resumeState: URL { file("resume.vzvmsave") }
  private var resumeHardware: URL { file("resume.json") }
  private var checkpointDisk: URL { file("checkpoint.img") }
  private var checkpointState: URL { file("checkpoint.vzvmsave") }
  private var checkpointHardware: URL { file("checkpoint.json") }
  /// Setup finished once (its disk was kept as `fresh.img`).
  var isSetUp: Bool { fm.fileExists(atPath: fresh.path) }
  /// Set up with the boot step that installs the pinned helper from the seed (`serein-boot.service`):
  /// written when such a setup finishes. One set up before it can never run this Serein's helper.
  var hasBootStep: Bool { fm.fileExists(atPath: file("boot-unit").path) }
  /// Set up with the boot step that installs Cua Driver from the seed (and the link that turns
  /// its telemetry off): written when such a setup finishes. One set up before it never gets the
  /// driver, and runs on the helper alone.
  var hasDriverBoot: Bool { fm.fileExists(atPath: file("driver-boot").path) }
  /// Its boot installs the pinned Cua Driver: this copy ships it and the computer has the step.
  var carriesDriver: Bool { hasDriverBoot && ComputerHost.driverShipped }
  var driverCommand: [String]? { CuaDriverPolicy.isOn() ? CuaDriverRelease.mcpCommand : nil }
  var isRunning: Bool { machine?.state == .running }

  // MARK: ComputerBackend

  func start() async throws -> Bool {
    guard Self.supported else { throw SereinError.invalid(VirtualMachinePolicy.unsupported) }
    if let vm = machine {
      switch vm.state {
      case .running: return false
      case .stopped, .error: machine = nil
      default: throw SereinError.invalid("Serein's built-in computer is busy starting, saving or stopping. Try again in a moment.")
      }
    }
    defer { progress(nil) }
    var created = false
    if !isSetUp {
      // A setup cut short (a quit, a crash) starts again from the verified image with a new
      // instance id, so cloud-init runs it all again; nothing of the half-made computer is kept.
      removeSaved(disk, seed, firmware, identity, resumeState, resumeHardware)
      try await makeComputer()
      created = true
      try await setUp()
    }
    // The seed carries this Serein's pinned helper, which the computer's boot installs (a resumed
    // pause keeps the one it had; ComputerHost.checkPins gives that one a fresh boot).
    try await writeSeed()
    progress("Starting the computer…")
    let vm = try await boot()
    // A new line once the machine exists, so the panel shows its screen while the desktop starts.
    progress("Starting the desktop…")
    try await waitForDesktop(vm)
    return created
  }

  func openStream(_ command: [String], stdin: Bool, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream
  {
    guard let vm = machine, vm.state == .running else { throw SereinError.invalid("Serein's built-in computer is not running.") }
    let connection = try await connect(vm, wait: 120)
    return try Self.stream(connection, command, stdin: stdin, framed: false, onStdout: onStdout, onEnd: onEnd)
  }

  func runOnce(_ command: [String], input: URL?, sink: @escaping (Data) -> Void) async throws -> Int {
    guard let vm = machine, vm.state == .running else { throw SereinError.invalid("Serein's built-in computer is not running.") }
    return try await run(vm, command, input: input, sink: sink)
  }

  /// Pause saves the computer's memory to its folder and turns the machine off, so it holds no
  /// memory on this Mac; the next start restores it where it was.
  func pause() async throws {
    guard let vm = machine, vm.state == .running else { return }
    // A machine that has not finished setup is never saved: it stops, and its next start sets it up again.
    guard isSetUp else {
      machine = nil
      try await stop(vm)
      return
    }
    if canSave {
      try await Self.result { vm.pause(completionHandler: $0) }
      do {
        try await save(vm, to: resumeState, hardware: resumeHardware)
      } catch {
        try? await Self.result { vm.resume(completionHandler: $0) }
        throw SereinError.invalid("Serein's built-in computer could not save its state: " + error.localizedDescription)
      }
      try await stop(vm)
    } else {
      try await shutDown(vm)
    }
    machine = nil
  }

  /// Ends every process inside: the machine goes off, and a saved pause is dropped.
  func restart() async throws {
    if let vm = machine {
      machine = nil
      try await stop(vm)
    }
    removeSaved(resumeState, resumeHardware)
  }

  /// The machine goes off and its whole folder is deleted: disk, setup copy, checkpoint, seed.
  func delete() async throws {
    if let vm = machine {
      // Cleared first, so a setup or start still waiting on this machine gives up.
      machine = nil
      try? await stop(vm)
    }
    if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
  }

  /// Quit: ComputerHost.saveForQuit saved it while the app waited; a machine still on now goes off.
  func stopForQuit(paused: Bool) {
    guard let vm = machine, vm.canStop else { return }
    machine = nil
    vm.stop { _ in }
  }

  // MARK: checkpoints (the whole computer, where Docker and E2B keep a home-folder archive)

  /// Saves the computer as it is now, replacing the last checkpoint: its disk, and its memory
  /// when it runs.
  func saveCheckpoint() async throws {
    guard isSetUp else { throw SereinError.invalid("Serein's built-in computer is not set up yet: start it once first.") }
    let diskPart = file("checkpoint.img.part")
    let statePart = file("checkpoint.vzvmsave.part")
    let hardwarePart = file("checkpoint.json.part")
    removeSaved(diskPart, statePart, hardwarePart)
    do {
      if let vm = machine, vm.state != .stopped {
        guard vm.state == .running else { throw SereinError.invalid("Serein's built-in computer is busy. Try again in a moment.") }
        // Memory and disk from the same instant: the machine waits while both are taken.
        try await Self.result { vm.pause(completionHandler: $0) }
        do {
          if canSave { try await save(vm, to: statePart, hardware: hardwarePart) }
          try Self.clone(disk, to: diskPart)
        } catch {
          try? await Self.result { vm.resume(completionHandler: $0) }
          throw error
        }
        try await Self.result { vm.resume(completionHandler: $0) }
      } else {
        try Self.clone(disk, to: diskPart)
        if fm.fileExists(atPath: resumeState.path), fm.fileExists(atPath: resumeHardware.path) {
          try Self.clone(resumeState, to: statePart)
          try Self.clone(resumeHardware, to: hardwarePart)
        }
      }
      removeSaved(checkpointDisk, checkpointState, checkpointHardware)
      try fm.moveItem(at: diskPart, to: checkpointDisk)
      if fm.fileExists(atPath: statePart.path) {
        try fm.moveItem(at: statePart, to: checkpointState)
        try fm.moveItem(at: hardwarePart, to: checkpointHardware)
      }
    } catch {
      removeSaved(diskPart, statePart, hardwarePart)
      throw error
    }
  }

  /// Puts the whole computer back to its checkpoint, or to how it was right after setup when
  /// there is none, and leaves it off; the next start runs it from there.
  func resetToCheckpoint() async throws {
    if let vm = machine {
      machine = nil
      try await stop(vm)
    }
    removeSaved(resumeState, resumeHardware)
    let checkpoint = fm.fileExists(atPath: checkpointDisk.path)
    let source = checkpoint ? checkpointDisk : fresh
    guard fm.fileExists(atPath: source.path) else {
      // Never set up: nothing to go back to, so its own files go and its next start sets it up
      // again. The folder stays: it may hold another place's checkpoint.
      removeSaved(disk, seed, firmware, identity, resumeState, resumeHardware)
      return
    }
    let part = file("disk.img.part")
    removeSaved(part)
    try Self.clone(source, to: part)
    // One step: the disk is the old one or the new one, never missing.
    try Self.replace(disk, with: part)
    if checkpoint, fm.fileExists(atPath: checkpointState.path), fm.fileExists(atPath: checkpointHardware.path) {
      try Self.clone(checkpointState, to: resumeState)
      try Self.clone(checkpointHardware, to: resumeHardware)
    }
  }

  // MARK: making and running the machine

  /// The computer's own files from the verified image: the seed, firmware variables, a machine
  /// identity and the disk (a clone of the image, grown sparsely to 10 GB). Nothing half-made stays.
  private func makeComputer() async throws {
    guard let base = image(), fm.fileExists(atPath: base.path) else { throw SereinError.invalid(VirtualMachinePolicy.notSetUp) }
    try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    let part = file("disk.img.part")
    do {
      let instance = "serein-" + UUID().uuidString.lowercased()
      try writeJSON(Identity(machine: VZGenericMachineIdentifier().dataRepresentation, instance: instance), to: identity)
      try await writeSeed()
      _ = try VZEFIVariableStore(creatingVariableStoreAt: firmware, options: [.allowOverwrite])
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: firmware.path)
      removeSaved(part)
      try Self.clone(base, to: part)
      let size = (try fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
      if size < VirtualMachinePolicy.diskBytes, truncate(part.path, off_t(VirtualMachinePolicy.diskBytes)) != 0 {
        throw SereinError.invalid("The computer's disk could not be made (\(String(cString: strerror(errno)))).")
      }
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: part.path)
      try fm.moveItem(at: part, to: disk)
    } catch {
      removeSaved(part, disk, seed, firmware, identity)
      throw error
    }
  }

  /// The NoCloud seed: `user-data` and `meta-data`, the helper the computer's boot installs
  /// (`VirtualMachineSeed.helperFile`) and, when this copy ships it, Cua Driver with its licence and
  /// notices, on a small ISO disk labelled `cidata`, made by macOS's own disk image tool from a
  /// folder of Serein's (removed after). Written when the computer is made and again before each
  /// start, with the instance id it was made with and the pinned files. The files are read,
  /// checked against their pins and written off the main actor (the driver is about 56 MB).
  private func writeSeed() async throws {
    guard let saved = readJSON(Identity.self, from: identity), let meta = VirtualMachineSeed.metaData(instanceID: saved.instance)
    else { throw SereinError.invalid("The seed could not be written.") }
    let source = file("seed-files")
    defer { removeSaved(source) }
    try await Task.detached(priority: .userInitiated) {
      let helper = try ComputerHost.shippedFile("serein-helper", "py")
      let driver = try ComputerHost.shippedDriver()
      let files: [(String, Data)] = [
        ("user-data", Data(VirtualMachineSeed.userData(helper: helper).utf8)), ("meta-data", Data(meta.utf8)),
      ] + VirtualMachineSeed.extraFiles(helper: helper, driver: driver)
      try VirtualMachineComputer.writeFiles(files, into: source)
    }.value
    let made = file("seed-new.iso")
    removeSaved(made)
    try await Self.tool(
      "/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", made.path, source.path])
    removeSaved(seed)
    try fm.moveItem(at: made, to: seed)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seed.path)
  }

  /// The machine's configuration: EFI with its own variable store, the disk and the read-only
  /// seed, a virtio socket, a screen of the tools' size, a keyboard and a pointer, an entropy
  /// source, and the person's shared folder over virtio-fs read-only when they picked one. No
  /// network device, no other shared folder, no clipboard, no sound.
  private func makeMachine(_ hardware: Hardware) throws -> VZVirtualMachine {
    guard let saved = readJSON(Identity.self, from: identity),
      let machineID = VZGenericMachineIdentifier(dataRepresentation: saved.machine)
    else { throw SereinError.invalid("The computer's identity file is missing; delete it in Settings › Serein's computer and start again.") }
    let config = VZVirtualMachineConfiguration()
    let platform = VZGenericPlatformConfiguration()
    platform.machineIdentifier = machineID
    config.platform = platform
    let boot = VZEFIBootLoader()
    boot.variableStore = VZEFIVariableStore(url: firmware)
    config.bootLoader = boot
    config.cpuCount = min(max(hardware.cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                          VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    config.memorySize = min(max(UInt64(hardware.memoryMB) * 1_048_576, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                            VZVirtualMachineConfiguration.maximumAllowedMemorySize)
    // Automatic and uncached I/O corrupted the guest filesystem during first boot on Apple silicon.
    // Cache the writable disk and honor guest flushes through to persistent storage.
    let rootDisk = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false, cachingMode: .cached, synchronizationMode: .full)
    config.storageDevices = [
      VZVirtioBlockDeviceConfiguration(attachment: rootDisk),
      VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true)),
    ]
    config.networkDevices = []
    config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    if let sharedFolder = shared() {
      // Read-only on this Mac's side: nothing inside can write to it, whatever its own mount says.
      let share = VZVirtioFileSystemDeviceConfiguration(tag: ComputerSharedFolder.tag)
      share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: sharedFolder, readOnly: true))
      config.directorySharingDevices = [share]
    }
    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [
      VZVirtioGraphicsScanoutConfiguration(widthInPixels: ComputerPolicy.screenWidth, heightInPixels: ComputerPolicy.screenHeight)
    ]
    config.graphicsDevices = [graphics]
    config.keyboards = [VZUSBKeyboardConfiguration()]
    config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    do { try config.validate() } catch let error where VirtualMachinePolicy.missingEntitlement(error.localizedDescription) {
      throw SereinError.invalid(VirtualMachinePolicy.unsigned)
    }
    #if arch(arm64)
    canSave = (try? config.validateSaveRestoreSupport()) != nil
    #else
    canSave = false
    #endif
    bootedHardware = hardware
    return VZVirtualMachine(configuration: config)
  }

  /// The memory and processors from Settings, for a machine that starts from off.
  private func currentHardware() -> Hardware {
    Hardware(
      memoryMB: VirtualMachinePolicy.memoryMB(totalBytes: ProcessInfo.processInfo.physicalMemory),
      cpus: ComputerPolicy.cpus(cores: ProcessInfo.processInfo.activeProcessorCount))
  }

  /// Turns the machine on: from a saved pause when there is one (with the memory and processors
  /// it was saved with), else from off. A saved state is used once and removed either way, since
  /// it no longer matches the disk after that; one that does not restore leaves a start from off.
  private func boot() async throws -> VZVirtualMachine {
    // Only a computer that finished setup is ever restored.
    let saved = isSetUp && fm.fileExists(atPath: resumeState.path) ? readJSON(Hardware.self, from: resumeHardware) : nil
    let vm = try makeMachine(saved ?? currentHardware())
    machine = vm
    if saved != nil {
      defer { removeSaved(resumeState, resumeHardware) }
      // Restore is Apple silicon only. An Intel slice drops the file and starts from off.
      #if arch(arm64)
      do {
        try await Self.call { vm.restoreMachineStateFrom(url: resumeState, completionHandler: $0) }
        try await Self.result { vm.resume(completionHandler: $0) }
        return vm
      } catch {
        guard machine === vm, vm.state == .stopped else { throw error }
      }
      #endif
    }
    try await Self.result { vm.start(completionHandler: $0) }
    return vm
  }

  /// First boot from the seed: the setup script installs the desktop, the browser and the helper's
  /// link through a proxy that reaches Debian's package archive only, then cloud-init powers the computer
  /// off. Its disk is then kept as `fresh.img`. Delete (or Cancel) ends the wait.
  private func setUp() async throws {
    let began = Date()
    progress("Setting up: starting the computer for the first time…")
    let vm = try await boot()
    var proxy: ProxyMux?
    defer { proxy?.close() }
    while true {
      guard machine === vm else { throw SereinError.invalid(VirtualMachinePolicy.setupCancelled) }
      if vm.state == .stopped { break }
      if vm.state == .error { throw SereinError.invalid("Serein's built-in computer stopped with an error while it was set up.") }
      let minutes = Int(Date().timeIntervalSince(began) / 60)
      guard Date().timeIntervalSince(began) < VirtualMachinePolicy.setupLimit else {
        machine = nil
        try? await stop(vm)
        throw SereinError.invalid("Setting up Serein's built-in computer took more than 45 minutes, so Serein stopped it. Delete it in Settings › Serein's computer and try again.")
      }
      if proxy?.isOpen != true, let link = try? await connect(vm, wait: 0) {
        let mux = ProxyMux(rules: setupRules)
        if let stream = try? Self.stream(
          link, ["python3", "-I", VirtualMachineSeed.helperPath, "--proxy"], stdin: true, framed: false,
          onStdout: mux.sink, onEnd: mux.ender)
        {
          mux.attach(stream)
          proxy = mux
        }
      }
      // The setup script's state, once its link is up.
      var said = Data()
      var code = -1
      if proxy != nil { code = (try? await run(vm, ["cat", VirtualMachineSeed.setupState], input: nil) { said.append($0) }) ?? -1 }
      let state = String(decoding: said.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      if code == 0, state.hasPrefix("failed: ") {
        machine = nil
        try? await stop(vm)
        let reason = String(state.dropFirst("failed: ".count).filter { $0.isASCII && !$0.isNewline && $0 != "\0" }.prefix(160))
        throw SereinError.invalid("Setting up Serein's built-in computer failed: \(reason). Delete it in Settings › Serein's computer and try again.")
      }
      progress(code == 0 && state == "running"
        ? "Setting up: installing the desktop and Chromium from Debian's archive (\(minutes) min so far)…"
        : "Setting up: the computer is starting for the first time (\(minutes) min so far)…")
      try await Task.sleep(nanoseconds: 5_000_000_000)
    }
    machine = nil
    // `fresh.img` marks setup as finished, so it appears whole or not at all.
    let part = file("fresh.img.part")
    removeSaved(part)
    try Self.clone(disk, to: part)
    // This setup installed the boot step, so later helper changes reach it with a fresh boot. Marked
    // before `fresh.img`, which ends setup: a cut here only means setup runs again.
    // It also installed the boot step for Cua Driver and the link with the driver's telemetry off.
    let marked = ["boot-unit", "driver-boot"].allSatisfy {
      fm.createFile(atPath: file($0).path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }
    guard marked else {
      removeSaved(part)
      throw SereinError.invalid("Serein could not mark the computer as set up.")
    }
    try Self.replace(fresh, with: part)
  }

  /// Waits until the desktop inside is up (its session writes the ready mark), so the helper finds
  /// its display at once.
  private func waitForDesktop(_ vm: VZVirtualMachine) async throws {
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
      guard machine === vm, vm.state == .running else { throw SereinError.invalid("Serein's built-in computer stopped while it started.") }
      if (try? await run(vm, ["test", "-e", "/tmp/serein/ready"], input: nil) { _ in }) == 0 { return }
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    throw SereinError.invalid("The desktop inside Serein's built-in computer did not come up in time.")
  }

  // MARK: the link

  /// A connection to the helper's link inside, tried again each second for up to `wait` seconds
  /// while the machine is on (the link starts a few seconds after the machine does).
  private func connect(_ vm: VZVirtualMachine, wait seconds: TimeInterval) async throws -> VZVirtioSocketConnection {
    guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
      throw SereinError.invalid("Serein's built-in computer has no link device.")
    }
    let deadline = Date().addingTimeInterval(seconds)
    while true {
      do {
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<VZVirtioSocketConnection, Error>) in
          device.connect(toPort: VirtualMachinePolicy.linkPort) { done.resume(with: $0) }
        }
      } catch {
        guard Date() < deadline, machine === vm, vm.state == .running else {
          throw SereinError.invalid("Serein's built-in computer is not answering on its link.")
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  /// One command over a connection: its first line says what to run, then the stream carries its
  /// stdin and stdout (raw for the helper and the shim, framed with the exit code for `run`). The
  /// stream reads a duplicate of the descriptor and keeps the connection, which owns the original.
  private nonisolated static func stream(
    _ connection: VZVirtioSocketConnection, _ command: [String], stdin: Bool, framed: Bool,
    onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void
  ) throws -> ExecStream {
    let fd = dup(connection.fileDescriptor)
    guard fd >= 0 else { throw SereinError.invalid("The link to Serein's built-in computer could not be opened.") }
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    let stream = ExecStream(fd: fd, rest: Data(), framed: framed, keep: connection, onStdout: onStdout, onEnd: onEnd)
    let request = Data(jsonString(["argv": command, "stdin": stdin, "framed": framed] as [String: Any]).utf8) + Data([10])
    guard stream.write(request) else {
      stream.close()
      throw SereinError.invalid("The link to Serein's built-in computer closed.")
    }
    return stream
  }

  /// One command to its end: `input` streamed to its stdin in 1 MB pieces, its stdout to `sink`;
  /// its exit code, or -1 when the link ended first.
  private func run(_ vm: VZVirtualMachine, _ command: [String], input: URL?, sink: @escaping (Data) -> Void) async throws -> Int {
    let connection = try await connect(vm, wait: 30)
    // The stream may end before it is stored (a fast command): the first end resumes, whenever it comes.
    final class Holder {
      let lock = NSLock()
      var done = false
      var stream: ExecStream?
      func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let first = !done
        done = true
        return first
      }
    }
    let holder = Holder()
    try await withCheckedThrowingContinuation { (finished: CheckedContinuation<Void, Error>) in
      do {
        let exec = try Self.stream(connection, command, stdin: input != nil, framed: true, onStdout: sink, onEnd: {
          if holder.first() { finished.resume() }
        })
        holder.lock.lock()
        holder.stream = exec
        holder.lock.unlock()
        Task.detached {
          if let input, let file = try? FileHandle(forReadingFrom: input) {
            while let piece = try? file.read(upToCount: 1_048_576), !piece.isEmpty {
              guard exec.write(piece) else { break }
            }
            try? file.close()
          }
          exec.closeWrite()
        }
      } catch {
        if holder.first() { finished.resume(throwing: error) }
      }
    }
    holder.lock.lock()
    let code = holder.stream?.exitCode ?? -1
    holder.stream = nil
    holder.lock.unlock()
    return code
  }

  // MARK: helpers

  /// Saves the paused machine's memory and the hardware it needs to be restored.
  private func save(_ vm: VZVirtualMachine, to state: URL, hardware: URL) async throws {
    removeSaved(state, hardware)
    #if arch(arm64)
    try await Self.call { vm.saveMachineStateTo(url: state, completionHandler: $0) }
    #else
    throw SereinError.invalid(VirtualMachinePolicy.unsupported)
    #endif
    try writeJSON(bootedHardware ?? currentHardware(), to: hardware)
    if fm.fileExists(atPath: state.path) { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path) }
  }
  private func stop(_ vm: VZVirtualMachine) async throws {
    guard vm.canStop else { return }
    try await Self.call { vm.stop(completionHandler: $0) }
  }
  /// A clean shutdown from inside (the power button), turned off after a minute if it did not.
  private func shutDown(_ vm: VZVirtualMachine) async throws {
    if vm.canRequestStop, (try? vm.requestStop()) != nil {
      for _ in 0..<60 where vm.state != .stopped { try? await Task.sleep(nanoseconds: 1_000_000_000) }
    }
    if vm.state != .stopped { try await stop(vm) }
  }
  private func removeSaved(_ urls: URL...) {
    for url in urls { try? fm.removeItem(at: url) }
  }
  private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  /// A copy-on-write clone (APFS `clonefile`), or a plain copy where the volume cannot clone. The
  /// source's written blocks are flushed first, so the clone holds them.
  nonisolated static func clone(_ source: URL, to target: URL) throws {
    let fd = Darwin.open(source.path, O_RDONLY)
    if fd >= 0 {
      _ = fcntl(fd, F_FULLFSYNC)
      Darwin.close(fd)
    }
    if clonefile(source.path, target.path, 0) == 0 { return }
    guard errno == ENOTSUP || errno == EXDEV else {
      throw SereinError.invalid("\(source.lastPathComponent) could not be copied (\(String(cString: strerror(errno)))).")
    }
    try FileManager.default.copyItem(at: source, to: target)
  }

  /// The seed's files in a new folder of Serein's own (0700, each file 0600); an older folder of
  /// that name goes first.
  nonisolated static func writeFiles(_ files: [(String, Data)], into folder: URL) throws {
    let fm = FileManager.default
    try? fm.removeItem(at: folder)
    try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for (name, data) in files {
      let target = folder.appendingPathComponent(name)
      try data.write(to: target, options: .atomic)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
  }

  /// Moves `part` over `target` in one step (rename replaces atomically); `part` goes on failure.
  nonisolated static func replace(_ target: URL, with part: URL) throws {
    guard Darwin.rename(part.path, target.path) == 0 else {
      let reason = String(cString: strerror(errno))
      try? FileManager.default.removeItem(at: part)
      throw SereinError.invalid("\(target.lastPathComponent) could not be replaced (\(reason)).")
    }
  }

  /// Runs one of macOS's own tools with fixed arguments, off the main actor; throws on a failure.
  nonisolated static func tool(_ path: String, _ arguments: [String]) async throws {
    let status: Int32 = try await Task.detached {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = arguments
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    }.value
    guard status == 0 else { throw SereinError.invalid("\(URL(fileURLWithPath: path).lastPathComponent) failed (code \(status)).") }
  }

  /// The framework's completion handlers as async calls: those that pass a Result, and those that
  /// pass an optional error.
  private static func result(_ body: (@escaping (Result<Void, Error>) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in body { done.resume(with: $0) } }
  }
  private static func call(_ body: (@escaping (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
      body { error in
        if let error { done.resume(throwing: error) } else { done.resume() }
      }
    }
  }
}

/// The built-in computer's own screen: the framework's view of its display, inside the
/// assistant's panel or, while it is open, the detached window only (no VNC, no listening port).
/// While the person only watches, every pointer, scroll and key event stops here, hover included,
/// and the view never takes the keyboard; after Take over they reach the computer directly, and
/// each kind is noted for the Hand back summary.
struct VirtualMachineScreen: NSViewRepresentable {
  @ObservedObject var computer: ComputerHost.Computer
  let machine: VZVirtualMachine
  func makeNSView(context: Context) -> WatchedScreen { WatchedScreen(frame: .zero) }
  func updateNSView(_ view: WatchedScreen, context: Context) {
    view.show(machine, for: computer, interactive: computer.control == .person)
  }
  static func dismantleNSView(_ view: WatchedScreen, coordinator: ()) { view.show(nil, for: nil, interactive: false) }

  final class WatchedScreen: VZVirtualMachineView {
    private weak var computer: ComputerHost.Computer?
    private(set) var interactive = false
    private var wakeObserver: NSObjectProtocol?
    private var displayWakeTimer: Timer?
    private var displayNeedsWake = false
    private var wakeScheduled = false
    private var lastPersonInput = Date.distantPast

    override init(frame: NSRect) {
      super.init(frame: frame)
      capturesSystemKeys = false
    }
    required init?(coder: NSCoder) { return nil }

    func show(_ machine: VZVirtualMachine?, for computer: ComputerHost.Computer?, interactive: Bool) {
      let opening = virtualMachine !== machine || (interactive && !self.interactive)
      if virtualMachine !== machine { virtualMachine = machine }
      self.computer = computer
      self.interactive = interactive && machine != nil
      capturesSystemKeys = self.interactive && computer?.place == .macOS
      if !self.interactive || computer?.place != .macOS {
        displayNeedsWake = false
        displayWakeTimer?.invalidate()
        displayWakeTimer = nil
      } else {
        if opening { displayNeedsWake = true }
        if displayWakeTimer == nil {
          let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
              guard let self, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor,
                Date().timeIntervalSince(self.lastPersonInput) > 15 else { return }
              self.displayNeedsWake = true
              self.scheduleDisplayWake()
            }
          }
          RunLoop.main.add(timer, forMode: .common)
          displayWakeTimer = timer
        }
      }
      scheduleDisplayWake()
      // Watching forwards nothing: the screen loses the keyboard as soon as control goes back.
      if !self.interactive, window?.firstResponder === self { window?.makeFirstResponder(nil) }
      if machine == nil, let wakeObserver {
        NotificationCenter.default.removeObserver(wakeObserver)
        self.wakeObserver = nil
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
      wakeObserver = nil
      if let window {
        wakeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
          object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, self.interactive, self.computer?.place == .macOS else { return }
            self.displayNeedsWake = true
            self.scheduleDisplayWake()
          }
        }
      }
      scheduleDisplayWake()
    }
    override func layout() {
      super.layout()
      scheduleDisplayWake()
    }
    private func scheduleDisplayWake() {
      guard displayNeedsWake, !wakeScheduled, window != nil, bounds.width > 0, bounds.height > 0,
        virtualMachine?.state == .running else { return }
      wakeScheduled = true
      // The native display's input channel connects after the AppKit view is attached.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self else { return }
        self.wakeScheduled = false
        self.wakeDisplay()
      }
    }
    /// Modifier-flags updates alone do not wake a sleeping macOS display. Send a complete
    /// bare Control key press/release to the guest's input channel instead. It produces no
    /// text, button press or host event, and never changes the host's keyboard focus.
    private func wakeDisplay() {
      let flags = NSEvent.modifierFlags
      guard displayNeedsWake, interactive, computer?.place == .macOS, let window,
        virtualMachine?.state == .running, window.isVisible, !isHiddenOrHasHiddenAncestor,
        Date().timeIntervalSince(lastPersonInput) > 1, NSEvent.pressedMouseButtons == 0,
        flags.intersection([.command, .option, .shift, .control, .function]).isEmpty,
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(.control),
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59),
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)
      else { return }
      displayNeedsWake = false
      super.keyDown(with: down)
      super.keyUp(with: up)
    }

    // Every input event reaches the computer only while the person has control.
    override var acceptsFirstResponder: Bool { interactive && super.acceptsFirstResponder }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { interactive }
    override func mouseMoved(with event: NSEvent) { if interactive { super.mouseMoved(with: event) } }
    override func mouseDragged(with event: NSEvent) { if interactive { super.mouseDragged(with: event) } }
    override func rightMouseDragged(with event: NSEvent) { if interactive { super.rightMouseDragged(with: event) } }
    override func otherMouseDragged(with event: NSEvent) { if interactive { super.otherMouseDragged(with: event) } }
    override func mouseEntered(with event: NSEvent) { if interactive { super.mouseEntered(with: event) } }
    override func mouseExited(with event: NSEvent) { if interactive { super.mouseExited(with: event) } }
    override func mouseDown(with event: NSEvent) {
      guard interactive else { return }
      window?.makeFirstResponder(self)
      note("clicked")
      super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) { if interactive { super.mouseUp(with: event) } }
    override func rightMouseDown(with event: NSEvent) {
      guard interactive else { return }
      window?.makeFirstResponder(self)
      note("clicked")
      super.rightMouseDown(with: event)
    }
    override func rightMouseUp(with event: NSEvent) { if interactive { super.rightMouseUp(with: event) } }
    override func otherMouseDown(with event: NSEvent) {
      guard interactive else { return }
      window?.makeFirstResponder(self)
      note("clicked")
      super.otherMouseDown(with: event)
    }
    override func otherMouseUp(with event: NSEvent) { if interactive { super.otherMouseUp(with: event) } }
    override func scrollWheel(with event: NSEvent) { if interactive { note("scrolled"); super.scrollWheel(with: event) } }
    override func keyDown(with event: NSEvent) { if interactive { note("typed or pressed keys"); super.keyDown(with: event) } }
    override func keyUp(with event: NSEvent) { if interactive { super.keyUp(with: event) } }
    override func flagsChanged(with event: NSEvent) { if interactive { super.flagsChanged(with: event) } }

    /// Record only input actually forwarded by this view. Wake pulses call super directly,
    /// so they never become person activity or postpone the host's normal idle deadline.
    private func note(_ step: String) {
      guard interactive, let computer else { return }
      lastPersonInput = Date()
      ComputerHost.shared.personActed(computer, step: step)
    }
  }
}
