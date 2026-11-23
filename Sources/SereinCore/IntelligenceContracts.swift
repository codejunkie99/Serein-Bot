import Foundation

public struct RouteDecision: Codable {
  public var mode: String
  public var project_id: String?
  public var candidates: [String]
  public var confidence: Double
  public var reason: String
  public var title: String
  public func validate(projectIDs: Set<String>) throws {
    guard ["answer", "project", "clarify", "anywhere", "search", "web", "web_here"].contains(mode),
      confidence.isFinite, (0...1).contains(confidence), title.count <= 160, reason.count <= 1000
    else { throw SereinError.invalid("Invalid routing response") }
    guard candidates.allSatisfy(projectIDs.contains), project_id.map(projectIDs.contains) ?? true
    else { throw SereinError.invalid("Router returned an unknown project") }
    if mode == "project" && project_id == nil {
      throw SereinError.invalid("Router did not choose a project")
    }
  }
}
public struct Episode: Codable, Identifiable {
  public var id: String = UUID().uuidString
  public var title: String
  public var summary: String
  public var visitIDs: [String]
  public init(title: String, summary: String, visitIDs: [String]) {
    self.title = title
    self.summary = summary
    self.visitIDs = visitIDs
  }
}
public struct DayTimeline: Codable {
  public var headline: String
  public var episodes: [Episode]
  public var generatedAt: Date = Date()
  public init(headline: String, episodes: [Episode]) {
    self.headline = headline
    self.episodes = episodes
  }
  public func validate(visits: [Visit]) throws {
    let expected = visits.map(\.id)
    let actual = episodes.flatMap(\.visitIDs)
    guard !headline.isEmpty, headline.count <= 240, actual == expected,
      Set(actual).count == actual.count,
      episodes.allSatisfy({
        !$0.title.isEmpty && $0.title.count <= 120 && !$0.summary.isEmpty && $0.summary.count <= 600
          && !$0.visitIDs.isEmpty
      })
    else {
      throw SereinError.invalid(
        "Timeline must include every visit once, in chronological order, with bounded factual summaries"
      )
    }
  }
}
public struct ProjectNote: Codable {
  public var projectID: String
  public var summary: String
  public var purpose: String
  public var resources: [String]
  public var unlike: String
  public var updatedAt: Date = Date()
  public init(
    projectID: String, summary: String, purpose: String, resources: [String], unlike: String = ""
  ) {
    self.projectID = projectID
    self.summary = summary
    self.purpose = purpose
    self.resources = resources
    self.unlike = unlike
  }
}
public enum StructuredOutput {
  public static func decode<T: Decodable>(_ type: T.Type, text: String) throws -> T {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("```") {
      let lines = value.components(separatedBy: "\n")
      guard lines.count >= 3, lines.last?.hasPrefix("```") == true else {
        throw SereinError.invalid("Incomplete structured response")
      }
      value = lines.dropFirst().dropLast().joined(separator: "\n")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(value.utf8))
  }
  public static func addedText(previous: String, current: String) -> String {
    let old = Set(
      previous.components(separatedBy: .newlines).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      })
    return current.components(separatedBy: .newlines).filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !old.contains($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }.joined(separator: "\n")
  }
}

public enum MacScriptPolicy {
  public static func validate(_ source: String) throws {
    guard !source.isEmpty, source.utf8.count <= 12000 else {
      throw SereinError.invalid("Use a short inline AppleScript")
    }
    let lower = source.lowercased()
    guard lower.range(of: "\\bapp\\b", options: .regularExpression) == nil else {
      throw SereinError.invalid("Use literal application targets")
    }
    for forbidden in [
      "do shell script", "do script", "run script", "load script", "javascript", "using terms from",
      "application id", "scripting additions", "«", "use framework", "system events", "terminal",
      "iterm", "osascript", "curl", "python", "ruby", "bash", "zsh", "open location",
      "mount volume", "use scripting", "tell app ", "tell app\n",
    ] {
      if lower.contains(forbidden) {
        throw SereinError.invalid("Unsupported AppleScript capability: " + forbidden)
      }
    }
    let regex = try NSRegularExpression(
      pattern: "application\\s+\"([^\"]+)\"", options: .caseInsensitive)
    let ns = source as NSString
    for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
      guard
        ["calendar", "reminders", "notes", "finder"].contains(
          ns.substring(with: match.range(at: 1)).lowercased())
      else { throw SereinError.invalid("Only Calendar, Reminders, Notes and Finder are supported") }
    }
    // Require literal targets; computed application names can bypass target validation.
    let targets = lower.components(separatedBy: "application").dropFirst()
    guard targets.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("\"") })
    else { throw SereinError.invalid("Use literal application names") }
  }
}

public struct TurnSummary: Codable {
  public var kind: String
  public var question: String
  public var choices: [String]
  public func validate() throws {
    guard ["answer", "action", "done", "failed"].contains(kind), !question.isEmpty,
      question.count <= 280, choices.count <= 5, choices.allSatisfy({ $0.count <= 120 }),
      kind == "answer" || choices.isEmpty
    else { throw SereinError.invalid("Invalid task outcome") }
  }
}
