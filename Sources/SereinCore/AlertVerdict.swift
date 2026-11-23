import Foundation

/// How a Mac alert's button code becomes a human answer.
/// The first button is yes, the second is no, and a timeout is not a yes.
public enum AlertVerdict {
  public static let yesCode = 1000
  public static let noCode = 1001
  public static let timeoutCode = 0

  public static func human(_ response: Int) -> ApprovalGate.HumanAnswer {
    switch response {
    case yesCode: return .yes
    case noCode: return .no
    default: return .timeout
    }
  }
}
