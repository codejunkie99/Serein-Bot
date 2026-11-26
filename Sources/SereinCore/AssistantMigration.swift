import Foundation

extension RelayProactive.Level {
  /// Check-ins when none was chosen: Often, so Serein speaks up without being asked first. The
  /// person turns them down or off in chat or Settings › Serein (raised from Sometimes 15 Nov
  /// 2026: "make it as proactive as possible").
  public static let newInstallDefault: RelayProactive.Level = .jarvis
}

extension RelayMemory {
  /// Note suggestions on a new install: off, so no background request uses the user's AI app.
  public static let learnsNewInstallDefault = false
}

/// "Ask Serein from any app with ⌥Space" (`serein.relay.enabled`): the global shortcuts, and with
/// them the menu bar item.
public enum GlobalAccess {
  public static let newInstallDefault = false
}

/// The one-time move to "Serein is always on in its window". Before it, `serein.relay.enabled`
/// was the whole assistant: with it off, nothing ran on its own. After it, the assistant works in
/// the window for everyone, so each setting that switch used to hold back gets an explicit value
/// that keeps what each install did before: check-ins, note suggestions and Autopilot stay what
/// they were in effect. For an install that had the assistant off, "in effect" means off even
/// when the user had once chosen Often or note suggestions (the switch held them back), its
/// stored requests and alerts are paused until the user resumes them, and outside agents allowed
/// to ask lose that permission until the user gives it again.
public enum AssistantMigration {
  public static let flagKey = "serein.assistant.migrated"
  public static let enabledKey = "serein.relay.enabled"
  public static let autopilotKey = "serein.relay.autopilot"
  public static let proactiveKey = "serein.relay.proactive"
  public static let learnsKey = "serein.relay.learnsNotes"

  public enum Write: Equatable, Sendable {
    case bool(String, Bool)
    case string(String, String)
    /// Clear "May ask Serein" on every stored outside-agent pairing.
    case clearOutsideAgentAsks
    /// Pause every stored request (action reminder) and alert (watch) that is not paused yet.
    case pauseRequestsAndWatches
    /// Add the daily morning briefing (RelayBriefing), on for a fresh install.
    case briefingOn
  }

  /// A fresh install: setup has not finished at this launch, no conversation is saved, and the
  /// assistant has no saved state. An upgrader who never finished setup still has the others.
  public static func isFreshInstall(needsFirstRun: Bool, savedConversations: Int, assistantStateExists: Bool) -> Bool {
    needsFirstRun && savedConversations == 0 && !assistantStateExists
  }

  /// The writes for one install. A key that is already set is never touched, with one
  /// exception: an existing install that had the assistant off gets check-ins and note
  /// suggestions off whatever they held, since that is what it had in effect. `approvalDefault`
  /// is `ApprovalLevel.newInstallDefault` (a parameter so the raised default can be tested): a
  /// fresh install given Only risky steps also gets `serein.approvals.defaulted`, so Serein says
  /// so once before its first routine step instead of going ahead silently. `canRunBuiltIn`: this
  /// Mac and build can run the built-in computer, so a fresh install starts with it on, setting
  /// itself up at first need; anywhere else, and on any existing install, it stays as it was.
  public static func plan(
    freshInstall: Bool, enabled: Bool?, proactive: String?, autopilot: Bool?, learnsNotes: Bool?,
    computer: Bool? = nil, canRunBuiltIn: Bool = false,
    approvalDefault: ApprovalLevel = ApprovalLevel.newInstallDefault
  ) -> [Write] {
    var writes: [Write] = []
    if freshInstall {
      if canRunBuiltIn, computer == nil {
        writes.append(.bool(ComputerPolicy.enabledKey, true))
        writes.append(.bool(ComputerPolicy.autoSetUpKey, true))
      }
      if autopilot == nil {
        if approvalDefault == .proactive {
          writes.append(.string(autopilotKey, ApprovalLevel.proactive.rawValue))
          writes.append(.bool(ApprovalLevel.defaultedKey, true))
        } else {
          writes.append(.bool(autopilotKey, approvalDefault.autopilot))
          if approvalDefault == .riskyOnly { writes.append(.bool(ApprovalLevel.defaultedKey, true)) }
        }
      }
      if proactive == nil { writes.append(.string(proactiveKey, RelayProactive.Level.newInstallDefault.rawValue)) }
      if learnsNotes == nil { writes.append(.bool(learnsKey, RelayMemory.learnsNewInstallDefault)) }
      if enabled == nil { writes.append(.bool(enabledKey, GlobalAccess.newInstallDefault)) }
      writes.append(.briefingOn)
      return writes
    }
    let wasOn = enabled == true
    if autopilot == nil { writes.append(.bool(autopilotKey, false)) }
    let off = RelayProactive.Level.off.rawValue
    if wasOn {
      if proactive == nil { writes.append(.string(proactiveKey, RelayProactive.Level.jarvis.rawValue)) }
      if learnsNotes == nil { writes.append(.bool(learnsKey, true)) }
    } else {
      // Nothing ran on its own before; nothing starts now without the user choosing it again.
      if proactive != off { writes.append(.string(proactiveKey, off)) }
      if learnsNotes != false { writes.append(.bool(learnsKey, false)) }
    }
    if enabled == nil { writes.append(.bool(enabledKey, false)) }
    if !wasOn {
      writes.append(.clearOutsideAgentAsks)
      writes.append(.pauseRequestsAndWatches)
    }
    return writes
  }

