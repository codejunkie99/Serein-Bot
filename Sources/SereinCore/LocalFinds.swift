import Foundation

/// What a first open finds already on this Mac, beside the AI apps setup lists: the browser
/// Serein can bring sign-ins and bookmarks from, the AI apps that keep connected tools, a model
/// app running here, and the speech model. Found by looking only (`LocalScan`): nothing is read,
/// imported or turned on, and the setup chat's closing line names it so the person can ask.
public struct LocalFinds: Equatable, Sendable {
  public var browser: String?
  /// AI apps with a file of connected tools (MCP servers), by name, in the order Serein reads them.
  public var toolApps: [String] = []
  /// Model apps answering on this Mac (Ollama, LM Studio).
  public var modelApps: [String] = []
  public var speechModel = false
  public init(browser: String? = nil, toolApps: [String] = [], modelApps: [String] = [], speechModel: Bool = false) {
    self.browser = browser
    self.toolApps = toolApps
    self.modelApps = modelApps
    self.speechModel = speechModel
  }

  /// One sentence for the end of setup, or nil when nothing was found.
  public var sentence: String? {
    var parts: [String] = []
    if let browser { parts.append("\(browser), with sign-ins and bookmarks I can bring in") }
    if !toolApps.isEmpty { parts.append("connected tools in " + Self.list(toolApps)) }
    if !modelApps.isEmpty { parts.append(Self.list(modelApps) + " running a model here") }
    if speechModel { parts.append("the speech model for typing by voice") }
    guard !parts.isEmpty else { return nil }
    return "On this Mac I also found " + Self.list(parts) + ". Ask me to bring any of it in."
  }

  /// "a", "a and b", "a, b and c".
  static func list(_ items: [String]) -> String {
    guard items.count > 1, let last = items.last else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + last
  }

  /// The model apps whose usual local address answered, by the ports they listen on.
  public static let modelPorts: [(name: String, url: String)] = [
    ("Ollama", "http://127.0.0.1:11434/api/tags"),
    ("LM Studio", "http://127.0.0.1:1234/v1/models"),
  ]
}
