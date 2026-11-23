import Foundation
import SereinCore

/// `serein-agent look`: write a look for Relay's hologram by hand and check it the way Serein
/// will, or start from one of Serein's.
enum LookCommand {
  static let usage = """
    serein-agent look validate <file.json>   check a look the way Serein will
    serein-agent look presets               Serein's looks, as JSON
    serein-agent look guide                 how a look is written: states, formations, cores
    """

  static func main(_ args: [String]) -> Never {
    switch args.first {
    case "validate":
      guard args.count >= 2 else { fail("Usage: serein-agent look validate <file.json>") }
      do {
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          throw SereinError.invalid("A look file holds one JSON object.")
        }
        let look = try RelayLook.parse(object)
        print("✓ \(look.name): \(look.summary)")
        exit(0)
      } catch {
        print("✗ " + error.localizedDescription)
        exit(1)
      }
    case "presets":
      print("[\n" + RelayLook.presets.map { $0.jsonText }.joined(separator: ",\n") + "\n]")
      exit(0)
    case "guide":
      print(RelayLook.guide)
      print("\nStates:")
      for state in RelayLook.State.allCases { print("  \(state.rawValue): \(state.meaning)") }
      print("\nFormations:")
      for f in RelayLook.formations { print("  \(f.name): \(f.shape)") }
      print("\nCores:")
      for c in RelayLook.cores { print("  \(c.name): \(c.shape)") }
      print("\nPresets: " + RelayLook.presets.map(\.name).joined(separator: ", "))
      exit(0)
    default:
      print(usage)
      exit(args.isEmpty ? 0 : 1)
    }
  }
  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
  }
}
