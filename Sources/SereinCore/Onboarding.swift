import Foundation

// MARK: First-run onboarding plan

/// The steps of the onboarding preview (import first, your sites, try Relay,
/// ready). Which of them apply is a pure function, so it is checked in SereinChecks.
public enum OnboardingStep: String, CaseIterable, Codable, Identifiable {
  case welcome, importData, sites, relay, ready
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .welcome: return "Welcome"
    case .importData: return "Bring your data"
    case .sites: return "Your sites"
    case .relay: return "Try Relay"
    case .ready: return "Ready"
    }
  }
}

public enum OnboardingPlan {
  /// The steps this person sees. Relay skipped once is gone for good — removed from the
  /// rail entirely, never shown disabled.
  public static func steps(relaySkipped: Bool) -> [OnboardingStep] {
    var out: [OnboardingStep] = [.welcome, .importData, .sites]
    if !relaySkipped { out.append(.relay) }
    out.append(.ready)
    return out
  }

  /// The next step after `step` in `steps`, skipping steps that stopped applying.
  public static func advance(from step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep {
    guard let index = steps.firstIndex(of: step), index + 1 < steps.count else {
      return steps.last ?? .ready
    }
    return steps[index + 1]
  }

  /// The step behind `step`, stopping at the front of the rail.
  public static func back(from step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep {
    guard let index = steps.firstIndex(of: step), index > 0 else { return step }
    return steps[index - 1]
  }
}

// MARK: The sites step's offer

/// The sites first-run offers, one fixed list: the services most people live in, with the
/// addresses Serein keeps for them. Keeping one pins a real tab. (The reference's catalog
/// shape; Serein's marks come from its own favicon store.)
public enum OnboardingSites {
  public struct Site: Identifiable, Equatable {
    public var id: String { host }
    public let name: String
    public let host: String
    public let address: String
  }

  public static let catalog: [Site] = [
    Site(name: "Gmail", host: "mail.google.com", address: "https://mail.google.com/"),
    Site(name: "Calendar", host: "calendar.google.com", address: "https://calendar.google.com/"),
    Site(name: "Slack", host: "app.slack.com", address: "https://app.slack.com/client"),
    Site(name: "Notion", host: "notion.so", address: "https://www.notion.so/"),
    Site(name: "Linear", host: "linear.app", address: "https://linear.app/"),
    Site(name: "GitHub", host: "github.com", address: "https://github.com/"),
    Site(name: "Figma", host: "figma.com", address: "https://www.figma.com/files"),
    Site(name: "ChatGPT", host: "chatgpt.com", address: "https://chatgpt.com/"),
    Site(name: "Claude", host: "claude.ai", address: "https://claude.ai/"),
    Site(name: "YouTube", host: "youtube.com", address: "https://www.youtube.com/"),
    Site(name: "Spotify", host: "open.spotify.com", address: "https://open.spotify.com/"),
    Site(name: "WhatsApp", host: "web.whatsapp.com", address: "https://web.whatsapp.com/"),
  ]
}
