import Foundation

/// Writes a file once, a moment after the last change of a burst, on its own queue: a run's end
/// rewrites the whole chats file, and several ends close together need one write, not several on
/// the main thread. The newest value always wins: a direct write (`now`) drops what is pending
/// and waits for a write in progress, and a read (`flush`) first writes what is pending.
public final class SaveCoalescer: @unchecked Sendable {
  public static let shared = SaveCoalescer()
  /// How long a burst may go quiet before its last value is written.
  public let delay: TimeInterval
  private let queue = DispatchQueue(label: "serein.save-coalescer", qos: .utility)
  private let lock = NSLock()
  private var pending: [String: (turn: Int, write: () -> Void)] = [:]
  /// Keys ever scheduled: only their direct writes and reads wait on the queue.
  private var known: Set<String> = []
  private var turn = 0
  public init(delay: TimeInterval = 1) { self.delay = delay }

  /// Keeps `write` as `key`'s next write, replacing one not yet made, and makes it `delay`
  /// after this call unless a later one replaces it first.
  public func schedule(_ key: String, write: @escaping () -> Void) {
    lock.lock()
    turn += 1
    let mine = turn
    pending[key] = (mine, write)
    known.insert(key)
    lock.unlock()
    queue.asyncAfter(deadline: .now() + delay) { [self] in run(key, only: mine) }
  }
  /// Makes `key`'s pending write now and waits for it.
  public func flush(_ key: String) {
    guard isKnown(key) else { return }
    queue.sync { run(key, only: nil) }
  }
  /// Makes every pending write now and waits for them: on quit.
  public func flushAll() {
    queue.sync {
      lock.lock()
      let keys = Array(pending.keys)
      lock.unlock()
      for key in keys { run(key, only: nil) }
    }
  }
  /// A direct write of `key`: what is pending is dropped (this value is newer), and the write
  /// waits for one in progress so an older value never lands after it.
  public func now<T>(_ key: String, _ write: () throws -> T) rethrows -> T {
    guard isKnown(key) else { return try write() }
    return try queue.sync {
      lock.lock()
      pending[key] = nil
      lock.unlock()
      return try write()
    }
  }
  /// Whether `key` has a write not yet made.
  public func isPending(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pending[key] != nil
  }
  private func isKnown(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return known.contains(key)
  }
  /// On the queue. `only`: the scheduled turn, skipped when a later schedule replaced it.
  private func run(_ key: String, only: Int?) {
    lock.lock()
    guard let job = pending[key], only == nil || job.turn == only else {
      lock.unlock()
      return
    }
    pending[key] = nil
    lock.unlock()
    job.write()
  }
}

/// A file decoded on another thread while launch does other work; `value` waits for the rest.
public final class BackgroundRead<T>: @unchecked Sendable {
  private let done = DispatchGroup()
  private var result: T?
  public init(_ read: @escaping () -> T?) {
    done.enter()
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      result = read()
      done.leave()
    }
  }
  public var value: T? {
    done.wait()
    return result
  }
}
