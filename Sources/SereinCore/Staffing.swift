import Foundation

/// Who may join a room, decided with no person: it never returns "ask", and it counts nothing. A
/// task makes any number of assistants; only a target that cannot take work, a loop and the chain
/// depth (`HandoffLedger.maxChain`) refuse, and every refusal names the way on. Saving a team asks
/// nothing of a room, so `team_make` never comes here.
public enum Staffing {
  public enum Wanted: Equatable, Sendable {
    case teammate(RelayProfile.ID)
    case newAssistant(AssistantDraft)
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
    /// A loop, the chain depth, or a target that cannot take work. The words name the way on.
    case carryOn(String)
  }

  /// `team` is the roster; `archived` the assistants archived from it, who never take work, even
  /// if they are still listed. Outside text the turn read changes nothing here: it is data.
  public static func decide(_ wanted: Wanted, by seat: Workroom.Seat, in room: Workroom, team: RelayTeam,
                            archived: Set<RelayProfile.ID>, ledger: HandoffLedger, now: Date) -> Verdict {
    let maker = team.profiles.first { $0.id == seat.who }?.name ?? "You"
    let row = seat.handoff.flatMap { h in ledger.records.first { $0.id == h } }
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
      if let refusal = row.flatMap({ ledger.chainRefusal(parent: $0, fromName: maker, to: id, toName: name) }) {
        return .carryOn(refusal)
      }
      return .seat(seat.reach.narrowed(to: target.scope))

    case .newAssistant(let draft):
      // A new assistant holds nothing up the chain yet, so "" only meets the depth rule.
      if let refusal = row.flatMap({ ledger.chainRefusal(parent: $0, fromName: maker, to: "", toName: draft.name) }) {
        return .carryOn(refusal)
      }
      // Connected apps start off for a made assistant, as `AssistantDraft.places` says.
      return .make(seat.reach.narrowed(to: AssistantScope(destinations: draft.places, apps: [])), Lineage(madeBy: seat.who, madeIn: room.id))
    }
  }

  /// Why an assistant in a turn the person did not start may not rename, pause, narrow, widen,
  /// rewrite or archive `target`, or nil when it may. Assistants a bot made are the bots' to
  /// change; the ones the person made only take work from them.
  public static func mayRework(_ target: RelayProfile, in turn: Admission.Turn) -> String? {
    guard turn != .person, target.lineage == nil else { return nil }
    return "\(target.name) was set up by the person, so only the person changes or removes it. Hand it work instead, or make a new assistant for this."
  }

  /// Applies a `.make` verdict to the roster: the drafted assistant at `reach` with no connected
  /// apps and its lineage. The shell's journaled change and the formal machine both run it; the
  /// caller records the make in its room (`Workroom.recordMade`).
  public static func make(_ draft: AssistantDraft, reach: Reach, lineage: Lineage, team: RelayTeam,
                          id: String = UUID().uuidString, now: Date = Date()) -> Result<MakePlan, AssistantDraft.Problem> {
    team.making(draft, person: reach.scope.destinations, id: id, now: now).map { plan in
      var plan = plan
      plan.profile.scope?.neverSites = reach.scope.neverSites
      plan.profile.scope?.apps = []
      plan.profile.lineage = lineage
      plan.team.profiles[plan.team.profiles.count - 1] = plan.profile
      return plan
    }
  }
}
