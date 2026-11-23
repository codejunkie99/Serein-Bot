import Darwin
import Foundation

public enum ProcessGroup {
  /// The host calls setsid before exec, so the PID is an owned session/group leader.
  public static func configure(_ process: Process) throws {
    let directory =
      Bundle.main.executableURL?.deletingLastPathComponent()
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let helper = directory.appendingPathComponent("serein-process-host")
    guard FileManager.default.isExecutableFile(atPath: helper.path),
      let executable = process.executableURL
    else {
      throw SereinError.invalid("Process host missing. Rebuild Serein with its helper.")
    }
    process.arguments = [executable.path] + (process.arguments ?? [])
    process.executableURL = helper
    // Every caller runs the process right after this returns.
    recordSoon()
  }
  public static func terminate(_ process: Process) {
    let pid = process.processIdentifier
    guard pid > 1 else { return }
    // If cancellation beats helper startup, terminate only that owned process. A leader that
    // has exited can no longer be asked, and its group may still hold what it started.
    let ownsGroup = !process.isRunning || getpgid(pid) == pid
    if ownsGroup { _ = kill(-pid, SIGTERM) } else if process.isRunning { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
      if ownsGroup { _ = kill(-pid, SIGKILL) } else if process.isRunning { _ = kill(pid, SIGKILL) }
    }
  }
  /// Blocks until no process is left in the group led by `pid` (or `pid` itself), or until the
  /// timeout. Returns true when everything exited. Call off the main thread.
  @discardableResult
  public static func waitForExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
    guard pid > 1 else { return true }
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let group = kill(-pid, 0) == 0 || errno == EPERM
      let leader = kill(pid, 0) == 0 || errno == EPERM
      if !group && !leader { return true }
      if Date() >= deadline { return false }
      usleep(50_000)
    }
  }

  /// Ends `groups` before it returns: SIGTERM, up to `timeout` for all of them together, then
  /// SIGKILL. For quitting, when terminate's SIGKILL 2 s later would come after Serein has exited.
  /// Blocks the calling thread.
  public static func end(_ groups: [pid_t], within timeout: TimeInterval) {
    let groups = groups.filter { $0 > 1 }
    for pid in groups { signalGroup(pid, SIGTERM) }
    let deadline = Date().addingTimeInterval(timeout)
    for pid in groups where !waitForExit(pid, timeout: max(0, deadline.timeIntervalSinceNow)) { signalGroup(pid, SIGKILL) }
  }

  /// Before the host's setsid the group does not exist yet; the leader alone is the whole run.
  private static func signalGroup(_ pid: pid_t, _ signal: Int32) {
    if kill(-pid, signal) != 0, errno == ESRCH { _ = kill(pid, signal) }
  }

  /// In the Library, which no harness can write, so no CLI can plant a record that has Serein end
  /// another program.
  static var recordDirectory: URL { AgentAccess.defaultRoot.appendingPathComponent("process-groups", isDirectory: true) }
  private static let recordQueue = DispatchQueue(label: "serein.process-groups")
  /// The groups last written to this Serein's file, and whether the 5 s rewrite runs. Only
  /// touched on `recordQueue`.
  private static var recorded: [ProcessGroupRecord.Group] = []
  private static var ticking = false

  /// Writes the record 0.5 s after a start, then every 5 s while any group lives, which also drops
  /// the groups that ended. A crash leaves at most the last few seconds unrecorded.
  private static func recordSoon() {
    recordQueue.asyncAfter(deadline: .now() + 0.5) {
      guard writeRecord(), !ticking else { return }
      ticking = true
      tick()
    }
  }
  private static func tick() {
    recordQueue.asyncAfter(deadline: .now() + 5) {
      if writeRecord() { tick() } else { ticking = false }
    }
  }
  /// This Serein's live groups: each child that leads its own group (every process `configure`
  /// started, as the host calls setsid), and each recorded group whose leader has exited while a
  /// member it started lives on. True while any is left.
  private static func writeRecord() -> Bool {
    let me = getpid()
    let leaders = pids(PROC_PPID_ONLY, me).filter { live($0)?.pgid == $0 }
    var groups = leaders.map(group)
    for old in recorded where !leaders.contains(old.pgid) && ProcessGroupRecord.isOurs(old, live: live) {
      groups.append(group(old.pgid))
    }
    groups.removeAll { $0.members.isEmpty }
    guard groups != recorded else { return !groups.isEmpty }
    recorded = groups
    let file = recordDirectory.appendingPathComponent("\(me).json")
    guard !groups.isEmpty, let owner = live(me).map({ ProcessGroupRecord.Member(pid: me, started: $0.started) }) else {
      try? FileManager.default.removeItem(at: file)
      return !groups.isEmpty
    }
    try? FileManager.default.createDirectory(at: recordDirectory, withIntermediateDirectories: true)
    try? JSONEncoder().encode(ProcessGroupRecord(owner: owner, groups: groups)).write(to: file, options: .atomic)
    return true
  }

  /// At launch: ends the groups that a Serein no longer running recorded and that still run.
  /// SIGTERM first, then SIGKILL 2 s later to what is left, as Stop does.
  public static func endLeftovers() {
    recordQueue.async {
      let files = (try? FileManager.default.contentsOfDirectory(at: recordDirectory, includingPropertiesForKeys: nil)) ?? []
      var ending: [ProcessGroupRecord.Group] = []
      for file in files where file.pathExtension == "json" {
        guard let record = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(ProcessGroupRecord.self, from: $0) })
        else {
          try? FileManager.default.removeItem(at: file)
          continue
        }
        if record.ownerRuns(live: live) { continue }
        // Read now, so this Serein's own file (written after) is never the one removed.
        try? FileManager.default.removeItem(at: file)
        for old in record.groups where old.pgid != getpgrp() && ProcessGroupRecord.isOurs(old, live: live) {
          _ = kill(-old.pgid, SIGTERM)
          ending.append(group(old.pgid))
        }
      }
      guard !ending.isEmpty else { return }
      recordQueue.asyncAfter(deadline: .now() + 2) { [ending] in
        for old in ending where ProcessGroupRecord.isOurs(old, live: live) { _ = kill(-old.pgid, SIGKILL) }
      }
    }
  }

  /// Start time and group of a running process of this user; nil once it has exited (a zombie
  /// counts as exited) or when it belongs to someone else.
  static func live(_ pid: pid_t) -> ProcessGroupRecord.Live? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
      info.pbi_uid == getuid(), info.pbi_status != SZOMB
    else { return nil }
    return ProcessGroupRecord.Live(
      started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, pgid: Int32(bitPattern: info.pbi_pgid))
  }
  private static func group(_ pgid: pid_t) -> ProcessGroupRecord.Group {
    ProcessGroupRecord.Group(pgid: pgid, members: pids(PROC_PGRP_ONLY, pgid).compactMap { pid in
      live(pid).map { ProcessGroupRecord.Member(pid: pid, started: $0.started) }
    })
  }
  /// `type` is PROC_PPID_ONLY (children of `value`) or PROC_PGRP_ONLY (members of group `value`).
  private static func pids(_ type: Int32, _ value: pid_t) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 4096)
    let bytes = buffer.withUnsafeMutableBytes { proc_listpids(UInt32(type), UInt32(value), $0.baseAddress, Int32($0.count)) }
    return buffer.prefix(max(0, Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
  }
}
