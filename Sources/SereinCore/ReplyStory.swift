import Foundation

/// A short visual explanation, saved as plain JSON in a reply's story fence. No scripts, URLs,
/// remote media or arbitrary drawing commands: the host owns every frame and control.
public struct ReplyStory: Codable, Equatable, Sendable {
  public struct Scene: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public var focus: Int
    public var narration: String?
    public var emphasis: String?
    public var visual: Visual?
    public init(title: String, body: String, focus: Int, narration: String? = nil, emphasis: String? = nil, visual: Visual? = nil) {
      self.title = title; self.body = body; self.focus = focus; self.narration = narration; self.emphasis = emphasis; self.visual = visual
    }
  }
  public enum Icon: String, Codable, CaseIterable, Sendable { case page, search, compare, result, app, memory, disk, person, clock, warning, parcel, truck, cloud, energy }
  public var icons: [Icon]?
  public var title: String
  public var summary: String
  public var nodes: [String]
  public var scenes: [Scene]
  public var caveat: String

  public init(title: String, summary: String, nodes: [String], scenes: [Scene], caveat: String, icons: [Icon]? = nil) {
    self.icons = icons
    self.title = title; self.summary = summary; self.nodes = nodes; self.scenes = scenes; self.caveat = caveat
  }
  public init?(json: String) {
    guard json.utf8.count <= 12_000, let value = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)), value.valid else { return nil }
    self = value
  }
  public var valid: Bool {
    func text(_ value: String, _ limit: Int) -> Bool {
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit
        && AgentPrivacy.redact(value) == value
    }
    return text(title, 100) && text(summary, 300) && text(caveat, 350)
      && (2...4).contains(nodes.count) && Set(nodes).count == nodes.count && nodes.allSatisfy { text($0, 32) }
      && (icons == nil || icons?.count == nodes.count)
      && (2...5).contains(scenes.count) && scenes.allSatisfy {
        text($0.title, 72) && text($0.body, 300) && nodes.indices.contains($0.focus)
          && ($0.narration == nil || text($0.narration!, 500))
          && ($0.emphasis == nil || (text($0.emphasis!, 60) && ($0.narration ?? $0.body).contains($0.emphasis!)))
          && ($0.visual?.valid(nodeCount: nodes.count) ?? true)
      }
  }
  /// Speak the takeaway with the first scene and the limitation with the last, so neither can
  /// be omitted by a custom spoken script. Older stories use their existing scene captions.
  public var spokenScenes: [String] {
    scenes.indices.map { index in
      ([index == 0 ? summary : nil, scenes[index].narration ?? scenes[index].body,
        index == scenes.count - 1 ? caveat : nil].compactMap { $0 }).joined(separator: "\n\n")
    }
  }
  public var narration: String {
    spokenScenes.joined(separator: "\n\n")
  }
  /// Fallback caption reading time for the diagram. Videos use measured speech durations.
  public func seconds(_ index: Int) -> Double {
    min(18, max(7, Double((scenes[index].title + " " + scenes[index].body).split(whereSeparator: \.isWhitespace).count) / 2.4 + 2))
  }
  public var duration: Double { scenes.indices.reduce(0) { $0 + seconds($1) } }
  public func frame(at seconds: Double) -> (scene: Int, progress: Double) {
    frame(at: seconds, durations: scenes.indices.map(self.seconds))
  }
  /// The video supplies measured speech durations; the readable story keeps caption timing.
  public func frame(at seconds: Double, durations: [Double]) -> (scene: Int, progress: Double) {
    guard durations.count == scenes.count, durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { return (0, 0) }
    var remaining = max(0, seconds)
    for index in scenes.indices {
      let length = durations[index]
      if remaining < length || index == scenes.count - 1 { return (index, min(1, remaining / length)) }
      remaining -= length
    }
    return (0, 0)
  }
}

