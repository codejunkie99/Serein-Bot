import Foundation

public enum CSVTable {
  public static func parse(_ text: String) throws -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    let chars = Array(text)
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c == "\"" {
        if quoted && i + 1 < chars.count && chars[i + 1] == "\"" {
          field.append("\"")
          i += 1
        } else if quoted || field.isEmpty {
          quoted.toggle()
        } else {
          throw SereinError.invalid("Malformed CSV quote")
        }
      } else if c == "," && !quoted {
        row.append(field)
        field = ""
      } else if (c == "\n" || c == "\r\n" || c == "\r") && !quoted {
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        row = []
        field = ""
      } else {
        field.append(c)
      }
      i += 1
    }
    guard !quoted else { throw SereinError.invalid("Unclosed CSV field") }
    if !field.isEmpty || !row.isEmpty {
      row.append(field)
      rows.append(row)
    }
    return rows
  }
  public static func encode(_ rows: [[String]]) -> String {
    rows.map { row in
      row.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(
        separator: ",")
    }.joined(separator: "\r\n")
  }
}
public struct PasswordImport {
  public var origin: String
  public var username: String
  public var password: String
  /// The passwords of an exported file. A row that Serein cannot keep is left out and counted:
  /// no password, or an address that is not HTTPS (an app's entry, a router's page, a note).
  /// A real export has such rows, and one of them must not stop all the others. The columns
  /// themselves must be there. Rows for one site and user name are one entry, the last one:
  /// `repeated` counts the others.
  public static func parse(_ text: String) throws -> (entries: [PasswordImport], skipped: Int, repeated: Int) {
    let rows = try CSVTable.parse(text)
    guard let header = rows.first else { return ([], 0, 0) }
    let keys = header.map {
      $0.trimmingCharacters(
        in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
      ).lowercased()
    }
    guard
      let urlIndex = keys.firstIndex(where: {
        ["url", "website", "origin", "login_uri"].contains($0)
      }),
      let userIndex = keys.firstIndex(where: {
        ["username", "user", "login_username"].contains($0)
      }), let passIndex = keys.firstIndex(where: { ["password", "login_password"].contains($0) })
    else { throw SereinError.invalid("CSV needs URL, username and password columns") }
    var entries: [PasswordImport] = []
    var skipped = 0
    var repeated = 0
    var place: [String: Int] = [:]
    for row in rows.dropFirst() {
      // A line with nothing in it is not a row.
      if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
      guard row.count > max(urlIndex, max(userIndex, passIndex)), !row[passIndex].isEmpty,
        let url = try? BrowserPolicy.url(row[urlIndex]), url.scheme?.lowercased() == "https",
        // The origin is made the way a saved entry's is, so the save cannot refuse it later
        // (an IPv6 host needs its brackets). It must also still be the host of the address:
        // a host with an escaped "#" or "/" in it would land under another site.
        let origin = CredentialOrigin.make(scheme: "https", host: url.host, port: url.port ?? 0),
        let made = try? BrowserPolicy.url(origin), made.host?.lowercased() == url.host?.lowercased()
      else {
        skipped += 1
        continue
      }
      let entry = PasswordImport(origin: origin, username: row[userIndex], password: row[passIndex])
      if let at = place[origin + "\n" + entry.username] {
        entries[at] = entry
        repeated += 1
      } else {
        place[origin + "\n" + entry.username] = entries.count
        entries.append(entry)
      }
    }
    return (entries, skipped, repeated)
  }
}
