import Darwin
import Foundation
import SQLite3

/// Local display evidence only. These sessions never become AgentHub runs or receive grants.
public struct ExternalSession: Identifiable, Equatable, Sendable {
  public enum State: String, Sendable { case running, needsUser, open }
  public var id: String
  public var driver: HarnessDriver
  public var title: String
  public var cwd: String?
  public var state: State
  public var updatedAt: Date
  /// The session's process, so Serein can bring forward the app it runs in.
  public var pid: Int32?
  /// The transcript it writes, followed for every write while the session lives.
  public var log: String?
  /// Codex's goal for this thread, by its status ("active", "complete", "paused", "blocked", …):
  /// while a goal is active Codex starts turn after turn on its own.
  public var goal: String?
  /// When Claude Code's loop wakes next (`/loop`, ScheduleWakeup), or `distantFuture` while a
  /// recurring job it made runs: until then the loop is not done.
  public var loopUntil: Date?
  /// The Codex thread that spawned this one: a helper whose turns are its parent's work.
  public var parent: String?
  /// More turns will come on their own (a goal or a loop), so a turn's end is not news.
  public func continuing(at now: Date) -> Bool { goal == "active" || (loopUntil.map { $0 > now } ?? false) }
  public init(id: String, driver: HarnessDriver, title: String, cwd: String?, state: State, updatedAt: Date, pid: Int32? = nil) {
    self.id = id; self.driver = driver; self.title = title; self.cwd = cwd
    self.state = state; self.updatedAt = updatedAt; self.pid = pid
  }
}

/// No prompts, environment, or command output are retained in process observations.
public struct HarnessProcess: Sendable {
  public var pid: Int32
  public var parent: Int32
  public var executable: String
  public var arguments: [String]  // Launcher identifiers from the first four argv entries.
  public var cwd: String?
  public var startedAt: Date
  public var logs: [String]
  public init(pid: Int32, parent: Int32, executable: String, arguments: [String] = [], cwd: String? = nil,
              startedAt: Date = Date(), logs: [String] = []) {
    self.pid = pid; self.parent = parent; self.executable = executable
    self.arguments = Array(arguments.prefix(4)); self.cwd = cwd
    self.startedAt = startedAt; self.logs = logs
  }
}

public enum HarnessProcessDiscovery {
  /// The process's parents, nearest first, up to launchd: the app a session runs in is the first
  /// of them that is an app (Terminal, Ghostty, the ChatGPT app, Cursor).
  public static func ancestors(_ pid: Int32) -> [Int32] {
    var out: [Int32] = []
    var current = pid
    while out.count < 64 {
      guard let parent = parentPID(current), parent > 1, parent != current else { break }
      out.append(parent)
      current = parent
    }
    return out
  }

