#if DEBUG
import Combine
import Foundation
import SereinCore

/// Synthetic cache and append-log benchmarks. They never open a user's projects or history.
@MainActor func checkBackgroundPerformance() throws {
  func check(_ value: @autoclosure () -> Bool, _ reason: String) {
    precondition(value(), "Background performance check: " + reason)
  }
  func milliseconds(_ work: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("serein-background-perf-\(UUID().uuidString)")
  defer { try? fm.removeItem(at: root) }
  let oldLibrary = try Library(root: root.appendingPathComponent("before"))
  let library = try Library(root: root.appendingPathComponent("after"))
  let titles = Dictionary(uniqueKeysWithValues: (0..<400).map { index in
    (root.appendingPathComponent("fixtures/project-\(index)").path,
      (0..<5).map { "Synthetic project \(index), session \($0)" })
  })
  var baseline: [String: ProjectInsight] = [:]
  let oldInitial = try milliseconds {
    for (path, values) in titles {
      var item = baseline[ProjectInsights.key(path)] ?? ProjectInsight()
      item.sessionTitles = values
      baseline[ProjectInsights.key(path)] = item
      try ProjectInsight.saveAll(baseline, library: oldLibrary)
    }
  }
  let insights = ProjectInsights()
  var publications = 0
  let subscription = insights.$all.dropFirst().sink { _ in publications += 1 }
  let newInitial = milliseconds { insights.setTitles(titles, library: library) }
  check(insights.all == baseline, "a batch has the exact same title membership and contents")
  check(publications == 1, "400 initial projects publish once")
  check(ProjectInsight.loadAll(library: library) == baseline, "batch persisted the complete cache")
  let oldRepeat = try milliseconds {
    for (path, values) in titles {
      var item = baseline[ProjectInsights.key(path)] ?? ProjectInsight()
      item.sessionTitles = values
      baseline[ProjectInsights.key(path)] = item
      try ProjectInsight.saveAll(baseline, library: oldLibrary)
    }
  }
  let cacheFile = library.root.appendingPathComponent(ProjectInsight.path)
  let beforeAttributes = try fm.attributesOfItem(atPath: cacheFile.path)
  let newRepeat = milliseconds { insights.setTitles(titles, library: library) }
  let afterAttributes = try fm.attributesOfItem(atPath: cacheFile.path)
  check(publications == 1, "unchanged discovery publishes nothing")
  check(beforeAttributes[.modificationDate] as? Date == afterAttributes[.modificationDate] as? Date,
    "unchanged discovery does not rewrite the cache")
  let path = titles.keys.sorted()[0]
  let git = GitSummary(branch: "synthetic", commits: ["Synthetic commit"])
  insights.setGit(git, for: path, library: library)
  insights.setGit(git, for: path, library: library)
  check(publications == 2, "identical Git evidence publishes nothing")
  insights.setTitles([path: ["Updated synthetic title"]], library: library)
  check(insights.all[ProjectInsights.key(path)]?.git == git, "title merge preserves Git facts")
  withExtendedLifetime(subscription) {}

  // Build one append log with repeated updates, just as run progress is stored in production.
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  var log = Data()
  for event in 0..<10_000 {
    var run = RunRecord(id: "run-\(event % 1000)", threadID: "t", provider: "synthetic", mode: "project",
      projectID: "p-\(event % 100)", title: "Synthetic task", startedAt: Date(timeIntervalSince1970: Double(event % 1000)))
    run.toolCount = event
    run.lastEventAt = run.startedAt.addingTimeInterval(Double(event))
    log.append(try encoder.encode(run))
    log.append(10)
  }
  let runFile = library.root.appendingPathComponent(Library.runLogPath)
  try log.write(to: runFile)
  var reader = RunLogSnapshotReader(library: library)
  let oldRun = milliseconds { _ = library.runs() }
  let newRun = milliseconds { _ = reader.snapshot() }
  check(reader.snapshot() == library.runs(), "incremental first snapshot matches latest-run winners")
  let oldPoll = milliseconds { for _ in 0..<5 { _ = library.runs() } } / 5
  let bytesBeforePoll = reader.bytesRead
  let newPoll = milliseconds { for _ in 0..<5 { _ = reader.snapshot() } } / 5
  check(reader.bytesRead == bytesBeforePoll, "unchanged log polls read no content")
  var appended = RunRecord(id: "run-0", threadID: "t", provider: "synthetic", mode: "project",
    projectID: "p-0", title: "Synthetic task", startedAt: Date(timeIntervalSince1970: 0))
  appended.outcome = .done
  try library.appendRun(appended)
  let oldAppend = milliseconds { _ = library.runs() }
  let decodedBefore = reader.decodedRecords
  let newAppend = milliseconds { _ = reader.snapshot() }
  check(reader.decodedRecords == decodedBefore + 1, "one append decodes one new record")
  check(reader.snapshot() == library.runs(), "appended snapshot preserves exact winners")
  let report = String(format:
    "PASS: background synthetic benchmark; 400-project initial %.2f → %.2f ms, unchanged %.2f → %.2f ms (400 → 0 saves/publications); 10,000-line log initial %.2f → %.2f ms, unchanged poll %.2f → %.3f ms, one-record append %.2f → %.3f ms\n",
    oldInitial, newInitial, oldRepeat, newRepeat, oldRun, newRun, oldPoll, newPoll, oldAppend, newAppend)
  FileHandle.standardOutput.write(Data(report.utf8))
}
#endif