  /// Requests (action reminders) paused by the migration; plain reminders and ones already
  /// paused stay as they are.
  public static func pausing(_ reminders: [RelayReminder]) -> [RelayReminder] {
    reminders.map { reminder in
      guard reminder.action, reminder.paused != true else { return reminder }
      var copy = reminder
      copy.paused = true
      copy.pausedByUpdate = true
      return copy
    }
  }
  /// Alerts (watches) paused by the migration.
  public static func pausing(_ watches: [RelayWatch]) -> [RelayWatch] {
    watches.map { watch in
      guard watch.paused != true else { return watch }
      var copy = watch
      copy.paused = true
      copy.pausedByUpdate = true
      return copy
    }
  }

  /// Runs the migration once for `defaults`: nothing when the flag is set. `freshInstall` is only
  /// asked when the migration runs. The approval level, its consent flag and the check-in level
  /// are read and written in `gates` (GateSettings in the app), the rest in `defaults`. Returns
  /// what was written (empty the second time).
  @discardableResult public static func run(
    _ defaults: UserDefaults, gates: (any SettingsStore)? = nil, freshInstall: () -> Bool, canRunBuiltIn: Bool = false,
    clearOutsideAgentAsks: () -> Void, pauseRequestsAndWatches: () -> Void = {}, turnOnBriefing: () -> Void = {}
  ) -> [Write] {
    guard defaults.integer(forKey: flagKey) < 1 else { return [] }
    let gates: any SettingsStore = gates ?? defaults
    let writes = plan(
      freshInstall: freshInstall(),
      enabled: defaults.object(forKey: enabledKey) as? Bool,
      proactive: gates.string(forKey: proactiveKey),
      // Allow all is held as a string: any stored level counts as set.
      autopilot: gates.object(forKey: autopilotKey).map { $0 as? Bool ?? true },
      learnsNotes: defaults.object(forKey: learnsKey) as? Bool,
      computer: gates.object(forKey: ComputerPolicy.enabledKey) as? Bool, canRunBuiltIn: canRunBuiltIn)
    func store(_ key: String) -> any SettingsStore {
      [
        autopilotKey, proactiveKey, ApprovalLevel.defaultedKey, ApprovalLevel.allowAllMigratedKey,
        ComputerPolicy.enabledKey, ComputerPolicy.autoSetUpKey,
      ].contains(key)
        ? gates : defaults as any SettingsStore
    }
    for write in writes {
      switch write {
      case .bool(let key, let value): store(key).set(value, forKey: key)
      case .string(let key, let value): store(key).set(value, forKey: key)
      case .clearOutsideAgentAsks: clearOutsideAgentAsks()
      case .pauseRequestsAndWatches: pauseRequestsAndWatches()
      case .briefingOn: turnOnBriefing()
      }
    }
    defaults.set(1, forKey: flagKey)
    return writes
  }

  /// One-time upgrade to Allow all (`ApprovalLevel.proactive`), returning the writes and the
  /// previous level so the app can show a receipt with Undo. Passwords and payments stay behind
  /// the secure card. Returns nil if already migrated or if the user explicitly set a level.
  public static func allowAllUpgrade(
    stored: Any?, userSet: Bool, migrated: Bool
  ) -> (writes: [Write], previous: ApprovalLevel)? {
    guard !migrated, !userSet else { return nil }
    let previous = ApprovalLevel.resolve(stored: stored)
    let writes: [Write] = [
      .string(autopilotKey, ApprovalLevel.proactive.rawValue),
      .bool(ApprovalLevel.allowAllMigratedKey, true),
      .bool(ApprovalLevel.defaultedKey, true),
    ]
    return (writes, previous)
  }

  /// The Undo entry on the Allow all receipt; the level it replaced follows the prefix.
  public static let allowAllUndoPrefix = "setting:allow-all-from:"

  /// The Allow all upgrade at launch, after `run`: the person's own choice is read from
  /// `defaults` (`ApprovalLevel.userSetKey`), the level and its flag from `gates`. Applies the
  /// writes and returns the receipt for the chat, with Undo back to the level it replaced. nil
  /// when there is nothing to show: done before, a level the person chose, or a level that was
  /// Allow all already (a fresh install, which `run` gave Allow all).
  @discardableResult public static func allowAllLaunch(_ defaults: UserDefaults, gates: any SettingsStore) -> Receipt? {
    guard let upgrade = allowAllUpgrade(
      stored: gates.object(forKey: autopilotKey), userSet: defaults.bool(forKey: ApprovalLevel.userSetKey),
      migrated: gates.bool(forKey: ApprovalLevel.allowAllMigratedKey))
    else { return nil }
    for case .bool(let key, let value) in upgrade.writes { gates.set(value, forKey: key) }
    for case .string(let key, let value) in upgrade.writes { gates.set(value, forKey: key) }
    guard upgrade.previous != .proactive else { return nil }
    return Receipt(
      kind: .assistantChanged, line: "Done. Serein now goes ahead without asking.",
      card: .banner(
        title: ApprovalLevel.proactive.title,
        detail: "Before it was \(upgrade.previous.title). Paying and passwords still go to a secure card you fill.",
        action: "Undo"),
      undo: UndoToken(entry: allowAllUndoPrefix + upgrade.previous.rawValue, kind: .assistantChanged))
  }

  /// The level an Allow all receipt's Undo puts back; nil for any other entry.
  public static func allowAllUndo(entry: String) -> ApprovalLevel? {
    guard entry.hasPrefix(allowAllUndoPrefix) else { return nil }
    return ApprovalLevel(rawValue: String(entry.dropFirst(allowAllUndoPrefix.count)))
  }
}