  /// A process's parent. proc_pidinfo is refused for root-owned processes such as `login`, which
  /// sits between every Terminal tab and its shell; the kernel's process table answers for any.
  public static func parentPID(_ pid: Int32) -> Int32? {
    var info = proc_bsdinfo()
    if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0 {
      return Int32(info.pbi_ppid)
    }
    var process = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, 4, &process, &size, nil, 0) == 0, size > 0 else { return nil }
    return process.kp_eproc.e_ppid
  }

  /// Exact executable/launcher matches; an arbitrary `agent` or `node` is not a harness.
  public static func driver(_ process: HarnessProcess, executables: [HarnessDriver: String] = [:]) -> HarnessDriver? {
    let path = process.executable
    let name = URL(fileURLWithPath: path).lastPathComponent
    let args = process.arguments
    if args.dropFirst().contains(where: { ["--version", "-V", "--help", "-h", "login", "logout", "completion", "generate-json-schema", "--list-models", "models", "auth", "mcp", "exec-server", "sandbox", "sandbox-helper"].contains($0) }) {
      return nil
    }
    if let configured = executables.first(where: {
      URL(fileURLWithPath: $0.value).resolvingSymlinksInPath().path == path
    }) {
      // Claude Code's binary also runs its bundled tools (ugrep, rg) under their own names.
      let invoked = URL(fileURLWithPath: args.first ?? name).lastPathComponent
      return invoked == name || configured.key.binaries.contains(invoked) ? configured.key : nil
    }
    let names: [String: HarnessDriver] = [
      "claude": .claude, "codex": .codex, "cursor-agent": .cursor, "opencode": .opencode,
      "pi": .pi, "omp": .ohMyPi, "grok": .grok, "gemini": .gemini,
    ]
    if let driver = names[name] { return driver }
    guard ["node", "bun"].contains(name) else { return nil }
    let entry = args.dropFirst().first(where: { !$0.hasPrefix("-") }) ?? ""
    if let configured = executables.first(where: {
      URL(fileURLWithPath: $0.value).resolvingSymlinksInPath().path == entry
    }) { return configured.key }
    for (fragment, driver) in [
      ("/@anthropic-ai/claude-code/", HarnessDriver.claude), ("/@openai/codex/", .codex),
      ("/cursor-agent/versions/", .cursor),
      ("/@mariozechner/pi-coding-agent/", .pi), ("/@earendil-works/pi-coding-agent/", .pi),
      ("/@oh-my-pi/pi-coding-agent/", .ohMyPi), ("/@xai-official/grok/", .grok),
      ("/@google/gemini-cli/", .gemini),
    ] where entry.contains(fragment) { return driver }
    return nil
  }

  /// libproc runs in the desktop host. Nothing is sent to a harness and no CLI is launched.
  public static func snapshot(executables: [HarnessDriver: String] = [:], home: String = NSHomeDirectory()) -> [HarnessProcess] {
    let capacity = min(32_768, max(1024, Int(proc_listallpids(nil, 0)) + 256))
    var pids = [Int32](repeating: 0, count: capacity)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0 else { return [] }
    var all: [Int32: (Int32, String)] = [:]
    var candidates: [HarnessProcess] = []
    // A process reports its real file (~/.local/share/claude/versions/2.1.301, opencode.exe), not
    // the link on PATH, so the configured executables are compared resolved.
    let installed = Set(executables.values.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    for pid in pids.prefix(Int(count)) where pid > 0 {
      guard !Task.isCancelled else { return [] }
      var info = proc_bsdinfo()
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
            info.pbi_uid == getuid(), info.pbi_status != SZOMB else { continue }
      var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
      let executable = String(cString: path)
      all[pid] = (Int32(info.pbi_ppid), executable)
      let name = URL(fileURLWithPath: executable).lastPathComponent
      // Read argv only for plausible harnesses/interpreters, and retain only launcher metadata.
      guard HarnessDriver.allCases.contains(where: { $0.binaries.contains(name) })
        || ["node", "bun"].contains(name)
        || installed.contains(executable) else { continue }
      var process = HarnessProcess(pid: pid, parent: Int32(info.pbi_ppid), executable: executable,
                                   arguments: argumentPrefix(pid), startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec)))
      guard let driver = driver(process, executables: executables) else { continue }
      var vnode = proc_vnodepathinfo()
      if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout.size(ofValue: vnode))) > 0 {
        process.cwd = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) {
          $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
      }
      if driver == .codex || driver == .claude { process.logs = openLogs(pid, driver: driver, home: home) }
      candidates.append(process)
    }
    // Serein-owned children (including probes and persistent servers) are already represented.
    return candidates.filter { candidate in
      var pid = candidate.pid
      var seen = Set<Int32>()
      while seen.insert(pid).inserted, let (parent, path) = all[pid] {
        if pid == getpid() || URL(fileURLWithPath: path).lastPathComponent == "Serein" { return false }
        pid = parent
      }
      return true
    }
  }

  private static func argumentPrefix(_ pid: Int32) -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 2 * 1024 * 1024 else { return [] }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
    let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    var offset = 4
    while offset < size && bytes[offset] != 0 { offset += 1 } // kernel executable path
    while offset < size && bytes[offset] == 0 { offset += 1 }
    var result: [String] = []
    for _ in 0..<min(4, max(0, argc)) {
      let start = offset
      while offset < size && bytes[offset] != 0 { offset += 1 }
      guard offset < size else { break }
      result.append(String(decoding: bytes[start..<offset], as: UTF8.self))
      offset += 1
    }
    // Keep launcher/subcommand identifiers only. Positional prompts and environment values
    // from the kernel buffer are discarded here, before creating an observation.
    let commands = Set(["app-server", "exec-server", "sandbox", "sandbox-helper", "exec", "serve", "acp", "login", "logout", "completion", "generate-json-schema", "--list-models", "models", "auth", "mcp",
                        "--version", "-V", "--help", "-h"])
    return result.enumerated().compactMap { index, value in
      if index == 0 || commands.contains(value) { return value }
      if index <= 2 && value.hasPrefix("/") && ["js", "mjs", "cjs"].contains(URL(fileURLWithPath: value).pathExtension) { return value }
      return nil
    }
  }

  private static func openLogs(_ pid: Int32, driver: HarnessDriver, home: String) -> [String] {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0, bytes < 4 * 1024 * 1024 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 32)
    let read = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    var paths = Set<String>()
    for fd in fds.prefix(max(0, Int(read)) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
      var info = vnode_fdinfowithpath()
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout.size(ofValue: info))) > 0 else { continue }
      let path = withUnsafePointer(to: &info.pvip.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      if ExternalSessionReader.allowedLog(path, driver: driver, home: home) { paths.insert(path) }
    }
    return paths.sorted()
  }
}

