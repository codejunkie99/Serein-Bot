import Darwin
import Foundation
import SereinCore

/// The CLIs this Serein started, one file per group, so the next launch can end what a crash left.
/// serein-process-host writes `<directory>/<pid>` after setsid and before exec, so a group that
/// could run has a record.
struct RunRecords: Sendable {
  static let tagVariable = "SEREIN_RUN_TAG"
  static let directoryVariable = "SEREIN_RUN_DIR"

  /// In the Library, which no harness can write, so no CLI can plant a record.
  let root: URL
  /// Unique to this Serein run. The CLI carries it in its environment, and the sweep ends only a
  /// group a process of which still carries it: a pid reused by another program never matches.
  let tag: String

  init(root: URL = AgentAccess.defaultRoot.appendingPathComponent("engine-runs", isDirectory: true), tag: String = UUID().uuidString) {
    self.root = root
    self.tag = tag
  }

  var directory: URL { root.appendingPathComponent(tag, isDirectory: true) }
  var environment: [String: String] { [Self.tagVariable: tag, Self.directoryVariable: directory.path] }

  func prepare(owner: ProcessGroupRecord.Member) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(owner).write(to: directory.appendingPathComponent("owner"), options: .atomic)
  }

  func release(_ pid: pid_t) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(String(pid))) }
  func removeAll() { try? FileManager.default.removeItem(at: directory) }
}

/// What the sweep reads about running processes. The real one asks the kernel; checks pass a fake.
protocol ProcessTable: Sendable {
  /// Start time and group of a process of this user; nil once it exited or is someone else's.
  func live(_ pid: pid_t) -> ProcessGroupRecord.Live?
  func members(ofGroup pgid: pid_t) -> [pid_t]
  func children(of pid: pid_t) -> [pid_t]
  func environment(of pid: pid_t) -> [String]?
  func signalGroup(_ pgid: pid_t, _ signal: Int32)
}

enum RunSweep {
  struct Leftover: Equatable {
    var pgid: pid_t
    var tag: String
  }

  /// Groups recorded by a Serein that no longer runs and still carrying its tag. Removes those
  /// records. Never matches by process name: a CLI the person runs by hand is never ended.
  static func leftovers(in root: URL, except ownTag: String, table: any ProcessTable) -> [Leftover] {
    let runs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    var found: [Leftover] = []
    for run in runs where run.lastPathComponent != ownTag {
      let owner = (try? Data(contentsOf: run.appendingPathComponent("owner")))
        .flatMap { try? JSONDecoder().decode(ProcessGroupRecord.Member.self, from: $0) }
      if let owner, table.live(owner.pid)?.started == owner.started { continue }
      let tag = run.lastPathComponent
      let files = (try? FileManager.default.contentsOfDirectory(atPath: run.path)) ?? []
      found += files.compactMap(pid_t.init).map { Leftover(pgid: $0, tag: tag) }.filter { carries($0, table: table) }
      try? FileManager.default.removeItem(at: run)
    }
    return found
  }

  static func carries(_ leftover: Leftover, table: any ProcessTable) -> Bool {
    let marker = "\(RunRecords.tagVariable)=\(leftover.tag)"
    return Set([leftover.pgid] + table.members(ofGroup: leftover.pgid)).contains { pid in
      table.live(pid)?.pgid == leftover.pgid && table.environment(of: pid)?.contains(marker) == true
    }
  }

  /// This Serein's own groups that still carry its tag, and each CLI whose host has not written
  /// its record yet: that host is a child carrying the tag, and its pid is the group it will lead.
  static func own(_ records: RunRecords, table: any ProcessTable) -> [pid_t] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: records.directory.path)) ?? []
    let recorded = files.compactMap(pid_t.init).filter { carries(Leftover(pgid: $0, tag: records.tag), table: table) }
    let marker = "\(RunRecords.tagVariable)=\(records.tag)"
    let starting = table.children(of: getpid()).filter { table.environment(of: $0)?.contains(marker) == true }
    return Array(Set(recorded + starting))
  }

  /// TERM to each leftover group, then KILL to what still carries the tag after the grace.
  static func sweep(_ records: RunRecords, table: any ProcessTable, sleep: Sleep) async {
    let found = leftovers(in: records.root, except: records.tag, table: table)
    guard !found.isEmpty else { return }
    for leftover in found { table.signalGroup(leftover.pgid, SIGTERM) }
    await sleep(.seconds(2))
    for leftover in found where carries(leftover, table: table) { table.signalGroup(leftover.pgid, SIGKILL) }
  }
}
