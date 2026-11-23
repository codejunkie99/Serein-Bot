#if DEBUG
import Foundation
import SereinCore

@MainActor
func checkBrowserOnboarding() async {
  func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assert(condition(), "Browser onboarding check failed: \(message)")
  }
  func wait(
    _ message: String, timeout: TimeInterval = 10, until condition: @escaping () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    assertionFailure("Browser onboarding check timed out: \(message)")
    return false
  }

  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "serein-browser-onboarding-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  do {
    let browser = try BrowserModel(root: root.appendingPathComponent("Library"))
    defer { browser.shutdown() }

    let profileRoot = root.appendingPathComponent("Synthetic Profile", isDirectory: true)
    let profile = BrowserImportProfile(
      browser: "Synthetic", profile: "Cancellation", directory: profileRoot,
      bookmarks: nil, history: nil, bookmarkFormat: nil)
    let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    let visits = (0..<2_000).map { index -> Visit in
      var visit = Visit(
        url: "https://example.com/import/\(index)", title: "Imported visit \(index)", text: "")
      visit.date = baseDate.addingTimeInterval(Double(index))
      return visit
    }
    let mark = Mark(title: "Imported bookmark", url: "https://example.com/saved", quote: "")
    let sourceVisitIDs = Set(visits.map(\.id))

    let model = BrowserImportModel(profiles: [profile])
    model.previews[profile.id] = BrowserImportPreview(
      profile: profile, bookmarks: [mark], visits: visits)
    model.importPreview(into: browser)

    guard await wait("writer did not persist a partial import while busy", until: {
      let count = browser.library.visits().count
      return count > 0 && count < visits.count && model.busy
    }) else { return }

    model.cancel()
    check(model.busy, "cancel exposed retry before the writer reconciled")
    check(
      model.phase == "Cancelling import and checking saved records…",
      "cancel did not report reconciliation")

    guard await wait("cancelled import did not reconcile", until: { !model.busy }) else { return }
    let cancelledVisits = browser.library.visits()
    let cancelledIDs = cancelledVisits.map(\.id)
    check(!cancelledVisits.isEmpty, "cancel discarded visits already written")
    check(
      cancelledIDs.count == Set(cancelledIDs).count && Set(cancelledIDs).isSubset(of: sourceVisitIDs),
      "cancelled import left duplicate or unknown visit IDs on disk")
    check(
      Set(browser.visits.map(\.id)) == Set(cancelledIDs),
      "cancel reconciliation left the UI out of sync with disk")

    model.importPreview(into: browser)
    check(model.busy, "retry did not start after reconciliation")
    guard await wait("retry did not finish", until: { !model.busy }) else { return }

    let persistedVisits = browser.library.visits()
    let persistedVisitIDs = persistedVisits.map(\.id)
    let persistedMarks = browser.library.load([Mark].self, from: "marks/saved.json") ?? []
    check(model.completed, "retry did not complete")
    check(
      persistedVisitIDs.count == visits.count && Set(persistedVisitIDs) == sourceVisitIDs,
      "retry did not persist every source visit exactly once")
    check(
      persistedMarks.count == 1 && persistedMarks.first?.id == mark.id,
      "retry did not persist the source bookmark exactly once")
    check(
      Set(browser.visits.map(\.id)) == sourceVisitIDs
        && browser.marks.map(\.id) == persistedMarks.map(\.id),
      "completed retry left the UI out of sync with disk")
  } catch {
    assertionFailure("Browser onboarding check could not create its synthetic library: \(error)")
  }
}
#endif
