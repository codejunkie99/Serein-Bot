import CryptoKit
import Foundation

/// Sign-in for remote MCP plugins that speak OAuth 2.1: authorization-server metadata discovery,
/// dynamic client registration as a public client (no secret), PKCE S256, and refresh. The browser
/// part runs in the app target (ASWebAuthenticationSession); everything here is pure or plain HTTP,
/// so it is checked in SereinChecks.
public enum PluginOAuth {
  public struct Tokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    /// Kept with the tokens so a refresh never repeats discovery and registration.
    public var tokenEndpoint: String?
    public var clientID: String?
    public init(
      accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
      tokenEndpoint: String? = nil, clientID: String? = nil
    ) {
      self.accessToken = accessToken
      self.refreshToken = refreshToken
      self.expiresAt = expiresAt
      self.tokenEndpoint = tokenEndpoint
      self.clientID = clientID
    }
  }

  public struct ServerMetadata: Codable, Equatable, Sendable {
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var registrationEndpoint: String?
    public var scopesSupported: [String]?
    /// Where the person signs in: the authorization endpoint's host, shown before the sign-in.
    public var signInHost: String? { URL(string: authorizationEndpoint)?.host?.lowercased() }
    enum CodingKeys: String, CodingKey {
      case authorizationEndpoint = "authorization_endpoint"
      case tokenEndpoint = "token_endpoint"
      case registrationEndpoint = "registration_endpoint"
      case scopesSupported = "scopes_supported"
    }
  }

  /// The loopback redirect ASWebAuthenticationSession intercepts before anything connects.
  public static let redirectURI = "http://127.0.0.1/serein-plugin-callback"

  /// A PKCE code verifier: 48 random bytes, base64url (86 characters, within 43–128).
  public static func makeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 48)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
      for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
    }
    return Data(bytes).base64URLEscaped
  }

  /// S256: base64url(SHA-256(verifier)) with no padding.
  public static func challenge(_ verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEscaped
  }

  /// RFC 8414 discovery: the well-known URL for an authorization server, path-aware.
  public static func metadataURL(from serverURL: URL) -> URL? {
    guard let host = serverURL.host, ["https", "http"].contains(serverURL.scheme?.lowercased() ?? "") else {
      return nil
    }
    var components = URLComponents()
    components.scheme = serverURL.scheme
    components.host = host
    components.port = serverURL.port
    let path = serverURL.path
    components.path = "/.well-known/oauth-authorization-server" + path
    return components.url
  }

  /// Dynamic client registration (RFC 7591): a public client, PKCE only, no secret.
  public static func registrationRequest(clientName: String, redirect: String) -> [String: Any] {
    [
      "client_name": String(clientName.prefix(60)),
      "redirect_uris": [redirect],
      "grant_types": ["authorization_code", "refresh_token"],
      "response_types": ["code"],
      "token_endpoint_auth_method": "none",
      "code_challenge_method": "S256",
    ]
  }

  public static func decodeRegistration(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["client_id"] as? String
  }

  public static func authorizeURL(
    authorization: URL, clientID: String, redirect: String, verifier: String, state: String,
    scopes: [String]
  ) -> URL? {
    var components = URLComponents(url: authorization, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirect),
      URLQueryItem(name: "code_challenge", value: challenge(verifier)),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
    ] + (scopes.isEmpty ? [] : [URLQueryItem(name: "scope", value: scopes.joined(separator: " "))])
    return components?.url
  }

  /// The code from the intercepted callback, when its state matches; nil otherwise.
  public static func callback(_ url: URL, state: String) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let returned = components.queryItems?.first(where: { $0.name == "state" })?.value,
      returned == state,
      let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty
    else { return nil }
    return code
  }

  public static func tokenRequest(code: String, redirect: String, verifier: String, clientID: String) -> [String: Any] {
    [
      "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
      "code_verifier": verifier, "client_id": clientID,
    ]
  }

  public static func refreshRequest(refreshToken: String, clientID: String) -> [String: Any] {
    ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]
  }

  /// The body of a token request: urlencoded, as the spec wants.
  public static func form(_ fields: [String: Any]) -> Data? {
    var components = URLComponents()
    components.queryItems = fields.map { name, value in
      URLQueryItem(name: name, value: "\(value)")
    }
    guard let query = components.query else { return nil }
    return Data(query.utf8)
  }

  public static func decodeTokens(_ data: Data) -> Tokens? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let access = object["access_token"] as? String, !access.isEmpty
    else { return nil }
    let refresh = object["refresh_token"] as? String
    let lifetime = object["expires_in"] as? Double
    return Tokens(
      accessToken: access, refreshToken: refresh,
      expiresAt: lifetime.map { Date().addingTimeInterval($0) })
  }

  /// Tokens count as spent a minute early, so a request never goes out on a dying token.
  public static func expired(_ tokens: Tokens, now: Date = Date()) -> Bool {
    tokens.expiresAt.map { now.timeIntervalSince($0) > -60 } ?? false
  }
}

