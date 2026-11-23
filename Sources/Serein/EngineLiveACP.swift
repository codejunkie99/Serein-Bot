#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// `--verify-acp-live <grok|opencode|cursor|gemini> <executable> [model]`: real turns on one
/// thread in a temp project (three turns) at Full, through `Engines`. Prints cold and warm milliseconds.
enum EngineLiveACP {
  static func run(_ arguments: [String]) async throws {
    guard arguments.count >= 2, let cli = HarnessDriver(rawValue: arguments[0]),
      let driver = DriverRegistry.all.first(where: { $0.cli == cli })
    else { throw SereinError.invalid("usage: --verify-acp-live <cli> <executable> [model]") }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acp-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "hello from serein\n".write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: folder) }
    let records = RunRecords(root: folder.appendingPathComponent(".runs"))
    let engines = Engines(drivers: [driver], host: SereinProcessHost(records: records), records: records)
    defer { Task { await engines.shutdown() } }
    func turn(_ message: String) async throws -> Bool {
      let request = TurnRequest(
        thread: ThreadKey("live"), cli: cli, executable: URL(fileURLWithPath: arguments[1]),
        access: .project(folder: folder, level: .full),
        prompt: TurnPrompt(stable: "You are a terse assistant.", volatile: "", message: message, recovery: nil),
        model: arguments.count > 2 ? arguments[2] : nil, effort: nil, resume: nil, browser: nil, taskID: "live")
      let start = Date()
      var firstText: Double?
      var asked = 0
      var text = ""
      var end: TurnEnd?
      for await event in try await engines.send(request).events {
        switch event {
        case .text(let chunk):
          if firstText == nil { firstText = Date().timeIntervalSince(start) * 1_000 }
          text += chunk
        case .declined: asked += 1
        case .ended(let ended): end = ended
        default: break
        }
      }
      let total = Date().timeIntervalSince(start) * 1_000
      print("LIVE \(cli.rawValue) firstText=\(Int(firstText ?? -1))ms total=\(Int(total))ms asked=\(asked) end=\(String(describing: end?.stopReason)) reply=\(text.prefix(120).debugDescription)")
      return end?.stopReason == .endTurn && asked == 0 && !text.isEmpty
    }
    // The same message cold and warm, then a shell step on the warm process.
    let cold = try await turn("Reply with the single word DONE.")
    let warm = try await turn("Reply with the single word DONE.")
    let shell = try await turn("Run `cat note.txt` in the shell, then reply with its contents only.")
    print(cold && warm && shell ? "PASS: live \(cli.rawValue)" : "FAIL: live \(cli.rawValue)")
  }
}
#endif
