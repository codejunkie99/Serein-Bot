import Foundation
import SereinCore

/// The empty, private folder every helper runs in. Helpers have no tools, so it stays empty. It and
/// the helpers' files sit in Serein's run folder, which no task's shell can write.
enum HelperFolder {
  static let url: URL = {
    let url = AgentFileGuard.runRoot.appendingPathComponent("serein-helper", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }()
  /// Session lists leave out helper runs, those from before the folder left TMPDIR included.
  static var hidden: Set<String> {
    [url.path, FileManager.default.temporaryDirectory.appendingPathComponent("serein-helper").path]
  }
  /// OpenCode 2.x has no `--pure`; pointing OPENCODE_CONFIG_DIR at this empty folder keeps the
  /// user's plugins, agents and commands out of Serein's server, as `--pure` did on 1.x.
  static let openCodeConfig: String = {
    let url = AgentFileGuard.runRoot.appendingPathComponent("serein-opencode-config", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url.path
  }()
}
