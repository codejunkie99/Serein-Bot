import Foundation

/// Who may join a room, decided with no person: it never returns "ask". Every refusal names the way
/// on, so a task is never left at a dead end.
public enum Staffing {
  /// Assistants one root may make, and teams it may save. Spent even when the make is undone.
  public static let makesPerRoot = 2
  public static let teamsPerRoot = 1

  public enum Wanted: Equatable, Sendable {
    case teammate(RelayProfile.ID)
    case newAssistant(AssistantDraft)
    case team
  }

  /// Saved on every assistant a room makes: who made it, in which room.
  public struct Lineage: Codable, Equatable, Sendable {
    public var madeBy: RelayProfile.ID
    public var madeIn: Workroom.ID
    public init(madeBy: RelayProfile.ID, madeIn: Workroom.ID) {
      self.madeBy = madeBy
      self.madeIn = madeIn
    }
  }

  public enum Verdict: Equatable, Sendable {
    /// Seat the asked teammate with this reach.
    case seat(Reach)
    /// Make the drafted assistant with this reach and lineage, then seat it.
    case make(Reach, Lineage)
    /// Save the team.
    case makeTeam
    /// A cap, the chain rule, or a target that cannot take work. The words name the way on.
    case carryOn(String)
    /// The turn read outside text, so it may not change the roster. The words say to hand the work
    /// to someone already on it, or to make the change in a turn that has read nothing from outside.
    case retryClean(String)
  }

  /// `team` is the roster; `archived` the assistants archived from it, who never take work, even
  /// if they are still listed. `readOutside`: this turn read text from outside Serein.
  public static func decide(_ wanted: Wanted, by seat: Workroom.Seat, in room: Workroom, team: RelayTeam,
                            archived: Set<RelayProfile.ID>, ledger: HandoffLedger, readOutside: Bool) -> Verdict {
    let maker = team.profiles.first { $0.id == seat.who }?.name ?? "You"
    let row = seat.handoff.flatMap { h in ledger.records.first { $0.id == h } }
    let roomFull = room.seats.count > HandoffLedger.maxPerRoot
      ? "This task has been handed on \(HandoffLedger.maxPerRoot) times, the most for one task. Finish it yourself, or reply with what you have."
      : nil
    switch wanted {
    case .teammate(let id):
      let name = team.profiles.first { $0.id == id }?.name ?? "That assistant"
      guard let target = team.profiles.first(where: { $0.id == id }), !archived.contains(id) else {
        return .carryOn("\(name) is archived or no longer on the roster, so it can't take work. Hand this to an assistant on the roster, or name a new assistant in `to`.")
      }
      if target.isPaused {
        return .carryOn("\(name) is paused, so it can't take work. Hand this to another assistant, or do this part yourself.")
      }
      if id == seat.who { return .carryOn("This is your own task. Do this part yourself, or hand it to another assistant.") }
      if let refusal = roomFull ?? row.flatMap({ ledger.chainRefusal(parent: $0, fromName: maker, to: id, toName: name) }) {
        return .carryOn(refusal)
      }
      return .seat(seat.reach.narrowed(to: target.scope))

    case .newAssistant(let draft):
      if readOutside {
        return .retryClean("This turn read text from outside Serein, so it can't make an assistant. Hand this to an assistant on the roster, or make it in a turn that has read nothing from outside.")
      }
      if room.made.count >= makesPerRoot {
        return .carryOn("This task already made \(makesPerRoot) assistants, the most for one task. Hand this to one of them or to another assistant on the roster, or do this part yourself.")
      }
      if team.profiles.filter({ !archived.contains($0.id) }).count >= RelayTeam.maxProfiles {
        return .carryOn("The roster is full (\(RelayTeam.maxProfiles) assistants). Hand this to an assistant on it, or do this part yourself.")
      }
      // A new assistant holds nothing up the chain yet, so "" only meets the depth and per-root caps.
      if let refusal = roomFull ?? row.flatMap({ ledger.chainRefusal(parent: $0, fromName: maker, to: "", toName: draft.name) }) {
        return .carryOn(refusal)
      }
      // Connected apps start off for a made assistant, as `AssistantDraft.places` says.
      return .make(seat.reach.narrowed(to: AssistantScope(destinations: draft.places, apps: [])), Lineage(madeBy: seat.who, madeIn: room.id))

    case .team:
      if readOutside {
        return .retryClean("This turn read text from outside Serein, so it can't save a team. Hand the work to the assistants directly, or save the team in a turn that has read nothing from outside.")
      }
      if room.teamsMade >= teamsPerRoot {
        return .carryOn("This task already saved a team, the most for one task. Hand the work to its members directly.")
      }
      return .makeTeam
    }
  }
}
