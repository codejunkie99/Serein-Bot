import Foundation
import SereinCore

/// The person's account at one hosting provider on this Mac (E2BAccount, DaytonaAccount). The key
/// lives in Keychain (this device only): it is read when a call needs it, kept in memory only, and
/// sent only to that provider's own hosts in its one header. It is never written to disk, a log, a
/// card, the model's prompt or a tool answer, never into an error (HostedWire.errorText takes it
/// out), and never into a computer. Every call goes through one EphemeralHTTP session: no cookies,
/// cache or credential store, and no redirect, so a header can never follow one to another host.
@MainActor class HostedAccount: ObservableObject {
  let provider: String
  private let item: KeychainItem
  @Published private(set) var hasKey: Bool
  /// The status line under the key field.
  @Published var status: String?
  private var cached: String?
  nonisolated let session = EphemeralHTTP.session()

  init(provider: String, item: KeychainItem) {
    self.provider = provider
    self.item = item
    hasKey = item.mayExist
  }

  /// The key, read from Keychain once per launch (Keychain may ask the person the first time).
  func key() -> String? {
    if let cached { return cached }
    guard let value = item.read(), HostedWire.validSecret(value) else { return nil }
    cached = value
    return value
  }
  /// Saves a pasted key in Keychain; false, with the reason on the status line, when it is not a
  /// key or Keychain refused.
  @discardableResult func save(_ raw: String) -> Bool {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard HostedWire.validSecret(value) else {
      status = "That does not look like \(provider == "E2B" ? "an" : "a") \(provider) key."
      return false
    }
    guard item.replace(with: value) else {
      status = "Keychain did not save the key."
      return false
    }
    cached = value
    hasKey = true
    status = "Key saved in this Mac's Keychain."
    return true
  }
  func remove() {
    guard item.replace(with: nil) else {
      status = "Keychain did not remove the key."
      return
    }
    cached = nil
    hasKey = false
    status = "Key removed from this Mac's Keychain."
  }

  struct Answer {
    var status: Int
    var body: Data
    var hasNextPage = false
  }
  /// One request and its answer; an answer over `limit` bytes is refused unread.
  nonisolated static func send(_ request: URLRequest, limit: Int, provider: String, session: URLSession) async throws -> Answer {
    let (bytes, response) = try await session.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    var body = Data()
    for try await byte in bytes {
      body.append(byte)
      if body.count > limit {
        bytes.task.cancel()
        throw SereinError.invalid("\(provider) sent a longer answer than Serein reads.")
      }
    }
    let cursor = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Next-Token")
    return Answer(status: status, body: body, hasNextPage: !(cursor ?? "").isEmpty)
  }
  /// The same, blocking for at most `seconds`, for quit; the answer is not read.
  nonisolated static func sendBlocking(_ request: URLRequest, session: URLSession, seconds: Double) {
    let done = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: request) { _, _, _ in done.signal() }
    task.resume()
    if done.wait(timeout: .now() + seconds) == .timedOut { task.cancel() }
  }
}

/// A hosted computer's stdin for one command stream (E2BStream, DaytonaStream): bytes go in order,
/// batched, one request at a time, so they never overtake each other, and a writer waits while too
/// much is queued. A failed send ends the stream (fail closed).
final class HostedInput: @unchecked Sendable {
  /// Bytes queued before a writer waits.
  static let pendingLimit = 8 << 20
  /// Guards every field below.
  private let state = NSCondition()
  private var pending = Data()
  private var closeWanted = false
  private var closed = false
  private var kick: AsyncStream<Void>.Continuation?
  private let batchLimit: Int
  private let send: (Data) async throws -> Void
  private let end: () async -> Void
  private let failed: (String) -> Void

  /// `send` delivers one batch of at most `batchLimit` bytes and throws when the provider did not
  /// take it; `end` ends the command's stdin; `failed` gets the reason of a failed send, after
  /// which nothing more is sent.
  init(batchLimit: Int, send: @escaping (Data) async throws -> Void, end: @escaping () async -> Void,
       failed: @escaping (String) -> Void) {
    self.batchLimit = batchLimit
    self.send = send
    self.end = end
    self.failed = failed
    var made: AsyncStream<Void>.Continuation?
    let kicks = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { made = $0 }
    kick = made
    Task { await self.run(kicks) }
  }

