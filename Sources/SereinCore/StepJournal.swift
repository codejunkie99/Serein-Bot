import CryptoKit
import Foundation

/// The journal of changing steps. A step that changes something outside Serein (an effect in
/// `ApprovalGate.mustAsk`) is written down before it runs, and its result after. A turn that is
/// sent again (after a connect, a model switch, a usage-limit hold, Try again) is another send of
/// the same request: a step it already finished is answered from the journal, and a step whose
/// outcome nobody knows asks the person first, whatever the level.
/// Scope: steps Serein itself runs. Steps inside Claude Code or Codex never reach it.
/// How to check a change against it: .claude/skills/proactive-safety/SKILL.md.
public enum StepJournal {
  /// The tool call running now, for the door and the cards under it (`BrowserModel.handle`).
  @TaskLocal public static var live: Live?

  public enum Outcome: Equatable, Sendable {
    /// Written down as started, and nothing since: Serein quit, or the step never came back.
    case open
    /// It came back with this result (clipped).
    case done(String)
    /// Its own code said it failed.
    case failed
    /// Its own code could not tell whether it happened (a send whose answer was lost).
    case unknown
  }

  public struct Entry: Equatable, Sendable {
    public var id: String
    public var key: String
    public var tool: String
    public var effect: String
    /// Which send of the request ran it, from 1.
    public var attempt: Int
    public var outcome: Outcome
    /// The person allowed a later step on a card that said this one's outcome is unknown.
    public var settled = false
    public var at: Date

    public var isDone: Bool { if case .done = outcome { return true } else { return false } }
    var unsettled: Bool { (outcome == .open || outcome == .unknown) && !settled }
  }

  /// One request in one chat: the person's message, or one firing of a schedule, with every
  /// send of it.
  public struct Request: Equatable, Sendable {
    public var id: String
    public var thread: String
    /// `words(_:)` of what was asked, when the sender gave it: Try again finds its request by it.
    public var words: String?
    public var attempt: Int
    public var entries: [Entry]
    public var at: Date
  }

