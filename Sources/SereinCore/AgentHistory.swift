import CryptoKit
import Darwin
import Foundation

/// The ledger also names native inference, which is not an installed CLI harness.
public enum AgentHistoryHarness: String, Codable, Sendable {
  case claude, codex, cursor, opencode, pi, ohMyPi = "omp", grok, gemini
  case localModel = "local-model"
  /// Runs recorded before Serein dropped these apps. The ledger is read whole, so they keep a case.
  case commandCode = "commandcode", hermes
  public var displayName: String {
    switch self {
    case .commandCode: return "Command Code"
    case .hermes: return "Hermes Agent"
    default: return HarnessDriver(rawValue: rawValue)?.displayName ?? "Local model"
    }
  }
}

/// Content-free records owned by Serein. Nothing in this format is executable or grants access.
public struct AgentHistoryRun: Codable, Equatable {
  public let id: UUID
  public let threadID: UUID?
  public let projectID: UUID?
  public let harness: AgentHistoryHarness
  /// The numeric release reported by the probe; no executable path or account information.
  public let harnessVersion: String?
  /// A selected model is fingerprinted, since custom model names can contain private data.
  /// nil means the CLI chose its default; Serein does not claim to know the resolved model.
  public let modelFingerprint: String?
  public let mode: Mode
  public let permission: RunPermissionMode
  public let grants: Grants
  /// What started this run, when it was not the user sending a message themselves: Relay's own
  /// chat, a run Relay delegated, a scheduled request, or a fired watch. nil for the user's own
  /// runs and for records written before this field existed.
  public var initiator: Initiator?

  public enum Mode: String, Codable { case answer, library, anywhere, research, page, project, auto }
  /// Who set a run in motion: every run in the ledger
  /// says whether the person, Relay, a schedule or a watch started it.
  public enum Initiator: String, Codable, Sendable {
    /// `handoff`: a task one assistant handed to another (the target's run). Like the unattended
    /// kinds it is not started by the person, so it is the lower trust class.
    /// `ask`: an assistant answers another assistant's light question (`assistant_ask`) in a
    /// hidden chat. It only reads.
    case relay, delegated, scheduled, watch, webhook, handoff, ask
    public var label: String {
      switch self {
      case .relay: return "Serein"
      case .delegated: return "a task Serein started"
      case .scheduled: return "a scheduled request"
      case .watch: return "an alert"
      case .webhook: return "a webhook"
      case .handoff: return "a hand-off between assistants"
      case .ask: return "a question from another assistant"
      }
    }
    /// Nobody is there to answer a card: a schedule, a watch or a webhook started the run.
    /// A hand-off target is attended: the person answers its cards (lead decision (a));
    /// downloads and backups refuse it on their own. A light ask only reads, so each of its
    /// steps is judged as unattended: what needs a card is refused.
    public var isUnattended: Bool {
      switch self {
      case .scheduled, .watch, .webhook, .ask: return true
      case .relay, .delegated, .handoff: return false
      }
    }
  }
  public struct Grants: Codable, Equatable {
    public var currentTab: Bool
    public var actions: Bool
    public var edits: Bool
    public var mac: Bool
    public var library: Bool
    public var signIns: Bool
    public init(currentTab: Bool = false, actions: Bool = false, edits: Bool = false,
                mac: Bool = false, library: Bool = false, signIns: Bool = false) {
      self.currentTab = currentTab; self.actions = actions; self.edits = edits
      self.mac = mac; self.library = library; self.signIns = signIns
    }
  }
  public init(id: UUID, threadID: String, projectID: String?, harness: HarnessDriver?,
              harnessVersion: String?, model: String, mode: Mode,
              permission: RunPermissionMode, grants: Grants, initiator: Initiator? = nil) {
    self.id = id
    self.threadID = UUID(uuidString: threadID)
    self.projectID = projectID.flatMap(UUID.init(uuidString:))
    self.harness = harness.flatMap { AgentHistoryHarness(rawValue: $0.rawValue) } ?? .localModel
    let version = harnessVersion?.split(separator: ".").prefix(3).map(String.init)
    self.harnessVersion = version.flatMap { parts in
      (2...3).contains(parts.count) && parts.allSatisfy {
        !$0.isEmpty && $0.count <= 6 && $0.allSatisfy { $0.isASCII && $0.isNumber }
      } ? parts.joined(separator: ".") : nil
    }
    self.modelFingerprint = model.isEmpty ? nil : AgentHistoryArchive.fingerprint(model)
    self.mode = mode; self.permission = permission; self.grants = grants
    self.initiator = initiator
  }
  public enum CodingKeys: String, CodingKey {
    case id, threadID, projectID, harness, harnessVersion, modelFingerprint
    case mode, permission, grants, initiator
  }
  /// Records written before `initiator` existed decode unchanged, with nil for it.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    threadID = try c.decodeIfPresent(UUID.self, forKey: .threadID)
    projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
    harness = try c.decode(AgentHistoryHarness.self, forKey: .harness)
    harnessVersion = try c.decodeIfPresent(String.self, forKey: .harnessVersion)
    modelFingerprint = try c.decodeIfPresent(String.self, forKey: .modelFingerprint)
    mode = try c.decode(Mode.self, forKey: .mode)
    permission = try c.decode(RunPermissionMode.self, forKey: .permission)
    grants = try c.decode(Grants.self, forKey: .grants)
    initiator = try c.decodeIfPresent(Initiator.self, forKey: .initiator)
  }
}

