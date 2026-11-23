import Foundation
import SQLite3

/// Cookies read from a browser plus the number of rows left out (expired, unreadable, partitioned).
public struct CookieReadResult: Sendable {
  public var cookies: [ImportedCookie]
  public var skipped: Int

  public init(cookies: [ImportedCookie], skipped: Int) {
    self.cookies = cookies
    self.skipped = skipped
  }
}

/// Reads website sign-ins from a Firefox profile's `cookies.sqlite`. Firefox stores cookie values
/// in plaintext, so no key or Keychain access is involved. Reading happens on a temporary copy.
public enum FirefoxCookies {
  public static func cookiesDatabase(in profile: URL) -> URL? {
    let url = profile.appendingPathComponent("cookies.sqlite")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// `expiry` is seconds in older profiles and milliseconds in newer ones.
  static func date(expiry value: Int64) -> Date? {
    guard value > 0 else { return nil }
    let seconds = value > 100_000_000_000 ? Double(value) / 1000 : Double(value)
    return Date(timeIntervalSince1970: seconds)
  }

  /// Partitioned cookies (`partitionKey=`) and container-tab cookies (`userContextId=` other
  /// than 0) belong to a narrower context than Serein's single store, so they are not imported.
  static func isDefaultContext(_ originAttributes: String) -> Bool {
    if originAttributes.contains("partitionKey=") { return false }
    for part in originAttributes.split(whereSeparator: { $0 == "^" || $0 == "&" }) {
      if part.hasPrefix("userContextId="), part != "userContextId=0" { return false }
    }
    return true
  }

  public static func read(
    database: URL, now: Date = Date(), limit: Int = 50_000
  ) throws -> CookieReadResult {
    try BrowserDataReader.withSQLiteSnapshot(database) { db in
      var statement: OpaquePointer?
      let attributes =
        ChromiumCookies.hasColumn(db, table: "moz_cookies", column: "originAttributes")
        ? "originAttributes" : "''"
      let sameSite =
        ChromiumCookies.hasColumn(db, table: "moz_cookies", column: "sameSite") ? "sameSite" : "0"
      let sql =
        "SELECT host, name, value, path, expiry, isSecure, isHttpOnly, \(sameSite), \(attributes) FROM moz_cookies"
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw SereinError.invalid("This file is not a Firefox cookie database")
      }
      defer { sqlite3_finalize(statement) }
      func text(_ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
      }
      var cookies: [ImportedCookie] = []
      var skipped = 0
      while sqlite3_step(statement) == SQLITE_ROW {
        if cookies.count >= limit || !isDefaultContext(text(8)) {
          skipped += 1
          continue
        }
        let host = text(0)
        let name = text(1)
        let value = text(2)
        let expires = date(expiry: sqlite3_column_int64(statement, 4))
        if let expires, expires <= now {
          skipped += 1
          continue
        }
        guard !host.isEmpty, !name.isEmpty || !value.isEmpty else {
          skipped += 1
          continue
        }
        let policy: String?
        switch sqlite3_column_int(statement, 7) {
        case 0: policy = "None"
        case 1: policy = "Lax"
        case 2: policy = "Strict"
        default: policy = nil
        }
        let path = text(3)
        cookies.append(
          ImportedCookie(
            domain: host, name: name, value: value, path: path.isEmpty ? "/" : path,
            expires: expires, secure: sqlite3_column_int(statement, 5) != 0,
            httpOnly: sqlite3_column_int(statement, 6) != 0, sameSite: policy))
      }
      return CookieReadResult(cookies: cookies, skipped: skipped)
    }
  }
}
