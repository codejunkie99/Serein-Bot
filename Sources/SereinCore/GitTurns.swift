import Foundation

/// Private per-turn snapshots of a project's working tree, kept as git trees.
///
/// A snapshot uses a temporary index (`GIT_INDEX_FILE`), `git add -u`, `git update-index` and
/// `git write-tree`, so the user's index, branches, stash list and config are never touched. Trees
/// are kept alive by refs under `refs/serein/turns/<run>/`. Nothing is ever committed or pushed.
///
/// The repository is untrusted: every call runs without system or global config, without hooks
/// or fsmonitor, with attributes read from the empty tree where git supports it, and with every
/// filter driver the repository defines blanked out, so git never runs a program the repository
/// names. Blocking: call off the main thread.
public struct GitTurns: Sendable {
  public enum Failure: Error, LocalizedError, Equatable {
    /// A limit or trust rule; the message is user-facing copy.
    case refused(String)
    case git(String)
    public var errorDescription: String? {
      switch self {
      case .refused(let copy): return copy
      case .git(let detail): return detail
      }
    }
  }
  public enum Probe: Sendable {
    case repo(GitTurns)
    case notGit
    case noGit
    case refused(String)
  }

  public let git: String
  public let root: URL

  public init(git: String, root: URL) {
    self.git = git
    self.root = root
  }

  /// A git that can run without prompting to install developer tools.
  public static func locateGit() -> String? {
    for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
    where FileManager.default.isExecutableFile(atPath: path) {
      return path
    }
    // /usr/bin/git is a shim that opens an installer when the command line tools are missing.
    let select = Process()
    select.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    select.arguments = ["-p"]
    select.standardOutput = FileHandle.nullDevice
    select.standardError = FileHandle.nullDevice
    guard (try? select.run()) != nil else { return nil }
    select.waitUntilExit()
    return select.terminationStatus == 0 ? "/usr/bin/git" : nil
  }

