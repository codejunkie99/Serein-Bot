import AppKit
import SereinCore

/// The first-open look round this Mac (`LocalFinds`). Each part only looks: whether a file is
/// there, which browser opens links, whether a model app answers on this Mac's own address. It
/// reads no file's contents and raises no macOS permission prompt; anything that needs one
/// (passwords, Contacts, Mail) stays behind its own card.
@MainActor enum LocalScan {
  private(set) static var finds: LocalFinds?
  private static var started = false

  /// Starts once per launch; the result is ready long before setup's last question.
  static func start() {
    guard !started, !RunMode.checking else { return }
    started = true
    Task {
      let browser = await SetupRun.sourceName(synthetic: nil)
      let tools = await Task.detached(priority: .utility) { toolApps() }.value
      let models = await modelApps()
      finds = LocalFinds(browser: browser, toolApps: tools, modelApps: models,
                         speechModel: SpeechEngine.modelFile() != nil)
    }
  }

  /// AI apps whose connected-tools file exists. Only its presence: the file holds keys.
  nonisolated private static func toolApps() -> [String] {
    let home = NSHomeDirectory()
    let environment = ProcessInfo.processInfo.environment
    return AppImport.Source.allCases
      .filter { FileManager.default.fileExists(atPath: $0.configFile(home: home, environment: environment)) }
      .map(\.name)
  }

  /// Model apps that answer on 127.0.0.1 within a second. Nothing leaves this Mac.
  private static func modelApps() async -> [String] {
    var found: [String] = []
    for app in LocalFinds.modelPorts {
      guard let url = URL(string: app.url) else { continue }
      var request = URLRequest(url: url, timeoutInterval: 1)
      request.httpMethod = "GET"
      if let (_, response) = try? await URLSession.shared.data(for: request),
        (response as? HTTPURLResponse)?.statusCode == 200 {
        found.append(app.name)
      }
    }
    return found
  }
}