public struct AgentHistoryEvent: Codable, Equatable, Identifiable {
  public enum Kind: String, Codable {
    case runStarted, toolRequested, toolReturned, toolFailed, toolReported, toolFailureReported
    case grantChanged, permissionAnswered, approvalRequested, approvalResolved, capabilityRevoked, runEnded
    case sessionLinked, outcomeReported, outcomeClassified, interrupted
    /// A kept sign-in's cookies went into the task's own store (the site is not recorded).
    case keptSignInUsed
  }
  /// Host tool returns confirm only that the call returned, never a purchase or other effect.
  public enum Source: String, Codable { case host, harness, agent }
  public enum Grant: String, Codable { case actions, edits, mac, signIns }
  public enum Effect: String, Codable { case currentRun, nextTurn }
  /// `allowedByAutopilot`: Relay's Autopilot let an ordinary step go ahead without asking (RelayAutonomy).
  public enum Decision: String, Codable { case allowedOnce, alwaysAllowed, denied, allowedByAutopilot }
  public enum Tool: String, Codable {
    case tabs, open, navigate, readPage, click, typeText, select, hover, scroll, key, back
    case wait, screenshot, close, finish, macScript, macObserve, macAct, plugin, unknown
    case fileRead, fileEdit, command, test, build, web, plan, other
    public static func browser(_ name: String) -> Tool {
      switch name {
      case "tabs", "list_tabs": return .tabs
      case "open", "open_tab": return .open
      case "go", "navigate": return .navigate
      case "read", "find": return .readPage
      case "type", "fill": return .typeText
      case "close", "close_tab": return .close
      case "mac_script": return .macScript
      case "mac_observe": return .macObserve
      case "mac_act": return .macAct
      default: return Tool(rawValue: name).flatMap {
        [.click, .select, .hover, .scroll, .key, .back, .wait, .screenshot, .finish].contains($0) ? $0 : nil
      } ?? .unknown
      }
    }
    public static func activity(_ name: String) -> Tool {
      switch name {
      case "read": return .fileRead
      case "edit": return .fileEdit
      case "command": return .command
      case "test": return .test
      case "build": return .build
      case "web": return .web
      case "plan": return .plan
      default: return .other
      }
    }
  }
  public let id: UUID
  public let sequence: Int
  public let time: Date
  public let issuerID: UUID
  /// Stable within this library for a harness, across runs and app launches. Not authenticated.
  public let actorID: String
  public let run: AgentHistoryRun
  public let kind: Kind
  public let source: Source
  /// An outcome helper can be a different harness from the one that performed the task.
  /// Kept as the ledger's own type so events from apps Serein dropped still read.
  public let reportingHarness: AgentHistoryHarness?
  public let operationID: UUID?
  public let tool: Tool?
  public let grant: Grant?
  public let enabled: Bool?
  public let effect: Effect?
  public let decision: Decision?
  public let outcome: RunRecord.Outcome?
  /// Hash of the harness session id. It can link resumed turns but cannot resume a session.
  public let sessionFingerprint: String?
}

