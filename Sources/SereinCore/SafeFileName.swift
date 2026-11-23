import Foundation

/// A file name from outside (a site's suggested download name, a document the person attached)
/// made safe to show and to store. One rule for task downloads and turn documents.
public enum SafeFileName {
  /// The longest name kept, its extension included.
  public static let limit = 120

  /// The last path part only (split at `/`, `\` and `:`), without control, zero-width or
  /// direction-changing characters (which can make "x.app" read as "x.pdf") and without leading
  /// dots or spaces, at most `limit` characters with its extension kept; `fallback` when nothing
  /// is left. Cleaning a cleaned name changes nothing, so a lookup can compare against it.
  public static func clean(_ raw: String, fallback: String) -> String {
    let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: last.unicodeScalars.filter { !hidden($0) })
    var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    while let first = name.first, first == "." || first.isWhitespace { name.removeFirst() }
    if name.count > limit {
      let ext = (name as NSString).pathExtension
      let keep = ext.isEmpty ? "" : "." + ext
      name = String(name.prefix(max(1, limit - keep.count))) + keep
      while name.last?.isWhitespace == true { name.removeLast() }
    }
    return name.isEmpty ? fallback : name
  }

  /// A title as the name a save panel suggests ("Trip planner.serein-team"): hidden characters
  /// dropped first, so a key they split is still redacted; path separators, line breaks and
  /// control characters become "-"; no leading or trailing dots or spaces; at most 80
  /// characters before ".ext"; `fallback` when nothing is left.
  public static func export(_ title: String, fallback: String, ext: String) -> String {
    var shown = String.UnicodeScalarView()
    shown.append(contentsOf: title.unicodeScalars.filter { $0.properties.generalCategory == .control || !hidden($0) })
    let unsafe = CharacterSet(charactersIn: "/\\:").union(.newlines).union(.controlCharacters)
    let words = AgentPrivacy.redact(String(shown)).components(separatedBy: unsafe).joined(separator: "-")
      .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    return (words.isEmpty ? fallback : String(words.prefix(80))) + "." + ext
  }

  /// A character that shows nothing or changes how the text around it reads: a control or format
  /// character, a zero-width space, joiner or direction mark, a direction embedding, override or
  /// isolate, or a byte-order mark. One rule for file names and for the team names, member names
  /// and personas `TeamProposal.parse` takes.
  public static func hidden(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.controlCharacters.contains(scalar)
      || (0x200B...0x200F).contains(scalar.value) || (0x202A...0x202E).contains(scalar.value)
      || (0x2066...0x2069).contains(scalar.value) || scalar.value == 0xFEFF
  }

  /// `name` for `count` 1 or less, else “name 2.ext”, “name 3.ext”…, the stem shortened so the
  /// result stays within `limit`. An “extension” over 16 characters is part of the stem, so the
  /// result never starts with a space (which `clean` would strip, and no upload could name).
  public static func numbered(_ name: String, _ count: Int) -> String {
    guard count > 1 else { return name }
    let found = (name as NSString).pathExtension
    let ext = found.count <= 16 ? found : ""
    let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    let room = max(0, limit - (ext.isEmpty ? 0 : ext.count + 1) - " \(count)".count)
    let stem = String(base.prefix(room))
    return ext.isEmpty ? "\(stem) \(count)" : "\(stem) \(count).\(ext)"
  }
}
