import Foundation

/// The onboarding pages, in order. A page is saved as the person reaches it, so a restart (Screen
/// Recording's Reopen Serein) comes back to it; finishing setup ends them for good.
public enum FirstRunPage: String, Codable, CaseIterable, Sendable {
  case connect, mac

  public static let savedKey = "serein.firstRun.page"

  /// A completed setup opens the app.
  public static func page(setupFinished: Bool, saved: FirstRunPage?) -> FirstRunPage? {
    guard !setupFinished else { return nil }
    return saved ?? allCases[0]
  }

  /// The same decision from what this Mac keeps: setup's progress and the saved page.
  public static func page(_ defaults: UserDefaults) -> FirstRunPage? {
    page(setupFinished: !SetupProgress.needsFirstRun(defaults),
      saved: defaults.string(forKey: savedKey).flatMap(FirstRunPage.init(rawValue:)))
  }

  public static func save(_ page: FirstRunPage?, _ defaults: UserDefaults) {
    if let page { defaults.set(page.rawValue, forKey: savedKey) } else { defaults.removeObject(forKey: savedKey) }
  }

  public func back() -> FirstRunPage? {
    let all = Self.allCases
    return all.firstIndex(of: self).flatMap { $0 > 0 ? all[$0 - 1] : nil }
  }
}