  /// Sends what is queued, a batch per request, until closed.
  private func run(_ kicks: AsyncStream<Void>) async {
    for await _ in kicks {
      while true {
        state.lock()
        if closed {
          state.unlock()
          return
        }
        let batch = Data(pending.prefix(batchLimit))
        let closing = batch.isEmpty && closeWanted
        if closing { closeWanted = false }
        state.unlock()
        if batch.isEmpty {
          if closing { await end() }
          break
        }
        do {
          try await send(batch)
        } catch {
          failed(AgentPrivacy.redact(error.localizedDescription))
          close()
          return
        }
        state.lock()
        pending.removeFirst(batch.count)
        state.broadcast()
        state.unlock()
      }
    }
  }

  @discardableResult func write(_ data: Data) -> Bool {
    state.lock()
    while !closed && pending.count >= Self.pendingLimit { state.wait() }
    guard !closed, let kick else {
      state.unlock()
      return false
    }
    pending.append(data)
    state.unlock()
    kick.yield()
    return true
  }
  func closeWrite() {
    state.lock()
    closeWanted = true
    let kick = self.kick
    state.unlock()
    kick?.yield()
  }
  /// Nothing more is sent; a writer waiting for room is let go.
  func close() {
    state.lock()
    closed = true
    let kick = self.kick
    self.kick = nil
    state.broadcast()
    state.unlock()
    kick?.finish()
  }
}

/// What every hosted computer's command stream shares (E2BStream, DaytonaStream): its stdin
/// (HostedInput), the last lines it wrote to stderr, and its end, after which waiters get the exit
/// code and every write is refused. Nothing listens anywhere, on this Mac or in the computer.
class HostedStream: NSObject, ComputerStream, @unchecked Sendable {
  /// Guards every field below, and the fields a subclass names as guarded by it.
  let state = NSCondition()
  /// No more reading or writing: closed by Serein, or the answer ended.
  var closed = false
  /// The command's exit code once known (-1 when it did not exit on its own).
  var exitCode = -1
  /// Ends the reading (cancels the request); set when the reading begins.
  var cancelReading: (() -> Void)?
  private var ended = false
  private var waiters: [CheckedContinuation<Int, Never>] = []
  private var tail: [String] = []
  private var input: HostedInput?

  /// Gives the stream its stdin, unless it already ended: a command that ended takes no input.
  func attach(_ input: HostedInput) {
    state.lock()
    let gone = closed
    if !gone { self.input = input }
    state.unlock()
    if gone { input.close() }
  }
  /// The reading is over: no more input, and every waiter gets the exit code.
  func endReading() {
    state.lock()
    closed = true
    ended = true
    cancelReading = nil
    let input = self.input
    self.input = nil
    let code = exitCode
    let resumed = waiters
    waiters = []
    state.unlock()
    input?.close()
    for waiter in resumed { waiter.resume(returning: code) }
  }
  func note(_ line: String) {
    state.lock()
    tail = Array((tail + [line]).suffix(8))
    state.unlock()
  }

  var isClosed: Bool {
    state.lock(); defer { state.unlock() }
    return closed
  }
  var stderrLines: [String] {
    state.lock(); defer { state.unlock() }
    return tail
  }
  @discardableResult func write(_ data: Data) -> Bool {
    state.lock()
    let input = closed ? nil : self.input
    state.unlock()
    return input?.write(data) ?? false
  }
  func closeWrite() {
    state.lock()
    let input = self.input
    state.unlock()
    input?.closeWrite()
  }
  /// Ends the reading; the subclass then finishes and fires the end once.
  func close() {
    state.lock()
    let cancel = cancelReading
    let alreadyClosed = closed
    closed = true
    let input = self.input
    state.unlock()
    input?.close()
    guard !alreadyClosed else { return }
    cancel?()
  }
  /// The exit code once the stream ended (-1 when the process did not exit on its own).
  func finished() async -> Int {
    await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
      state.lock()
      guard !ended else {
        let code = exitCode
        state.unlock()
        done.resume(returning: code)
        return
      }
      waiters.append(done)
      state.unlock()
    }
  }
}
