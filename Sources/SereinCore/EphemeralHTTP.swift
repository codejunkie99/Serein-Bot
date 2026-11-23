import Foundation

/// A URLSession that keeps nothing and follows no redirect: no cookies, credential store or cache,
/// and a redirect comes back as its own 3xx answer, so a request and its headers (an API key) never
/// move to another destination. Plugin downloads, provider model lists and the models.dev refresh use it.
public enum EphemeralHTTP {
  public static func session(resourceTimeout: TimeInterval? = nil) -> URLSession {
    URLSession(configuration: configuration(resourceTimeout: resourceTimeout), delegate: NoRedirects(), delegateQueue: nil)
  }
  /// The settings alone, for a session with a delegate of its own (a hosted computer's process
  /// stream, E2BStream and DaytonaStream), which must refuse redirects itself.
  public static func configuration(resourceTimeout: TimeInterval? = nil) -> URLSessionConfiguration {
    let settings = URLSessionConfiguration.ephemeral
    settings.httpCookieStorage = nil
    settings.urlCredentialStorage = nil
    settings.httpShouldSetCookies = false
    settings.urlCache = nil
    if let resourceTimeout { settings.timeoutIntervalForResource = resourceTimeout }
    return settings
  }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
