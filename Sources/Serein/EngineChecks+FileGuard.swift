#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// The file guard through the real process host and the kernel's sandbox: a CLI that never asks
/// before it reads gets main's own-setup file rules, and its network stays open.
extension AssistantCoreChecks {
  static func engineFileGuard(_ check: Check) throws {
    let fm = FileManager.default
    let library = AgentAccess.defaultRoot.appendingPathComponent("file-guard-check-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let project = fm.temporaryDirectory.appendingPathComponent("file-guard-project-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try fm.createDirectory(at: library, withIntermediateDirectories: true)
    try fm.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: library); try? fm.removeItem(at: project) }
    let secret = library.appendingPathComponent("secret.txt")
    try "LIBRARY-SECRET".write(to: secret, atomically: true, encoding: .utf8)
    try "PROJECT-FILE".write(to: project.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
    // As in the app: the host's empty folder sits in the library, beside the run records.
    let records = RunRecords(root: library.appendingPathComponent("engine-runs", isDirectory: true))
    try fm.createDirectory(at: records.directory, withIntermediateDirectories: true)
    defer { records.removeAll() }
    let host = SereinProcessHost(records: records)

    func run(_ script: String, access: Access, guarded: Bool) throws -> String {
      let request = TurnRequest(
        thread: ThreadKey("guard"), cli: .pi, executable: URL(fileURLWithPath: "/bin/sh"), access: access,
        prompt: TurnPrompt(stable: "", volatile: "", message: "", recovery: nil), model: nil, effort: nil, resume: nil,
        browser: nil, taskID: "guard")
      var contract = LaunchContract(
        request, arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"], expectedMode: .nothing(flagOnArgv: []),
        network: .open)
      contract.sandboxProfile = guarded ? LaunchContract.fileGuard(request) : nil
      let hosted = try host.spawn(contract)
      hosted.closeInput()
      return try blocking {
        var text = Data()
        for await chunk in hosted.output { text.append(chunk) }
        _ = await hosted.exited()
        return String(decoding: text, as: UTF8.self)
      }
    }
    let read = "cat \"\(secret.path)\" 2>/dev/null; echo; cat mine.txt 2>/dev/null; echo; echo made > made.txt && echo wrote"

    let open = try run(read, access: .project(folder: project, level: .edits), guarded: false)
    try check(open.contains("LIBRARY-SECRET"), "Without the guard a CLI can read Serein's library (the check sees the difference)")
    let guarded = try run(read, access: .project(folder: project, level: .edits), guarded: true)
    try check(!guarded.contains("LIBRARY-SECRET"), "A guarded CLI cannot read Serein's library")
    try check(guarded.contains("PROJECT-FILE") && guarded.contains("wrote"), "A guarded CLI still reads and writes its own folder")
    let server = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(server) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, size) == 0 && getsockname(server, $0, &size) == 0 }
    }
    try check(bound && listen(server, 4) == 0, "A local listener for the network check starts")
    let reach = "/usr/bin/nc -z -G 3 127.0.0.1 \(UInt16(bigEndian: address.sin_port)) && echo reached || echo blocked; "
      + "echo x > \"\(library.path)/written.txt\" 2>/dev/null && echo LIBRARY-WRITTEN || echo library-closed"
    let network = try run(reach, access: .project(folder: project, level: .full), guarded: true)
    try check(network.contains("reached") && network.contains("library-closed"),
      "A guarded shell reaches a host no list names, and still cannot write Serein's library (\(network))")
    if ProcessInfo.processInfo.environment["SEREIN_SHELL_NETWORK_LIVE"] == "1" {
      let online = try run("/usr/bin/curl -sI -m 15 -o /dev/null -w '%{http_code}' https://example.com", access: .project(folder: project, level: .full), guarded: true)
      try check(online == "200", "Live: a guarded shell reaches example.com (\(online))")
    }
    let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    let list = "ls \"\(ssh.path)\" >/dev/null 2>&1 && echo listed || echo closed"
    if try run(list, access: .ownSetup(folder: project), guarded: false).contains("listed") {
      try check(!(try run(list, access: .ownSetup(folder: project), guarded: true).contains("listed")), "A guarded CLI cannot list ~/.ssh")
    }
    let pi = PiDriver(cli: .pi, files: project.appendingPathComponent("pi-files"))
    let levels: [Access] = [.answer, .web, .ownSetup(folder: project), .project(folder: project, level: .review),
      .project(folder: project, level: .edits), .project(folder: project, level: .full), .task(folder: project)]
    let everyLevel = try levels.allSatisfy { access in
      let request = TurnRequest(
        thread: ThreadKey("pi"), cli: .pi, executable: URL(fileURLWithPath: "/usr/bin/true"), access: access,
        prompt: TurnPrompt(stable: "s", volatile: "", message: "m", recovery: nil), model: nil, effort: nil, resume: nil,
        browser: nil, taskID: "pi")
      return try pi.contract(for: request, network: .open).sandboxProfile?.contains(AgentFileGuard.physicalPath(AgentAccess.defaultRoot.path)) == true
    }
    try check(everyLevel, "Pi runs under the file guard at every level, Serein's library closed")
    let answer = try run("cat \"\(secret.path)\" 2>/dev/null; ls . >/dev/null && echo LISTED; echo {} > AGENTS.md 2>/dev/null && echo PLANTED", access: .answer, guarded: true)
    try check(!answer.contains("LIBRARY-SECRET") && answer.contains("LISTED") && !answer.contains("PLANTED"),
      "A turn with no folder reads its empty folder inside the library and plants nothing there for the next, and the rest stays closed")
  }
}
#endif