public extension PluginOAuth {
  /// Metadata discovery: the server's well-known document, bounded and short-lived, through a
  /// session that follows no redirect.
  /// When the server's own host has no such document, its protected-resource metadata (RFC 9728)
  /// names the authorization server, which is then discovered the same way. That metadata must
  /// name this server as its `resource`, and the issuer must be https on a public host name.
  /// Either way every endpoint must pass `allowedEndpoint`, so a server cannot point the sign-in
  /// at this Mac, the local network or a plain-http address.
  static func discover(serverURL: URL, timeout: TimeInterval = 20) async throws -> ServerMetadata {
    guard let url = metadataURL(from: serverURL) else {
      throw SereinError.invalid("The plugin's server URL is not http(s).")
    }
    do {
      return try await checked(
        decodeRequest(ServerMetadata.self, url: url, timeout: timeout, what: "sign-in discovery"), server: serverURL)
    } catch {
      for resource in resourceMetadataURLs(from: serverURL) {
        guard let named = try? await decodeRequest(ResourceMetadata.self, url: resource, timeout: timeout, what: "sign-in discovery"),
          sameResource(named.resource, serverURL),
          let issuer = named.authorizationServers?.first.flatMap({ URL(string: $0) }),
          allowedEndpoint(issuer.absoluteString, server: serverURL, loopback: false),
          let issuerMetadata = metadataURL(from: issuer),
          let found = try? await decodeRequest(ServerMetadata.self, url: issuerMetadata, timeout: timeout, what: "sign-in discovery"),
          let usable = try? checked(found, server: serverURL, loopback: false)
        else { continue }
        return usable
      }
      throw error
    }
  }

  /// RFC 9728: what a protected MCP server says about who signs its users in.
  struct ResourceMetadata: Decodable {
    var resource: String?
    var authorizationServers: [String]?
    enum CodingKeys: String, CodingKey {
      case resource
      case authorizationServers = "authorization_servers"
    }
  }
  /// The metadata is about this server (RFC 9728 §3.3), a trailing slash aside.
  static func sameResource(_ resource: String?, _ serverURL: URL) -> Bool {
    func bare(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
    guard let resource else { return false }
    return bare(resource) == bare(serverURL.absoluteString)
  }
  /// An endpoint the sign-in may use: https on a public host name, never a raw IP address or a
  /// local one. The one exception keeps a server on this Mac itself working (plain http to
  /// 127.0.0.1, as the plugin endpoint rule allows): its own discovery may name that same host.
  static func allowedEndpoint(_ string: String?, server: URL, loopback: Bool = true) -> Bool {
    guard let string, let url = URL(string: string), let host = url.host?.lowercased(), !host.isEmpty,
      url.user == nil, url.password == nil
    else { return false }
    let scheme = url.scheme?.lowercased() ?? ""
    if loopback, let serverHost = server.host?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(serverHost),
      host == serverHost, ["http", "https"].contains(scheme)
    {
      return true
    }
    // A dotted name that is not mDNS (.local): a bare intranet name or a router is never used.
    return scheme == "https" && host.contains(".") && !host.hasSuffix(".local") && !host.hasSuffix(".local.")
      && !ConnectGate.isLocal(host) && !ConnectGate.isRawIP(host)
  }
  /// The metadata, when its authorization, token and registration endpoints are all allowed.
  static func checked(_ metadata: ServerMetadata, server: URL, loopback: Bool = true) throws -> ServerMetadata {
    var endpoints: [String] = [metadata.authorizationEndpoint, metadata.tokenEndpoint]
    if let registration = metadata.registrationEndpoint { endpoints.append(registration) }
    guard endpoints.allSatisfy({ allowedEndpoint($0, server: server, loopback: loopback) }) else {
      throw SereinError.invalid("The plugin's sign-in names an address Serein does not use (https on a public host only).")
    }
    return metadata
  }
  /// The protected-resource documents to try: path-aware first, then the host's root.
  static func resourceMetadataURLs(from serverURL: URL) -> [URL] {
    guard let host = serverURL.host, ["https", "http"].contains(serverURL.scheme?.lowercased() ?? "") else { return [] }
    var components = URLComponents()
    components.scheme = serverURL.scheme
    components.host = host
    components.port = serverURL.port
    let path = serverURL.path == "/" ? "" : serverURL.path
    return (path.isEmpty ? [""] : [path, ""]).compactMap { suffix in
      components.path = "/.well-known/oauth-protected-resource" + suffix
      return components.url
    }
  }

  /// Dynamic client registration as a public client; answers with the client_id.
  static func register(clientName: String, metadata: ServerMetadata, timeout: TimeInterval = 20) async throws -> String {
    guard let endpoint = metadata.registrationEndpoint, let url = URL(string: endpoint) else {
      throw SereinError.invalid("The plugin's sign-in does not support app sign-in (no registration endpoint).")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: registrationRequest(clientName: clientName, redirect: redirectURI))
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw SereinError.invalid("The plugin's sign-in registration failed.")
    }
    guard let clientID = decodeRegistration(data) else {
      throw SereinError.invalid("The plugin's sign-in registration answered without a client id.")
    }
    return clientID
  }

  /// The token exchange, or a refresh: one urlencoded POST, tokens back.
  static func exchange(_ fields: [String: Any], tokenEndpoint: String, timeout: TimeInterval = 20) async throws -> Tokens {
    guard let url = URL(string: tokenEndpoint) else { throw SereinError.invalid("The plugin's sign-in token endpoint is malformed.") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = form(fields)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw SereinError.invalid("The plugin's sign-in could not be completed: " + String(decoding: data.prefix(200), as: UTF8.self))
    }
    guard let tokens = decodeTokens(data) else {
      throw SereinError.invalid("The plugin's sign-in answered without tokens.")
    }
    return tokens
  }

  /// Keeps nothing and follows no redirect, so no request or token moves to another address.
  private static let session = EphemeralHTTP.session(resourceTimeout: 20)

  private static func decodeRequest<T: Decodable>(_ type: T.Type, url: URL, timeout: TimeInterval, what: String) async throws -> T {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw SereinError.invalid("The plugin's \(what) failed.")
    }
    guard let decoded = try? JSONDecoder().decode(type, from: data) else {
      throw SereinError.invalid("The plugin's \(what) answered something unreadable: " + String(decoding: data.prefix(200), as: UTF8.self))
    }
    return decoded
  }
}

extension Data {
  /// base64url, no padding — the alphabet PKCE uses.
  var base64URLEscaped: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
