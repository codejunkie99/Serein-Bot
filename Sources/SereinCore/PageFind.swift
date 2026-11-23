import Foundation

/// `find`: the rows of a page read that match a role and words, so the agent gets a few references
/// instead of the whole page. The rows come from the same read as `read` (PageKit, with the
/// accessibility tree's roles and the frames' rows), so every sensitive-field exclusion and
/// redaction of `read` applies. Pure, so the checks run it without a browser.
public enum PageFind {
  /// The most matches one call returns.
  public static let limit = 30
  /// Keys of a read that `find` leaves out: the page's words and the full element list.
  static let dropped: Set<String> = ["elements", "text", "start", "next_start", "choices", "page_tools"]

  /// The result for a page read: the read's notes (sensitive, user steps, challenge, consent,
  /// frames, tab, url, title) without its text and full element list, plus the matching rows.
  public static func result(page: [String: Any], role: String?, text: String?) -> [String: Any] {
    let rows = page["elements"] as? [[String: Any]] ?? []
    let found = matches(rows, role: role, text: text)
    var result = page.filter { !dropped.contains($0.key) }
    result["matches"] = Array(found.prefix(limit))
    result["count"] = found.count
    if found.isEmpty {
      result["find_note"] = "Nothing matched. Read the page to see every element."
    } else if found.count > limit {
      result["find_note"] = "\(found.count - limit) more matched. Give a narrower role or text, or read the page."
    }
    return result
  }

  /// The matching rows, best first: a label equal to the words, then rows with more of the words,
  /// then page order. A row matches when at least one word matches. With no words, every row of
  /// the role in page order.
  public static func matches(_ rows: [[String: Any]], role: String?, text: String?) -> [[String: Any]] {
    let wanted = fold(role ?? "")
    let words = tokens(text ?? "")
    let phrase = words.joined(separator: " ")
    var scored: [(row: [String: Any], exact: Bool, hits: Int, index: Int)] = []
    for (index, row) in rows.enumerated() where wanted.isEmpty || matchesRole(wanted, row) {
      if words.isEmpty {
        scored.append((row, false, 0, index))
        continue
      }
      let label = tokens(row["label"] as? String ?? "")
      // A word matches the start of a word in the label, value or options: "sub" finds Subscribe,
      // and "in" does not find Pricing.
      let haystack = label + tokens(row["value"] as? String ?? "") + optionLabels(row).flatMap(tokens)
      let hits = words.filter { word in haystack.contains { $0.hasPrefix(word) } }.count
      if hits > 0 { scored.append((row, label.joined(separator: " ") == phrase, hits, index)) }
    }
    return scored.sorted { a, b in
      if a.exact != b.exact { return a.exact }
      if a.hits != b.hits { return a.hits > b.hits }
      return a.index < b.index
    }.map(\.row)
  }

  /// A role word the agent gave against a row. PageKit names a row by its tag or ARIA role and its
  /// acts (click, type, select); the accessibility tree names it button, link, textbox and so on.
  /// A word with no group below matches the row's own role exactly ("tab", "menuitem", "option").
  static func matchesRole(_ wanted: String, _ row: [String: Any]) -> Bool {
    let role = fold(row["role"] as? String ?? "")
    let acts = Set(row["acts"] as? [String] ?? [])
    let toggle = row["checked"] != nil || ["checkbox", "radio", "switch"].contains(role)
    switch wanted {
    case "button":
      return ["button", "menubutton", "disclosure", "summary", "clickable"].contains(role)
        || (role == "input" && acts.contains("click") && !toggle)
    case "link", "a": return role == "a" || role == "link"
    case "textbox", "text", "input", "field", "searchbox", "search", "textarea", "type":
      return acts.contains("type") || role == "textbox" || role == "searchbox"
    case "checkbox", "radio", "switch", "toggle":
      return wanted == "toggle" ? toggle : role == wanted || (toggle && role == "input")
    case "select", "combobox", "listbox", "dropdown":
      return acts.contains("select") || role == "combobox" || role == "listbox"
    case "file", "upload": return role == "file"
    default: return role == wanted
    }
  }

  static func optionLabels(_ row: [String: Any]) -> [String] {
    (row["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
  }

  /// Lower case, without accents, one space between words.
  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }
  /// The folded words of a text, split at anything that is not a letter or a digit.
  static func tokens(_ text: String) -> [String] {
    fold(text).split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
  }
}
