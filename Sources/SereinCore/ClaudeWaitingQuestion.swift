import Foundation

/// The question a Claude Code session is waiting on, read from its own transcript. Claude's desktop
/// app draws its questions where Accessibility can't read them (multiple-choice options, no yes/no
/// buttons, a deep Electron tree), but the transcript holds the exact question and options.
/// Display only: Serein shows the question and points the person to Claude to answer it. Its words
/// are untrusted transcript text: shown to the person as text, never sent to a model.
extension WaitingPromptReader {
  /// How much of the transcript's end is read for the pending question.
  public static let transcriptTail = 256 * 1024
  /// The most answers a card lists, and the longest each may be.
  static let choiceLimit = 6
  static let choiceLength = 120

  /// The pending question in a Claude Code transcript file, or nil.
  public static func claudeTranscript(path: String) -> WaitingPrompt? {
    SessionHistory.tail(path, bytes: transcriptTail).flatMap(claudeTranscript)
  }

  /// The pending question at the end of a Claude Code transcript: the last assistant turn asked
  /// with AskUserQuestion or ExitPlanMode, and no user line (its answer) came after it.
  public static func claudeTranscript(_ data: Data) -> WaitingPrompt? {
    var pending: WaitingPrompt?
    for line in data.split(separator: 10) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        let message = object["message"] as? [String: Any], object["isMeta"] as? Bool != true
      else { continue }
      switch object["type"] as? String {
      case "user":
        pending = nil
      case "assistant":
        let blocks = message["content"] as? [[String: Any]] ?? []
        for block in blocks {
          switch block["type"] as? String {
          case "tool_use":
            pending = asked(block["name"] as? String, input: block["input"] as? [String: Any] ?? [:])
          case "text":
            pending = nil
          default: break
          }
        }
      default: break
      }
    }
    return pending
  }

  private static func asked(_ tool: String?, input: [String: Any]) -> WaitingPrompt? {
    switch tool {
    case "AskUserQuestion":
      let questions = input["questions"] as? [[String: Any]] ?? []
      guard let first = questions.first, let text = first["question"] as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      let options = (first["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        .filter { !$0.isEmpty }.prefix(choiceLimit)
      let more = questions.count > 1 ? "Question 1 of \(questions.count). Answer the rest in Claude." : nil
      return WaitingPrompt(
        kind: .transcript, question: String(text.prefix(questionLimit)), detail: more,
        choices: options.enumerated().map { .init(label: String($0.element.prefix(choiceLength)), index: $0.offset) })
    case "ExitPlanMode":
      let plan = (input["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return WaitingPrompt(
        kind: .transcript, question: "Claude has a plan ready. Approve it?",
        detail: plan.flatMap { $0.isEmpty ? nil : String($0.prefix(detailLimit)) }, choices: [])
    default:
      return nil
    }
  }
}
