import Darwin
import Foundation

/// Outside agents (Grok Bot, Claude Code, Codex and others) drive Serein through the
/// `serein-agent` command. The socket, the pairings and the audit log live in the library's
/// agents folder (0700). A pairing exists only after the user made a code in
/// Settings › AI apps and the agent sent that code back.
public enum AgentAccess {
  public static func directory(root: URL) -> URL {
    root.appendingPathComponent("agents", isDirectory: true)
  }
  public static func socketPath(root: URL) -> String {
    directory(root: root).appendingPathComponent("serein.sock").path
  }
  public static func grants(root: URL) -> URL {
    directory(root: root).appendingPathComponent("grants", isDirectory: true)
  }
  /// One file per pairing, read by the command: its name and token.
  public static func clients(root: URL) -> URL {
    directory(root: root).appendingPathComponent("clients", isDirectory: true)
  }
  /// The library Serein uses when nothing else is set (the same rule as the app).
  public static var defaultRoot: URL {
    ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Serein/Library")
  }
  /// Eight digits shown as 1234-5678; the system generator is cryptographically secure.
  public static func newCode() -> String {
    let digits = (0..<8).map { _ in String(Int.random(in: 0...9)) }.joined()
    return String(digits.prefix(4)) + "-" + String(digits.suffix(4))
  }
  public static func normalizedCode(_ code: String) -> String { code.filter(\.isNumber) }

  /// Compares two secrets in time that depends only on their lengths: no early return on a
  /// length mismatch or at the first different byte, and every byte of the longer one is read.
  public static func tokensEqual(_ presented: String, _ expected: String) -> Bool {
    let left = Array(presented.utf8)
    let right = Array(expected.utf8)
    var diff: UInt8 = left.count == right.count ? 0 : 1
    for index in 0..<max(left.count, right.count) {
      let x: UInt8 = index < left.count ? left[index] : 0
      let y: UInt8 = index < right.count ? right[index] : 0
      diff |= x ^ y
    }
    return diff == 0
  }
  /// Takes "May ask Serein" back from every stored pairing that has it, keeping each file
  /// owner-only. Returns the ids changed.
  @discardableResult public static func clearRelayGrants(root: URL) -> [String] {
    let folder = grants(root: root)
    var changed: [String] = []
    for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    where file.pathExtension == "json" {
      guard let data = try? Data(contentsOf: file), let grant = try? JSONDecoder().decode(AgentGrant.self, from: data),
        grant.mayAskRelay
      else { continue }
      if (try? grant.clearingRelay().write(to: file)) != nil { changed.append(grant.id) }
    }
    return changed
  }
}

