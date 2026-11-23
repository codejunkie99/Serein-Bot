import Foundation

// Pure rule for the sidebar's width. Its edge drags between a list (the usual width, up to 44
// points narrower and 168 wider) and, pulled narrower than that, a rail of faces only.

public enum SidebarWidth {
  /// The rail: one column of faces, and room for the window's three buttons.
  public static let rail: CGFloat = 84
  /// What a drag adds to the list's usual width.
  public static let extra: ClosedRange<CGFloat> = -44...168
  /// One VoiceOver step.
  public static let step: CGFloat = 20

  public enum Settled: Equatable, Sendable {
    case rail
    case list(extra: CGFloat)
  }

  public enum Move: Equatable, Sendable {
    /// The pointer wants the edge at this width.
    case width(CGFloat)
    /// One step wider or narrower.
    case step(up: Bool)
  }

  /// The visible edge follows the pointer, including the space between the rail and list.
  public static func dragged(_ width: CGFloat, usual: CGFloat) -> CGFloat {
    min(usual + extra.upperBound, max(rail, width))
  }

  /// On release, choose the nearer endpoint of the gap. VoiceOver moves in discrete steps.
  public static func settle(_ move: Move, from now: Settled, usual: CGFloat) -> Settled {
    switch move {
    case .width(let width):
      if width < (rail + usual + extra.lowerBound) / 2 { return .rail }
      return .list(extra: clamped(width - usual))
    case .step(let up):
      guard case .list(let current) = now else { return up ? .list(extra: extra.lowerBound) : .rail }
      if !up, current <= extra.lowerBound { return .rail }
      return .list(extra: clamped(current + (up ? step : -step)))
    }
  }

  public static func clamped(_ value: CGFloat) -> CGFloat {
    min(extra.upperBound, max(extra.lowerBound, value))
  }
}
