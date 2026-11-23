#if DEBUG
import Darwin
import Foundation
import SereinCore
@testable import SereinEngines

/// Core findings from the driver reviews, each through the real process host and kernel or
/// through Engines with a fake CLI.
extension AssistantCoreChecks {
  static func engineCore(_ check: Check) throws {
    try coreStopReachesDetached(check)
    try engineCoreTurns(check)
    try coreEnvironment(check)
  }

  /// A CLI starts with no token, secret, password or credential of the person's, and no
  /// secret-looking value, except its own key variables (as AgentFileGuard.environment).
  private static func coreEnvironment(_ check: Check) throws {
    let planted = [
      "SEREIN_CHECK_GITHUB_TOKEN": "ghp_check", "SEREIN_CHECK_DB_PASSWORD": "hunter2",
      "SEREIN_CHECK_NOTE": "sk-ant-api03-\(String(repeating: "a", count: 40))", "SEREIN_CHECK_COLOR": "blue",
    ]
    let saved = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
    for (name, value) in planted { setenv(name, value, 1) }
    setenv("ANTHROPIC_API_KEY", "theirs-anthropic", 1)
    setenv("OPENAI_API_KEY", "theirs-openai", 1)
    defer {
      for name in planted.keys { unsetenv(name) }
      for (name, value) in saved { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
    }
    let request = TurnRequest(
      thread: ThreadKey("env"), cli: .opencode, executable: URL(fileURLWithPath: "/usr/bin/true"), access: .answer,
      prompt: TurnPrompt(stable: "", volatile: "", message: "", recovery: nil), model: nil, effort: nil, resume: nil,
      browser: nil, taskID: "env")
    let acp = ACPGrant.environment(request)
    let claude = ClaudeDriver.environment(ownSetup: false, cardWait: .seconds(118), executable: request.executable)
    let leaked = Set(planted.keys).subtracting(["SEREIN_CHECK_COLOR"])
    try check(
      leaked.allSatisfy { acp[$0] == nil && claude[$0] == nil } && acp["SEREIN_CHECK_COLOR"] == "blue" && claude["SEREIN_CHECK_COLOR"] == "blue",
      "A CLI gets no token, password or secret-looking value of the person's, and their other variables")
    try check(
      acp["ANTHROPIC_API_KEY"] == nil && acp["OPENAI_API_KEY"] == nil && claude["ANTHROPIC_API_KEY"] == "theirs-anthropic"
        && claude["OPENAI_API_KEY"] == nil,
      "A CLI keeps only its own key variables")
  }

  /// Claude starts its shell commands detached (their own session and group), so a stop that
  /// signals only the CLI's group leaves them running.
  private static func coreStopReachesDetached(_ check: Check) throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("core-stop-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    // macOS hides the environment of Apple's own binaries; a signed copy shows it, as a CLI's does.
    let sleep = dir.appendingPathComponent("sleep")
    try fm.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleep)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", sleep.path]
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
    let records = RunRecords(root: dir.appendingPathComponent("runs"))
    try fm.createDirectory(at: records.directory, withIntermediateDirectories: true)
    let host = SereinProcessHost(records: records)
    let table = KernelProcessTable()

    let script = #"""
      import os, signal, subprocess, sys, time
      sleep, mode = sys.argv[1], sys.argv[2]
      pids = [subprocess.Popen([sleep, "300"], start_new_session=True).pid]
      if mode in ("orphan", "bare"):
          r, w = os.pipe()
          shell = os.fork()
          if shell == 0:
              os.setsid()
              os.write(w, str(subprocess.Popen([sleep, "301"], env={} if mode == "bare" else None).pid).encode())
              time.sleep(0.5)
              os._exit(0)
          os.close(w)
          pids.append(int(os.read(r, 32)))
          os.waitpid(shell, 0)
      if mode == "stubborn":
          signal.signal(signal.SIGTERM, signal.SIG_IGN)
      print(" ".join(map(str, pids)), flush=True)
      sys.stdin.read()
      if mode == "stubborn":
          while True: signal.pause()
      """#

    func contract(_ arguments: [String], executable: URL = URL(fileURLWithPath: "/usr/bin/python3")) -> LaunchContract {
      let request = TurnRequest(
        thread: ThreadKey("stop"), cli: .claude, executable: executable, access: .answer,
        prompt: TurnPrompt(stable: "", volatile: "", message: "", recovery: nil), model: nil, effort: nil, resume: nil,
        browser: nil, taskID: "stop")
      return LaunchContract(
        request, arguments: arguments, environment: ["PATH": "/usr/bin:/bin"], expectedMode: .nothing(flagOnArgv: []), network: .open)
    }
    /// A killed leader stays a zombie until Foundation reaps it, so the end is awaited.
    func gone(_ hosted: any HostedProcess, _ pids: [pid_t]) -> Bool {
      let deadline = Date().addingTimeInterval(3)
      func done() -> Bool { !hosted.groupAlive && pids.allSatisfy { table.live($0) == nil } }
      while !done(), Date() < deadline { usleep(20_000) }
      return done()
    }

    let neighbour = try host.spawn(contract(["30"], executable: sleep))
    defer { neighbour.signalGroup(SIGKILL) }
    for (mode, says) in [
      ("eof", "A CLI that leaves on end of input takes its detached shell commands with it"),
      ("stubborn", "A CLI that ignores end of input and TERM is killed with its detached shell commands"),
      ("orphan", "A detached command whose parent already left still ends, found by the CLI's tag"),
      ("bare", "A detached command with no environment whose parent already left still ends"),
    ] {
      let hosted = try host.spawn(contract(["-I", "-c", script, sleep.path, mode]))
      let printed = try blocking { () async -> String in
        var text = ""
        for await chunk in hosted.output {
          text += String(decoding: chunk, as: UTF8.self)
          if text.contains("\n") { break }
        }
        return text
      }
      let children = printed.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
      try blocking { await StopLadder.run(StopLadder.standard, on: hosted, sleep: { try? await Task.sleep(for: $0) }) }
      try check(
        children.count == (["orphan", "bare"].contains(mode) ? 2 : 1) && gone(hosted, [hosted.pgid] + children),
        says + " [children=\(children) alive=\(children.filter { table.live($0) != nil })]")
      for pid in children where table.live(pid) != nil { kill(pid, SIGKILL) }
    }
    try check(table.live(neighbour.pgid) != nil, "Another CLI of the same Serein run survives those stops")
  }
}
#endif