extension ResearchJob {
  /// A factual recap for existing notebooks too. Rendering this spends no model/network usage
  /// and never changes the report, its evidence, message identity or completion status.
  public var visualStory: ReplyStory {
    let claims = sources.compactMap(\.claimCheck).flatMap(\.claims)
    let supported = claims.filter { $0.outcome == .supported }.count
    let disputed = claims.filter { $0.outcome == .disputed }.count
    let weak = claims.count - supported - disputed
    let original = sources.filter { $0.comparisonOnly != true }
    let added = sources.filter { $0.comparisonOnly == true && $0.state == .checked }
    let checked = sources.filter { $0.state == .checked }.count
    let searches = followUp?.searches.filter { $0.candidates != nil } ?? []
    let failedSearches = searches.filter { $0.limitation != nil }.count
    let outcome: String
    if checksEnabled != true { outcome = "The quotations were checked. The claims have not been independently compared." }
    else if claims.isEmpty { outcome = "The available pages did not establish any independently checked claims." }
    else if disputed > 0 { outcome = "The sources disagree on \(disputed) claim\(disputed == 1 ? "" : "s"). The report keeps both sides visible." }
    else if weak > 0 { outcome = "The source checks finished, but \(weak) claim\(weak == 1 ? " still needs" : "s still need") independent support." }
    else { outcome = "Independent support was found for \(supported) claim\(supported == 1 ? "" : "s") in the saved pages." }
    var scenes: [ReplyStory.Scene] = [
      .init(title: "Started with the source material", body: "The task began with \(original.count) selected page\(original.count == 1 ? "" : "s"). \(original.filter { $0.state == .checked }.count) yielded findings with exact quotations.", focus: 0),
      .init(title: "Checked what the evidence could establish", body: totalClaims == 0 ? "The selected pages did not yield usable quoted findings, so there was no claim to independently compare." : checksEnabled == true
        ? "I matched quotations to saved text, then checked whether the pages offered support or counterevidence. A matching statement alone is not independent confirmation."
        : "I matched quotations to the saved pages. This older report did not include an independent claim comparison.", focus: 1)
    ]
    if let followUp, !followUp.initialChecks.isEmpty {
      scenes.append(.init(title: "Looked further when evidence was weak", body: "I tried \(searches.count) public search\(searches.count == 1 ? "" : "es") and read \(added.count) additional page\(added.count == 1 ? "" : "s")."
        + (failedSearches > 0 ? " \(failedSearches) search\(failedSearches == 1 ? " could" : "es could") not return usable results." : "")
        + " New pages still had to be checked before they could support a claim.", focus: 2))
    } else if !added.isEmpty {
      scenes.append(.init(title: "Compared additional sources", body: "I read \(added.count) additional page\(added.count == 1 ? "" : "s") and compared them with the original claims. The original findings stayed intact.", focus: 2))
    }
    let expanded = scenes.count > 2
    let nodes = expanded ? ["Sources", "Evidence check", "Look further", "Result"] : ["Sources", "Evidence check", "Result"]
    let icons: [ReplyStory.Icon] = expanded ? [.page, .compare, .search, .result] : [.page, .compare, .result]
    scenes.append(.init(title: "What this means", body: outcome + " \(checked) of \(sources.count) pages were checked."
      + (checksEnabled == true ? " Results: \(supported) supported, \(disputed) disputed, \(weak) still unconfirmed." : ""), focus: nodes.count - 1))
    scenes[0].visual = .init(kind: .gather, headline: "Start with the sources",
      figures: [.init(label: "Selected pages", value: original.count)])
    scenes[1].visual = .init(kind: .compare, headline: "A quote is not proof")
    if expanded { scenes[2].visual = .init(kind: .search, headline: "Look beyond the first source") }
    scenes[scenes.count - 1].visual = .init(kind: .result,
      headline: weak > 0 ? "Checked does not mean confirmed" : disputed > 0 ? "Keep the disagreement visible" : "Here is what the evidence supports",
      figures: checksEnabled == true ? [.init(label: "Supported", value: supported), .init(label: "Disputed", value: disputed), .init(label: "Unconfirmed", value: weak)] : nil)
    return ReplyStory(title: question.count <= 100 ? question : String(question.prefix(97)) + "…", summary: reportTitle + ". " + outcome,
      nodes: nodes, scenes: scenes,
      caveat: "Checked quotations establish where the words came from, not a guarantee that the claims are true.", icons: icons)
  }
}
