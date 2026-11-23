import Foundation
import os
import SereinCore

/// Makes a session's reel (`ReportReel`) from facts on this Mac: git's line counts for the turn,
/// the media files the session wrote in its project while it worked, and its steps' test runs.
/// Media are copied into the library's chat-images folder, the one place a chat draws local files
/// from (`MessageImage.file`), so a picture stays after its original is changed or deleted. It
/// spends no AI usage and nothing in it reaches a model.
enum ReportReelMaker {
  private static let log = Logger(subsystem: "Serein", category: "ReportReel")
  /// The day's log of session reels, for the morning brief's roll-up.
  static let logPath = "relay/reels.json"
  /// A scan stops after this many entries: a report is never worth a long walk.
  static let scanLimit = 20_000
  static let scanDepth = 8
  /// How long git may take before the reel goes without line counts.
  static let gitWait: TimeInterval = 4
  /// A turn's start is known to the scan's second; files written just before still count.
  static let slack: TimeInterval = 60

  /// A reel for the turn between `since` and `until` in `cwd`, or nil when it has nothing to show.
  /// `project` is the folder's display name.
  @MainActor static func make(
    app: String, project: String?, cwd: String?, since: Date?, until: Date, activities: [TranscriptActivity],
    library: Library
  ) async -> ReportReel? {
    let images = library.root.appendingPathComponent("chat-images")
    var reel = ReportReel(title: app + (project.map { " in " + $0 } ?? ""))
    reel.tests = ReportReel.tests(activities)
    if let since { reel.minutes = max(1, Int(until.timeIntervalSince(since) / 60)) }
    if let cwd, scannable(cwd) {
      let start = (since ?? until.addingTimeInterval(-3600)).addingTimeInterval(-slack)
      let root = URL(fileURLWithPath: cwd)
      async let changes = gitChanges(in: root, since: start)
      // Walking and copying (a video can be large) stay off the main thread.
      async let made = Task.detached(priority: .utility) {
        copy(scan(root, since: start, until: until), project: project, into: images)
      }.value
      reel.setChanges(await changes)
      reel.media = await made
    }
    return reel.isEmpty ? nil : reel
  }

  /// A project folder, not the home folder, the root or a system place: walking those would read
  /// the person's own files.
  static func scannable(_ cwd: String) -> Bool {
    let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
    let home = NSHomeDirectory()
    let closed = ["/", home, home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Library", "/Users", "/Volumes"]
    guard !closed.contains(path), !path.hasPrefix(home + "/Library/"), !path.hasPrefix("/System"), !path.hasPrefix("/private") else {
      return false
    }
    return FileManager.default.fileExists(atPath: path)
  }

  // MARK: Git

  /// What git says the turn changed: commits since `since`, and what is not committed yet.
  static func gitChanges(in root: URL, since: Date) async -> [ReportReel.FileChange] {
    let epoch = "@\(Int(since.timeIntervalSince1970))"
    async let committed = git(["log", "--since=\(epoch)", "--numstat", "--format="], in: root)
    async let open = git(["diff", "--numstat", "HEAD"], in: root)
    let (done, pending) = await (committed, open)
    return ReportReel.numstat(done + "\n" + pending)
  }

  /// One git command's output, "" on any failure or after `gitWait`. Optional locks are off, so
  /// this never holds the index while the session's own git runs.
  private static func git(_ arguments: [String], in root: URL) async -> String {
    await Task.detached(priority: .utility) { () -> String in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["-C", root.path, "--no-pager"] + arguments
      var environment = ProcessInfo.processInfo.environment
      environment["GIT_OPTIONAL_LOCKS"] = "0"
      environment["GIT_TERMINAL_PROMPT"] = "0"
      process.environment = environment
      let out = Pipe()
      process.standardOutput = out
      process.standardError = FileHandle.nullDevice
      do { try process.run() } catch { return "" }
      let deadline = DispatchTime.now() + gitWait
      DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
      let data = out.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return "" }
      return String(decoding: data.prefix(1_000_000), as: UTF8.self)
    }.value
  }

  // MARK: Media

  /// The media the session wrote in `root` during the turn (`ReportReel.pick`), skipping
  /// dependency, build and hidden folders and symlinks.
  nonisolated static func scan(_ root: URL, since: Date, until: Date) -> [ReportReel.Candidate] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
    guard let walk = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var seen = 0
    var found: [ReportReel.Candidate] = []
    while let url = walk.nextObject() as? URL {
      seen += 1
      if seen > scanLimit { break }
      guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
      if values.isDirectory == true {
        if ReportReel.skippedFolders.contains(url.lastPathComponent) || walk.level >= scanDepth { walk.skipDescendants() }
        continue
      }
      guard ReportReel.kind(ofExtension: url.pathExtension) != nil, let modified = values.contentModificationDate,
        modified >= since
      else { continue }
      found.append(ReportReel.Candidate(path: url.path, modified: modified, bytes: values.fileSize ?? 0))
    }
    return ReportReel.pick(found, since: since, until: until)
  }

  /// Copies into chat-images as "reel-<id>.<ext>"; a file that cannot be copied stays out.
  nonisolated private static func copy(_ picked: [ReportReel.Candidate], project: String?, into folder: URL) -> [ReportReel.Media] {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return picked.compactMap { candidate in
      let source = URL(fileURLWithPath: candidate.path)
      guard let kind = ReportReel.kind(ofExtension: source.pathExtension) else { return nil }
      let name = "reel-" + UUID().uuidString.lowercased() + "." + source.pathExtension.lowercased()
      do {
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
      } catch {
        log.error("A made file could not be copied: \(error.localizedDescription, privacy: .public)")
        return nil
      }
      return ReportReel.Media(kind: kind, path: "chat-images/" + name, name: source.lastPathComponent, project: project, made: candidate.modified)
    }
  }

  // MARK: The day's log

  /// Keeps the reel for the morning brief, with the last three days.
  @MainActor static func remember(_ reel: ReportReel, project: String?, library: Library, now: Date = Date()) {
    var entries = library.load([ReportReel.Stamped].self, from: logPath) ?? []
    entries.append(ReportReel.Stamped(at: now, project: project, reel: reel))
    do {
      try library.save(ReportReel.pruned(entries, now: now), to: logPath)
    } catch {
      log.error("The day's reels could not be saved: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Yesterday's sessions as one reel, for under the morning brief.
  @MainActor static func yesterday(library: Library, now: Date = Date()) -> ReportReel? {
    ReportReel.day(library.load([ReportReel.Stamped].self, from: logPath) ?? [], before: now)
  }
}
