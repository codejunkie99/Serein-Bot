import Foundation

/// Background features that send data to the user's agent provider. Each can be turned off in Settings.
public enum AgentFeature: String, CaseIterable {
  case routing, timeline, proofreading, recall, outcome, projectGrouping
  public var title: String {
    switch self {
    case .routing: return "Choose a destination automatically"
    case .timeline: return "Describe each day automatically"
    case .proofreading: return "Proofread dictation"
    case .recall: return "Find pages by description"
    case .outcome: return "Summarize how each finished task went"
    case .projectGrouping: return "Sort projects by purpose"
    }
  }
  var defaultOn: Bool { self != .timeline }
}

public enum FeaturePolicy {
  /// Day descriptions keep the key of their switch in Settings › History, so the two switches
  /// are one setting and a choice made there before stays in effect.
  public static func key(_ f: AgentFeature) -> String {
    f == .timeline ? "serein.autoTimeline" : "serein.feature." + f.rawValue
  }
  /// Every feature sends data to a model, so its switch lives in GateSettings; while that file
  /// cannot be read, every feature is off.
  public static func isEnabled(_ f: AgentFeature, defaults: any SettingsStore = GateSettings.shared) -> Bool {
    if (defaults as? GateSettings)?.unreadable == true { return false }
    return defaults.object(forKey: key(f)) as? Bool ?? f.defaultOn
  }
  public static func set(_ f: AgentFeature, _ on: Bool, defaults: any SettingsStore = GateSettings.shared) {
    defaults.set(on, forKey: key(f))
    NotificationCenter.default.post(name: changed, object: f.rawValue)
  }
  public static let changed = Notification.Name("SereinFeaturePolicyChanged")
}
