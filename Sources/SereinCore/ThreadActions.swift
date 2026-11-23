import Foundation

/// Helpers for Retry, Continue in a copy and Send to another project.
public enum ThreadActions {
  /// Retry is offered only after the last turn failed or was stopped.
  public static func canRetry(outcome: RunRecord.Outcome?, running: Bool) -> Bool {
    guard !running else { return false }
    return outcome == .stuck || outcome == .stopped
  }
  /// The most recent request in a transcript.
  public static func lastRequest(_ turns: [(role: String, text: String)]) -> String? {
    turns.last { $0.role == "you" && !$0.text.isEmpty }?.text
  }
  /// A short, local summary of a thread for the copy's first message: the opening request, the
  /// latest request when it differs, and the start of the last answer. Plain text, no model call.
  public static func forkSummary(title: String, turns: [(role: String, text: String)]) -> String {
    var lines = ["Continued from \u{201C}\(RunNow.clip(title, 60))\u{201D}. The original thread is unchanged."]
    let requests = turns.filter { $0.role == "you" && !$0.text.isEmpty }
    if let first = requests.first { lines.append("Started with: " + RunNow.clip(first.text, 240)) }
    if let last = requests.last, requests.count > 1 {
      lines.append("Latest request: " + RunNow.clip(last.text, 240))
    }
    if let answer = turns.last(where: { $0.role == "assistant" && !$0.text.isEmpty }) {
      lines.append("Last answer began: " + RunNow.clip(answer.text, 320))
    }
    return lines.joined(separator: "\n")
  }
}

/// A model the user can pick, with a one-line description of when it fits.
public struct ModelChoice: Equatable, Identifiable, Sendable {
  public enum Tier: String, Sendable { case balanced, deepest, fastest }
  public var id: String { model.isEmpty ? "default" : model }
  public var model: String
  public var name: String
  public var tier: Tier
  public var blurb: String
  /// From a live list (Codex's model/list): the model's own effort levels and its default effort.
  public var efforts: [String] = []
  public var defaultEffort: String?
  /// The model the app itself runs when none is named (Codex's `isDefault`).
  public var isDefault = false
  public init(
    model: String, name: String, tier: Tier, blurb: String, efforts: [String] = [], defaultEffort: String? = nil,
    isDefault: Bool = false
  ) {
    self.model = model
    self.name = name
    self.tier = tier
    self.blurb = blurb
    self.efforts = efforts
    self.defaultEffort = defaultEffort
    self.isDefault = isDefault
  }
}

/// What the user allowed for a project last time, so the next task there starts the same way.
public struct AccessMemory: Codable, Equatable, Sendable {
  public struct Access: Codable, Equatable, Sendable {
    public var edits: Bool
    public var actions: Bool
    public init(edits: Bool, actions: Bool) {
      self.edits = edits
      self.actions = actions
    }
  }
  public static let path = "sessions/project-access.json"
  public private(set) var byProject: [String: Access] = [:]
  public init() {}
  public func access(for projectID: String) -> Access? { byProject[projectID] }
  /// What may be remembered: project edits only. Website clicks and typing always start off.
  public static func remembering(edits: Bool) -> Access { Access(edits: edits, actions: false) }
  /// Returns true when the stored value changed. Turning both off forgets the project.
  @discardableResult
  public mutating func record(_ access: Access, project id: String) -> Bool {
    let stored = (access.edits || access.actions) ? access : nil
    guard byProject[id] != stored else { return false }
    byProject[id] = stored
    return true
  }
  public static func load(from library: Library) -> AccessMemory {
    library.load(AccessMemory.self, from: path) ?? AccessMemory()
  }
  public func save(to library: Library) throws { try library.save(self, to: Self.path) }
}