/// What one paired agent may do. The token travels in every request; the file is 0600.
public struct AgentGrant: Codable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var token: String
  /// Sites where the agent works with the user's sign-ins. Empty: isolated tabs with no
  /// sign-ins, on any public site.
  public var signInSites: [String]
  public var allowActions: Bool
  /// Local or private hosts the agent may open, such as a dev server. Others are refused.
  public var localHosts: [String]
  public var created: Date
  public var expires: Date?
  /// May send Relay requests (`serein-agent relay ask`). Relay can run the user's agents and
  /// operate Mac apps, so this is its own choice, off unless the user ticks it; nil in pairings
  /// made before it existed means off.
  public var relay: Bool?
  public var mayAskRelay: Bool { relay == true }
  /// Set when the one-time assistant migration took "May ask Serein" back (the assistant was
  /// off when the pairing was allowed to ask); cleared when the user allows it again.
  public var relayCleared: Bool?
  /// This pairing without "May ask Serein", marked as taken back when it had it.
  public func clearingRelay() -> AgentGrant {
    var copy = self
    if copy.relay == true { copy.relayCleared = true }
    copy.relay = nil
    return copy
  }
  public init(
    name: String, signInSites: [String], allowActions: Bool, localHosts: [String], expires: Date?, relay: Bool = false
  ) {
    id = UUID().uuidString
    self.name = String(name.prefix(40))
    token = UUID().uuidString + UUID().uuidString
    self.signInSites = signInSites
    self.allowActions = allowActions
    self.localHosts = localHosts
    created = Date()
    self.expires = expires
    self.relay = relay ? true : nil
  }
  public var usesSignIns: Bool { !signInSites.isEmpty }
  public func expired(at now: Date = Date()) -> Bool { expires.map { now >= $0 } ?? false }
  /// A main-frame address the agent's tabs may load.
  public func allows(_ url: URL) -> Bool {
    guard let host = url.host.map(SitePolicy.host) else { return false }
    if SitePolicy.isPrivate(host) { return localHosts.contains(host) }
    return !usesSignIns || signInSites.contains { SitePolicy.matches(host: host, site: $0) }
  }
  public func write(to url: URL) throws {
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

public enum SitePolicy {
  /// "https://www.GitHub.com/x" and "github.com" are the same site; nil for anything else.
  public static func site(_ input: String) -> String? {
    var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
    s = String(s.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    // A port goes; an IPv6 address keeps its colons.
    if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
      s = String(s[...end])
    } else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
      s = String(s[..<colon])
    }
    s = host(s)
    if s.hasPrefix("www.") { s.removeFirst(4) }
    guard !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || ".-:".contains($0) }) else { return nil }
    return s
  }
  /// A host as compared: lower case, no brackets, no trailing dot.
  public static func host(_ value: String) -> String {
    var h = value.lowercased()
    if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
    while h.hasSuffix(".") { h.removeLast() }
    return h
  }
  public static func matches(host: String, site: String) -> Bool {
    host == site || host.hasSuffix("." + site)
  }
  /// Loopback, private, link-local and single-label hosts. ponytail: by name and address only;
  /// a public name that resolves to a private address (DNS rebinding, nip.io) is not caught.
  public static func isPrivate(_ host: String) -> Bool {
    let h = Self.host(host)
    if h.isEmpty || !h.contains(".") && !h.contains(":") { return true }
    for suffix in [".localhost", ".local", ".internal", ".lan", ".home.arpa"] where h.hasSuffix(suffix) {
      return true
    }
    var v4 = in_addr()
    // inet_aton also reads the old forms (0x7f.1, 2130706433) that some URL parsers accept.
    if !h.contains(":"), inet_aton(h, &v4) != 0 {
      let a = UInt32(bigEndian: v4.s_addr)
      let first = a >> 24, second = (a >> 16) & 0xff
      return first == 0 || first == 10 || first == 127 || (first == 169 && second == 254)
        || (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168)
        || (first == 100 && (64...127).contains(second))
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, h, &v6) == 1 {
      let b = withUnsafeBytes(of: v6) { Array($0) }
      if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
        return isPrivate(b[12...].map(String.init).joined(separator: "."))
      }
      return b[0..<15].allSatisfy({ $0 == 0 })  // :: and ::1
        || b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80)
    }
    return false
  }
}

public enum MCPConnection {
  public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
  public static func pairCommand(executable: String, code: String, dataRoot: String? = nil) -> String {
    (dataRoot.map { "SEREIN_DATA_DIR=" + shellQuote($0) + " " } ?? "") + shellQuote(executable) + " pair " + shellQuote(code)
  }

  public static func codexConfiguration(executable: String, name: String, dataRoot: String? = nil) -> String {
    var text = "[mcp_servers.serein]\ncommand = " + jsonString(executable) + "\nargs = " + jsonString(["--as", name, "mcp"])
    if let dataRoot { text += "\n\n[mcp_servers.serein.env]\nSEREIN_DATA_DIR = " + jsonString(dataRoot) }
    return text
  }
  /// Client configuration contains a pairing name, never a token or one-time code.
  public static func configuration(executable: String, name: String, dataRoot: String? = nil) -> String {
    var server: [String: Any] = ["command": executable, "args": ["--as", name, "mcp"]]
    if let dataRoot { server["env"] = ["SEREIN_DATA_DIR": dataRoot] }
    let value: [String: Any] = ["mcpServers": ["serein": server]]
    return (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
      .map { String(decoding: $0, as: UTF8.self) } ?? jsonString(value)
  }
}
