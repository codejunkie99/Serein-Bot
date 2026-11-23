import Foundation
import SereinCore

extension ComputerHost {
  /// Save checkpoint: the home folder as an archive in the Library (0600), replacing the last.
  func saveCheckpoint(_ computer: Computer) async {
    guard computer.place != .macOS else { notice = "Virtual Mac checkpoints are not available yet."; return }
    guard computer.place.capabilities.isolated else {
      notice = "Serein keeps no checkpoint of your own machine."
      return
    }
    guard !computer.resetting, !computer.busy, computer.holder == nil, computer.control == .assistant else {
      notice = "Finish the current task or hand back the computer before saving a checkpoint."
      return
    }
    computer.resetting = true
    defer { computer.resetting = false }
    guard !computer.restoreOwed else {
      notice = "The checkpoint was not put back yet; start the computer again first."
      return
    }
    guard let root, let machine = self.machine(for: computer) else { return }
    if let whole = machine as? VirtualMachineComputer {
      do {
        try await whole.saveCheckpoint()
        computer.lastUsed = Date()
        computer.hasCheckpoint = true
        notice = "Checkpoint saved for \(assistantName(computer.id))'s computer."
      } catch {
        notice = "The checkpoint could not be saved: " + error.localizedDescription
      }
      return
    }
    do {
      try await ensureRunning(computer)
      computer.lastUsed = Date()
      let folder = root.appendingPathComponent(computer.id, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let kept = folder.appendingPathComponent("checkpoint.tar")
      let output = try CheckpointOutput(replacing: kept)
      let owned = machine as? OwnedHomeCheckpoint
      let code: Int
      if let owned {
        code = try await owned.checkpoint(.save, input: nil, sink: output.append)
      } else {
        code = try await machine.runOnce(["tar", "--mode=ug-s", "--exclude=./.Xauthority", "-C", "/home/serein", "-cf", "-", "."], input: nil, sink: output.append)
      }
      guard code == 0 else { throw SereinError.invalid("The checkpoint could not read every file (code \(code)). The previous checkpoint is kept.") }
      try output.finish()
      try CheckpointOperation.verifyEnvelope(output.url)
      if let owned, try await owned.checkpoint(.check, input: output.url, sink: { _ in }) != 0 {
        throw SereinError.invalid("The new checkpoint did not pass verification. The previous checkpoint is kept.")
      }
      try output.publish(to: kept)
      computer.hasCheckpoint = true
      if (machine as? DockerComputer)?.checkpointNeedsResume == true {
        computer.state = .error("Docker has not confirmed that the desktop resumed.")
        notice = "Checkpoint saved. Resume the computer to reconnect its desktop."
      } else {
        notice = "Checkpoint saved for \(assistantName(computer.id))'s computer."
      }
    } catch {
      notice = "The checkpoint could not be saved: " + error.localizedDescription
    }
  }

  /// Puts the checkpoint back into the home folder, when there is one.
  func restoreCheckpoint(_ machine: ComputerBackend, _ computer: Computer) async throws {
    guard let root else { return }
    let checkpoint = root.appendingPathComponent(computer.id + "/checkpoint.tar")
    guard FileManager.default.fileExists(atPath: checkpoint.path) else {
      if (machine as? E2BComputer)?.previousID != nil { throw SereinError.invalid("The saved checkpoint is missing. The previous E2B computer is kept.") }
      return
    }
    let code: Int
    if let owned = machine as? OwnedHomeCheckpoint {
      try CheckpointOperation.verifyEnvelope(checkpoint)
      code = try await owned.checkpoint(.restore, input: checkpoint) { _ in }
      if code == 0, machine is E2BComputer {
        let scrubbed = try await machine.runOnce(machine.helperCommand + ["--scrub"], input: nil) { _ in }
        guard scrubbed == 0 else { throw SereinError.invalid("The restored home could not be checked. Its checkpoint is kept.") }
      }
    } else {
      code = try await machine.runOnce(Self.restoreCommand, input: checkpoint) { _ in }
    }
    guard code == 0 else { throw SereinError.invalid("The checkpoint could not be put back (code \(code)). The saved checkpoint is kept.") }
  }

  /// Returns true when the owned home had a checkpoint and the reset was handled.
  func resetFromHomeCheckpoint(_ machine: ComputerBackend, _ computer: Computer, root: URL) async throws -> Bool {
    let archive = root.appendingPathComponent(computer.id + "/checkpoint.tar")
    guard FileManager.default.fileExists(atPath: archive.path), let owned = machine as? OwnedHomeCheckpoint else { return false }
    try CheckpointOperation.verifyEnvelope(archive)
    if let e2b = machine as? E2BComputer {
      // Keep the old sandbox paused. Its ID survives an app restart and is released only
      // after a replacement starts with verified pins, network and checkpoint.
      try await e2b.prepareReplacement()
      closeLinks(computer)
      computer.state = .none
      computer.screen = nil
      computer.pinsRefused = nil
      return true
    }
    // On Docker, restore into a private stage before any existing file is replaced.
    try await ensureRunning(computer)
    closeLinks(computer)
    try await machine.restart()
    computer.state = .stopped
    computer.screen = nil
    guard try await owned.checkpoint(.restore, input: archive, sink: { _ in }) == 0 else {
      throw SereinError.invalid("Docker reported a restore error. The saved archive is kept. Resume the computer to recover its home.")
    }
    if (machine as? DockerComputer)?.checkpointNeedsResume == true {
      computer.state = .error("Docker has not confirmed that the desktop resumed.")
    }
    return true
  }
}
