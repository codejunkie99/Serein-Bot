import Foundation
import SereinCore

/// Pull request state for the Agents list, from the GitHub CLI (`gh`) when it is installed and
/// signed in: by a PR link a task's messages hold, or by the branch an outside session's folder is
/// on. One lookup at a time, off the main thread, from a neutral folder (never inside a project);
/// answers are kept for a few minutes (an hour once merged or closed). Without `gh` nothing runs
/// and rows show no state.
@MainActor final class PullRequestStore: ObservableObject {
  static let shared = PullRequestStore()
  enum Key: Hashable {
    case url(String)
    case folder(String)
  }
  /// nil: looked up, no pull request.
  @Published private(set) var found: [Key: PullRequestLookup.Info?] = [:]
  private var checked: [Key: Date] = [:]
  private var queue: [Key] = []
  private var running = false
  private lazy var gh: String? = AgentModel.locate("gh")

  /// What is known for a key; asks for it (once per few minutes) when it is missing or old.
  func info(_ key: Key) -> PullRequestLookup.Info? { found[key] ?? nil }

  func want(_ key: Key) {
    guard !RunMode.automated, !RunMode.previewing, gh != nil else { return }
    if let at = checked[key], Date().timeIntervalSince(at) < lifetime(found[key] ?? nil) { return }
    guard !queue.contains(key) else { return }
    queue.append(key)
    next()
  }
  private func lifetime(_ info: PullRequestLookup.Info?) -> TimeInterval {
    switch info?.state {
    case .merged?, .closed?: return 3600
    default: return 300
    }
  }
  private func next() {
    guard !running, !queue.isEmpty, let gh else { return }
    let key = queue.removeFirst()
    running = true
    Task {
      let info = await Task.detached(priority: .utility) { Self.lookup(key, gh: gh) }.value
      running = false
      checked[key] = Date()
      if found[key] != .some(info) { found[key] = info }
      next()
    }
  }

  nonisolated private static func lookup(_ key: Key, gh: String) -> PullRequestLookup.Info? {
    let arguments: [String]
    switch key {
    case .url(let url):
      guard let url = PullRequestLookup.pullURL(url) else { return nil }
      arguments = PullRequestLookup.viewArguments(url: url)
    case .folder(let folder):
      guard let place = PullRequestLookup.repositoryAndBranch(folder: folder) else { return nil }
      arguments = PullRequestLookup.listArguments(repository: place.repository, branch: place.branch)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: gh)
    process.arguments = arguments
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    var environment = ProcessInfo.processInfo.environment
    environment["GH_PROMPT_DISABLED"] = "1"
    environment["NO_COLOR"] = "1"
    environment["GH_NO_UPDATE_NOTIFIER"] = "1"
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let deadline = DispatchTime.now() + 15
    DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return PullRequestLookup.parse(data.prefix(64 * 1024))
  }

  /// Previews show each state without running anything.
  func installPreview(_ values: [Key: PullRequestLookup.Info?]) {
    for (key, value) in values {
      found[key] = value
      checked[key] = .distantFuture
    }
  }
}
