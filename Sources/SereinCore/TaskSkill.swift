import CryptoKit
import Foundation

/// Save as Skill: what Serein drafts from a finished task for the person to edit. Name is the
/// skill's name, `whenToUse` its description and `steps` its instructions (SKILL.md).
public struct TaskSkillDraft: Equatable, Sendable {
  public var name: String
  public var whenToUse: String
  public var steps: String
  public init(name: String, whenToUse: String, steps: String) {
    self.name = name
    self.whenToUse = whenToUse
    self.steps = steps
  }
}

/// A written how-to drafted from a finished task's own step record, by a fixed template and no
/// model. It holds Serein's words only: the sites as host names and the steps as Serein's own
/// labels with every value left out (typed text, picked options, titles, paths, commands). The
/// task's request and title are never copied: the first message of a task Serein started is
/// worded by Serein after reading mail, pages or notes, so the person writes the name, when to
/// use it and the request themselves. The person's own steps (sign-ins, take over, files they
/// put in) are never part of it. A saved skill is text for the prompt: it grants nothing.
public enum TaskSkill {
  /// One entry of the task's record. `browser` marks Serein's tab board (`AgentStep.label`);
  /// the others are the AI app's own steps, by `RunActivity` tool key (read, edit, command…).
  public struct Step: Equatable, Sendable {
    public var tool: String
    public var label: String
    public var browser: Bool
    public var failed: Bool
    public init(tool: String, label: String, browser: Bool, failed: Bool = false) {
      self.tool = tool
      self.label = label
      self.browser = browser
      self.failed = failed
    }
  }
  public static let maxSteps = 40
  public static let maxSites = 12
  public static let whenToUsePrompt = "(Write when to use this, in your own words.)"
  public static let requestPrompt = "(Write the request here in your own words.)"
  /// Steps the person took for the task, not the assistant: they hold sign-ins and file names.
  static let personSteps: Set<String> = ["take_over", "hand_back", "sign_in", "kept_sign_in", "computer_file_in"]
  static let hostPattern = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"

  /// The draft has no name: the person types it.
  public static func draft(steps: [Step]) -> TaskSkillDraft {
    var sites: [String] = []
    var lines: [String] = []
    for step in steps where !step.failed {
      let (label, host) = words(step)
      if let host, !sites.contains(host), sites.count < maxSites { sites.append(host) }
      // Five reads in a row are one step of the how-to.
      if let label, lines.last != label, lines.count < maxSteps { lines.append(label) }
    }
    let numbered = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    let body = """
      The person asked:
      \(requestPrompt)

      Sites used: \(sites.isEmpty ? "none" : sites.joined(separator: ", "))

      Steps, in order:
      \(numbered.isEmpty ? "No steps were recorded." : numbered)

      Use this as a guide, not a script: read each page again, take what to type or choose from the person's new request, and pick a sensible default when it does not say. Sign-ins and payments go through Serein's secure card, and Serein still shows its card for any step that needs the person's OK.
      """
    return TaskSkillDraft(name: "", whenToUse: whenToUsePrompt, steps: AgentPrivacy.redact(body))
  }

  /// A skill name as the store takes it: lowercase words joined by hyphens, up to 64 characters.
  public static func isName(_ name: String) -> Bool {
    name.count <= 64 && name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
  }

  /// The SKILL.md the plugins store keeps, from the person's edited draft: each field redacted
  /// again with block tags neutralised, the name a skill name, and the whole file parsed by
  /// `SkillParser` so the store's own size caps apply. `skill` is that parse, for the pin.
  public static func file(_ draft: TaskSkillDraft) throws -> (name: String, text: String, skill: PluginSkill) {
    let name = draft.name.trimmingCharacters(in: .whitespaces)
    guard isName(name) else {
      throw SereinError.invalid("A skill's name is lowercase words joined by hyphens, up to 64 characters.")
    }
    let description = oneLine(seal(draft.whenToUse))
    let instructions = seal(draft.steps).trimmingCharacters(in: .whitespacesAndNewlines)
    // Save as Skill and the app import both come through here.
    if let why = SavedText.problem(name + "\n" + description + "\n" + instructions) { throw SereinError.invalid(why) }
    let text = "---\nname: \(name)\ndescription: \(description)\n---\n\(instructions)\n"
    let skill = try SkillParser.parse(text, folder: URL(fileURLWithPath: NSTemporaryDirectory()))
    return (name, text, skill)
  }

