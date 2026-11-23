import Foundation

/// One engine a chat can answer with: a harness CLI (or the local model endpoint) and one of its
/// models, labelled by who pays for a turn and what the engine can do. The model list builds its
/// rows from these, so a row's tag, capabilities and greyed state come from one place.
public struct ModelRoute: Equatable, Identifiable, Sendable {
  /// Who pays for a turn on this route; every route has exactly one.
  public enum CostClass: String, Equatable, Sendable {
    /// Nothing is billed: a model endpoint that takes no key (the user's own server).
    case free
    /// The user's own API key: one named in the harness's environment, or the endpoint's key in
    /// Keychain.
    case yourKey
    /// The plan the user signed in to through the provider's own CLI. Serein only launches that
    /// CLI; it never reads, copies or stores its sign-in.
    case yourPlan
    public var label: String {
      switch self {
      case .free: return "free"
      case .yourKey: return "your key"
      case .yourPlan: return "your plan"
      }
    }
  }
  /// What the engine can do in Serein, shown as text.
  public enum Capability: String, Equatable, Sendable {
    /// It is given Serein's tools (browser, Mac, settings).
    case tools
    /// It reads pictures.
    case vision
    /// Neither: it answers in text only.
    case textOnly
    public var label: String {
      switch self {
      case .tools: return "tools"
      case .vision: return "vision"
      case .textOnly: return "text only"
      }
    }
  }
  /// The harness instance id (`HarnessDriver.instanceID`, or the local endpoint's).
  public var provider: String
  /// The model id; empty is the harness's own default.
  public var model: String
  public var costClass: CostClass
  public var caps: [Capability]
  /// The CLI is on this Mac (for the endpoint: it is set up).
  public var installed: Bool
  /// Why the route cannot answer now (not installed, off, signed out); nil when it can.
  public var reason: String?
  public init(provider: String, model: String, costClass: CostClass, caps: [Capability], installed: Bool, reason: String?) {
    self.provider = provider
    self.model = model
    self.costClass = costClass
    self.caps = caps
    self.installed = installed
    self.reason = reason
  }
  public var id: String { provider + ":" + model }
  /// Only a route with no reason against it can be picked.
  public var selectable: Bool { reason == nil }
}

public enum ModelRoutes {
  /// A variable name that carries a provider API key. Only names are looked at, never values.
  public static func isKeyName(_ name: String) -> Bool {
    let upper = name.uppercased()
    return upper.hasSuffix("_API_KEY") || upper == "ANTHROPIC_AUTH_TOKEN"
  }
  /// Text only when the engine has neither tools nor pictures.
  public static func caps(tools: Bool, vision: Bool) -> [ModelRoute.Capability] {
    let shown: [ModelRoute.Capability] = (tools ? [.tools] : []) + (vision ? [.vision] : [])
    return shown.isEmpty ? [.textOnly] : shown
  }
  /// A harness's routes, one per listed model (or one for its default when it lists none).
  /// `found`: the app has a runnable executable for it (enabled and installed). `hasKey`: the
  /// instance's API key item exists in Keychain (its presence only). That key, the only one a run
  /// is given, or a CLI that reports it is signed in with a key makes it "your key"; otherwise the
  /// turn runs on the plan signed in through the CLI. A key still in the plain-text environment
  /// does not count: no run receives it (Settings warns with Move to Keychain). A found CLI is
  /// greyed when it cannot be driven (a Gemini CLI with no ACP mode) or reports it is signed out.
  public static func harness(instance: HarnessInstance, snapshot: HarnessSnapshot?, found: Bool, hasKey: Bool, models: [String]) -> [ModelRoute] {
    let name = instance.name
    // "Gemini CLI" already says CLI.
    let cli = name.hasSuffix(" CLI") ? name : name + " CLI"
    let reason: String?
    if found {
      if snapshot?.lacksACPMode == true {
        reason = HarnessSnapshot.noACPMode
      } else if snapshot?.signedIn == false {
        reason = instance.driver.signedOutReason ?? "Not signed in to the \(cli)"
      } else {
        reason = nil
      }
    } else if !instance.enabled {
      reason = "\(name) is off. Turn it on in Settings › AI apps."
    } else if snapshot?.checkedAt == nil {
      reason = "Checking \(name)…"
    } else {
      reason = "\(cli) not installed"
    }
    // The CLI's own status line also says when it runs on a key ("API key"); no token is read.
    let keyed = hasKey || snapshot?.account == "API key"
    let abilities = snapshot?.capabilities ?? .base(instance.driver)
    let tags = Self.caps(tools: abilities.canInjectMCP, vision: abilities.supportsImages)
    return (models.isEmpty ? [""] : models).map {
      ModelRoute(provider: instance.id, model: $0, costClass: keyed ? .yourKey : .yourPlan, caps: tags,
                 installed: found || snapshot?.installed == true, reason: reason)
    }
  }
  /// The letters on a route's tile: the initials of the first two words of the harness's name,
  /// or the first two letters of a one-word name ("Claude Code" CC, "Codex" Co).
  public static func monogram(_ name: String) -> String {
    let words = name.split { !$0.isLetter && !$0.isNumber }
    guard let first = words.first else { return "" }
    if words.count > 1, let second = words[1].first { return (String(first.prefix(1)) + String(second)).uppercased() }
    return first.prefix(1).uppercased() + first.dropFirst().prefix(1).lowercased()
  }
  /// Tile letters for every harness at once, in driver order, so no two tiles read the same: a
  /// name keeps its `monogram` unless an earlier name took it, then tries its first letter with
  /// each later letter of its first word ("Cloud Coder" after "Claude Code" and "Codex": Cl).
  public static func monograms(_ names: [String]) -> [String] {
    var taken: Set<String> = []
    return names.map { name in
      let plain = monogram(name)
      let word = name.split { !$0.isLetter && !$0.isNumber }.first.map(String.init) ?? ""
      let initial = word.prefix(1).uppercased()
      let tries = [plain] + word.dropFirst().map { initial + String($0).lowercased() }
      let chosen = tries.first { !taken.contains($0) } ?? plain
      taken.insert(chosen)
      return chosen
    }
  }
}
