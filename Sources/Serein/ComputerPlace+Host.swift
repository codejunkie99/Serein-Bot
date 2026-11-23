import Foundation
import SereinCore

extension ComputerHost {
  /// Whether the computer's place is set up to start it: Docker with its image, the built-in
  /// computer with its downloaded image (or a disk of its own already), a hosted place with a key,
  /// or the person's own machine connected.
  func ready(_ computer: Computer) -> Bool {
    switch computer.place {
    case .docker: return imageBuilt
    case .builtIn: return VirtualMachineComputer.supported && (BuiltInImage.shared.ready || hasBuiltInDisk(computer))
    case .macOS:
      return VirtualMachineComputer.supported && (machine(for: computer) as? MacVirtualComputer)?.isInstalled == true
    case .e2b, .daytona: return account(computer.place)?.hasKey == true
    case .ownDesktop, .ownMachine: return computer.own != nil
    case .unavailable: return false
    }
  }
  /// The person's account a hosted place runs under; nil for a place that is not hosted.
  func account(_ place: ComputerPlace) -> HostedAccount? {
    switch place {
    case .docker, .builtIn, .macOS, .ownDesktop, .ownMachine, .unavailable: return nil
    case .e2b: return E2BAccount.shared
    case .daytona: return DaytonaAccount.shared
    }
  }
  /// Whether its place can be reached at all (to delete what is there); the built-in computer's
  /// files are on this Mac.
  func reachable(_ computer: Computer) -> Bool {
    switch computer.place {
    case .docker: return backendName != nil
    case .builtIn, .macOS: return true
    case .e2b, .daytona: return account(computer.place)?.hasKey == true
    case .ownDesktop, .ownMachine: return computer.own != nil
    case .unavailable: return false
    }
  }
  func hasBuiltInDisk(_ computer: Computer) -> Bool {
    guard let root else { return false }
    return FileManager.default.fileExists(atPath: root.appendingPathComponent(computer.id + "/" + VirtualMachinePolicy.diskName).path)
  }

  func resetNotice(_ computer: Computer) -> String {
    if (computer.machine as? DockerComputer)?.checkpointNeedsResume == true {
      return "Checkpoint restored. Resume the computer to reconnect its desktop."
    }
    return "Serein's computer was reset" + (computer.hasCheckpoint ? " to its checkpoint." : ".")
  }
}
