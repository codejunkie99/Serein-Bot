import Foundation

/// A bare WKWebView sends "Mozilla/5.0 (Macintosh; …) AppleWebKit/605.1.15 (KHTML, like Gecko)"
/// with no `Version/… Safari/…` tail, so sites such as Google treat it as an unknown or old
/// browser and serve their basic pages. Appending Safari's own tail (the WebKit build is
/// shared) makes the agent read as the installed Safari.
public enum UserAgent {
  public static let webKitBuild = "605.1.15"
  public static let fallbackSafariVersion = "26.0"
  /// `applicationNameForUserAgent` for the web view configuration.
  public static func safariSuffix(version: String?) -> String {
    let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let usable = trimmed.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil
    return "Version/\(usable ? trimmed : fallbackSafariVersion) Safari/\(webKitBuild)"
  }
}
