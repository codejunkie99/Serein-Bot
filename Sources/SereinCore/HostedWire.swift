import Foundation

/// What the wires of every hosted computer share (E2BWire, DaytonaWire): the computer's own user
/// and home, the environment Serein starts its processes with, the shape a key or token must have
/// to ride in one header, and how an answer is read. Every answer is untrusted input: read with a
/// size cap, and an error reduced to one plain line with every secret Serein holds taken out, so
/// no key or token can reach a log, a card, a tool answer or the model through an error.
public enum HostedWire {
  /// The computer's own unprivileged user (Serein's recipe, `Sources/Serein/Computer/Dockerfile`).
  public static let user = "serein"
  /// computer_run's user in the recipe's image (serein-start.sh), in `user`'s group.
  public static let shellUser = "shell"
  public static let home = "/home/serein"

  /// A key or access token fit for one header: 8 to 512 visible ASCII characters, nothing that
  /// could end the header or start another.
  public static func validSecret(_ text: String) -> Bool {
    (8...512).contains(text.utf8.count) && text.utf8.allSatisfy { (0x21...0x7E).contains($0) }
  }
  /// An id a provider gave: ASCII letters, digits, `-` and `_`, at most 64. Anything else is
  /// refused before it reaches a path or a header.
  public static func validID(_ text: String) -> Bool {
    guard !text.isEmpty, text.count <= 64 else { return false }
    return text.unicodeScalars.allSatisfy { (s: Unicode.Scalar) -> Bool in
      s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "-" || s == "_")
    }
  }

  /// The environment of every process Serein starts inside: the desktop, the home folder, and the
  /// way out. Through this Mac points every program at the shim on the computer's loopback; on the
  /// provider's own internet the proxy variables are emptied and the helper is told to open the
  /// browser without a proxy. No secret is ever put here.
  public static func environment(_ network: HostedNetwork) -> [String: String] {
    var envs = ["DISPLAY": ":0", "HOME": home]
    let proxy = network.usesProxy ? "http://127.0.0.1:3128" : ""
    for name in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"] { envs[name] = proxy }
    if !network.usesProxy { envs["SEREIN_NETWORK"] = "provider" }
    return envs
  }

  static func json(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
  }
  /// A JSON object no longer than `limit` bytes; nil for anything else.
  static func jsonObject(_ data: Data, limit: Int) -> [String: Any]? {
    guard data.count <= limit else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
  /// A whole number from a JSON number (never a boolean) or a short numeric string.
  static func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
    if let text = value as? String, text.count <= 12 { return Int(text) }
    return nil
  }
  /// Untrusted text in one plain line: control characters gone, at most `limit` characters.
  static func plain(_ text: String, limit: Int) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) { scalars.append(scalar) }
    return String(String(scalars).prefix(limit))
  }

  /// A plain sentence for an error answer. The provider's message is untrusted (control
  /// characters gone, cut), and every secret Serein holds is taken out before the cut.
  public static func errorText(provider: String, status: Int, body: Data, secrets: [String], limit: Int) -> String {
    var message = (jsonObject(body, limit: limit)?["message"] as? String).map { plain($0, limit: 2000) } ?? ""
    for secret in secrets where secret.count >= 4 { message = message.replacingOccurrences(of: secret, with: "…") }
    message = String(message.prefix(300))
    let fallback: String
    switch status {
    case 401, 403: fallback = "\(provider) did not accept the key. Check it in Settings › Serein's computer."
    case 404: fallback = "\(provider) does not know that computer, or what it is made from."
    case 429: fallback = "\(provider) is busy or a limit was reached. Try again in a minute."
    case 500...599: fallback = "\(provider) had a problem. Try again later."
    default: fallback = "\(provider) refused the request."
    }
    return "\(provider) answered \(status): " + (message.isEmpty ? fallback : message)
  }
}