/// Unsigned, versioned transport. The checksum detects accidental changes, not forgery.
public struct AgentHistoryArchive: Codable, Equatable {
  public static let format = "serein-agent-history"
  public static let version = 1
  public static let maxBytes = 64 * 1024 * 1024
  public let format: String
  public let schemaVersion: Int
  public let issuerID: UUID
  public let exportedAt: Date
  public let events: [AgentHistoryEvent]
  public let checksum: String

  public init(issuerID: UUID, events: [AgentHistoryEvent], exportedAt: Date = Date()) throws {
    self.format = Self.format; self.schemaVersion = Self.version
    self.issuerID = issuerID; self.exportedAt = exportedAt; self.events = events
    self.checksum = Self.digest(try Self.encoder().encode(events))
    try validate()
  }
  public func encoded() throws -> Data {
    try validate()
    let data = try Self.encoder().encode(self)
    guard data.count <= Self.maxBytes else { throw SereinError.invalid("Agent history export is too large.") }
    return data
  }
  public static func decode(_ data: Data) throws -> AgentHistoryArchive {
    guard data.count <= maxBytes else { throw SereinError.invalid("Choose an agent history file smaller than 64 MB.") }
    let archive = try decoder().decode(Self.self, from: data)
    try archive.validate()
    return archive
  }
  public func validate() throws {
    guard format == Self.format, schemaVersion == Self.version, Self.validDate(exportedAt) else {
      throw SereinError.invalid("Unsupported agent history format or version.")
    }
    var ids = Set<UUID>()
    var last = 0
    for event in events {
      guard event.sequence > last, ids.insert(event.id).inserted, Self.validMetadata(event, issuer: issuerID)
      else { throw SereinError.invalid("Invalid agent history metadata or event order.") }
      last = event.sequence
    }
    guard checksum == Self.digest(try Self.encoder().encode(events)) else {
      throw SereinError.invalid("Agent history checksum does not match.")
    }
  }
  static func isDigest(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
  }
  static func validMetadata(_ event: AgentHistoryEvent, issuer: UUID) -> Bool {
    let versionValid = event.run.harnessVersion.map { version in
      let parts = version.split(separator: ".", omittingEmptySubsequences: false)
      return (2...3).contains(parts.count) && parts.allSatisfy {
        !$0.isEmpty && $0.count <= 6 && $0.allSatisfy { $0.isASCII && $0.isNumber }
      }
    } ?? true
    return event.issuerID == issuer
      && event.actorID == issuer.uuidString + ":" + (event.reportingHarness?.rawValue ?? event.run.harness.rawValue)
      && (event.reportingHarness == nil || (event.source == .harness && event.kind == .outcomeClassified))
      && validDate(event.time) && versionValid
      && (event.run.modelFingerprint.map(isDigest) ?? true)
      && (event.sessionFingerprint.map(isDigest) ?? true)
  }
  static func validDate(_ value: Date) -> Bool {
    (-62_135_596_800...253_402_300_799).contains(value.timeIntervalSince1970)
  }
  public static func fingerprint(_ value: String) -> String { digest(Data(value.utf8)) }
  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }
  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

