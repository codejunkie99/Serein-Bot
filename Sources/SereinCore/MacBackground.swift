import Foundation

/// Background work in one Mac app (mac_observe and mac_act with `background`): Serein reads the
/// app's chosen window through Accessibility and acts on it with the element's own actions, or
/// with keys addressed to that app's process alone, so the person's pointer, front app and focus
/// stay theirs. Every step still asks on the mac_act card. The words and refusals are pure here.
public enum MacBackgroundPolicy {
  /// Settings › AI apps › Mac access: off until the person turns it on.
  public static let enabledKey = "serein.mac.background"
  /// The answer to any step the app offers no background way to do (a point on a canvas, a drag).
  public static let needsForeground =
    "This needs the foreground; ask to use foreground mode. mac_act without background asks the person on its own card."
  public static let off =
    "Background work in Mac apps is off. The person turns it on from a card Serein offers in its chat (setup_offer, topic background) or in Settings › AI apps › Mac access; until then use mac_observe and mac_act without background."
  public static let unattended =
    "Background work in Mac apps needs the person there to answer each step, so it is refused in a scheduled or unattended run."
  public static let stopped = "The person stopped background work for this task. Do not retry it."
  public static let startButton = "Allow for this task"

  /// Why `app` may not be worked on in the background, or nil: Serein itself, and the apps that
  /// hold the person's secrets (`RelayAutonomy.holdsSecrets`, by name or bundle identifier).
  public static func refusal(app: String, bundleID: String?, isSerein: Bool) -> String? {
    if isSerein { return "Serein never works on itself." }
    if RelayAutonomy.holdsSecrets(app: app, bundleID: bundleID) {
      return "This app is the user's: \(app) holds passwords or other secrets."
    }
    return nil
  }

  /// The card before the first background step in an app, once per task. Autopilot never answers it.
  public static func startCard(app: String, window: String) -> (title: String, detail: String) {
    let named = window.isEmpty ? "its front window" : "the window “\(String(window.prefix(60)))”"
    return ("Work in \(app) in the background?",
            "Serein reads \(named) and asks before every step in it, without moving your pointer or bringing \(app) to the front. Stop ends it for this task.")
  }

  /// The card for a minimised window: Serein cannot see one in the Dock.
  public static func unminimiseCard(app: String, window: String) -> (title: String, detail: String) {
    let named = window.isEmpty ? "the window" : "“\(String(window.prefix(60)))”"
    return ("Un-minimise \(named) in \(app)?",
            "Serein cannot see a minimised window. This brings it back from the Dock, where it may cover your other windows. Decline to keep it there; Serein can ask to use foreground mode instead.")
  }

  /// The answer when a minimised window stays in the Dock.
  public static func minimised(app: String, window: String) -> String {
    let named = window.isEmpty ? "That window" : "“\(String(window.prefix(60)))”"
    return "\(named) in \(app) is minimised, so Serein cannot see it, and it stays in the Dock. Ask the person to use foreground mode instead."
  }

  /// A background step in the step list and Serein's activity: “Pressed “Save” in Notes, in the background”.
  /// `inserted`: a `type` that added text at a text area's cursor rather than replacing it.
  public static func describe(_ step: RelayAutonomy.MacStep, inserted: Bool = false) -> String {
    let target = step.label.flatMap { $0.isEmpty ? nil : "“\(String($0.prefix(40)))”" }
    let did: String
    switch step.kind {
    case "click": did = "Pressed \(target ?? "a control")"
    case "confirm": did = "Confirmed \(target ?? "a control")"
    case "increment": did = "Increased \(target ?? "a value")"
    case "decrement": did = "Decreased \(target ?? "a value")"
    case "menu": did = "Opened the menu of \(target ?? "a control")"
    case "select": did = "Selected \(target ?? "a row")"
    case "type": did = inserted ? "Added text to \(target ?? "a text area")" : "Typed into \(target ?? "a field")"
    case "key": did = "Pressed \(step.key ?? "a key")"
    case "scroll": did = "Scrolled"
    default: did = step.kind.capitalized
    }
    return "\(did) in \(step.app), in the background"
  }
}
