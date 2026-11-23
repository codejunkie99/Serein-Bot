import Foundation

/// A short report on a session's last turn, made by the app from the AI app's own transcript (no
/// model): its final words cut to a sentence or two and what it changed. Display only: the words
/// are the AI app's, untrusted, and no part of it is ever given to a model.
public enum SessionReport {
  /// The longest gist of the final words.
  public static let gistLimit = 220

  /// The outcome first, then its source in the same bubble. This quotes the app's report; it
  /// does not independently verify its claims. Nil when there are no readable words or changes.
  public static func text(app: String, folder: String?, answer: String, activities: [TranscriptActivity], goal: String? = nil)
    -> String?
  {
    let gist = gist(answer)
    let changed = changes(activities)
    let head = app + (folder.map { " in " + $0 } ?? "") + (goal.flatMap(goalEnd).map { " " + $0 } ?? "")
    // “Done” may be the only final reply to real work. Missing detail is not proof of a courtesy.
    if changed == nil, answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: ".!")) == "done" {
      return "Reported done, but no result details were provided.\n" + head
    }
    guard !gist.isEmpty || changed != nil else { return goal.flatMap(goalEnd) == nil ? nil : head + "." }
    // Never a bare "has an update": with no words, what changed is the news.
    guard !gist.isEmpty else { return (changed ?? "") + "\n" + head }
    var result = gist
    // Keep a limitation from later in the answer; a cheerful first paragraph is not enough.
    if let caveat = paragraphs(answer).flatMap(sentences).first(where: {
      $0.range(of: #"(?i)\b(limitations?|remaining risk|unverified|unavailable|not verified|not tested|not run|couldn[’']t|cannot|can[’']t|failed|blocked)\b"#,
        options: .regularExpression) != nil && !gist.contains($0)
    }) {
      let plain = caveat.replacingOccurrences(of: #"(?i)^(?:remaining risk|limitations?|caveat):\s*"#,
        with: "", options: .regularExpression)
      let words = shortened(plain, limit: 180)
      if !result.contains(words) { result += " " + words }
    }
    if activities.contains(where: { $0.tool == "test" && $0.failed }), !result.lowercased().contains("failed") {
      result += " A test run failed."
    }
    return result + "\n" + head
  }

  /// Only explicit courtesies and a successful Finder-opening confirmation stay quiet. A
  /// short fix, research result, failure or goal still gets delivered, even with Codex in front.
  public static func isRoutineReply(_ answer: String, activities: [TranscriptActivity], goal: String? = nil) -> Bool {
    guard changes(activities) == nil, !activities.contains(where: \.failed), goal == nil || goal == "active" else { return false }
    let raw = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.range(of: #"(?i)^(yes|sure|okay|ok|thanks|thank you|you’re welcome)[.!]?$"#, options: .regularExpression) != nil { return true }
    let plain = paragraphs(answer).joined(separator: " ").lowercased()
    guard plain.range(of: #"\b(but|failed|error|warning|couldn[’']t|cannot)\b"#, options: .regularExpression) == nil else { return false }
    return plain.range(of: #"^opened [^.!?\n]+ in finder\.$"#, options: .regularExpression) != nil
  }

  /// How a Codex goal ended, said after the app and folder; nil while it is active.
  static func goalEnd(_ status: String) -> String? {
    switch status {
    case "active": return nil
    case "complete": return "finished its goal"
    case "usage_limited": return "stopped its goal at the usage limit"
    case "budget_limited": return "stopped its goal at its budget"
    case "blocked": return "is blocked on its goal"
    case "paused": return "paused its goal"
    default: return "stopped its goal"
    }
  }

  /// The first useful paragraph as plain sentences; standalone local links retain their paths.
  public static func gist(_ answer: String) -> String {
    let blocks = paragraphs(answer)
    guard var first = blocks.first else { return "" }
    // An introductory label needs the value that follows it, even across a blank line.
    if first.hasSuffix(":"), blocks.count > 1 { first += " " + blocks[1] }
    return shortened(first, limit: gistLimit)
  }

  /// Present old notices consistently without rewriting history or inventing missing detail.
  public static func display(_ text: String) -> String {
    let prefix = "Finished this turn.\n\n"
    guard text.hasPrefix(prefix) else { return text }
    let old = String(text.dropFirst(prefix.count))
    guard let divider = old.range(of: ": ") else { return old }
    let source = String(old[..<divider.lowerBound])
    let body = String(old[divider.upperBound...])
    // These legacy snippets have already lost their answer; an orphaned label adds no news.
    if body.hasSuffix(":"), !body.contains("\n") { return "" }
    if !source.contains("goal"), isRoutineReply(body, activities: []) { return "" }
    return body + "\n" + source
  }

  private static func paragraphs(_ answer: String) -> [String] {
    var text = answer
    // Fenced code goes first, whole.
    while let open = text.range(of: "```") {
      guard let close = text.range(of: "```", range: open.upperBound..<text.endIndex) else {
        text = String(text[..<open.lowerBound]); break
      }
      text.replaceSubrange(open.lowerBound..<close.upperBound, with: " ")
    }
    // The first paragraph that says something: headings and tables are labels, not the answer.
    var blocks: [String] = []
    var lines: [String] = []
    var caveatHeading: String?
    func flush() {
      var flat = lines.joined(separator: " ")
      flat = flat.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
      flat = flat.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
      flat = flat.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
      flat = flat.replacingOccurrences(of: #"(?i)^(?:yes|done|sure|okay|ok)[.!]\s*"#, with: "", options: .regularExpression)
      if !flat.isEmpty, !["i found:", "here it is:", "here’s what i found:", "summary:", "result:"].contains(flat.lowercased()) {
        blocks.append(flat)
      }
      lines = []
    }
    for raw in text.components(separatedBy: "\n") {
      var line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty {
        flush()
        continue
      }
      if line.hasPrefix("#") {
        flush()
        let heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        caveatHeading = ["limitations", "limitation", "remaining risk", "caveat", "caveats"].contains(heading) ? heading : nil
        continue
      }
      guard !line.hasPrefix("|") else { continue }
      while let first = line.first, ">-*•".contains(first) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
      if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
        line = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
      }
      // A standalone local link is often the entire answer to “where is it?”. Keep its path.
      if line.range(of: #"^\[[^\]]+\]\(<?/[^)]+>?\)$"#, options: .regularExpression) != nil,
        let opening = line.range(of: "]("), line.hasSuffix(")") {
        line = String(line[opening.upperBound..<line.index(before: line.endIndex)])
          .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
      }
      if !line.isEmpty { lines.append(line) }
      if let heading = caveatHeading, !lines.isEmpty {
        lines[0] = heading + ": " + lines[0]
        caveatHeading = nil
      }
    }
    flush()
    return blocks
  }

  private static func shortened(_ flat: String, limit: Int) -> String {
    guard !flat.isEmpty else { return "" }
    // Whole sentences while they fit; a first sentence too long is cut at a word.
    var out = ""
    for sentence in sentences(flat) {
      let next = out.isEmpty ? sentence : out + " " + sentence
      if next.count > limit { break }
      out = next
      if out.count > limit / 2 { break }
    }
    if out.isEmpty {
      let cut = String(flat.prefix(limit - 1))
      out = (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut) + "…"
    }
    return out
  }

  /// "Edited 3 files · ran tests": what the turn did, from its steps. Nil when it only read.
  public static func changes(_ activities: [TranscriptActivity]) -> String? {
    var parts: [String] = []
    // One step may name several files: "Edited prices.py and 1 more".
    let edited = Set(activities.filter { $0.tool == "edit" }.map(\.label)).reduce(0) { total, label in
      let more = label.range(of: #" and (\d+) more$"#, options: .regularExpression)
        .flatMap { Int(label[$0].filter(\.isNumber)) } ?? 0
      return total + 1 + more
    }
    if edited > 0 { parts.append(edited == 1 ? "Edited 1 file" : "Edited \(edited) files") }
    if activities.contains(where: { $0.tool == "test" }) {
      parts.append(activities.contains { $0.tool == "test" && $0.failed } ? "tests failed" : "ran tests")
    }
    if activities.contains(where: { $0.tool == "build" }) { parts.append("built") }
    guard !parts.isEmpty else { return nil }
    let joined = parts.joined(separator: " · ")
    return joined.prefix(1).uppercased() + joined.dropFirst()
  }

  // MARK: Parts

  private static func sentences(_ text: String) -> [String] {
    var out: [String] = []
    var current = ""
    var chars = Array(text)
    var i = 0
    while i < chars.count {
      current.append(chars[i])
      if ".!?".contains(chars[i]), i + 1 == chars.count || chars[i + 1] == " " {
        out.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      }
      i += 1
    }
    chars.removeAll()
    let rest = current.trimmingCharacters(in: .whitespaces)
    if !rest.isEmpty { out.append(rest) }
    return out
  }
}
