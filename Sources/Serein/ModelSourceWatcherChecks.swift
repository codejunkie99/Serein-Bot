#if DEBUG
import Foundation
import SereinCore

/// `--verify-model-watch`: the watcher against real files in a temporary folder (run with
/// CODEX_HOME set to that folder's codex-home). A cache rewrite with the same models and a write
/// next to it are not changes; new model ids and a CLI link moved to a new install are.
@MainActor func checkModelSourceWatcher() async throws {
  guard let home = ProcessInfo.processInfo.environment["CODEX_HOME"], home.hasPrefix(NSTemporaryDirectory()) || home.hasPrefix("/private/tmp/") || home.hasPrefix("/tmp/") else {
    throw SereinError.invalid("Set CODEX_HOME to a new folder under the temporary folder.")
  }
  let fm = FileManager.default
  let root = URL(fileURLWithPath: home).deletingLastPathComponent()
  let cache = URL(fileURLWithPath: home).appendingPathComponent("models_cache.json")
  let link = root.appendingPathComponent("bin/codex")
  for folder in ["bin", "v1", "v2", "codex-home/sessions"] {
    try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
  }
  try Data("v1".utf8).write(to: root.appendingPathComponent("v1/codex"))
  try Data("v2!".utf8).write(to: root.appendingPathComponent("v2/codex"))
  try fm.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("v1/codex").path)
  func cacheFile(_ slugs: [String], at time: String) throws {
    let models = slugs.map { "{\"slug\":\"\($0)\"}" }.joined(separator: ",")
    try Data("{\"fetched_at\":\"\(time)\",\"models\":[\(models)]}".utf8).write(to: cache, options: .atomic)
  }
  try cacheFile(["gpt-a"], at: "1")

  var seen: [ModelSourceWatcher.Change] = []
  let watcher = ModelSourceWatcher.shared
  watcher.onChange = { driver, change in if driver == .codex { seen.append(change) } }
  watcher.watch(.codex, executable: link.path, environment: ProcessInfo.processInfo.environment)
  try await Task.sleep(nanoseconds: 1_500_000_000)
  func step(_ name: String, expect: [ModelSourceWatcher.Change], _ change: () throws -> Void) async throws {
    seen = []
    try change()
    try await Task.sleep(nanoseconds: 4_500_000_000)
    guard seen == expect else { throw SereinError.invalid("\(name): expected \(expect), saw \(seen)") }
    print("PASS: \(name)")
  }
  try await step("same models, new fetch time", expect: []) { try cacheFile(["gpt-a"], at: "2") }
  try await step("a write next to the cache", expect: []) {
    try Data("x".utf8).write(to: URL(fileURLWithPath: home).appendingPathComponent("sessions/rollout.jsonl"))
  }
  try await step("a new model in the cache", expect: [.models]) { try cacheFile(["gpt-a", "gpt-b"], at: "3") }
  let version = URL(fileURLWithPath: home).appendingPathComponent("version.json")
  try await step("Codex's update check found a newer release", expect: [.version]) {
    try Data(#"{"latest_version":"9.9.9"}"#.utf8).write(to: version, options: .atomic)
  }
  try await step("the same release checked again", expect: []) {
    try Data(#"{"latest_version":"9.9.9","last_checked_at":"later"}"#.utf8).write(to: version, options: .atomic)
  }
  try await step("CLI link moved to a new install", expect: [.cli]) {
    let temporary = root.appendingPathComponent("bin/.codex-new")
    try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: root.appendingPathComponent("v2/codex").path)
    _ = rename(temporary.path, link.path)
  }
  watcher.watch(.codex, executable: nil)
}
#endif
