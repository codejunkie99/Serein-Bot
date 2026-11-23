import CommonCrypto
import Foundation
import SQLite3

/// One website cookie read from another browser, before it is written anywhere.
public struct ImportedCookie: Hashable, Sendable {
  public var domain: String
  public var name: String
  public var value: String
  public var path: String
  /// nil for a session cookie.
  public var expires: Date?
  public var secure: Bool
  public var httpOnly: Bool
  /// "Lax", "Strict", "None" or nil when unspecified.
  public var sameSite: String?

  public init(
    domain: String, name: String, value: String, path: String, expires: Date?, secure: Bool,
    httpOnly: Bool, sameSite: String?
  ) {
    self.domain = domain
    self.name = name
    self.value = value
    self.path = path
    self.expires = expires
    self.secure = secure
    self.httpOnly = httpOnly
    self.sameSite = sameSite
  }

  /// Identity used to keep a newer cookie that already exists in Serein.
  public var key: String { domain.lowercased() + "|" + name + "|" + path }
}

/// Pure decryption and reading of a Chromium-family (Chrome, Arc, Brave, Edge, Vivaldi...)
/// `Cookies` database on macOS. The key comes from the browser's "Safe Storage" Keychain
/// item, which the caller reads; this type never touches the Keychain.
public enum ChromiumCookies {
  public static let salt = Data("saltysalt".utf8)
  public static let iterations: UInt32 = 1003
  /// Chromium's AES-128-CBC IV: sixteen spaces.
  public static let iv = Data(repeating: 0x20, count: 16)

  /// Keychain service names for each browser's cookie key, keyed by `BrowserImportProfile.browser`.
  public static let safeStorageServices: [String: String] = [
    "Google Chrome": "Chrome Safe Storage",
    "Chromium": "Chromium Safe Storage",
    "Microsoft Edge": "Microsoft Edge Safe Storage",
    "Brave": "Brave Safe Storage",
    "Vivaldi": "Vivaldi Safe Storage",
    "Opera": "Opera Safe Storage",
    "Arc": "Arc Safe Storage",
    "Comet": "Comet Safe Storage",
  ]

  public static func cookiesDatabase(in profile: URL) -> URL? {
    for relative in ["Network/Cookies", "Cookies"] {
      let url = profile.appendingPathComponent(relative)
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return nil
  }

  public static func pbkdf2SHA1(password: Data, salt: Data, rounds: UInt32, length: Int) -> Data {
    var out = Data(repeating: 0, count: length)
    let status = out.withUnsafeMutableBytes { outBytes in
      password.withUnsafeBytes { pw in
        salt.withUnsafeBytes { s in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: Int8.self),
            password.count, s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
            outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
        }
      }
    }
    return status == kCCSuccess ? out : Data()
  }

  /// The AES key Chromium derives from its Safe Storage password.
  public static func key(safeStoragePassword: Data) -> Data {
    pbkdf2SHA1(password: safeStoragePassword, salt: salt, rounds: iterations, length: 16)
  }

  /// AES-128-CBC with PKCS#7 padding. Returns nil on failure (wrong key, bad padding).
  public static func aes128CBC(_ input: Data, key: Data, iv: Data = iv, encrypt: Bool) -> Data? {
    guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
    // CommonCrypto can report success for a ciphertext that is not whole blocks and return
    // bytes it never wrote, so a truncated or corrupt value must be rejected here.
    if !encrypt, input.isEmpty || input.count % kCCBlockSizeAES128 != 0 { return nil }
    var out = Data(repeating: 0, count: input.count + kCCBlockSizeAES128)
    let capacity = out.count
    var moved = 0
    let status = out.withUnsafeMutableBytes { o in
      input.withUnsafeBytes { i in
        key.withUnsafeBytes { k in
          iv.withUnsafeBytes { v in
            CCCrypt(
              CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, v.baseAddress,
              i.baseAddress, input.count, o.baseAddress, capacity, &moved)
          }
        }
      }
    }
    guard status == kCCSuccess else { return nil }
    return out.prefix(moved)
  }

