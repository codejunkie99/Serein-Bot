#if DEBUG
import Foundation
import SereinCore

/// The built-in computer on a new install: who gets it switched on, and when its first need may
/// start the download. Synthetic facts only; nothing here downloads anything.
extension AssistantCoreChecks {
  static func builtInSetup(_ check: Check) throws {
    typealias S = BuiltInSetup
    let enough = S.freeBytesNeeded
    func decide(
      itself: Bool = true, working: Bool = false, share: Double? = nil, unattended: Bool = false, failed: Bool = false,
      online: Bool = true, metered: Bool = false, free: Int64? = nil
    ) -> S {
      S.decide(
        setsItselfUp: itself, working: working, share: share, unattended: unattended, failed: failed, online: online,
        metered: metered, freeBytes: free ?? enough)
    }

    try check(decide() == .start, "A person's run on a new install starts the download")
    try check(decide(free: enough - 1) != .start, "Too little disk never starts it")
    if case .answer(let words) = decide(free: enough - 1) {
      try check(words.contains("GB"), "Too little disk says how much it needs")
    } else {
      try check(false, "Too little disk answers in words")
    }
    try check(S.decide(setsItselfUp: true, working: false, share: nil, unattended: false, failed: false, online: true,
                       metered: false, freeBytes: nil) == .start, "A disk that can't be measured does not block it")
    try check(decide(unattended: true) != .start, "A run nobody is watching never starts the download")
    try check(decide(metered: true) != .start, "A metered connection never starts the download")
    try check(decide(online: false) != .start, "Being offline never starts the download")
    try check(decide(failed: true) != .start, "A failed download is not tried again by itself")
    try check(decide(itself: false) == .answer(VirtualMachinePolicy.notSetUp),
              "An install that did not opt in is still set up from Settings")
    try check(decide(working: true) == .answer(S.downloading(share: nil)), "A second call does not start a second download")
    try check(decide(itself: false, working: true) == .answer(S.downloading(share: nil)),
              "A download from Settings answers the same way")
    try check(decide(working: true, unattended: true, metered: true) == .answer(S.downloading(share: nil)),
              "A download under way is reported whoever asks")
    try check(S.downloading(share: 0.34).contains("34%"), "The answer says how far it is")
    try check(!S.downloading(share: nil).contains("%"), "With no share yet it gives no number")
    func wake(online: Bool = true, free: Int64 = enough) -> S {
      S.decide(setsItselfUp: false, working: false, share: nil, unattended: true, failed: true,
               online: online, metered: true, freeBytes: free, requested: true)
    }
    try check(wake() == .start, "An explicit Wake sets up the computer without an agent task or automatic setup")
    try check(wake(online: false) != .start, "Wake explains an offline Mac instead of starting a download")
    try check(wake(free: enough - 1) != .start, "Wake still requires enough disk for the computer")

    // Who gets it switched on: a new install this Mac can run it on, and nobody else.
    let on = AssistantMigration.Write.bool(ComputerPolicy.enabledKey, true)
    let itself = AssistantMigration.Write.bool(ComputerPolicy.autoSetUpKey, true)
    func plan(fresh: Bool, canRun: Bool = true, computer: Bool? = nil) -> [AssistantMigration.Write] {
      AssistantMigration.plan(
        freshInstall: fresh, enabled: nil, proactive: nil, autopilot: nil, learnsNotes: nil, computer: computer, canRunBuiltIn: canRun)
    }
    try check(plan(fresh: true).contains(on) && plan(fresh: true).contains(itself), "A new install has the computer on, setting itself up")
    try check(!plan(fresh: true, canRun: false).contains(on) && !plan(fresh: true, canRun: false).contains(itself),
              "A Mac or build that can't run it keeps it off")
    try check(!plan(fresh: false).contains(on) && !plan(fresh: false).contains(itself), "An existing install keeps what it has")
    try check(!plan(fresh: true, computer: false).contains(on) && !plan(fresh: true, computer: false).contains(itself),
              "A switch already set is never touched")

    // Both land in the gate file, which a harness shell can't write through `defaults write`.
    let suite = "serein.checks.builtin.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite), let gates = UserDefaults(suiteName: suite + ".gates") else {
      try check(false, "The check's settings could be made")
      return
    }
    defer {
      defaults.removePersistentDomain(forName: suite)
      gates.removePersistentDomain(forName: suite + ".gates")
    }
    AssistantMigration.run(defaults, gates: gates, freshInstall: { true }, canRunBuiltIn: true, clearOutsideAgentAsks: {})
    try check(gates.object(forKey: ComputerPolicy.enabledKey) as? Bool == true && ComputerPolicy.isEnabled(defaults: gates),
              "The switch is written to the gate file")
    try check(ComputerPolicy.setsItselfUp(defaults: gates), "So is setting itself up")
    try check(defaults.object(forKey: ComputerPolicy.enabledKey) == nil, "Neither is in the plain defaults")
    try check(!ComputerPolicy.setsItselfUp(defaults: defaults), "Unset means it does not set itself up")
  }
}
#endif