  public struct Line: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case request, attempt, started, done, failed, unknown, settled }
    public var kind: Kind
    public var thread: String
    public var request: String
    public var attempt: Int
    public var step: String?
    public var key: String?
    public var tool: String?
    public var effect: String?
    public var result: String?
    public var words: String?
    public var at: Date

    public init(
      _ kind: Kind, thread: String, request: String, attempt: Int, step: String? = nil, key: String? = nil,
      tool: String? = nil, effect: String? = nil, result: String? = nil, words: String? = nil, at: Date
    ) {
      self.kind = kind
      self.thread = thread
      self.request = request
      self.attempt = attempt
      self.step = step
      self.key = key
      self.tool = tool
      self.effect = effect
      self.result = result
      self.words = words
      self.at = at
    }
  }

  /// What the lines add up to: every request by its id, and each chat's current one (the request
  /// of the turn it started last). A line for a request nobody opened, or for a step that was
  /// never started, changes nothing.
  public struct Book: Equatable, Sendable {
    public private(set) var requests: [String: Request] = [:]
    public private(set) var current: [String: String] = [:]
    public init() {}

    public func request(in thread: String) -> Request? { current[thread].flatMap { requests[$0] } }

    public mutating func apply(_ line: Line) {
      if line.kind == .request {
        if requests[line.request] == nil {
          requests[line.request] = Request(
            id: line.request, thread: line.thread, words: line.words, attempt: 1, entries: [], at: line.at)
        }
        if requests[line.request]?.thread == line.thread { current[line.thread] = line.request }
        return
      }
      guard var request = requests[line.request], request.thread == line.thread else { return }
      request.at = line.at
      let index = line.step.flatMap { step in request.entries.firstIndex { $0.id == step } }
      switch line.kind {
      case .request: break
      case .attempt:
        request.attempt = max(request.attempt, line.attempt)
        current[line.thread] = request.id
      case .started:
        guard index == nil, let step = line.step, let key = line.key, let tool = line.tool else { return }
        request.entries.append(
          Entry(id: step, key: key, tool: tool, effect: line.effect ?? "", attempt: line.attempt, outcome: .open, at: line.at))
      case .done: if let index { request.entries[index].outcome = .done(line.result ?? "") }
      case .failed: if let index { request.entries[index].outcome = .failed }
      case .unknown: if let index { request.entries[index].outcome = .unknown }
      case .settled: if let index { request.entries[index].settled = true }
      }
      requests[request.id] = request
    }

    private static func earlier(_ a: Request, _ b: Request) -> Bool { a.at != b.at ? a.at < b.at : a.id < b.id }

    /// Requests nothing touched since `date` go: a turn that old is not sent again. A chat whose
    /// current request went has its newest one left as current.
    public mutating func drop(before date: Date) {
      requests = requests.filter { $0.value.at >= date }
      for (thread, id) in current where requests[id] == nil {
        current[thread] = requests.values.filter { $0.thread == thread }.sorted(by: Self.earlier).last?.id
      }
    }

    /// The fewest lines that add up to this book (the file as it is rewritten at launch): each
    /// chat's current request comes after its others.
    public func lines() -> [Line] {
      let ordered = requests.values.sorted(by: Self.earlier)
      let last = ordered.filter { current[$0.thread] == $0.id }
      return (ordered.filter { current[$0.thread] != $0.id } + last).flatMap { request -> [Line] in
        let thread = request.thread
        var lines = [Line(.request, thread: thread, request: request.id, attempt: 1, words: request.words, at: request.at)]
        for entry in request.entries {
          lines.append(
            Line(.started, thread: thread, request: request.id, attempt: entry.attempt, step: entry.id, key: entry.key,
                 tool: entry.tool, effect: entry.effect, at: entry.at))
          let ended: (Line.Kind, String?)?
          switch entry.outcome {
          case .open: ended = nil
          case .done(let result): ended = (.done, result)
          case .failed: ended = (.failed, nil)
          case .unknown: ended = (.unknown, nil)
          }
          if let ended {
            lines.append(Line(ended.0, thread: thread, request: request.id, attempt: entry.attempt, step: entry.id, result: ended.1, at: entry.at))
          }
          if entry.settled {
            lines.append(Line(.settled, thread: thread, request: request.id, attempt: entry.attempt, step: entry.id, at: entry.at))
          }
        }
        lines.append(Line(.attempt, thread: thread, request: request.id, attempt: request.attempt, at: request.at))
        return lines
      }
    }
  }

  /// What a request's words are kept as: never the words themselves.
  public static func words(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// A step that changes something outside Serein: the effects that wait for a person even
  /// under Autopilot.
  public static func isChange(_ effect: ApprovalGate.Effect) -> Bool { ApprovalGate.mustAsk.contains(effect) }

  /// The same tool with the same arguments is the same step.
  public static func key(tool: String, arguments: [String: Any]) -> String {
    let body = JSONSerialization.isValidJSONObject(arguments)
      ? (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data()
      : Data(String(describing: arguments.sorted { $0.key < $1.key }).utf8)
    return SHA256.hash(data: Data(tool.utf8) + [0] + body).map { String(format: "%02x", $0) }.joined()
  }

  public static let resultLimit = 2000
  public static func clip(_ result: String) -> String { String(result.prefix(resultLimit)) }

  /// Steps whose outcome nobody knows: started with no result, or their own code could not
  /// tell. One that the same step later finished, or that the person answered for, is known.
  public static func stuck(_ entries: [Entry]) -> [Entry] {
    entries.indices.filter { index in
      entries[index].unsettled
        && !entries[(index + 1)...].contains { $0.key == entries[index].key && $0.isDone }
    }.map { entries[$0] }
  }

  public enum Before: Equatable, Sendable {
    case run
    /// An earlier send of this request finished it: it is not run, and the model reads its
    /// result then.
    case replay(Entry)
    /// Its outcome is unknown: it asks the person, whatever the level.
    case asks(Entry)
  }

  /// What the journal says about a tool call before it runs. `occurrence`: how many calls with
  /// this key this send has already made, so a step the request needs twice runs twice.
  public static func before(key: String, tool: String, occurrence: Int, in request: Request?) -> Before {
    guard let request else { return .run }
    let stuck = stuck(request.entries)
    // Told in this very send that nobody knows whether it happened: the same call asks.
    if let entry = stuck.first(where: { $0.key == key && $0.attempt == request.attempt && $0.outcome == .unknown }) {
      return .asks(entry)
    }
    let earlier = request.entries.filter { $0.attempt < request.attempt }
    let ran = earlier.filter { entry in entry.key == key && (entry.isDone || stuck.contains { $0.id == entry.id }) }
    if occurrence < ran.count { return ran[occurrence].isDone ? .replay(ran[occurrence]) : .asks(ran[occurrence]) }
    // A model that words the step differently after the turn was sent again still asks.
    if let entry = stuck.first(where: { $0.tool == tool && $0.attempt < request.attempt }) { return .asks(entry) }
    return .run
  }

  public enum Resend: Equatable, Sendable {
    /// It may go by itself. `done`: the steps the request already finished.
    case send(done: [Entry])
    /// A step's outcome is unknown: nothing sends the turn again by itself.
    case waits(Entry)
  }

  /// Read by every path that sends a turn again by itself.
  public static func resend(_ request: Request?) -> Resend {
    guard let request else { return .send(done: []) }
    if let entry = stuck(request.entries).first { return .waits(entry) }
    return .send(done: request.entries.filter(\.isDone))
  }

  /// The line a card adds when its step asks because of the journal.
  public static let unknownLine = "Serein started this step earlier and cannot tell whether it finished."

  /// The recorded result of a step that ran but whose call ended in an error.
  public static let ranUnseen = "It ran. Its result was not returned."

  /// What the model reads in place of running a step again.
  public static let replayed =
    "Not run again. This step already ran for this request, before the turn was sent again. "
    + "What it returned then follows; carry on from there."

  /// The same for a step a repl program makes: the program stops, and the model reads this.
  public static let replayedInProgram =
    "This step already ran for this request, before the turn was sent again, so it was not run again and the "
    + "program stopped here. Carry on from what the step returned then, without this step:"

  /// One tool call, as the journal sees it. The door tells it what the step would do and what
  /// it decided; a card tells it the person said yes. It writes the step down before either
  /// lets the step run.
  public final class Live: @unchecked Sendable {
    /// The earlier step whose outcome is unknown, when this call asks because of it.
    public let stuck: Entry?
    private let start: (ApprovalGate.Effect) -> String?
    private let lock = NSLock()
    private var entry: String?
    private var lastEffect: ApprovalGate.Effect?
    private var lost = false
    private var happened = false

    init(stuck: Entry?, start: @escaping (ApprovalGate.Effect) -> String?) {
      self.stuck = stuck
      self.start = start
    }

    /// The id of the journal entry, once the step was written down as started.
    public var started: String? { lock.withLock { entry } }
    public var cannotTellOutcome: Bool { lock.withLock { lost } }
    public var ranAnyway: Bool { lock.withLock { happened } }

    /// The door's answer, as the journal lets it stand: a changing step whose earlier outcome is
    /// unknown asks, and one that would run is written down first (refused when that fails).
    public func decided(_ effect: ApprovalGate.Effect, _ decision: RelayAutonomy.Decision) -> RelayAutonomy.Decision {
      lock.withLock { lastEffect = effect }
      guard decision == .auto, StepJournal.isChange(effect) else { return decision }
      if stuck != nil { return .ask }
      return begin(effect) ? .auto : .refuse
    }

    /// The person said yes on this call's card. False: the step could not be written down, so
    /// it must not run.
    public func allowed() -> Bool {
      let effect = lock.withLock { lastEffect }
      guard effect.map(StepJournal.isChange) ?? true else { return true }
      return begin(effect ?? .unknown)
    }

    /// The step's own code cannot tell whether it happened.
    public func cannotTell() { lock.withLock { lost = true } }
    /// The step happened, though its call ends in an error (its result is withheld).
    public func ran() { lock.withLock { happened = true } }

    private func begin(_ effect: ApprovalGate.Effect) -> Bool {
      lock.withLock {
        if entry != nil { return true }
        entry = start(effect)
        return entry != nil
      }
    }
  }
}

/// The journal on disk: one line a change, added and synced before the step it names runs
/// (`relay/steps.jsonl`). A line that cannot be saved stops the step.
public final class StepJournalStore: @unchecked Sendable {
  public static let path = "relay/steps.jsonl"
  /// A request nothing touched for this long is forgotten at launch.
  public static let keeps: TimeInterval = 14 * 24 * 3600
  public typealias Rule = (_ key: String, _ tool: String, _ occurrence: Int, _ request: StepJournal.Request?) -> StepJournal.Before

  private let file: URL?
  private let now: () -> Date
  private let rule: Rule
  private let lock = NSLock()
  private var book = StepJournal.Book()
  private var broken = false
  /// What each chat's next turn is, when its sender said: a request's id (one the book knows
  /// is sent again) and what was asked.
  private var next: [String: (request: String?, words: String?)] = [:]
  /// Calls this send has made, by chat and key.
  private var calls: [String: [String: Int]] = [:]

  /// `file` nil keeps it in memory (previews and checks). `rule` is `StepJournal.before`; only
  /// a check passes another, to show a broken rule is caught.
  public init(file: URL?, now: @escaping () -> Date = Date.init, rule: @escaping Rule = StepJournal.before) {
    self.file = file
    self.now = now
    self.rule = rule
    guard let file, let data = try? Data(contentsOf: file) else { return }
    let decoder = JSONDecoder()
    // A torn last line is a step that was never written down, so it never ran.
    for row in data.split(separator: 10) {
      if let line = try? decoder.decode(StepJournal.Line.self, from: row) { book.apply(line) }
    }
    book.drop(before: now().addingTimeInterval(-Self.keeps))
    if let data = try? Self.encode(book.lines()) { try? data.write(to: file, options: .atomic) }
  }

  /// A copy with the same state, in memory. For checks that walk every order of events.
  public func fork() -> StepJournalStore {
    lock.withLock {
      let copy = StepJournalStore(file: nil, now: now, rule: rule)
      copy.book = book
      copy.broken = broken
      copy.next = next
      copy.calls = calls
      return copy
    }
  }

  /// The request of the turn `thread` started last.
  public func request(_ thread: String) -> StepJournal.Request? { lock.withLock { book.request(in: thread) } }

  /// The next turn in `thread` is the request `request`: sent again when the journal knows that
  /// id in this chat, new otherwise (nil: new). `settle` takes it back when no turn started.
  public func nextTurn(in thread: String, is request: String?, words: String? = nil) {
    lock.withLock { next[thread] = (request, words) }
  }
  /// The next turn in `thread` is the request it ran last, sent again.
  public func sendAgain(_ thread: String) { lock.withLock { next[thread] = (book.current[thread], nil) } }
  public func settle(_ thread: String) { lock.withLock { next[thread] = nil } }

  /// The request `thread` ran last, when these were its words: what Try again sends again.
  public func current(_ thread: String, words: String) -> String? {
    lock.withLock { book.request(in: thread).flatMap { $0.words == words ? $0.id : nil } }
  }

  /// A turn starts in `thread`: the next send of the request its sender named, when the journal
  /// knows it here, else a new request.
  public func turnStarts(_ thread: String) {
    lock.withLock {
      calls[thread] = nil
      let named = next.removeValue(forKey: thread)
      if let id = named?.request, let request = book.requests[id], request.thread == thread {
        _ = write([StepJournal.Line(.attempt, thread: thread, request: id, attempt: request.attempt + 1, at: now())])
      } else {
        // An id another chat's request holds names nothing here.
        let id: String = named?.request.flatMap { book.requests[$0] == nil ? $0 : nil } ?? UUID().uuidString
        _ = write([StepJournal.Line(.request, thread: thread, request: id, attempt: 1, words: named?.words, at: now())])
      }
    }
  }

  /// Whether the request `thread` ran last may be sent again by itself.
  public func resend(_ thread: String) -> StepJournal.Resend { lock.withLock { StepJournal.resend(book.request(in: thread)) } }
  /// The same for a request by its id. One the journal does not know ran no step.
  public func resend(request: String) -> StepJournal.Resend { lock.withLock { StepJournal.resend(book.requests[request]) } }

  /// A tool call arrives: what the journal says, and the call's own line to the door.
  public func step(thread: String, tool: String, arguments: [String: Any]) -> (before: StepJournal.Before, live: StepJournal.Live) {
    let key = StepJournal.key(tool: tool, arguments: arguments)
    return lock.withLock {
      let occurrence = calls[thread]?[key] ?? 0
      calls[thread, default: [:]][key] = occurrence + 1
      let before = rule(key, tool, occurrence, book.request(in: thread))
      var stuck: StepJournal.Entry?
      if case .asks(let entry) = before { stuck = entry }
      let live = StepJournal.Live(stuck: stuck) { [weak self] effect in
        self?.start(thread: thread, tool: tool, key: key, effect: effect, settles: stuck)
      }
      return (before, live)
    }
  }

  /// The call ended. `result` nil: it threw.
  public func finish(_ live: StepJournal.Live, thread: String, result: String?) {
    guard let step = live.started else { return }
    lock.withLock {
      // Its own request, which is no longer the chat's current one when a newer turn started.
      guard let request = book.requests.values.first(where: { $0.thread == thread && $0.entries.contains { $0.id == step } }),
        let entry = request.entries.first(where: { $0.id == step })
      else { return }
      let result = result ?? (live.ranAnyway ? StepJournal.ranUnseen : nil)
      let kind: StepJournal.Line.Kind = live.cannotTellOutcome ? .unknown : result == nil ? .failed : .done
      _ = write([
        StepJournal.Line(
          kind, thread: thread, request: request.id, attempt: entry.attempt, step: step,
          result: kind == .done ? result.map(StepJournal.clip) : nil, at: now())
      ])
    }
  }

  private func start(thread: String, tool: String, key: String, effect: ApprovalGate.Effect, settles: StepJournal.Entry?) -> String? {
    lock.withLock {
      var lines: [StepJournal.Line] = []
      var request = book.request(in: thread).map { ($0.id, $0.attempt) }
      if request == nil {
        // A task with no run of its own (a paired app's call): its steps are one request.
        let id = UUID().uuidString
        lines.append(StepJournal.Line(.request, thread: thread, request: id, attempt: 1, at: now()))
        request = (id, 1)
      }
      guard let request else { return nil }
      if let settles {
        lines.append(StepJournal.Line(.settled, thread: thread, request: request.0, attempt: settles.attempt, step: settles.id, at: now()))
      }
      let step = UUID().uuidString
      lines.append(
        StepJournal.Line(
          .started, thread: thread, request: request.0, attempt: request.1, step: step, key: key, tool: tool,
          effect: effect.rawValue, at: now()))
      return write(lines) ? step : nil
    }
  }

  private static func encode(_ lines: [StepJournal.Line]) throws -> Data {
    let encoder = JSONEncoder()
    var data = Data()
    for line in lines {
      data.append(try encoder.encode(line))
      data.append(10)
    }
    return data
  }

  /// Adds the lines and syncs them, then counts them. After one failure nothing more is
  /// written, so no step runs unrecorded. Called with the lock held.
  private func write(_ lines: [StepJournal.Line]) -> Bool {
    guard !broken else { return false }
    if let file {
      do {
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SereinError.invalid("Could not save the step journal.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: Self.encode(lines))
        try handle.synchronize()
      } catch {
        broken = true
        return false
      }
    }
    for line in lines { book.apply(line) }
    return true
  }
}