  public static func sha256(_ data: Data) -> Data {
    var digest = Data(repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    digest.withUnsafeMutableBytes { d in
      data.withUnsafeBytes { s in
        _ = CC_SHA256(s.baseAddress, CC_LONG(data.count), d.baseAddress?.assumingMemoryBound(to: UInt8.self))
      }
    }
    return digest
  }

  /// Decrypts one `encrypted_value`. Values start with `v10`. Since cookie database version 24,
  /// the plaintext starts with SHA-256(host_key), which is checked and removed.
  public static func decrypt(_ blob: Data, key: Data, hostKey: String) -> String? {
    guard blob.count > 3, blob.prefix(3) == Data("v10".utf8),
      var plain = aes128CBC(blob.dropFirst(3), key: key, encrypt: false)
    else { return nil }
    if plain.count >= 32, plain.prefix(32) == sha256(Data(hostKey.utf8)) {
      plain = plain.dropFirst(32)
    }
    return String(data: Data(plain), encoding: .utf8)
  }

  /// Chromium stores times as microseconds since 1601-01-01 UTC; 0 means a session cookie.
  public static func date(chromeMicroseconds value: Int64) -> Date? {
    guard value > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(value) / 1_000_000 - 11_644_473_600)
  }

  public struct ReadResult: Sendable {
    public var cookies: [ImportedCookie]
    /// Rows that could not be decrypted, were already expired, or are partitioned.
    public var skipped: Int
  }

  /// Reads a read-only snapshot of the `Cookies` database. Expired cookies and rows that fail
  /// to decrypt are skipped. At most `limit` cookies are returned.
  public static func read(
    database: URL, key: Data, now: Date = Date(), limit: Int = 50_000
  ) throws -> ReadResult {
    try BrowserDataReader.withSQLiteSnapshot(database) { db in
      var statement: OpaquePointer?
      // Partitioned (CHIPS) cookies belong to one top-level site. Writing them unpartitioned
      // would turn them into cross-site trackers, so they are skipped. Older databases have
      // no partition column.
      let partition = hasColumn(db, table: "cookies", column: "top_frame_site_key")
        ? "top_frame_site_key" : "''"
      let sql =
        "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite, \(partition) FROM cookies"
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw SereinError.invalid("This file is not a Chromium cookie database")
      }
      defer { sqlite3_finalize(statement) }
      var cookies: [ImportedCookie] = []
      var skipped = 0
      func text(_ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
      }
      while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { break }
        // An error in the middle of the table is not its end (the browser can run while Serein reads).
        guard step == SQLITE_ROW else { throw SereinError.invalid("The cookie database could not be read to its end") }
        if cookies.count >= limit {
          skipped += 1
          continue
        }
        if !text(9).isEmpty {
          skipped += 1
          continue
        }
        let host = text(0)
        let name = text(1)
        var value = text(2)
        if value.isEmpty, let bytes = sqlite3_column_blob(statement, 3) {
          let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 3)))
          guard let plain = decrypt(blob, key: key, hostKey: host) else {
            skipped += 1
            continue
          }
          value = plain
        }
        let expires = date(chromeMicroseconds: sqlite3_column_int64(statement, 5))
        if let expires, expires <= now {
          skipped += 1
          continue
        }
        guard !host.isEmpty, !name.isEmpty || !value.isEmpty else {
          skipped += 1
          continue
        }
        let sameSite: String?
        switch sqlite3_column_int(statement, 8) {
        case 0: sameSite = "None"
        case 1: sameSite = "Lax"
        case 2: sameSite = "Strict"
        default: sameSite = nil
        }
        let path = text(4)
        cookies.append(
          ImportedCookie(
            domain: host, name: name, value: value, path: path.isEmpty ? "/" : path,
            expires: expires, secure: sqlite3_column_int(statement, 6) != 0,
            httpOnly: sqlite3_column_int(statement, 7) != 0, sameSite: sameSite))
      }
      return ReadResult(cookies: cookies, skipped: skipped)
    }
  }
}

extension ChromiumCookies {
  static func hasColumn(_ db: OpaquePointer?, table: String, column: String) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK
    else { return false }
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
      if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
        return true
      }
    }
    return false
  }
}

