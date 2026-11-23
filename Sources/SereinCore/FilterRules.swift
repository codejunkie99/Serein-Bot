import Foundation

/// WebKit-native network and cosmetic rules. Unrepresentable syntax is counted explicitly.
public enum FilterRules {
  public static func convert(_ text: String, allowedSites: [String] = []) -> (
    rules: [[String: Any]], skipped: Int
  ) {
    let lines = text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func withoutBadfilter(_ line: String) -> String {
      guard let dollar = line.lastIndex(of: "$") else { return line }
      let options = line[line.index(after: dollar)...].split(separator: ",").filter {
        $0 != "badfilter"
      }.sorted()
      return String(line[..<dollar]) + (options.isEmpty ? "" : "$" + options.joined(separator: ","))
    }
    let disabled = Set(
      lines.filter {
        $0.hasSuffix("$badfilter") || $0.contains(",badfilter") || $0.contains("$badfilter,")
      }.map(withoutBadfilter))
    var rules: [[String: Any]] = []
    var exceptions: [[String: Any]] = []
    var skipped = 0
    let types = [
      "script": "script", "image": "image", "stylesheet": "style-sheet", "font": "font",
      "media": "media", "xmlhttprequest": "raw", "subdocument": "document", "document": "document",
    ]
    let allTypes = Set(types.values).union(["svg-document"])
    // Cosmetic exceptions are selector-specific, so they never disable unrelated network rules.
    var cosmeticExceptions: [String: Set<String>] = [:]
    var globallyExcepted = Set<String>()
    for line in lines {
      guard let range = line.range(of: "#@#") else { continue }
      let selector = String(line[range.upperBound...])
      let domains = line[..<range.lowerBound].split(separator: ",").map(String.init)
      if domains.isEmpty {
        globallyExcepted.insert(selector)
      } else if domains.allSatisfy({ validDomain($0) }) {
        cosmeticExceptions[selector, default: []].formUnion(domains)
      }
    }
    for raw in lines {
      if raw.isEmpty || raw.hasPrefix("!") || raw.hasPrefix("[") { continue }
      if disabled.contains(withoutBadfilter(raw)) { continue }
      if raw.contains("#@#") { continue }
      if let marker = raw.range(of: "##"), !raw.contains("#?#"), !raw.contains("#$#") {
        let selector = String(raw[marker.upperBound...])
        let domains = raw[..<marker.lowerBound].split(separator: ",").map(String.init)
        if globallyExcepted.contains(selector) { continue }
        guard !selector.isEmpty, !selector.hasPrefix("+js("), !selector.contains(":has-text("),
          !selector.contains(":matches-css("), !selector.contains(":style("),
          !selector.contains("{")
        else {
          skipped += 1
          continue
        }
        let positive = domains.filter { !$0.hasPrefix("~") }
        let negative =
          domains.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }
          // Sorted, so the same lists give the same rules each launch (ContentBlocking's cache).
          + (cosmeticExceptions[selector] ?? []).sorted()
        guard (positive + negative).allSatisfy(validDomain) else {
          skipped += 1
          continue
        }
        var trigger: [String: Any] = ["url-filter": ".*"]
        if !positive.isEmpty && !negative.isEmpty {
          // WebKit permits only one domain/frame condition per trigger.
          skipped += 1
          continue
        } else if !positive.isEmpty {
          trigger["if-domain"] = positive.map { "*" + $0 }
        } else if !negative.isEmpty {
          trigger["unless-domain"] = negative.map { "*" + $0 }
        }
        rules.append([
          "trigger": trigger, "action": ["type": "css-display-none", "selector": selector],
        ])
        continue
      }
      if raw.contains("#") || !raw.unicodeScalars.allSatisfy({ $0.isASCII }) {
        skipped += 1
        continue
      }
      var line = raw
      let exception = line.hasPrefix("@@")
      if exception { line = String(line.dropFirst(2)) }
      let split = line.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
      guard let pattern = split.first, !pattern.isEmpty else {
        skipped += 1
        continue
      }
      var trigger: [String: Any] = [:]
      var resources = Set<String>()
      var excluded = Set<String>()
      var supported = true
      if split.count == 2 {
        for option in split[1].split(separator: ",") {
          if let type = types[String(option)] {
            resources.insert(type)
          } else if option.hasPrefix("~"), let type = types[String(option.dropFirst())] {
            excluded.insert(type)
          } else if option == "third-party" || option == "3p" {
            trigger["load-type"] = ["third-party"]
          } else if ["~third-party", "first-party", "1p", "~3p"].contains(option) {
            trigger["load-type"] = ["first-party"]
          } else if option == "match-case" {
            trigger["url-filter-is-case-sensitive"] = true
          } else if option.hasPrefix("domain=") {
            let domains = option.dropFirst(7).split(separator: "|").map(String.init)
            let positive = domains.filter { !$0.hasPrefix("~") }
            let negative = domains.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }
            if domains.isEmpty || !(positive + negative).allSatisfy(validDomain) {
              supported = false
            } else if !positive.isEmpty && !negative.isEmpty {
              supported = false
            } else if !positive.isEmpty {
              trigger["if-domain"] = positive.map { "*" + $0 }
            } else {
              trigger["unless-domain"] = negative.map { "*" + $0 }
            }
          } else {
            supported = false
          }
        }
      }
      if !excluded.isEmpty {
        resources = (resources.isEmpty ? allTypes : resources).subtracting(excluded)
      }
      guard supported, excluded.isEmpty || !resources.isEmpty else {
        skipped += 1
        continue
      }
      var source = String(pattern)
      var prefix = ""
      var suffix = ""
      var regex = ""
      var terminalSeparator = false
      if source.hasPrefix("/"), source.hasSuffix("/"), source.count > 2 {
        regex = String(source.dropFirst().dropLast())
        if regex.contains("(?") || regex.contains("|") || regex.contains("{") || regex.contains("}")
          || regex.range(of: #"\\[A-Za-z]"#, options: .regularExpression) != nil
          || regex.range(of: #"\\[1-9]"#, options: .regularExpression) != nil
          || (try? NSRegularExpression(pattern: regex)) == nil
        {
          skipped += 1
          continue
        }
      } else {
        if source.hasPrefix("||") {
          prefix = "^https?://([a-zA-Z0-9-]+\\.)*"
          source = String(source.dropFirst(2))
        } else if source.hasPrefix("|") {
          prefix = "^"
          source = String(source.dropFirst())
        }
        if source.hasSuffix("|") {
          suffix = "$"
          source.removeLast()
        }
        terminalSeparator = source.hasSuffix("^")
        if terminalSeparator { source.removeLast() }
        for char in source {
          if char == "*" {
            regex += ".*"
          } else if char == "^" {
            regex += "[^a-zA-Z0-9_.%-]"
          } else {
            regex += NSRegularExpression.escapedPattern(for: String(char))
          }
        }
        if source.isEmpty {
          skipped += 1
          continue
        }
      }
      let patterns =
        terminalSeparator
        ? [prefix + regex + "[^a-zA-Z0-9_.%-]" + suffix, prefix + regex + "$"]
        : [prefix + regex + suffix]
      if !resources.isEmpty { trigger["resource-type"] = Array(resources).sorted() }
      for pattern in patterns {
        trigger["url-filter"] = pattern
        let rule: [String: Any] = [
          "trigger": trigger, "action": ["type": exception ? "ignore-previous-rules" : "block"],
        ]
        if exception { exceptions.append(rule) } else { rules.append(rule) }
      }
    }
    rules += exceptions
    for site in allowedSites where validDomain(site) {
      rules.append([
        "trigger": ["url-filter": ".*", "if-domain": ["*" + site]],
        "action": ["type": "ignore-previous-rules"],
      ])
    }
    return (rules, skipped)
  }
  private static func validDomain(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$", options: .regularExpression) != nil
  }

  /// Every list gets its own exceptions; WebKit exceptions do not cross list boundaries.
  public static func chunks(_ rules: [[String: Any]], size: Int = 30000) -> [[[String: Any]]] {
    let exceptions = rules.filter {
      ($0["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules"
    }
    let blocks = rules.filter {
      ($0["action"] as? [String: Any])?["type"] as? String != "ignore-previous-rules"
    }
    if blocks.isEmpty { return exceptions.isEmpty ? [] : [exceptions] }
    return stride(from: 0, to: blocks.count, by: max(1, size)).map { start in
      Array(blocks[start..<min(start + max(1, size), blocks.count)]) + exceptions
    }
  }
}
