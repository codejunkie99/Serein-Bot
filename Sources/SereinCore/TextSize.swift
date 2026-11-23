import Foundation

/// One text size for everything: Serein's own type scales by the factor, and every webpage's
/// zoom is the site's own zoom (⌘+ / ⌘-) multiplied by the same factor. A slider from 90% to
/// 160% in 5% steps, stored as a number under `serein.textScale`.
public enum TextSize {
  public static let defaultsKey = "serein.textScale"
  public static let range: ClosedRange<Double> = 0.9...1.6
  public static let step = 0.05
  public static let standard = 1.0

  /// Clamps to the range and rounds to the nearest step, so stored values stay tidy.
  public static func snap(_ value: Double) -> Double {
    let clamped = min(range.upperBound, max(range.lowerBound, value))
    return (clamped / step).rounded() * step
  }
  /// "120%" for the label beside the slider.
  public static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

  /// The zoom a webpage actually gets: its stored site zoom (1 when none) times the text size.
  public static func pageZoom(site stored: Double, factor: Double) -> Double {
    (stored > 0 ? stored : 1) * factor
  }
  /// The site's own zoom, read back from an applied page zoom.
  public static func siteZoom(page: Double, factor: Double) -> Double {
    guard factor > 0 else { return page }
    // Snap to the nearest step so float drift never makes ⌘+ skip or repeat a step.
    let raw = page / factor
    return PageZoom.steps.min { abs($0 - raw) < abs($1 - raw) } ?? raw
  }
}
