import Foundation

/// The document version an approval is bound to. Every navigation advances it.
public enum PageVersion {
  public static func advance(_ version: String, because reason: String) -> String {
    advance(version, because: reason, bumping: true)
  }

  /// `bumping` false is the dropped guard: the version stays, so an old yes would still fit.
  @_spi(SereinReview)
  public static func advance(_ version: String, because reason: String, bumping: Bool) -> String {
    guard bumping else { return version }
    let reason = reason.isEmpty ? "navigation" : reason
    return "\(version)+\(reason)-\(UUID().uuidString)"
  }
}
