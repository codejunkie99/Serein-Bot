#if DEBUG
import Foundation
import SereinCore

/// Checks only (AgentHub.start): a turn that runs `spec.executable` with fixed arguments in its
/// own process group and completes the run when it exits. Its output is ignored.
@MainActor final class CheckProcessTurn: HarnessTurn {
  private weak var run: AgentRun?
  private weak var hub: AgentHub?
  private let arguments: [String]
  private let folder: URL
  private var child: Process?

  init(run: AgentRun, hub: AgentHub, arguments: [String], folder: URL) {
    self.run = run
    self.hub = hub
    self.arguments = arguments
    self.folder = folder
  }

  func start() {
    guard let run else { return }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: run.spec.executable)
    child.arguments = arguments
    child.currentDirectoryURL = folder
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    child.standardInput = FileHandle.nullDevice
    child.terminationHandler = { [weak self] child in
      ProcessGroup.terminate(child)
      let code = child.terminationStatus
      DispatchQueue.main.async {
        guard let self, let run = self.run else { return }
        self.hub?.complete(run, code: code, diagnostic: "")
      }
    }
    do {
      try ProcessGroup.configure(child)
      try child.run()
    } catch {
      hub?.stop(run, outcome: .stuck, message: error.localizedDescription)
      return
    }
    self.child = child
    run.phase = "Starting \(run.spec.provider.name)"
  }

  func interrupt() {
    if let child { ProcessGroup.terminate(child) }
  }

  /// A stopped process's children may still be writing: waits until the whole group is gone.
  func settled(timeout: TimeInterval) async {
    guard let group = child?.processIdentifier else { return }
    await Task.detached { _ = ProcessGroup.waitForExit(group, timeout: min(timeout, 5)) }.value
  }
}
#endif