/// Serialized appends, outside the journal folders agents may read. Imported records are kept
/// separately and never merged into the local issuer's log, run queue, or permission stores.
public final class AgentHistoryStore: @unchecked Sendable {
  public static let directory = "agent-history"
  public let issuerID: UUID
  private let root: URL
  private let lock = NSLock()
  private var sequence: Int
  private var recordingFailed = false
  /// The opening scan's runs with no end, so launch recovery does not read the log a second
  /// time. Any write drops it, and recovery then reads the log again.
  private var unendedAtOpen: [AgentHistoryEvent]?
  private struct Identity: Codable { let issuerID: UUID }
  public init(library: Library) throws {
    root = library.root.appendingPathComponent(Self.directory)
    try Self.ensureDirectory(root)
    let identity = root.appendingPathComponent("identity.json")
    if FileManager.default.fileExists(atPath: identity.path) {
      issuerID = try AgentHistoryArchive.decoder().decode(Identity.self, from: Self.read(identity)).issuerID
    } else {
      // Never silently change the issuer of an existing history.
      guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("events.jsonl").path) else {
        throw SereinError.invalid("Agent history identity is missing. Export or clear the history before starting a task.")
      }
      issuerID = UUID()
      try Self.write(AgentHistoryArchive.encoder().encode(Identity(issuerID: issuerID)), to: identity)
    }
    let scan = try Self.scanRuns(root: root, issuer: issuerID)
    sequence = scan.sequence
    unendedAtOpen = scan.unended
  }

  @discardableResult public func record(
    run: AgentHistoryRun, kind: AgentHistoryEvent.Kind, source: AgentHistoryEvent.Source = .host,
    operationID: UUID? = nil, tool: AgentHistoryEvent.Tool? = nil,
    grant: AgentHistoryEvent.Grant? = nil, enabled: Bool? = nil,
    effect: AgentHistoryEvent.Effect? = nil, decision: AgentHistoryEvent.Decision? = nil,
    outcome: RunRecord.Outcome? = nil, sessionID: String? = nil, reportingHarness: HarnessDriver? = nil
  ) throws -> AgentHistoryEvent {
    lock.lock(); defer { lock.unlock() }
    unendedAtOpen = nil
    guard !recordingFailed, sequence < Int.max else {
      throw SereinError.invalid("Agent history recording is unavailable.")
    }
    var saved = false
    defer { if !saved { recordingFailed = true } }
    let event = AgentHistoryEvent(
      id: UUID(), sequence: sequence + 1, time: Date(), issuerID: issuerID,
      actorID: issuerID.uuidString + ":" + (reportingHarness?.rawValue ?? run.harness.rawValue), run: run,
      kind: kind, source: source, reportingHarness: reportingHarness.flatMap { AgentHistoryHarness(rawValue: $0.rawValue) },
      operationID: operationID, tool: tool, grant: grant,
      enabled: enabled, effect: effect, decision: decision, outcome: outcome,
      sessionFingerprint: sessionID.map { AgentHistoryArchive.fingerprint(issuerID.uuidString + ":" + run.harness.rawValue + ":" + $0) })
    guard AgentHistoryArchive.validMetadata(event, issuer: issuerID) else {
      throw SereinError.invalid("Invalid agent history metadata.")
    }
    var data = try AgentHistoryArchive.encoder().encode(event); data.append(10)
    let url = root.appendingPathComponent("events.jsonl")
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard fd >= 0 else { throw SereinError.invalid("Could not save agent history.") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      throw SereinError.invalid("Agent history must use a regular file.")
    }
    guard fchmod(fd, 0o600) == 0 else { throw SereinError.invalid("Could not protect agent history.") }
    try file.write(contentsOf: data)
    try file.synchronize()
    sequence += 1
    saved = true
    return event
  }
  public func archive(runID: UUID? = nil) throws -> AgentHistoryArchive {
    lock.lock(); defer { lock.unlock() }
    guard !recordingFailed else { throw SereinError.invalid("Agent history may be incomplete after a recording failure.") }
    var events: [AgentHistoryEvent] = []
    _ = try Self.scanEvents(root: root, issuer: issuerID) { event in
      if runID == nil || event.run.id == runID { events.append(event) }
    }
    return try AgentHistoryArchive(issuerID: issuerID, events: events)
  }
  public func checkIntegrity() throws {
    lock.lock(); defer { lock.unlock() }
    guard !recordingFailed, try Self.scanEvents(root: root, issuer: issuerID, visit: { _ in }) == sequence else {
      throw SereinError.invalid("Agent history is incomplete or has changed outside its writer.")
    }
  }
  /// Records an interrupted run as an observation of the next launch, without inventing tool results.
  public func recoverInterruptedRuns() throws {
    lock.lock()
    let opened = unendedAtOpen
    unendedAtOpen = nil
    lock.unlock()
    for event in try opened ?? Self.scanRuns(root: root, issuer: issuerID).unended {
      try record(run: event.run, kind: .interrupted, outcome: .stopped)
    }
  }
  public func importArchive(_ data: Data) throws -> AgentHistoryArchive {
    let archive = try AgentHistoryArchive.decode(data)
    lock.lock(); defer { lock.unlock() }
    let imports = root.appendingPathComponent("imports")
    try Self.ensureDirectory(imports)
    // A snapshot has its own file. Neither the local identity nor any capability is restored.
    try Self.write(archive.encoded(), to: imports.appendingPathComponent(UUID().uuidString + ".json"))
    return archive
  }
  public func importedArchives() throws -> [AgentHistoryArchive] {
    lock.lock(); defer { lock.unlock() }
    let folder = root.appendingPathComponent("imports")
    guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
    try Self.ensureDirectory(folder)
    return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.map { try AgentHistoryArchive.decode(Self.read($0)) }
      .sorted { $0.exportedAt > $1.exportedAt }
  }
  public func importArchive(from url: URL) throws -> AgentHistoryArchive {
    try importArchive(Self.read(url))
  }
  public static func export(_ archive: AgentHistoryArchive, to url: URL) throws {
    try write(archive.encoded(), to: url)
  }
  public func clear() throws {
    lock.lock(); defer { lock.unlock() }
    for name in ["events.jsonl", "imports"] {
      let file = root.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    sequence = 0
    recordingFailed = false
    unendedAtOpen = nil
  }
  /// One read of the log: its last sequence, and the last event of each run that has no end,
  /// in log order.
  private static func scanRuns(root: URL, issuer: UUID) throws -> (sequence: Int, unended: [AgentHistoryEvent]) {
    var last: [UUID: AgentHistoryEvent] = [:]
    var ended = Set<UUID>()
    let sequence = try scanEvents(root: root, issuer: issuer) { event in
      last[event.run.id] = event
      if [.runEnded, .interrupted].contains(event.kind) { ended.insert(event.run.id) }
    }
    let unended = last.values.filter { !ended.contains($0.run.id) }.sorted { $0.sequence < $1.sequence }
    return (sequence, unended)
  }
  private static func scanEvents(root: URL, issuer: UUID, visit: (AgentHistoryEvent) throws -> Void) throws -> Int {
    let url = root.appendingPathComponent("events.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw SereinError.invalid("Could not read agent history.") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      throw SereinError.invalid("Agent history must use a regular file.")
    }
    var pending = Data()
    var sequence = 0
    var ids = Set<UUID>()
    let decoder = AgentHistoryArchive.decoder()
    while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
      pending.append(chunk)
      while let end = pending.firstIndex(of: 10) {
        guard end - pending.startIndex <= 65_536 else { throw SereinError.invalid("Agent history record is too large.") }
        let event = try decoder.decode(AgentHistoryEvent.self, from: Data(pending[..<end]))
        guard event.sequence == sequence + 1, ids.insert(event.id).inserted else {
          throw SereinError.invalid("Agent history has missing or duplicate records.")
        }
        guard AgentHistoryArchive.validMetadata(event, issuer: issuer) else {
          throw SereinError.invalid("Invalid agent history metadata.")
        }
        sequence = event.sequence
        try visit(event)
        pending.removeSubrange(...end)
      }
      guard pending.count <= 65_536 else { throw SereinError.invalid("Agent history record is too large.") }
    }
    // A torn final write or invalid line must not be silently presented as complete history.
    guard pending.isEmpty else { throw SereinError.invalid("Agent history has an incomplete final record.") }
    return sequence
  }
  private static func ensureDirectory(_ url: URL) throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: url.path) {
      try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw SereinError.invalid("Agent history must use a private directory, not a link.")
    }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }
  private static func read(_ url: URL) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw SereinError.invalid("Could not read agent history.") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size <= AgentHistoryArchive.maxBytes
    else { throw SereinError.invalid("Agent history must be a regular file smaller than 64 MB.") }
    return try file.read(upToCount: AgentHistoryArchive.maxBytes + 1) ?? Data()
  }
  private static func write(_ data: Data, to url: URL) throws {
    // New files only. Atomic publication, with private permissions before bytes are written.
    let temporary = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw SereinError.invalid("Could not save agent history.") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
    try file.write(contentsOf: data); try file.synchronize()
    guard rename(temporary.path, url.path) == 0 else { throw SereinError.invalid("Could not publish agent history.") }
  }
}
