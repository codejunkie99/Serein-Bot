import AuthenticationServices
import SereinCore

/// The browser half of a remote plugin's OAuth 2.1 sign-in: discover, register as a public client,
/// open the user's browser with PKCE, catch the callback, exchange the code, and keep the tokens in
/// the Keychain. One call: `PluginSignIn.run(package:manifest:)`.
@MainActor enum PluginSignIn {
  static func run(manifest: PluginManifest) async throws {
    guard let server = manifest.mcp, server.auth == "oauth2",
      let raw = server.url?.trimmingCharacters(in: .whitespacesAndNewlines),
      let serverURL = URL(string: raw)
    else { throw SereinError.invalid("\(manifest.name) is not an oauth2 plugin.") }
    try await run(plugin: manifest.id, name: manifest.name, serverURL: serverURL)
  }

  /// The same sign-in by plugin id, for a server connected by address before its local manifest
  /// exists (the Marketplace (Your apps, On this Mac)); the tokens land where that manifest's calls read them.
  /// `expectedHost` is the "Signs in at" host the person was shown: a discovery that now names
  /// another one is refused.
  static func run(plugin id: String, name: String, serverURL: URL, expectedHost: String? = nil) async throws {
    let metadata = try await PluginOAuth.discover(serverURL: serverURL)
    guard expectedHost == nil || metadata.signInHost == expectedHost else {
      throw SereinError.invalid("\(name)'s sign-in moved to another address. Close this and add the server again.")
    }
    let clientID = try await PluginOAuth.register(
      clientName: "Serein — \(name)", metadata: metadata)
    let verifier = PluginOAuth.makeVerifier()
    let state = PluginOAuth.makeVerifier()
    guard let authorization = URL(string: metadata.authorizationEndpoint),
      let url = PluginOAuth.authorizeURL(
        authorization: authorization, clientID: clientID, redirect: PluginOAuth.redirectURI,
        verifier: verifier, state: state, scopes: metadata.scopesSupported ?? [])
    else { throw SereinError.invalid("The plugin's sign-in endpoint is malformed.") }
    let callback: URL
    #if DEBUG
    if let browserOverride { callback = try await browserOverride(url) } else {
      callback = try await browserSession(url)
    }
    #else
    callback = try await browserSession(url)
    #endif
    guard let code = PluginOAuth.callback(callback, state: state) else {
      throw SereinError.invalid("Sign-in was cancelled or did not come back.")
    }
    var tokens = try await PluginOAuth.exchange(
      PluginOAuth.tokenRequest(code: code, redirect: PluginOAuth.redirectURI, verifier: verifier, clientID: clientID),
      tokenEndpoint: metadata.tokenEndpoint)
    tokens.tokenEndpoint = metadata.tokenEndpoint
    tokens.clientID = clientID
    PluginHost.saveOAuth(plugin: id, tokens: tokens)
  }

  static func signOut(_ manifest: PluginManifest) {
    PluginHost.saveOAuth(plugin: manifest.id, tokens: nil)
  }
  static var signedIn: (String) -> Bool { { plugin in PluginHost.oauthTokens(plugin: plugin) != nil } }

  #if DEBUG
  /// Checks play the browser here: they get the authorize URL and return the callback.
  static var browserOverride: ((URL) async throws -> URL)?
  #endif
  /// Opens the user's browser and waits for the redirect ASWebAuthenticationSession intercepts.
  private static func browserSession(_ url: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let anchor = Anchor()
      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "http") { callback, error in
        if let callback {
          continuation.resume(returning: callback)
        } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
          continuation.resume(throwing: SereinError.invalid("The sign-in window closed before it finished. Try again."))
        } else {
          continuation.resume(throwing: SereinError.invalid(error?.localizedDescription ?? "Sign-in did not finish."))
        }
        anchor.release()
      }
      session.presentationContextProvider = anchor
      // A one-time browser window the user can always cancel.
      session.prefersEphemeralWebBrowserSession = false
      anchor.hold(session)
      guard session.start() else {
        anchor.release()
        continuation.resume(throwing: SereinError.invalid("The browser could not open the sign-in."))
        return
      }
    }
  }

  /// Keeps the session and the window anchor alive for the length of the sign-in.
  private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var sessions: [ASWebAuthenticationSession] = []
    func hold(_ session: ASWebAuthenticationSession) { sessions.append(session) }
    func release() { sessions.removeAll() }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
      NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    }
  }
}
