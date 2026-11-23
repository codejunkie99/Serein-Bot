#if DEBUG
import Foundation
import SereinCore

/// Explicit live-provider acceptance. Only a fresh, marked temporary library and synthetic
/// requests are used; normal verification never calls this function. The caller shuts Engines
/// down after, since the check exits without Serein's quit path.
@MainActor func checkLiveOpenCodeIntelligence() async throws {
  let fm = FileManager.default
  guard let path = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"],
    path.hasPrefix(fm.temporaryDirectory.path) || path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/"),
    (try? fm.contentsOfDirectory(atPath: path)) == [".serein-opencode-intelligence-check"],
    let executable = AgentModel.locate("opencode"),
    let model = ProcessInfo.processInfo.environment["SEREIN_OPENCODE_TEST_MODEL"],
    model.hasPrefix("opencode/"), model.hasSuffix("-free")
  else { throw SereinError.invalid("Use a fresh marked temporary library and an explicit OpenCode free model.") }
  // Feature switches live in GateSettings, which a check keeps in memory.
  for feature in AgentFeature.allCases {
    GateSettings.shared.set([.projectGrouping, .proofreading].contains(feature), forKey: FeaturePolicy.key(feature))
  }
  let browser = try BrowserModel(root: URL(fileURLWithPath: path))
  defer { browser.shutdown() }
  let agent = AgentModel(browser: browser, discoverProviders: false)
  agent.provider = Provider(.opencode)
  agent.model = model
  agent.pin(Provider(.opencode), executable: executable)
  guard agent.helperProvider == Provider(.opencode), agent.helperModel == model else {
    throw SereinError.invalid("The selected OpenCode model was not retained by intelligence.")
  }
  func report(_ line: String) { print(line); fflush(stdout) }
  func until(_ condition: () -> Bool) async throws {
    let end = Date().addingTimeInterval(150)
    while !condition(), Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
    guard condition() else { throw SereinError.invalid("Live intelligence check exceeded its deadline.") }
  }
  report("LIVE: installed OpenCode, model \(model); synthetic input only")
  let nonce = UUID().uuidString
  var applied = false
  var failure: String?
  browser.runIntelligence(.projectGrouping, agent: agent,
    prompt: "Return only JSON {\"marker\":\"\(nonce)\",\"sum\":42}. Do not call any tools. Synthetic arithmetic check: 19 + 23.",
    completion: { failure = $0 }) { text in
      struct Reply: Decodable { var marker: String; var sum: Int }
      let reply = try StructuredOutput.decode(Reply.self, text: text)
      guard reply.marker == nonce, reply.sum == 42 else { throw SereinError.invalid("Live response did not match the synthetic request.") }
      applied = true
    }
  try await until { !browser.intelligenceRunning(.projectGrouping) }
  guard applied, failure == nil else { throw SereinError.invalid(failure ?? browser.notice ?? "Live intelligence failed") }
  report("PASS: real free DeepSeek request completed through Serein's intelligence dispatcher and decoded/applied JSON")
  agent.draft = "hello world this is a synthetic punctuation test"
  agent.proofreadDraft()
  try await until { agent.status == "Dictation proofread. Review before sending." || agent.error != nil }
  guard agent.error == nil, !agent.draft.isEmpty,
    agent.draft.localizedCaseInsensitiveContains("synthetic") else {
    throw SereinError.invalid(agent.error ?? "Proofreading did not preserve the synthetic input.")
  }
  report("PASS: real free DeepSeek proofreading completed through the production composer action")
  let fixtures = [
    ("Atlas Recipes", "A recipe collection app for home cooks to plan meals and save ingredients."),
    ("Beacon News", "A personal news reader for following articles and newsletters."),
    ("Trip Ledger", "A travel budget planner that tracks trip expenses and itineraries."),
  ]
  for (index, fixture) in fixtures.enumerated() {
    let folder = browser.library.root.appendingPathComponent("synthetic-projects/project-\(index)")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try fixture.1.write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "{}".write(to: folder.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    var project = Project(name: fixture.0, path: folder.path)
    project.placement = .project
    browser.projects.append(project)
  }
  browser.refreshProjectKindsNow()
  let ids = Set(browser.projects.map(\.id))
  let purpose = ProjectPurposeStore.shared
  purpose.arrange(browser: browser, agent: agent, order: browser.projects.map(\.id))
  try await until { !purpose.busy(browser) }
  let persisted = browser.library.load([ProjectArea].self, from: ProjectPurposeStore.path) ?? []
  guard !persisted.isEmpty, Set(persisted.flatMap(\.projectIDs)) == ids,
    Set(purpose.current(browser).flatMap(\.projectIDs)) == ids else {
    throw SereinError.invalid("Live Sort by purpose failed: \(purpose.status); \(browser.notice ?? "")")
  }
  report("PASS: real free DeepSeek Sort by purpose read three synthetic briefs, validated every project and persisted the arrangement")
  guard browser.tasks.isEmpty, agent.hub.runs.isEmpty else { throw SereinError.invalid("Intelligence created an unexpected visible run or capability.") }
  report("PASS: live intelligence created no browser capabilities or visible agent runs")
}
#endif
