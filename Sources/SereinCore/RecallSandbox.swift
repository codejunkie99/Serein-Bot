import Foundation

/// A throwaway folder for one recall job. It holds copies of history, the daily summaries and kept
/// passages only, so the agent's working directory never contains the rest of the Library
/// (agent transcripts, projects, indexes). Symbolic links are never followed or copied.
public enum RecallSandbox {
  /// Library folders the agent may read, relative to the Library root.
  public static let folders = ["history", "index/days", "marks"]
  /// Tool patterns for Claude Code, limited to those folders.
  public static var claudeAllowedTools: String {
    ["Read", "Grep", "Glob"].flatMap { tool in
      ["history", "index", "marks"].map { "\(tool)(./\($0)/**)" }
    }.joined(separator: ",")
  }

  public static func prepare(library: URL) throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("serein-recall-" + UUID().uuidString)
    try fm.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    do {
      for folder in folders {
        try copyRegularFiles(
          from: library.appendingPathComponent(folder), to: root.appendingPathComponent(folder))
      }
    } catch {
      try? fm.removeItem(at: root)
      throw error
    }
    return root
  }
  public static func remove(_ root: URL) { try? FileManager.default.removeItem(at: root) }

  static func copyRegularFiles(from source: URL, to destination: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: keys)
    else { return }
    for item in items {
      let values = try? item.resourceValues(forKeys: Set(keys))
      if values?.isSymbolicLink == true { continue }
      if values?.isDirectory == true {
        try copyRegularFiles(from: item, to: destination.appendingPathComponent(item.lastPathComponent))
      } else if values?.isRegularFile == true {
        guard let text = String(data: try Data(contentsOf: item), encoding: .utf8) else { continue }
        func safeJSON(_ data: Data) -> String? {
          guard let json = try? JSONSerialization.jsonObject(with: data),
            let encoded = try? JSONSerialization.data(withJSONObject: AgentPrivacy.sanitize(json), options: [.sortedKeys, .withoutEscapingSlashes])
          else { return nil }
          return String(data: encoded, encoding: .utf8)
        }
        let safe: String
        if item.pathExtension == "jsonl" {
          safe = text.split(separator: "\n").compactMap { safeJSON(Data($0.utf8)) }.joined(separator: "\n") + "\n"
        } else if item.pathExtension == "json" {
          guard let json = safeJSON(Data(text.utf8)) else { continue }
          safe = json
        } else { safe = AgentPrivacy.redact(text) }
        let target = destination.appendingPathComponent(item.lastPathComponent)
        try Data(safe.utf8).write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      }
    }
  }
}
