import Foundation

/// Claude's process records identify a conversation even when a launcher owns the process tree.
/// Profile roots are admitted only from the known profile layout or a validated process record.
public enum ClaudeSessionRecords {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var discovered = Set<String>()

  public static func roots(home: String) -> [URL] {
    let fm = FileManager.default
    let profiles = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Multi Claude/profiles")
    var roots = [URL(fileURLWithPath: home).appendingPathComponent(".claude")]
    roots += ((try? fm.contentsOfDirectory(atPath: profiles.path)) ?? []).map {
      profiles.appendingPathComponent($0).appendingPathComponent("claude-code")
    }
    lock.lock()
    let realHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
    roots += discovered.filter { $0.hasPrefix(realHome + "/") }.map { URL(fileURLWithPath: $0) }
    lock.unlock()
    return Array(Set(roots.map { $0.resolvingSymlinksInPath() }))
  }

  public struct Record {
    public var id: String
    public var cwd: String?
    public var file: String?
    /// What the live session waits on ("input needed"), while Claude Code says it is waiting. The
    /// transcript may not show the question yet (newer versions write it once answered).
    public var waitingFor: String? = nil
  }

  public static func read(_ process: HarnessProcess, home: String) -> Record? {
    var candidates = roots(home: home)
    var folder = URL(fileURLWithPath: process.executable).deletingLastPathComponent()
    for _ in 0..<10 where folder.path.hasPrefix(home + "/") {
      candidates += [folder.appendingPathComponent("claude-code"), folder.appendingPathComponent(".claude")]
      folder = folder.deletingLastPathComponent()
    }
    for config in candidates {
      let record = config.appendingPathComponent("sessions/\(process.pid).json")
      guard let size = try? record.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 64 * 1024,
        let data = try? Data(contentsOf: record),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        (json["pid"] as? NSNumber)?.int32Value == process.pid,
        let id = json["sessionId"] as? String, UUID(uuidString: id) != nil,
        (json["startedAt"] as? Double).map({ abs($0 / 1000 - process.startedAt.timeIntervalSince1970) < 10 }) ?? true
      else { continue }
      lock.lock()
      discovered.insert(config.resolvingSymlinksInPath().path)
      lock.unlock()
      let projects = config.appendingPathComponent("projects")
      let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
      let file = folders.lazy.map { $0.appendingPathComponent(id + ".jsonl").path }
        .first { FileManager.default.fileExists(atPath: $0) }
      return Record(id: id, cwd: json["cwd"] as? String ?? process.cwd, file: file, waitingFor: waiting(json))
    }
    return nil
  }

  /// "waiting" with a reason: a question or an approval holds the session for the person. Any
  /// other status (busy, idle) leaves the state to the transcript.
  public static func waiting(_ json: [String: Any]) -> String? {
    guard json["status"] as? String == "waiting", let reason = json["waitingFor"] as? String,
      !reason.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return reason
  }
}