  /// The repository containing `folder`. Its root is resolved (symlinks followed), so two folders
  /// of one repository compare equal.
  public static func probe(folder: URL, git: String? = locateGit()) -> Probe {
    guard let git else { return .noGit }
    guard FileManager.default.fileExists(atPath: folder.path) else { return .notGit }
    let result = run(git, ["rev-parse", "--show-toplevel"], cwd: folder)
    if result.status != 0 {
      if result.error.contains("dubious ownership") {
        return .refused(EditTrackingCopy.untrustedOwner)
      }
      return .notGit
    }
    let top = String(decoding: result.output, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !top.isEmpty else { return .notGit }
    return .repo(GitTurns(git: git, root: URL(fileURLWithPath: top).resolvingSymlinksInPath()))
  }

  /// `git init` in a folder, only when the user asks for it.
  public static func initialize(folder: URL, git: String) throws {
    let result = run(git, ["init", "--quiet"], cwd: folder)
    if result.status != 0 { throw Failure.git(result.error) }
  }

  // MARK: Snapshots

  /// One saved working tree, plus the untracked files left out of it on purpose.
  public struct Snapshot: Sendable, Equatable {
    public var tree: String
    /// Untracked paths never written to git: likely secrets, or files over the size cap.
    public var skipped: [String]
  }

  /// The working tree as a tree id, refusing when untracked files exceed the limits.
  public func snapshot(
    maxBytes: Int64 = TrackingLimits.maxUntrackedBytes,
    maxFiles: Int = TrackingLimits.maxUntrackedFiles
  ) throws -> String {
    try capture(maxBytes: maxBytes, maxFiles: maxFiles).tree
  }

  /// Saves the working tree into a private temporary index and returns its tree.
  ///
  /// Untracked files that look like secrets or are larger than `SnapshotSkips.maxFileBytes` are
  /// never hashed into the repository; they are listed in `skipped` instead. The user's index is
  /// only read, and is reused as a stat cache only when no attribute in the repository could make
  /// a stored blob differ from the file's bytes.
  public func capture(
    maxBytes: Int64 = TrackingLimits.maxUntrackedBytes,
    maxFiles: Int = TrackingLimits.maxUntrackedFiles
  ) throws -> Snapshot {
    let flags = try safetyFlags()
    let (untracked, skipped) = try untrackedFiles(maxBytes: maxBytes, maxFiles: maxFiles, flags: flags)
    let seed = try reusesIndex(flags: flags)
    let tree = try withTemporaryIndex(seed: seed, flags: flags) { env in
      var tracked: [String] = []
      if seed {
        // Tracked files: the copied stat cache skips rehashing files that did not change.
        let update = call(["add", "-u", "--", "."], env: env, flags: flags)
        if update.status != 0 {
          // A split or unusual index can fail to copy; start from an empty one instead.
          if let path = env["GIT_INDEX_FILE"] { try? FileManager.default.removeItem(atPath: path) }
          tracked = try trackedFiles(flags: flags)
        }
      } else {
        tracked = try trackedFiles(flags: flags)
      }
      // Tracked files missing from disk are dropped from the index by --remove.
      let paths = tracked + untracked
      if !paths.isEmpty {
        let input = Data(paths.joined(separator: "\0").utf8) + Data([0])
        let add = call(
          ["update-index", "--add", "--remove", "-z", "--stdin"], env: env, input: input, flags: flags)
        guard add.status == 0 else { throw Failure.git(add.error) }
      }
      let tree = call(["write-tree"], env: env, flags: flags)
      let id = String(decoding: tree.output, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard tree.status == 0, Self.isObjectID(id) else { throw Failure.git(tree.error) }
      return id
    }
    return Snapshot(tree: tree, skipped: skipped)
  }

  /// Paths in the user's index, read only.
  private func trackedFiles(flags: [String]) throws -> [String] {
    let listing = call(["ls-files", "-z"], outputLimit: 256 * 1024 * 1024, flags: flags)
    guard listing.status == 0, !listing.truncated else { throw Failure.git(listing.error) }
    return listing.output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
  }

  /// Untracked, not ignored files to include, and the ones left out (secrets, big files).
  /// Refuses when what would be included exceeds the limits.
  private func untrackedFiles(maxBytes: Int64, maxFiles: Int, flags: [String]) throws -> (
    [String], [String]
  ) {
    // Enough output for the file limit with long paths; more means too many files anyway.
    let listing = call(
      ["ls-files", "-z", "--others", "--exclude-standard"], outputLimit: 32 * 1024 * 1024,
      flags: flags)
    guard listing.status == 0 else { throw Failure.git(listing.error) }
    if listing.truncated {
      throw Failure.refused(
        TrackingLimits.refusal(untrackedBytes: 0, untrackedFiles: maxFiles + 1, maxFiles: maxFiles)!)
    }
    var included: [String] = []
    var skipped: [String] = []
    var bytes: Int64 = 0
    for raw in listing.output.split(separator: 0) {
      let path = String(decoding: raw, as: UTF8.self)
      // A nested repository is listed as a folder; its files are not this project's.
      if path.hasSuffix("/") { continue }
      var info = stat()
      let found = lstat(root.appendingPathComponent(path).path, &info) == 0
      let size: Int64 = found ? Int64(info.st_size) : 0
      if SnapshotSkips.skips(path: path, size: size) {
        skipped.append(path)
        continue
      }
      included.append(path)
      bytes += size
      if included.count > maxFiles || bytes > maxBytes { break }
    }
    if let refusal = TrackingLimits.refusal(
      untrackedBytes: bytes, untrackedFiles: included.count, maxBytes: maxBytes, maxFiles: maxFiles)
    {
      throw Failure.refused(refusal)
    }
    return (included, skipped)
  }

  /// Whether the user's index may seed the temporary one. Its blobs were made with the
  /// repository's filters and conversions, which Serein switches off; reusing a stat-clean entry
  /// such as an LFS pointer would make Undo write the pointer instead of the file.
  private func reusesIndex(flags: [String]) throws -> Bool {
    if !(try filterNames()).isEmpty { return false }
    var sources: [URL] = []
    let info = call(["rev-parse", "--git-path", "info/attributes"], flags: flags)
    let infoPath = String(decoding: info.output, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if info.status == 0, !infoPath.isEmpty {
      sources.append(
        infoPath.hasPrefix("/") ? URL(fileURLWithPath: infoPath) : root.appendingPathComponent(infoPath))
    }
    var attributeFiles = Set([".gitattributes"])
    for path in try trackedFiles(flags: flags)
    where path == ".gitattributes" || path.hasSuffix("/.gitattributes") {
      attributeFiles.insert(path)
    }
    sources += attributeFiles.sorted().map { root.appendingPathComponent($0) }
    for url in sources {
      guard let data = SafeFileRead.regularFile(url.path, limit: 1_000_000) else { continue }
      if SnapshotSkips.changesContent(attributes: String(decoding: data, as: UTF8.self)) {
        return false
      }
    }
    return true
  }

  /// Keeps a tree reachable under `refs/serein/turns/<run>/<name>`.
  public func keep(_ tree: String, run: String, name: String) throws {
    guard Self.isObjectID(tree) else { throw Failure.git("Not an object id") }
    let ref = "refs/serein/turns/\(TurnPaths.refComponent(run))/\(TurnPaths.refComponent(name))"
    let result = call(["update-ref", ref, tree], flags: try safetyFlags())
    if result.status != 0 { throw Failure.git(result.error) }
  }

  /// Deletes this run's refs. Their trees become unreachable and git's own gc may prune them.
  public func drop(run: String) {
    let base = "refs/serein/turns/\(TurnPaths.refComponent(run))/"
    guard let flags = try? safetyFlags() else { return }
    for name in ["before", "after"] { _ = call(["update-ref", "-d", base + name], flags: flags) }
  }

  /// Run ids that still hold refs under `refs/serein/turns/`.
  public func keptRuns() -> [String] {
    guard let flags = try? safetyFlags() else { return [] }
    let result = call(
      ["for-each-ref", "--format=%(refname)", "refs/serein/turns/"], flags: flags)
    guard result.status == 0 else { return [] }
    let prefix = "refs/serein/turns/"
    var runs: [String] = []
    for line in String(decoding: result.output, as: UTF8.self).split(separator: "\n")
    where line.hasPrefix(prefix) {
      let run = line.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
      if !run.isEmpty && !runs.contains(run) { runs.append(run) }
    }
    return runs
  }

  // MARK: Diffs

  public func numstat(_ from: String, _ to: String) throws -> [DiffFile] {
    let result = call(
      ["diff-tree", "-r", "-z", "--numstat", "--no-renames", "--no-ext-diff", "--no-textconv", from, to],
      flags: try safetyFlags())
    guard result.status == 0 else { throw Failure.git(result.error) }
    return DiffStat.parseNumstat(String(decoding: result.output, as: UTF8.self))
  }

  public func changedPaths(_ from: String, _ to: String) throws -> [String] {
    let result = call(
      ["diff-tree", "-r", "-z", "--name-only", "--no-renames", from, to], flags: try safetyFlags())
    guard result.status == 0 else { throw Failure.git(result.error) }
    return result.output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
  }

  /// One file's unified diff, capped for display.
  public func patch(_ from: String, _ to: String, path: String) throws -> (
    text: String, truncated: Bool
  ) {
    guard TurnPaths.isSafe(path) else { throw Failure.git("Unsafe path") }
    let result = call(
      [
        "diff-tree", "-r", "-p", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
        from, to, "--", path,
      ], outputLimit: UnifiedDiff.maxBytes + 1, flags: try safetyFlags())
    guard result.status == 0 || result.truncated else { throw Failure.git(result.error) }
    return UnifiedDiff.cap(
      String(decoding: result.output, as: UTF8.self), inputTruncated: result.truncated)
  }

  // MARK: Restore

  /// Puts `paths` back to how they are in `tree`: files in the tree are written with
  /// `checkout-index`, files missing from it are removed. Only the listed paths change.
  public func restore(_ tree: String, paths: [String]) throws {
    guard Self.isObjectID(tree) else { throw Failure.git("Not an object id") }
    for path in paths where !TurnPaths.isSafe(path) { throw Failure.git("Unsafe path " + path) }
    let flags = try safetyFlags()
    try withTemporaryIndex(seed: false, flags: flags) { env in
      let read = call(["read-tree", tree], env: env, flags: flags)
      guard read.status == 0 else { throw Failure.git(read.error) }
      let listing = call(["ls-files", "-z"], env: env, outputLimit: 256 * 1024 * 1024, flags: flags)
      guard listing.status == 0 else { throw Failure.git(listing.error) }
      let inTree = Set(listing.output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
      let present = paths.filter { inTree.contains($0) }
      let absent = paths.filter { !inTree.contains($0) }
      for path in absent {
        let url = root.appendingPathComponent(path)
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR else { continue }
        try FileManager.default.removeItem(at: url)
        removeEmptyParents(of: url)
      }
      guard !present.isEmpty else { return }
      let input = Data(present.joined(separator: "\0").utf8) + Data([0])
      let checkout = call(
        ["checkout-index", "-f", "-z", "--stdin"], env: env, input: input, flags: flags)
      guard checkout.status == 0 else { throw Failure.git(checkout.error) }
    }
  }

  private func removeEmptyParents(of url: URL) {
    var dir = url.deletingLastPathComponent().standardizedFileURL
    let top = root.standardizedFileURL.path
    while dir.path.count > top.count, dir.path.hasPrefix(top + "/") {
      guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
        items.isEmpty, (try? FileManager.default.removeItem(at: dir)) != nil
      else { return }
      dir = dir.deletingLastPathComponent()
    }
  }

  // MARK: Safety

  /// Filter drivers defined in the repository's own config (system and global config are never
  /// read). Throws when a name cannot be neutralised with `-c`.
  public func filterNames() throws -> [String] {
    let result = Self.run(git, ["config", "-z", "--get-regexp", "^filter\\."], cwd: root)
    // Status 1: no filter is defined.
    if result.status == 1 && result.output.isEmpty { return [] }
    guard result.status == 0, !result.truncated,
      let names = GitSafety.filterNames(configZ: result.output)
    else { throw Failure.refused(EditTrackingCopy.unsafeFilters) }
    return names
  }

  /// Per-call flags: every repository filter driver blanked, and the empty tree as the only
  /// attribute source when this git supports it.
  func safetyFlags() throws -> [String] {
    var flags = GitSafety.blankFilters(try filterNames())
    if let empty = Self.emptyTree(git: git, root: root) { flags.insert("--attr-source=" + empty, at: 0) }
    return flags
  }

  /// The empty tree in this repository's hash, or nil when git is older than 2.40.
  private static func emptyTree(git: String, root: URL) -> String? {
    guard GitSafety.supportsAttrSource(version(git)) else { return nil }
    let key = "format|" + root.path
    if let known = cache.get(key) { return GitSafety.emptyTree(objectFormat: known) }
    let format = run(git, ["rev-parse", "--show-object-format"], cwd: root)
    let name = String(decoding: format.output, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard format.status == 0 else { return GitSafety.emptyTree(objectFormat: "sha1") }
    cache.set(key, name)
    return GitSafety.emptyTree(objectFormat: name)
  }

  private static let cache = Cache()
  private static func version(_ git: String) -> String {
    if let known = cache.get("version|" + git) { return known }
    let result = run(git, ["--version"], cwd: URL(fileURLWithPath: "/"))
    let text = String(decoding: result.output, as: UTF8.self)
    cache.set("version|" + git, text)
    return text
  }
  /// The user's own global excludes file, kept although global config is otherwise ignored.
  private static func globalExcludes(_ git: String) -> String {
    if let known = cache.get("excludes|" + git) { return known }
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: git)
    process.arguments = ["config", "--global", "--path", "--get", "core.excludesFile"]
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    process.environment = env
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    var value = ""
    if (try? process.run()) != nil {
      let data = (try? out.fileHandleForReading.read(upToCount: 4096)) ?? Data()
      process.waitUntilExit()
      let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      if process.terminationStatus == 0, path.hasPrefix("/"), !path.contains("\n") { value = path }
    }
    cache.set("excludes|" + git, value)
    return value
  }

  // MARK: Plumbing

  private func withTemporaryIndex<T>(
    seed: Bool, flags: [String], _ body: ([String: String]) throws -> T
  ) throws -> T {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("serein-turns", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = dir.appendingPathComponent("index")
    if seed {
      // Starting from a copy of the real index reuses its stat cache; the original is only read.
      let located = call(["rev-parse", "--git-path", "index"], flags: flags)
      let path = String(decoding: located.output, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if located.status == 0, !path.isEmpty {
        let real = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        try? FileManager.default.copyItem(at: real, to: index)
      }
    }
    return try body(["GIT_INDEX_FILE": index.path])
  }

  struct Result {
    var status: Int32
    var output: Data
    var error: String
    var truncated: Bool
  }

  func call(
    _ args: [String], env: [String: String] = [:], input: Data? = nil,
    outputLimit: Int = 16 * 1024 * 1024, flags: [String]
  ) -> Result {
    Self.run(git, flags + args, cwd: root, env: env, input: input, outputLimit: outputLimit)
  }

  /// Runs git with the repository treated as untrusted. `args` may start with global options
  /// (`--attr-source`, `-c`) before the command.
  static func run(
    _ git: String, _ args: [String], cwd: URL, env: [String: String] = [:], input: Data? = nil,
    outputLimit: Int = 16 * 1024 * 1024
  ) -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: git)
    // No hooks, no fsmonitor daemon, no attribute files outside the repository, literal paths,
    // no optional index writes.
    var base = [
      "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0",
      "-c", "core.attributesFile=/dev/null",
    ]
    if args.first != "--version" {
      let excludes = globalExcludes(git)
      if !excludes.isEmpty { base += ["-c", "core.excludesFile=" + excludes] }
    }
    process.arguments = base + ["--literal-pathspecs", "--no-optional-locks"] + args
    process.currentDirectoryURL = cwd
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_TERMINAL_PROMPT"] = "0"
    // Only the repository's own config: a system or global filter, hook path or helper never runs.
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["LC_ALL"] = "C"
    for (key, value) in env { environment[key] = value }
    process.environment = environment
    let out = Pipe()
    let err = Pipe()
    let inPipe = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
    do { try process.run() } catch {
      return Result(status: -1, output: Data(), error: error.localizedDescription, truncated: false)
    }
    let group = DispatchGroup()
    let errBox = DataBox()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      errBox.set(err.fileHandleForReading.readDataToEndOfFile())
      group.leave()
    }
    if let input {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        try? inPipe.fileHandleForWriting.write(contentsOf: input)
        try? inPipe.fileHandleForWriting.close()
        group.leave()
      }
    }
    var output = Data()
    var truncated = false
    // Keep draining past the limit so git never blocks on a full pipe.
    while let chunk = try? out.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
      if output.count < outputLimit {
        output.append(chunk.prefix(outputLimit - output.count))
        if output.count >= outputLimit { truncated = true }
      } else {
        truncated = true
      }
    }
    process.waitUntilExit()
    group.wait()
    return Result(
      status: process.terminationStatus, output: output,
      error: String(String(decoding: errBox.get(), as: UTF8.self).prefix(2000)),
      truncated: truncated)
  }

  static func isObjectID(_ id: String) -> Bool {
    (id.count == 40 || id.count == 64) && id.allSatisfy { $0.isHexDigit }
  }
}

private final class DataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Data()
  func set(_ data: Data) {
    lock.lock()
    value = data
    lock.unlock()
  }
  func get() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private final class Cache: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]
  func get(_ key: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }
  func set(_ key: String, _ value: String) {
    lock.lock()
    values[key] = value
    lock.unlock()
  }
}

