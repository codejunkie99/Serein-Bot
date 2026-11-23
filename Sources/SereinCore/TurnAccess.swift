import Foundation

/// What one agent turn may do, from the user's toggles and plan mode.
///
/// A plan turn is read-only: no project edits and no website clicks or typing (Mac actions and
/// the one-shot sign-in grant are withheld by the caller too). An approved plan may edit project
/// files for that turn only; the user's own toggles are never changed.
public struct TurnAccess: Equatable, Sendable {
  public var projectEdits: Bool
  public var actions: Bool

  public static func resolve(
    plan: Bool, approved: Bool, isProject: Bool, projectEdits: Bool, actions: Bool
  ) -> TurnAccess {
    if plan { return TurnAccess(projectEdits: false, actions: false) }
    return TurnAccess(
      projectEdits: isProject && (projectEdits || approved), actions: actions)
  }

  public init(projectEdits: Bool, actions: Bool) {
    self.projectEdits = projectEdits
    self.actions = actions
  }
}