/// Serial-use cache. Polls read at most a head and a 512 KiB tail of changed, open logs.
/// Closed logs and completed Codex turns disappear immediately; old history cannot look live.
public struct ExternalSessionReader {
  private struct Cached {
    var stamp: String
    var session: ExternalSession?
  }
  private var cache: [String: Cached] = [:]
  public private(set) var bytesRead = 0
  public init() {}

  public static func allowedLog(_ path: String, driver: HarnessDriver, home: String) -> Bool {
    if driver == .claude, path.hasSuffix(".jsonl") {
      let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
      return ClaudeSessionRecords.roots(home: home).contains {
        resolved.hasPrefix($0.appendingPathComponent("projects").resolvingSymlinksInPath().path + "/")
      }
    }
    if let root = otherRoot(driver, home: home) {
      let real = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
      return path.hasSuffix(".jsonl") && URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(real + "/")
    }
    guard let store = driver.sessionStore, [.codex, .claude].contains(driver), path.hasSuffix(".jsonl") else { return false }
    let root = URL(fileURLWithPath: store.root.replacingOccurrences(of: "~", with: home)).resolvingSymlinksInPath().path
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return resolved.hasPrefix(root + "/") && (driver != .codex || URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-"))
  }

  /// nil means a completed/idle turn. An open process without usable lifecycle evidence has
  /// its own `open` row rather than being counted as a running model turn.
  public static func codexState(_ data: Data) -> ExternalSession.State? {
    var state: ExternalSession.State?
    for line in data.split(separator: 10) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            let payload = object["payload"] as? [String: Any] else { continue }
      let type = payload["type"] as? String ?? ""
      if object["type"] as? String == "event_msg" {
        switch type {
        case "task_started", "turn_started": state = .running
        case "task_complete", "turn_complete", "turn_aborted": state = nil
        default: break
        }
      } else if object["type"] as? String == "response_item" {
        switch type {
        case "reasoning", "function_call_output", "custom_tool_call_output": state = .running
        case "function_call", "custom_tool_call":
          let name = payload["name"] as? String ?? ""
          state = name.hasSuffix("request_user_input") || name.hasSuffix("request_user_input_async") ? .needsUser : .running
        case "message" where payload["role"] as? String == "assistant":
          state = payload["phase"] as? String == "final_answer" ? nil : .running
        default: break
        }
      }
    }
    return state
  }

