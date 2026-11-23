import Foundation

/// One choice under Serein's first message: an AI app Serein supports, and what a click on it
/// does next.
public struct WelcomeChoice: Equatable, Identifiable, Sendable {
  public enum Next: String, Codable, Sendable {
    /// The app is not on this Mac yet.
    case install
    /// The app is on this Mac, and the app says nobody is signed in.
    case signIn
    /// The app can think for Serein now.
    case ready

    /// A short line under the name.
    public var words: String {
      switch self {
      case .install: return "Install"
      case .signIn: return "Sign in"
      case .ready: return "Ready"
      }
    }
  }
  /// The harness id (`HarnessDriver.instanceID`, the same as `Provider.rawValue`).
  public var id: String { harness }
  public var harness: String
  public var driver: HarnessDriver
  /// The name the person reads: their own name for it, else the app's name.
  public var name: String
  public var installed: Bool
  /// True when installed and the app does not say it is signed out. When the app cannot say
  /// without a model call, it counts as signed in, as `HarnessSnapshot.summarize` does.
  public var signedIn: Bool
  public var next: Next

  public init(driver: HarnessDriver, name: String, installed: Bool, signedIn: Bool) {
    harness = driver.instanceID
    self.driver = driver
    self.name = name
    self.installed = installed
    self.signedIn = installed && signedIn
    if !installed {
      next = .install
    } else if !signedIn {
      next = .signIn
    } else {
      next = .ready
    }
  }
}

/// What the shell does after a click on a choice.
public enum WelcomeStep: Equatable, Sendable {
  /// Start the app's own install (`AgentSetup.commands`, `HarnessDriver.installHint`).
  case install(HarnessDriver)
  /// Start the app's own sign-in (`HarnessDriver.signInCommand`).
  case signIn(HarnessDriver)
  /// The app is ready: show Serein's model picker (`ModelPickerView`, the same as the composer's)
  /// for this harness id.
  case showModelPicker(harness: String)
}

/// Serein's first message on the first launch. Serein (the chief of staff) is there from the
/// start, and it asks which AI app to set up. Pure: the shell posts the message, shows the
/// choices, and runs each step.
public enum Welcome {
  /// Exactly these words.
  public static let firstMessage = "Hey, welcome to Serein. Which AI app should I use?"

  /// One choice per AI app Serein supports (`HarnessDriver.allCases`), installed apps first, then
  /// the others; in each group the apps keep Serein's own order. A local model endpoint is not a
  /// choice: it cannot use Serein's tools, so it cannot be the chief of staff.
  ///
  /// `snapshots` are the last probes (`HarnessRegistry.snapshots`). An app with no snapshot yet
  /// counts as not installed; the shell builds the list again when a probe ends. An app the
  /// person turned off is still a choice: their click is their choice to use it.
  public static func choices(
    snapshots: [HarnessDriver: HarnessSnapshot], settings: HarnessSettings = HarnessSettings()
  ) -> [WelcomeChoice] {
    var installed: [WelcomeChoice] = []
    var missing: [WelcomeChoice] = []
    for driver in HarnessDriver.allCases {
      let snapshot: HarnessSnapshot? = snapshots[driver]
      let isInstalled: Bool = snapshot?.installed ?? false
      let signedOut: Bool = snapshot?.signedIn == false || snapshot?.signInProblem != nil
      let name: String = settings.instance(driver).name
      let choice = WelcomeChoice(driver: driver, name: name, installed: isInstalled, signedIn: !signedOut)
      if isInstalled {
        installed.append(choice)
      } else {
        missing.append(choice)
      }
    }
    return installed + missing
  }

  /// The connect menu's rows: every app on this Mac, then the first apps that are not, enough to
  /// make `limit` rows and never fewer than two, so Claude Code and Codex are always a choice.
  public static func connectMenu(
    snapshots: [HarnessDriver: HarnessSnapshot], settings: HarnessSettings = HarnessSettings(), limit: Int = 5
  ) -> (here: [WelcomeChoice], other: [WelcomeChoice]) {
    let all: [WelcomeChoice] = choices(snapshots: snapshots, settings: settings)
    let here: [WelcomeChoice] = all.filter(\.installed)
    let other: [WelcomeChoice] = all.filter { !$0.installed }
    return (here, Array(other.prefix(max(2, limit - here.count))))
  }

  /// What a click on `choice` does now. After an install or a sign-in, the shell probes again,
  /// builds the choices again and asks again; a ready choice shows the model picker.
  public static func step(for choice: WelcomeChoice) -> WelcomeStep {
    switch choice.next {
    case .install: return .install(choice.driver)
    case .signIn: return .signIn(choice.driver)
    case .ready: return .showModelPicker(harness: choice.harness)
    }
  }
}
