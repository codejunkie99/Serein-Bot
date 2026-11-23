import Foundation

/// Zoom steps shared by the keyboard shortcuts and the menu.
public enum PageZoom {
  public static let steps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

  public static func step(from current: Double, up: Bool) -> Double {
    if up { return steps.first { $0 > current + 0.001 } ?? steps.last! }
    return steps.last { $0 < current - 0.001 } ?? steps.first!
  }
  /// The preference key for a host, or nil when the host is empty.
  public static func key(host: String?) -> String? {
    guard let host = host?.lowercased(), !host.isEmpty else { return nil }
    return "serein.zoom." + host
  }
}
