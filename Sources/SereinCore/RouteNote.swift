import Foundation

/// A route-change message from a page. Only the main frame, or a frame on the same origin
/// as the page, may advance the page version.
public enum RouteNote {
  /// `nav` and `nav:` are route changes. Anything else is a frame id, not a navigation.
  public static func reason(body: String) -> String? {
    if body == "nav" { return "route" }
    guard body.hasPrefix("nav:") else { return nil }
    let reason = String(body.dropFirst(4))
    return reason.isEmpty ? "route" : reason
  }

  /// `mainFrame` is the document the person is looking at. A sub-frame must match the page's
  /// scheme, host and port. An empty host does not match.
  public static func allowed(
    mainFrame: Bool, frameScheme: String, frameHost: String, framePort: Int,
    pageScheme: String, pageHost: String, pagePort: Int
  ) -> Bool {
    if mainFrame { return true }
    let frameHost = frameHost.lowercased()
    let pageHost = pageHost.lowercased()
    guard !frameHost.isEmpty, frameHost == pageHost else { return false }
    guard frameScheme.lowercased() == pageScheme.lowercased(), !pageScheme.isEmpty else { return false }
    return framePort == pagePort
  }

  /// about:blank and srcdoc. A push from one of these stales the yes. It does not retarget the reader.
  public static func blankChild(scheme: String) -> Bool {
    let scheme = scheme.lowercased()
    return scheme == "about" || scheme == "srcdoc"
  }
}