/// Saved passwords of a Chromium-family browser on macOS. They are in the profile's `Login Data`
/// database, sealed with the same Safe Storage key as the cookies (`v10`, AES-128-CBC), so the
/// one key the person lets Serein use serves both.
public enum ChromiumLogins {
  public static func database(in profile: URL) -> URL? {
    let url = profile.appendingPathComponent("Login Data")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// How many passwords the browser has saved. It opens none of them and needs no key.
  public static func count(database: URL) throws -> Int {
    try BrowserDataReader.withSQLiteSnapshot(database) { db in
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM logins WHERE blacklisted_by_user = 0", -1, &statement, nil) == SQLITE_OK
      else { throw SereinError.invalid("This file is not a Chromium password database") }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw SereinError.invalid("The password database could not be read")
      }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  /// Reads a read-only snapshot of the database. A row that Serein cannot keep is left out and
  /// counted: a site the person told the browser never to save, a row with no password or one
  /// that does not open with this key, and an address that is not HTTPS (an app's entry, a
  /// page on a local network). One entry for each site and user name; the last one wins.
  public static func read(database: URL, key: Data, limit: Int = 20_000) throws
    -> (entries: [PasswordImport], skipped: Int)
  {
    try BrowserDataReader.withSQLiteSnapshot(database) { db in
      var statement: OpaquePointer?
      let sql = "SELECT origin_url, username_value, password_value, blacklisted_by_user FROM logins"
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw SereinError.invalid("This file is not a Chromium password database")
      }
      defer { sqlite3_finalize(statement) }
      var entries: [String: PasswordImport] = [:]
      var order: [String] = []
      var skipped = 0
      while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { break }
        guard step == SQLITE_ROW else { throw SereinError.invalid("The password database could not be read to its end") }
        let address = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let user = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        guard order.count < limit, sqlite3_column_int(statement, 3) == 0,
          let bytes = sqlite3_column_blob(statement, 2),
          let url = URL(string: address), url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(), !host.isEmpty
        else {
          skipped += 1
          continue
        }
        let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8),
          let plain = ChromiumCookies.aes128CBC(blob.dropFirst(3), key: key, encrypt: false),
          let password = String(data: Data(plain), encoding: .utf8), !password.isEmpty
        else {
          skipped += 1
          continue
        }
        let origin = "https://" + host + (url.port.map { ":\($0)" } ?? "")
        let id = origin + "\u{0}" + user
        if entries[id] == nil { order.append(id) }
        entries[id] = PasswordImport(origin: origin, username: user, password: password)
      }
      return (order.compactMap { entries[$0] }, skipped)
    }
  }
}

/// Cookies grouped into sites for the review sheet.
public struct CookieSite: Identifiable, Hashable, Sendable {
  public var id: String { site }
  public var site: String
  public var cookies: [ImportedCookie]
}

public enum CookieSites {
  /// Second-level labels that are usually part of a public suffix (`co.uk`, `com.au`...).
  static let compoundSuffixes: Set<String> = [
    "co", "com", "net", "org", "gov", "edu", "ac", "ne", "or", "go",
  ]

  /// A site label such as `example.com` or `example.co.uk` for a cookie domain.
  public static func site(for domain: String) -> String {
    var host = domain.lowercased()
    while host.hasPrefix(".") { host.removeFirst() }
    host = host.withoutWWW
    if host.allSatisfy({ $0.isNumber || $0 == "." }) || host.contains(":") { return host }
    let labels = host.split(separator: ".").map(String.init)
    guard labels.count > 2 else { return host }
    let count =
      labels[labels.count - 1].count == 2 && compoundSuffixes.contains(labels[labels.count - 2])
      ? 3 : 2
    return labels.suffix(count).joined(separator: ".")
  }

  public static func group(_ cookies: [ImportedCookie]) -> [CookieSite] {
    Dictionary(grouping: cookies, by: { site(for: $0.domain) })
      .map { CookieSite(site: $0.key, cookies: $0.value) }
      .sorted { $0.site < $1.site }
  }

  public static func filter(_ sites: [CookieSite], query: String) -> [CookieSite] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return sites }
    return sites.filter { $0.site.localizedCaseInsensitiveContains(q) }
  }

  /// Cookies from the chosen sites, minus those whose identity already exists in Serein.
  public static func selection(
    _ sites: [CookieSite], chosen: Set<String>, existingKeys: Set<String>
  ) -> (write: [ImportedCookie], kept: Int) {
    var write: [ImportedCookie] = []
    var kept = 0
    for site in sites where chosen.contains(site.site) {
      for cookie in site.cookies {
        if existingKeys.contains(cookie.key) { kept += 1 } else { write.append(cookie) }
      }
    }
    return (write, kept)
  }
}
