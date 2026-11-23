import Foundation

/// Plain-language copy for failed page loads, chosen by the NSURLError code.
public struct ErrorPageCopy: Equatable {
  public enum Kind: String { case offline, host, connection, timeout, certificate, blocked, generic }
  public var kind: Kind
  public var title: String
  public var detail: String
  public var symbol: String
  /// True when the person may choose to continue despite the problem (certificate errors).
  public var canContinue: Bool
}
public enum ErrorCopy {
  /// Returns nil for failures that should not show a page (cancelled loads, downloads).
  public static func page(domain: String, code: Int, host: String?) -> ErrorPageCopy? {
    if domain == "WebKitErrorDomain" {
      // 102: frame load interrupted by a download or a policy change; 204: plug-in handled it.
      return [102, 204].contains(code) ? nil : generic(host)
    }
    guard domain == NSURLErrorDomain else { return generic(host) }
    let site = host.flatMap { $0.isEmpty ? nil : $0 } ?? "this site"
    func make(
      _ kind: ErrorPageCopy.Kind, _ title: String, _ detail: String, _ symbol: String,
      _ cont: Bool = false
    ) -> ErrorPageCopy {
      ErrorPageCopy(kind: kind, title: title, detail: detail, symbol: symbol, canContinue: cont)
    }
    switch code {
    case NSURLErrorCancelled: return nil
    case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed,
      NSURLErrorInternationalRoamingOff:
      return make(
        .offline, "You’re offline",
        "This Mac isn’t connected to the internet. Check Wi-Fi or your cable, then try again.",
        "wifi.slash")
    case NSURLErrorNetworkConnectionLost:
      return make(
        .connection, "The connection dropped",
        "The network went away while \(site) was loading. Try again.", "wifi.exclamationmark")
    case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
      return make(
        .host, "Can’t find \(site)",
        "Check the address for typos. If it looks right, the site may be down.",
        "questionmark.circle")
    case NSURLErrorCannotConnectToHost:
      return make(
        .connection, "\(site) isn’t answering",
        "The server refused the connection. It may be down or busy.", "bolt.horizontal.circle")
    case NSURLErrorTimedOut:
      return make(
        .timeout, "\(site) took too long",
        "The server didn’t respond in time. Try again in a moment.", "clock.badge.exclamationmark")
    case NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
      return make(
        .certificate, "This connection isn’t private",
        "The certificate for \(site) is outside its valid dates. Someone could be intercepting your traffic.",
        "lock.trianglebadge.exclamationmark", true)
    case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot:
      return make(
        .certificate, "This connection isn’t private",
        "\(site) presented a certificate this Mac doesn’t trust. Someone could be intercepting your traffic.",
        "lock.trianglebadge.exclamationmark", true)
    case NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected,
      NSURLErrorClientCertificateRequired:
      return make(
        .certificate, "Couldn’t make a secure connection",
        "Serein couldn’t set up an encrypted connection to \(site).", "lock.slash")
    case NSURLErrorAppTransportSecurityRequiresSecureConnection:
      return make(
        .blocked, "Insecure address blocked",
        "\(site) only offers an unencrypted connection, which is blocked here.", "lock.slash")
    case NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation:
      return make(
        .generic, "Too many redirects",
        "\(site) keeps sending the browser in circles. Clearing its cookies may help.",
        "arrow.triangle.2.circlepath")
    case NSURLErrorUnsupportedURL, NSURLErrorBadURL:
      return make(
        .generic, "That address won’t work", "The address isn’t one this browser can open.",
        "link.badge.plus")
    case NSURLErrorResourceUnavailable, NSURLErrorFileDoesNotExist:
      return make(
        .generic, "Nothing here", "The page you asked for isn’t available.", "doc.questionmark")
    default: return generic(host)
    }
  }
  static func generic(_ host: String?) -> ErrorPageCopy {
    ErrorPageCopy(
      kind: .generic, title: "This page couldn’t load",
      detail: "Something went wrong while loading "
        + (host.flatMap { $0.isEmpty ? nil : $0 } ?? "the page") + ". Try again in a moment.",
      symbol: "exclamationmark.triangle", canContinue: false)
  }
}
