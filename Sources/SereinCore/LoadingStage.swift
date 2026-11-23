import Foundation

/// What a loading place shows after it has waited so long: nothing at first, so a fast load
/// never flashes; then a skeleton; then a plain line that it is slow, with a way to try again.
public enum LoadingStage: Equatable, Sendable {
  case blank, skeleton, slow
  public static let skeletonAfter: TimeInterval = 0.2
  public static let slowAfter: TimeInterval = 8
  /// The moments the stage changes, in order.
  public static let moments: [TimeInterval] = [skeletonAfter, slowAfter]
  public init(waited: TimeInterval) {
    self = waited < Self.skeletonAfter ? .blank : waited < Self.slowAfter ? .skeleton : .slow
  }
}