  /// Claude Code's transcript tail: running while a turn is going (a prompt or tool result waits
  /// for the model, or the model asked for a tool), needsUser while it waits on AskUserQuestion
  /// or ExitPlanMode, nil once the turn ended or was interrupted.
  public static func claudeState(_ data: Data) -> ExternalSession.State? {
    var state: ExternalSession.State?
    for line in data.split(separator: 10) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            let message = object["message"] as? [String: Any], object["isMeta"] as? Bool != true else { continue }
      let content = message["content"] as? [[String: Any]] ?? []
      switch object["type"] as? String {
      case "user":
        let text = (message["content"] as? String) ?? content.compactMap { $0["text"] as? String }.joined()
        state = text.hasPrefix("[Request interrupted") ? nil : .running
      case "assistant":
        switch message["stop_reason"] as? String {
        case "tool_use":
          let asks = content.contains {
            $0["type"] as? String == "tool_use" && ["AskUserQuestion", "ExitPlanMode"].contains($0["name"] as? String ?? "")
          }
          state = asks ? .needsUser : state == .needsUser ? .needsUser : .running
        case nil: state = .running
        default: state = nil
        }
      default: break
      }
    }
    return state
  }
  /// Claude Code's loop in the transcript's tail: the last ScheduleWakeup's wake time plus a little
  /// grace (none once it stopped the loop), or `distantFuture` while a recurring CronCreate job
  /// has not been deleted. Nil when it is in no loop.
  public static func claudeLoop(_ data: Data) -> Date? {
    var until: Date?
    var jobs = 0
    let markers = ["ScheduleWakeup", "CronCreate", "CronDelete"].map { Data($0.utf8) }
    let stamps = ISO8601DateFormatter()
    stamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for line in data.split(separator: 10) where markers.contains(where: { line.range(of: $0) != nil }) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        object["type"] as? String == "assistant",
        let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
      let at = (object["timestamp"] as? String).flatMap(stamps.date(from:)) ?? Date()
      for block in content where block["type"] as? String == "tool_use" {
        let input = block["input"] as? [String: Any] ?? [:]
        switch block["name"] as? String {
        case "ScheduleWakeup":
          if input["stop"] as? Bool == true { until = nil; continue }
          guard let delay = (input["delaySeconds"] as? NSNumber)?.doubleValue else { continue }
          until = at.addingTimeInterval(delay + loopGrace)
        case "CronCreate" where input["recurring"] as? Bool != false: jobs += 1
        case "CronDelete": jobs = max(0, jobs - 1)
        default: break
        }
      }
    }
    return jobs > 0 ? .distantFuture : until
  }
  /// A loop's wake may start a little after its time.
  public static let loopGrace: TimeInterval = 120

  /// The parent thread a Codex session file's header names, when another thread spawned it.
  public static func codexParent(_ head: Data) -> String? {
    guard let line = head.split(separator: 10).first,
      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
      let payload = object["payload"] as? [String: Any],
      let spawn = ((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
    else { return nil }
    return (spawn["parent_thread_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Codex's goals by thread id and status, from its goals database (read only).
  public static func codexGoals(_ threads: [String], home: String) -> [String: String] {
    guard !threads.isEmpty else { return [:] }
    let folder = roots(home: home).codexHome
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
      .filter { $0.hasPrefix("goals_") && $0.hasSuffix(".sqlite") }
    // The newest schema version Codex writes.
    guard let name = names.max(by: { (Int($0.dropFirst(6).dropLast(7)) ?? 0) < (Int($1.dropFirst(6).dropLast(7)) ?? 0) })
    else { return [:] }
    let marks = Array(repeating: "?", count: threads.count).joined(separator: ",")
    let rows = SQLiteRows.read(folder + "/" + name, "SELECT thread_id, status FROM thread_goals WHERE thread_id IN (\(marks))", threads) ?? []
    var goals: [String: String] = [:]
    for row in rows { if let id = row[0], let status = row[1] { goals[id] = status } }
    return goals
  }

  /// The newest title Claude Code gave the session (custom, then generated).
  public static func claudeTitle(_ data: Data) -> String? {
    var title: String?
    let marker = Data("Title\"".utf8)  // customTitle, aiTitle
    for line in data.split(separator: 10) where line.range(of: marker) != nil {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
      if let custom = object["customTitle"] as? String, !custom.isEmpty { title = custom }
      else if let generated = object["aiTitle"] as? String, !generated.isEmpty { title = generated }
    }
    return title.map { String($0.prefix(160)) }
  }
  /// The stores of harnesses other than Codex and Claude Code, for their running sessions.
  static func roots(home: String) -> SessionHistory.Roots {
    SessionHistory.Roots(home: home, environment: home == NSHomeDirectory() ? ProcessInfo.processInfo.environment : [:])
  }
  static func otherRoot(_ driver: HarnessDriver, home: String) -> String? {
    let r = roots(home: home)
    switch driver {
    case .pi: return r.pi
    case .ohMyPi: return r.ohMyPi
    case .grok: return r.grok
    default: return nil
    }
  }

  /// Pi, Oh My Pi and Grok keep no session file open either: each process gets the newest session
  /// of its folder written since it started (as older Claude Code does). Pi names the folder
  /// `--<cwd, "/" as "-">--`; Grok `<cwd percent-encoded>/<id>/`, whose events.jsonl marks each
  /// turn.
  public static func recentLog(_ process: HarnessProcess, driver: HarnessDriver, home: String, taken: Set<String>) -> String? {
    guard let cwd = process.cwd, let root = otherRoot(driver, home: home) else { return nil }
    let fm = FileManager.default
    func files(_ folder: String) -> [String] {
      ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).map { folder + "/" + $0 }
    }
    let candidates: [String]
    switch driver {
    case .pi, .ohMyPi:
      let name = "--" + String(cwd.drop { $0 == "/" }).replacingOccurrences(of: "[/\\\\:]", with: "-", options: .regularExpression) + "--"
      candidates = files(root + "/" + name).filter { $0.hasSuffix(".jsonl") }
    case .grok:
      let name = cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
      candidates = files(root + "/" + name).map { $0 + "/events.jsonl" }
    default: return nil
    }
    let since = process.startedAt.addingTimeInterval(-5)
    return candidates.filter { !taken.contains($0) }.compactMap { path -> (String, Date)? in
      guard let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, date >= since else { return nil }
      return (path, date)
    }.max { $0.1 < $1.1 }?.0
  }

  /// Pi's session format (also Oh My Pi): working while the last message is the
  /// user's or a tool result, or an answer that called a tool; nil once an answer ended the turn.
  public static func piState(_ data: Data) -> ExternalSession.State? {
    var state: ExternalSession.State?
    for line in data.split(separator: 10) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        object["type"] as? String == "message", let message = object["message"] as? [String: Any]
      else { continue }
      switch message["role"] as? String {
      case "user", "toolResult": state = .running
      case "assistant": state = message["stopReason"] as? String == "toolUse" ? .running : nil
      default: break
      }
    }
    return state
  }
  /// Grok's events.jsonl: working between `turn_started` and `turn_ended`.
  public static func grokState(_ data: Data) -> ExternalSession.State? {
    var state: ExternalSession.State?
    for line in data.split(separator: 10) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
      switch object["type"] as? String {
      case "turn_started": state = .running
      case "turn_ended": state = nil
      default: break
      }
    }
    return state
  }

  /// OpenCode keeps its chats in a database: the newest chat of the process's folder updated since
  /// it started. Working while the last message waits for an answer (one with no completion time).
  public static func databaseSession(
    _ process: HarnessProcess, driver: HarnessDriver, home: String, taken: Set<String>
  ) -> ExternalSession? {
    let r = roots(home: home)
    let folder = process.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    func session(_ id: String, _ title: String?, _ cwd: String?, _ state: ExternalSession.State, log: String) -> ExternalSession {
      var s = ExternalSession(
        id: "\(driver.rawValue):\(id)", driver: driver,
        title: AgentPrivacy.redact(SessionIndex.userTitle(title) ?? folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? driver.displayName),
        cwd: cwd.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? folder,
        state: state, updatedAt: process.startedAt, pid: process.pid)
      s.log = log
      return s
    }
    switch driver {
    case .opencode:
      // OpenCode records the folder as the process sees it (/private/tmp, not /tmp).
      guard let folder, let raw = process.cwd else { return nil }
      let since = String(Int((process.startedAt.timeIntervalSince1970 - 5) * 1000))
      let rows = SQLiteRows.read(r.opencodeDB, """
        SELECT s.id, s.title, s.directory,
          (SELECT json_extract(m.data, '$.role') || '|' || COALESCE(json_extract(m.data, '$.time.completed'), '')
           FROM message m WHERE m.session_id = s.id ORDER BY m.time_created DESC LIMIT 1)
        FROM session s WHERE s.directory IN (?, ?) AND s.parent_id IS NULL AND s.time_archived IS NULL
          AND s.time_updated >= CAST(? AS INTEGER)
        ORDER BY s.time_updated DESC
        """, [raw, folder, since]) ?? []
      guard let row = rows.first(where: { $0[0].map { !taken.contains("opencode:" + $0) } ?? false }), let id = row[0] else { return nil }
      let last = row[3] ?? ""
      return session(id, row[1], row[2], last == "user|" || last == "assistant|" ? .running : .open, log: r.opencodeDB + "-wal")
    default: return nil
    }
  }

  /// `~/.claude/projects/<cwd with every other character as "-">/<session>.jsonl`. Claude Code
  /// 2.1 and later names each process's session in `~/.claude/sessions/<pid>.json`; older
  /// versions get the newest transcript in the folder written since the process started, which
  /// can be a later `claude -p` run's.
  public static func claudeLog(_ process: HarnessProcess, home: String, taken: Set<String>) -> String? {
    func folder(_ cwd: String) -> URL {
      URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        .appendingPathComponent(String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }))
    }
    let record = URL(fileURLWithPath: home).appendingPathComponent(".claude/sessions/\(process.pid).json")
    if let data = try? Data(contentsOf: record),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = json["sessionId"] as? String, !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }),
      // The same process, not an earlier one with this pid.
      (json["startedAt"] as? Double).map({ abs($0 / 1000 - process.startedAt.timeIntervalSince1970) < 10 }) ?? true,
      let cwd = json["cwd"] as? String ?? process.cwd
    {
      let file = folder(cwd).appendingPathComponent(id + ".jsonl").path
      // No transcript yet (no request sent): none, rather than another chat's.
      return FileManager.default.fileExists(atPath: file) && !taken.contains(file) ? file : nil
    }
    guard let cwd = process.cwd else { return nil }
    let folder = folder(cwd)
    let files = (try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
    return files.filter { $0.pathExtension == "jsonl" && !taken.contains($0.path) }
      .compactMap { url -> (String, Date)? in
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              date >= process.startedAt.addingTimeInterval(-5) else { return nil }
        return (url.path, date)
      }.max { $0.1 < $1.1 }?.0
  }

  public mutating func snapshot(processes: [HarnessProcess], executables: [HarnessDriver: String] = [:], home: String = NSHomeDirectory()) -> [ExternalSession] {
    let drivers = Dictionary(uniqueKeysWithValues: processes.compactMap { process in
      HarnessProcessDiscovery.driver(process, executables: executables).map { (process.pid, $0) }
    })
    let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
    // A JS launcher may keep running while its native child holds the actual session logs.
    // Combine the evidence before deduping, so those logs are not lost with the child row.
    var roots: [Int32: HarnessProcess] = [:]
    var members: [Int32: Set<Int32>] = [:]
    for process in processes {
      guard let driver = drivers[process.pid] else { continue }
      var root = process
      var seen = Set<Int32>()
      while seen.insert(root.pid).inserted, drivers[root.parent] == driver, let parent = byPID[root.parent] { root = parent }
      members[root.pid, default: []].insert(process.pid)
      var combined = roots[root.pid] ?? root
      combined.logs = Array(Set(combined.logs + process.logs)).sorted()
      if process.arguments.contains("app-server"), !combined.arguments.contains("app-server") { combined.arguments.append("app-server") }
      roots[root.pid] = combined
    }
    // A server whose client is gone (its parent is launchd) serves no one: not a session.
    roots = roots.filter { _, process in
      !(process.parent == 1 && process.arguments.contains { ["serve", "app-server", "acp"].contains($0) })
    }
    // Claude Code does not keep its transcript open; each process gets the newest transcript in
    // its folder written since it started (newest process first, one transcript each).
    var taken = Set(roots.values.flatMap(\.logs))
    var claudeRecords: [Int32: [ClaudeSessionRecords.Record]] = [:]
    for (pid, process) in roots.sorted(by: { $0.value.startedAt > $1.value.startedAt })
    where drivers[pid] == .claude && process.logs.isEmpty {
      // Inspect the native children before falling back to the launcher's folder. A wrapper
      // has no process record and may otherwise be paired with a different chat in that folder.
      let records = (members[pid] ?? [pid]).sorted().compactMap { byPID[$0] }
        .compactMap { ClaudeSessionRecords.read($0, home: home) }
      if !records.isEmpty {
        claudeRecords[pid] = records
        roots[pid]?.logs = Array(Set(records.compactMap(\.file))).sorted()
        taken.formUnion(records.compactMap(\.file))
      } else if let log = Self.claudeLog(process, home: home, taken: taken) {
        roots[pid]?.logs = [log]
        taken.insert(log)
      }
    }
    for (pid, process) in roots.sorted(by: { $0.value.startedAt > $1.value.startedAt })
    where [.pi, .ohMyPi, .grok].contains(drivers[pid]) && process.logs.isEmpty {
      if let driver = drivers[pid], let log = Self.recentLog(process, driver: driver, home: home, taken: taken) {
        roots[pid]?.logs = [log]
        taken.insert(log)
      }
    }
    var sessions: [String: ExternalSession] = [:]
    var used = Set<String>()
    for process in roots.values {
      guard !Task.isCancelled else { return [] }
      guard let driver = drivers[process.pid] else { continue }
      let logs = process.logs.filter { Self.allowedLog($0, driver: driver, home: home) }
      for path in logs {
        used.insert(path)
        if var session = read(path, driver: driver, home: home) {
          session.pid = process.pid
          session.log = path
          sessions[session.id] = session
        }
      }
      // A Codex app-server can keep dozens of completed threads open. Only its active turns
      // count; a server with no rollouts is infrastructure, not a session.
      if driver == .codex && (!logs.isEmpty || process.arguments.contains("app-server")) { continue }
      if let records = claudeRecords[process.pid] {
        for record in records {
          let id = "claude:" + record.id
          if sessions[id] == nil {
            var session = ExternalSession(id: id, driver: .claude,
              title: record.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code",
              cwd: record.cwd, state: .open, updatedAt: process.startedAt, pid: process.pid)
            session.log = record.file
            sessions[id] = session
          }
          if record.waitingFor != nil { sessions[id]?.state = .needsUser }
        }
        continue
      }
      if !logs.isEmpty { continue }
      if let session = Self.databaseSession(
        process, driver: driver, home: home, taken: Set(sessions.keys))
      {
        sessions[session.id] = session
        continue
      }
      let id = "process:\(driver.rawValue):\(process.pid):\(process.startedAt.timeIntervalSince1970)"
      let folder = process.cwd.flatMap { $0 == "/" ? nil : URL(fileURLWithPath: $0).lastPathComponent }
      sessions[id] = ExternalSession(id: id, driver: driver, title: folder ?? driver.displayName,
                                    cwd: process.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                                    state: .open, updatedAt: process.startedAt, pid: process.pid)
    }
    cache = cache.filter { used.contains($0.key) }
    // Codex goals: a thread's own, or the goal of the thread that spawned it.
    let threads = sessions.values.filter { $0.driver == .codex }.flatMap { [String($0.id.dropFirst(6))] + ($0.parent.map { [$0] } ?? []) }
    let goals = Self.codexGoals(Array(Set(threads)), home: home)
    if !goals.isEmpty {
      for (id, session) in sessions where session.driver == .codex {
        sessions[id]?.goal = goals[String(id.dropFirst(6))] ?? session.parent.flatMap { goals[$0] }
      }
    }
    return sessions.values.sorted {
      if $0.state != $1.state { return rank($0.state) > rank($1.state) }
      return $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id
    }
  }
  private func rank(_ state: ExternalSession.State) -> Int { state == .needsUser ? 3 : state == .running ? 2 : 1 }

  private mutating func read(_ path: String, driver: HarnessDriver, home: String) -> ExternalSession? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
    let stamp = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
    if let cached = cache[path], cached.stamp == stamp { return cached.session }
    guard let head = try? handle.read(upToCount: SessionIndex.headLimit) else { return nil }
    let offset = max(0, info.st_size - 512 * 1024)
    guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
          var tail = try? handle.read(upToCount: 512 * 1024) else { return nil }
    bytesRead += head.count + tail.count
    // Ignore a partial first/last JSON line. A concurrent writer finishes it on the next poll.
    if offset > 0, let newline = tail.firstIndex(of: 10) { tail = Data(tail[tail.index(after: newline)...]) }
    if let newline = tail.lastIndex(of: 10) { tail = Data(tail[...newline]) } else { tail = Data() }
    let date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
    let metadata = driver == .codex
      ? SessionIndex.parseCodex(head: head, mtime: date, fallbackID: URL(fileURLWithPath: path).lastPathComponent)
      : SessionIndex.parseClaude(head: head, mtime: date, fallbackID: URL(fileURLWithPath: path).lastPathComponent)
    var session: ExternalSession?
    switch driver {
    case .pi, .ohMyPi:
      if let found = SessionHistory.piFormat(path, driver: driver) {
        session = ExternalSession(
          id: "\(driver.rawValue):\(found.id)", driver: driver, title: found.title,
          cwd: URL(fileURLWithPath: found.cwd).resolvingSymlinksInPath().path, state: Self.piState(tail) ?? .open, updatedAt: date)
      }
      cache[path] = Cached(stamp: stamp, session: session)
      return session
    case .grok:
      // events.jsonl beside the chat; summary.json may come only after the first turn.
      let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
      let found = SessionHistory.grok(folder.appendingPathComponent("summary.json").path)
      session = ExternalSession(
        id: "grok:" + (found?.id ?? folder.lastPathComponent), driver: driver, title: found?.title ?? "Grok session",
        cwd: found.map { URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().path }, state: Self.grokState(tail) ?? .open,
        updatedAt: date)
      cache[path] = Cached(stamp: stamp, session: session)
      return session
    default: break
    }
    if let metadata, let state = driver == .codex ? Self.codexState(tail) : Self.claudeState(tail) ?? .open {
      let title = driver == .codex
        ? Self.codexTitle(metadata.id, home: home).flatMap(SessionIndex.userTitle) ?? metadata.title
        : Self.claudeTitle(tail) ?? metadata.title
      session = ExternalSession(id: "\(driver.rawValue):\(metadata.id)", driver: driver,
                                title: AgentPrivacy.redact(title), cwd: URL(fileURLWithPath: metadata.cwd).resolvingSymlinksInPath().path,
                                state: state, updatedAt: date)
      if driver == .codex { session?.parent = Self.codexParent(head) } else { session?.loopUntil = Self.claudeLoop(tail) }
    }
    cache[path] = Cached(stamp: stamp, session: session)
    return session
  }

  /// For each Codex thread, its name as the Codex app shows it and whether another thread spawned
  /// it (a helper, which the app lists under its parent, never on its own), from Codex's newest
  /// state database, read only.
  public static func codexThreads(_ ids: [String], home: String) -> [String: (name: String?, helper: Bool)] {
    guard !ids.isEmpty else { return [:] }
    let root = URL(fileURLWithPath: home).appendingPathComponent(".codex")
    guard let database = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
      .filter({ $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" })
      .max(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending })
    else { return [:] }
    let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
    var facts: [String: (name: String?, helper: Bool)] = [:]
    let named = SQLiteRows.read(database.path, "SELECT id, COALESCE(NULLIF(name, ''), title) FROM threads WHERE id IN (\(marks))", ids)
      ?? SQLiteRows.read(database.path, "SELECT id, title FROM threads WHERE id IN (\(marks))", ids) ?? []
    for row in named { if let id = row[0] { facts[id] = (row[1].flatMap { $0.isEmpty ? nil : $0 }, false) } }
    let spawned = SQLiteRows.read(database.path, "SELECT child_thread_id FROM thread_spawn_edges WHERE child_thread_id IN (\(marks))", ids) ?? []
    for row in spawned { if let id = row[0] { facts[id] = (facts[id]?.name, true) } }
    return facts
  }

  public static func codexTitle(_ id: String, home: String) -> String? {
    let root = URL(fileURLWithPath: home).appendingPathComponent(".codex")
    let databases = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
      .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
    for url in databases {
      var db: OpaquePointer?
      guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        if let db { sqlite3_close(db) }; continue
      }
      defer { sqlite3_close(db) }
      sqlite3_busy_timeout(db, 50)
      // The thread's name (as the Codex app shows it) first; older databases have only a title.
      var statement: OpaquePointer?
      if sqlite3_prepare_v2(db, "SELECT name, title FROM threads WHERE id = ? LIMIT 1", -1, &statement, nil) != SQLITE_OK {
        sqlite3_finalize(statement)
        statement = nil
        guard sqlite3_prepare_v2(db, "SELECT NULL, title FROM threads WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK
        else { continue }
      }
      defer { sqlite3_finalize(statement) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      sqlite3_bind_text(statement, 1, id, -1, transient)
      guard sqlite3_step(statement) == SQLITE_ROW else { continue }
      for column in Int32(0)...1 {
        // Whole, not cut: the request in a Codex app title comes after its attached files.
        if let text = sqlite3_column_text(statement, column), case let value = String(cString: text), !value.isEmpty {
          return String(value.prefix(8000))
        }
      }
    }
    return nil
  }
}
