import Foundation

/// The quiet offer under a finished reply to keep how it was done as a skill. Save as Skill
/// already drafts one with no model (`TaskSkill.draft`); this only offers it when the work was
/// long enough to be worth repeating, so the person does not have to find it in the ⋯ menu.
public enum SkillOffer {
  /// Fewer tool calls than this is not a how-to worth keeping.
  public static let minimumSteps = 8
  public static let words = "Save how I did this as a skill?"

  /// Whether the turn `turn` of a chat shows the offer. Only a turn the person started that
  /// finished done (not stopped, not failed). Once per chat: `offeredFor` is the turn the chat's
  /// offer went to, which keeps showing it; `closed`, it was put away or the chat's task already
  /// has a saved skill.
  public static func offers(outcome: RunRecord.Outcome, steps: Int, kind: StepBudget.Kind, turn: String,
                            offeredFor: String?, closed: Bool) -> Bool {
    outcome == .done && steps >= minimumSteps && kind == .person && !closed
      && (offeredFor == nil || offeredFor == turn)
  }
}