  /// The text a saved skill was reviewed with, front matter included. A copy changed on disk no
  /// longer matches it.
  public static func pin(_ skills: [PluginSkill]) -> String {
    let text = skills.map {
      [$0.name, $0.description, $0.instructions, $0.license ?? "", $0.compatibility ?? ""].joined(separator: "\u{0}")
    }.joined(separator: "\u{1}")
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// A step in Serein's words, and the host it names; both nil for a step left out.
  static func words(_ step: Step) -> (label: String?, host: String?) {
    guard step.browser else { return runWords(step) }
    if personSteps.contains(step.tool) { return (nil, nil) }
    switch step.tool {
    case "open", "open_tab": return hostStep(step, prefix: "Opened a new tab on ", suffix: "")
    case "navigate", "go": return hostStep(step, prefix: "Went to ", suffix: "")
    case "computer_open_url": return hostStep(step, prefix: "Opened ", suffix: " in Serein's computer")
    // Background traffic from programs inside Serein's computer, which pick the names: not a
    // site the how-to used.
    case "computer_net": return (nil, nil)
    case "scroll":
      let kept = ["up", "down", "left", "right"].map { "Scrolled " + $0 }
      return (kept.contains(step.label) ? step.label : AgentStep.label(tool: "scroll", arguments: [:]), nil)
    default:
      // The label with no arguments has no value in it: “Typed”, “Picked an option”.
      guard step.tool.range(of: "^[a-z][a-z0-9_]{0,47}$", options: .regularExpression) != nil else { return ("Used a tool", nil) }
      let label = AgentStep.label(tool: step.tool, arguments: [:])
      // An unknown tool's label is its raw name, which the model chose: never words of the how-to.
      return (label == "Used " + String(step.tool.prefix(40)) ? "Used a tool" : label, nil)
    }
  }

  /// The AI app's own steps, by kind only: their labels name files, commands and searches.
  static func runWords(_ step: Step) -> (label: String?, host: String?) {
    switch step.tool {
    case "read": return ("Read files", nil)
    case "edit": return ("Edited files", nil)
    case "search": return ("Searched files", nil)
    case "command": return ("Ran a command", nil)
    case "test": return ("Ran tests", nil)
    case "build": return ("Built the project", nil)
    case "plan": return ("Updated its plan", nil)
    // A card's answer and a choice Serein made on a page are not steps of a how-to.
    case SessionLog.cardTool, "choice": return (nil, nil)
    case "browser": return ("Used the browser", nil)
    case "web":
      let host = hostName(in: step.label, prefix: "Read ", suffix: "")
      return (host.map { "Read " + $0 } ?? "Used the web", host)
    default: return ("Used a tool", nil)
    }
  }

  static func hostStep(_ step: Step, prefix: String, suffix: String) -> (label: String?, host: String?) {
    let host = hostName(in: step.label, prefix: prefix, suffix: suffix)
    var arguments: [String: Any] = [:]
    if let host { arguments["url"] = "https://\(host)/" }
    return (AgentStep.label(tool: step.tool, arguments: arguments), host)
  }

  /// The host a label names, only when it is a plain host name (“a page” and anything else is nil).
  static func hostName(in label: String, prefix: String, suffix: String) -> String? {
    guard label.count >= prefix.count + suffix.count, label.hasPrefix(prefix), label.hasSuffix(suffix) else { return nil }
    let raw = String(label.dropFirst(prefix.count).dropLast(suffix.count)).lowercased()
    return raw.range(of: hostPattern, options: .regularExpression) == nil ? nil : raw
  }

  /// 13 to 19 digits that pass the Luhn check, as `[REDACTED]`.
  static func cards(_ text: String) -> String {
    guard let pattern = try? NSRegularExpression(pattern: #"\d(?:[ -]?\d){12,18}"#) else { return text }
    var out = text
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let range = Range(match.range, in: out), HandBack.looksLikeCardNumber(String(out[range])) else { continue }
      out.replaceSubrange(range, with: AgentPrivacy.replacement)
    }
    return out
  }

  /// Text the person edited, before it is stored: redacted, and unable to open or close a block.
  static func seal(_ text: String) -> String { UntrustedText.escape(cards(AgentPrivacy.redact(text))) }

  static func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
