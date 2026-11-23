#if DEBUG
import Foundation
import SereinCore

/// The onboarding pages (FirstRunPage.swift): which page opens, the resume after a restart, the end once
/// setup is finished. Defaults are a throwaway suite, never the app's.
extension AssistantCoreChecks {
  static func firstRun(_ check: Check) throws {
    typealias Page = FirstRunPage
    try check(Page.allCases.allSatisfy { Page.page(setupFinished: true, saved: $0) == nil } && Page.page(setupFinished: true, saved: nil) == nil,
      "first run: a finished setup opens the app whatever page was saved")
    try check(Page.page(setupFinished: false, saved: nil) == .connect, "first run: a new person starts at connect")
    try check(Page.page(setupFinished: false, saved: .mac) == .mac && Page.page(setupFinished: false, saved: .connect) == .connect,
      "first run: a saved page is where the person comes back to, as after Reopen Serein")
    try check(Page.connect.back() == nil && Page.mac.back() == .connect,
      "first run: Back from Mac is connect, and connect has none")

    var deferred = SereinChatSetupState()
    try check(deferred.begin(in: "first-run") && deferred.skip(in: "first-run") && deferred.phase == .skipped
      && deferred.selectedHarness == nil && deferred.holdsCheckIns(firstRunFinished: true),
      "first run: deferring provider setup selects no harness and holds scheduled check-ins")

    let name = "serein.checks.firstRun.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
      try check(false, "first run: a throwaway defaults suite opens")
      return
    }
    defer { defaults.removePersistentDomain(forName: name) }
    let fresh = Page.page(defaults)
    Page.save(.mac, defaults)
    let resumed = Page.page(defaults)
    Page.save(nil, defaults)
    var progress = SetupProgress.load(defaults)
    progress.finished = true
    progress.save(defaults)
    let finished = Page.page(defaults)
    try check(fresh == .connect && resumed == .mac && defaults.string(forKey: Page.savedKey) == nil && finished == nil,
      "first run: this Mac's defaults open connect, resume at a saved Mac page, and open the app once setup is finished")
    defaults.removePersistentDomain(forName: name)
    defaults.set(true, forKey: SetupProgress.legacyImportKey)
    try check(!SetupProgress.needsFirstRun(defaults) && Page.page(defaults) == nil,
      "first run: a Mac set up by the older import flow opens the app")
  }
}
#endif
