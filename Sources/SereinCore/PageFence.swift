import Foundation

/// Page text is wrapped so a tool parser only sees the text outside the fence.
/// The gate mints action ids. An id on the model text is not used.
/// Mac run not verified.
public enum PageFence {
  public static let start = "<<<serein-page-untrusted>>>"
  public static let end = "<<<serein-page-end>>>"

  public struct Action: Equatable, Sendable {
    public var id: String
    public var effect: String
  }

  /// Wraps untrusted page text. An end marker inside the page cannot close the fence.
  public static func fence(_ text: String) -> String {
    let safe = text.replacingOccurrences(of: end, with: "\\u003cserein-page-end>")
    return "\(start)\n\(safe)\n\(end)"
  }

  /// Text a tool parser may treat as instructions. Fenced page bytes are omitted.
  public static func textOutside(_ text: String) -> String {
    var rest = text
    var outside = ""
    while !rest.isEmpty {
      guard let startRange = rest.range(of: start) else {
        outside += rest
        break
      }
      outside += rest[..<startRange.lowerBound]
      let after = rest[startRange.upperBound...]
      guard let endRange = after.range(of: end) else { break }
      rest = String(after[endRange.upperBound...])
    }
    return outside
  }

  /// Action objects outside the fence. `mint` supplies every id.
  /// Scanning the raw text accepts a send written inside the page.
  /// Reading the object's id keeps the id the model chose.
  public static func actions(in text: String, mint: () -> String) -> [Action] {
    var found: [Action] = []
    for object in jsonObjects(textOutside(text)) {
      let effect = (object["effect"] as? String) ?? (object["kind"] as? String)
      guard let effect, !effect.isEmpty else { continue }
      _ = object["id"]
      found.append(Action(id: mint(), effect: effect))
    }
    return found
  }

  private static func jsonObjects(_ text: String) -> [[String: Any]] {
    var found: [[String: Any]] = []
    let chars = Array(text)
    var start = 0
    while start < chars.count {
      if chars[start] != "{" {
        start += 1
        continue
      }
      var depth = 0
      var end = start
      var closed = false
      while end < chars.count {
        if chars[end] == "{" { depth += 1 }
        else if chars[end] == "}" { depth -= 1 }
        if depth == 0 {
          closed = true
          break
        }
        end += 1
      }
      if closed {
        let slice = String(chars[start...end])
        if let object = try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any] {
          found.append(object)
        }
      }
      start += 1
    }
    return found
  }
}
