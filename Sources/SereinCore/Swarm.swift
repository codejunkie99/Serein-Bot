import Foundation

/// A swarm (owner, 2026-11-25: "Swarms on different models, using a hidden model registry with
/// usage left per model"): a lead fans one task out to up to three seats of itself, each on a
/// different model the registry picks, and gets one merged turn when they are back. Its rows are
/// hand-off rows (`AssistantHandoff.Side.swarm`), so they share the seat cap and `claimReport`.
/// A seat's words never post in the chat; only the lead's merged answer does.
public enum Swarm {
  /// Seats share "At most three delegated runs work at once" (`SideSeat.cap`).
  public static let cap = ModelRegistry.widthCap
  /// A seat's wall time (TEAMS-V2-BASE 7.4); past it the sweep closes it with what it had.
  public static let timeCap: TimeInterval = 30 * 60

  /// The routes a swarm's seats run on: `ModelRegistry.pick` over every route but one that bills
  /// each use (spending the person's key is a pay question, so a swarm never does it on its own).
  public static func routes(_ registry: ModelRegistry, need: ModelRegistry.Need, width: Int) -> [ModelRoute] {
    ModelRegistry(rows: registry.rows.filter { !LimitFailover.billsEachUse($0.route) }).pick(need: need, width: width)
  }

  /// How many seats a swarm gets: what was asked, at most `cap`, one per route found.
  public static func width(asked: Int, routes: Int) -> Int {
    max(0, min(asked, cap, routes))
  }

  /// The swarm's one line in the chat, from its lead: which models took a seat, and whether it
  /// shrank or some seats wait for a free one.
  public static func line(models: [String], asked: Int, waiting: Int) -> String {
    var words = "Asked \(models.count) model\(models.count == 1 ? "" : "s") at once: \(list(models))."
    if models.count < min(asked, cap) {
      words += " Only \(models.count) of \(min(asked, cap)) could take a seat now."
    }
    if waiting > 0 {
      words += " \(waiting) \(waiting == 1 ? "waits" : "wait") for a free seat and \(waiting == 1 ? "starts" : "start") when one frees."
    }
    return words
  }
  public static let lateWords = "It ran past 30 minutes, so the swarm went on without the rest."
  public static let deepWords = "A swarm seat can't start a swarm of its own. Finish this part yourself."
  public static let noRouteWords = "No other model can take a seat now. Do the task yourself."

  static func list(_ names: [String]) -> String {
    names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
  }
}
