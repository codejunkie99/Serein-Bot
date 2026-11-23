import Foundation

/// Which navigation makes an approval stale.
/// The top frame does. The frame that holds the approved element does.
/// Any other frame is logged and leaves the yes in place.
public enum FrameBump {
  public struct Decision: Equatable, Sendable {
    public var bumps: Bool
    /// The navigation is recorded and does not move the page version.
    public var logged: Bool
  }

  public static func decide(mainFrame: Bool, holdsApprovedElement: Bool, blankChild: Bool = false) -> Decision {
    if mainFrame || holdsApprovedElement || blankChild {
      return Decision(bumps: true, logged: false)
    }
    return Decision(bumps: false, logged: true)
  }

  public static func bumps(mainFrame: Bool, holdsApprovedElement: Bool) -> Bool {
    decide(mainFrame: mainFrame, holdsApprovedElement: holdsApprovedElement).bumps
  }

  /// A blank child navigation does not move which frame the reader is bound to.
  public static func keepsReaderFrame(blankChild: Bool) -> Bool { blankChild }
}
