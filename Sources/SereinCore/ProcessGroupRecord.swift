import Foundation

/// The process groups one Serein started, kept on disk (ProcessGroup.recordDirectory, one file per
/// Serein) so the next launch can end the ones a crash, or a CLI that ignored the quit, left running.
public struct ProcessGroupRecord: Codable, Equatable {
  /// One process. A pid alone can belong to an unrelated process after a reboot or a long gap;
  /// the start time tells them apart.
  public struct Member: Codable, Hashable {
    public var pid: Int32
    /// The kernel's start time, in microseconds since 1970.
    public var started: UInt64
    public init(pid: Int32, started: UInt64) {
      self.pid = pid
      self.started = started
    }
  }
  /// What the kernel says about a process that runs now.
  public struct Live: Equatable {
    public var started: UInt64
    public var pgid: Int32
    public init(started: UInt64, pgid: Int32) {
      self.started = started
      self.pgid = pgid
    }
  }
  public struct Group: Codable, Equatable {
    public var pgid: Int32
    /// The members seen when the record was last written, the leader among them while it ran.
    public var members: [Member]
    public init(pgid: Int32, members: [Member]) {
      self.pgid = pgid
      self.members = members
    }
  }
  /// The Serein that wrote the record. Its groups are left alone while it runs.
  public var owner: Member
  public var groups: [Group]
  public init(owner: Member, groups: [Group]) {
    self.owner = owner
    self.groups = groups
  }

  /// The guard against ending someone else's processes: a group is still Serein's only while one
  /// recorded member runs with the same start time and is still in that group. The kernel gives
  /// no new process a group's id while any member of the group lives, and a process from another
  /// session cannot join it, so a reused pid never matches.
  public static func isOurs(_ group: Group, live: (Int32) -> Live?) -> Bool {
    group.pgid > 1 && group.members.contains { member in
      live(member.pid).map { $0.started == member.started && $0.pgid == group.pgid } ?? false
    }
  }
  public func ownerRuns(live: (Int32) -> Live?) -> Bool { live(owner.pid)?.started == owner.started }
}