/// Pure helpers for running git on an untrusted repository.
public enum GitSafety {
  /// Filter driver names from `git config -z --get-regexp '^filter\.'` output (`key\nvalue\0`).
  /// nil when a name could not be passed safely to `-c`.
  public static func filterNames(configZ: Data) -> [String]? {
    var names: [String] = []
    for entry in configZ.split(separator: 0) {
      let text = String(decoding: entry, as: UTF8.self)
      let key = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
        .map(String.init) ?? ""
      guard key.lowercased().hasPrefix("filter."), let dot = key.lastIndex(of: ".") else { continue }
      let start = key.index(key.startIndex, offsetBy: "filter.".count)
      guard start < dot else { continue }
      let name = String(key[start..<dot])
      if name.contains("=") || name.contains("\0") || name.contains("\n") { return nil }
      if !names.contains(name) { names.append(name) }
    }
    return names
  }
  /// `-c` flags that leave each named filter driver with nothing to run.
  public static func blankFilters(_ names: [String]) -> [String] {
    names.flatMap { name in
      ["clean=", "smudge=", "process=", "required=false"].flatMap { ["-c", "filter.\(name).\($0)"] }
    }
  }
  /// `--attr-source` arrived in git 2.40.
  public static func supportsAttrSource(_ versionOutput: String) -> Bool {
    guard let token = versionOutput.split(separator: " ").first(where: { $0.first?.isNumber == true })
    else { return false }
    let parts = token.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    guard parts.count >= 2 else { return false }
    return parts[0] > 2 || (parts[0] == 2 && parts[1] >= 40)
  }
  public static func emptyTree(objectFormat: String) -> String {
    objectFormat == "sha256"
      ? "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"
      : "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  }
}

/// Untracked files a snapshot never stores: likely secrets and large files.
public enum SnapshotSkips {
  public static let maxFileBytes: Int64 = 5 * 1024 * 1024
  /// `.env*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, SSH keys (`id_rsa`, `id_ed25519.pub` …) and
  /// credential dotfiles.
  public static func isSecret(_ path: String) -> Bool {
    let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
    if name.hasPrefix(".env") { return true }
    if [".pem", ".key", ".p12", ".pfx"].contains(where: { name.hasSuffix($0) }) { return true }
    if [".netrc", ".npmrc", ".pypirc"].contains(name) { return true }
    if name.hasPrefix("id_") {
      // SSH key pairs have no extension, or .pub; source files such as id_card.swift do not match.
      return !name.contains(".") || name.hasSuffix(".pub")
    }
    return false
  }
  public static func skips(path: String, size: Int64) -> Bool {
    isSecret(path) || size > maxFileBytes
  }
  /// Whether attribute text may make git store something other than the file's bytes.
  public static func changesContent(attributes text: String) -> Bool {
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      let lower = trimmed.lowercased()
      if ["filter", "eol", "crlf", "ident", "working-tree-encoding"].contains(where: lower.contains) {
        return true
      }
    }
    return false
  }
  /// One line for the changes card.
  public static func note(_ skipped: [String]) -> String? {
    guard let first = skipped.first else { return nil }
    let more = skipped.count > 1 ? " and \(skipped.count - 1) more" : ""
    return "Left out of undo: \(first)\(more). Untracked files that look like secrets or are over 5 MB are never saved in snapshots."
  }
}
