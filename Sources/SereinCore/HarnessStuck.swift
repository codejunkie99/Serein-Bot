import Foundation

/// What a CLI that has gone quiet mid-turn is doing. Healthy CLIs go silent for minutes (a slow
/// model call, a rate-limit wait), so silence alone only stops a turn at `silenceCeiling`. Before
/// that, a turn is stopped as stuck only after `noSignsStop` with no open connection and no CPU.
/// The caller samples the process tree and the clock; this value only reads them.
public struct HarnessStuck: Equatable, Sendable {
  public static let quietNotice: TimeInterval = 60
  public static let stuckAfter: TimeInterval = 180
  public static let noSignsStop: TimeInterval = 5 * 60
  public static let silenceCeiling: TimeInterval = 15 * 60
  /// CPU seconds per minute above which the tree counts as busy.
  public static let busyCPU: TimeInterval = 3

  /// Loopback endpoints (such as Serein's local ShellGuard proxy or local MCP sockets) never
  /// represent active upstream model I/O and should be excluded when sampling `openTCP`.
  public static func isLoopbackAddress(_ host: String) -> Bool {
    var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
    if name == "localhost" { return true }
    var v4 = in_addr()
    if inet_pton(AF_INET, name, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
    var v6 = in6_addr()
    guard inet_pton(AF_INET6, name, &v6) == 1 else { return false }
    let bytes = withUnsafeBytes(of: v6) { Array($0) }
    if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }
    // IPv4-mapped (::ffff:127.x.y.z), as a dual-stack socket reports an IPv4 peer.
    return bytes.prefix(12).elementsEqual([UInt8](repeating: 0, count: 10) + [0xff, 0xff]) && bytes[12] == 127
  }

  public struct Evidence: Equatable, Sendable {
    /// CPU seconds the CLI's process tree used per minute since the last tick; nil when unknown.
    public var cpuPerMinute: TimeInterval?
    /// Established TCP connections the tree holds; nil when unknown.
    public var openTCP: Int?
    /// The CLI's own log grew since the last tick.
    public var logGrew: Bool

    public init(cpuPerMinute: TimeInterval?, openTCP: Int?, logGrew: Bool) {
      self.cpuPerMinute = cpuPerMinute
      self.openTCP = openTCP
      self.logGrew = logGrew
    }
  }

  public enum Quiet: Equatable, Sendable {
    case waitingModel, busy
    /// No connection and no CPU, briefly: a CLI sleeping between retries looks like this.
    case betweenRequests
    /// No connection and no CPU for `stuckAfter`.
    case stuck
    case unknown
  }
  public enum Stop: Equatable, Sendable { case noSigns, silence }
  public enum Verdict: Equatable, Sendable { case talking, quiet(Quiet), stop(Stop) }

  public private(set) var lastHeard: Date
  private var noSignsSince: Date?

  public init(promptSent: Date) { lastHeard = promptSent }

  /// The CLI sent something.
  public mutating func heard(at date: Date) {
    lastHeard = date
    noSignsSince = nil
  }

  public mutating func tick(now: Date, evidence: Evidence) -> Verdict {
    if evidence.logGrew { heard(at: now) }
    let silence = now.timeIntervalSince(lastHeard)
    if silence >= Self.silenceCeiling { return .stop(.silence) }
    guard silence >= Self.quietNotice else {
      noSignsSince = nil
      return .talking
    }
    if let tcp = evidence.openTCP, tcp > 0 { return quiet(.waitingModel) }
    if let cpu = evidence.cpuPerMinute, cpu > Self.busyCPU { return quiet(.busy) }
    // Both readings known and both idle; an unreadable reading is never taken as idle.
    guard evidence.openTCP == 0, evidence.cpuPerMinute != nil else { return quiet(.unknown) }
    let since = noSignsSince ?? now
    noSignsSince = since
    let none = now.timeIntervalSince(since)
    if none >= Self.noSignsStop { return .stop(.noSigns) }
    return .quiet(none >= Self.stuckAfter ? .stuck : .betweenRequests)
  }

  private mutating func quiet(_ state: Quiet) -> Verdict {
    noSignsSince = nil
    return .quiet(state)
  }
}
