import Foundation

/// The finish tool's call.
public enum FinishCall: Sendable, Equatable {
  case done(answer: String, resultTab: String?)
  case stuck(routes: [String], nextAction: String)

  public struct Parsed: Sendable {
    public let ok: FinishCall?
    public let blocked: Blocked?
  }
  /// A bad call returns a route line, not a throw.
  public static func parse(_ json: String) -> Parsed {
    let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    let summary = object["summary"] as? String ?? object["answer"] as? String ?? ""
    let tab = object["result_tab"] as? String
    switch object["outcome"] as? String {
    case "done": return Parsed(ok: .done(answer: summary, resultTab: tab), blocked: nil)
    case "stuck":
      let routes = object["routes"] as? [String] ?? (summary.isEmpty ? [] : [summary])
      return Parsed(ok: .stuck(routes: routes, nextAction: object["next_action"] as? String ?? ""), blocked: nil)
    default:
      return Parsed(ok: nil, blocked: Blocked(
        "finish takes outcome done or stuck",
        routes: .init("call finish with outcome done and your answer", "call finish with outcome stuck, the routes you tried and the next action")))
    }
  }
}
