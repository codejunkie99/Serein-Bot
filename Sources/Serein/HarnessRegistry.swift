import AppKit
import Combine
import Foundation
import SereinCore
import SereinEngines

/// Every harness Serein can drive: the user's instance settings, and a snapshot per instance
/// (installed, version, sign-in, models, what Serein can enforce). Probes run off the main
/// actor with timeouts, at launch for the chosen apps only, on demand, and when a harness's
/// CLI or model file changes on disk (ModelSourceWatcher, no polling); none makes a model call,
/// updates a CLI or writes its configuration.
@MainActor final class HarnessRegistry: ObservableObject {
  static let shared = HarnessRegistry()

  @Published private(set) var settings = HarnessSettings()
  @Published private(set) var snapshots: [HarnessDriver: HarnessSnapshot] = [:]
  @Published private(set) var refreshing: Set<HarnessDriver> = []
  /// PATH from the user's login shell, captured once at launch (GUI apps do not inherit it).
  private(set) var shellPath: String?
  /// The login shell's environment, captured with its PATH. Only own-setup runs get it (API keys
  /// and tokens their MCP servers read).
  private(set) var shellEnvironment: [String: String] = [:]
  private var library: Library?
  private var startup: Task<Void, Never>?
  /// Turned off for UI previews and checks that must not spawn CLIs.
  var probesEnabled = true
  /// Called after any snapshot changes (AgentModel mirrors availability).
  var onChange: (() -> Void)?
  /// When each model was first listed (ModelWatch), kept in the library. Previews seed it.
  @Published var watch = ModelWatch()
  /// Called after a harness's list was recorded, with the models it added since its last list.
  var onModelsListed: ((Provider, [HarnessModel]) -> Void)?

  private init() {
    for instance in settings.instances { snapshots[instance.driver] = HarnessSnapshot(instance: instance) }
  }

  func configure(library: Library) {
    guard self.library == nil else { return }
    self.library = library
    settings = HarnessSettings.load(from: library)
    watch = library.load(ModelWatch.self, from: ModelWatch.path) ?? ModelWatch()
    for instance in settings.instances { snapshots[instance.driver] = HarnessSnapshot(instance: instance) }
    checkKeys()
  }

  /// Captures the login-shell PATH and probes the chosen AI apps (HarnessLaunchProbes); other
  /// enabled apps wait (`deferred`), turned-off ones are only located. After that, changes on
  /// disk say when to probe a harness again.
  func start() {
    guard probesEnabled, startup == nil else { return }
    ModelSourceWatcher.shared.onChange = { [weak self] driver, change in self?.sourceChanged(driver, change) }
    let defaults = UserDefaults.standard
    let launch = HarnessLaunchProbes.drivers(
      newChats: defaults.data(forKey: AgentModel.taskDefaultKey)
        .flatMap { try? JSONDecoder().decode(RoutedChoice.self, from: $0) }?.provider,
      relay: defaults.string(forKey: RelayOrchestrator.providerKey).map(Provider.init(rawValue:)),
      helpers: Set(HelperWire.drivers))
    deferred = Set(settings.instances.filter { $0.enabled && !launch.contains($0.driver) }.map(\.driver))
    let skipped = deferred
    startup = Task { [weak self] in
      await self?.captureShellPath()
      await self?.refreshAll(except: skipped)
    }
  }
  /// Enabled AI apps left unprobed at launch: nothing knows yet whether they are installed or
  /// signed in. A send to one waits for its probe (AgentModel.send's "Finding…"), the first ask
  /// for one's models probes it (`models`), and setup probes them all.
  private var deferred: Set<HarnessDriver> = []
  /// Probes the given AI apps left unprobed at launch (all of them by default), once, after the
  /// login-shell PATH is in. For the model picker and Settings › AI apps to call when they open.
  func probeDeferred(_ only: Set<HarnessDriver>? = nil) {
    let drivers = only.map { $0.intersection(deferred) } ?? deferred
    guard !drivers.isEmpty else { return }
    deferred.subtract(drivers)
    let startup = startup
    Task {
      await startup?.value
      await withTaskGroup(of: Void.self) { group in
        for driver in drivers { group.addTask { await self.refresh(driver) } }
      }
    }
  }
  /// Some enabled AI app has not been checked yet (`deferred`).
  var hasUnchecked: Bool { !deferred.isEmpty }
  /// Checks every AI app left unprobed at launch and returns once they are checked: for a chat
  /// that needs another AI app now (a usage limit), where "Not checked yet" would count as none.
  func probeDeferredNow() async {
    let drivers = deferred
    guard !drivers.isEmpty else { return }
    deferred.subtract(drivers)
    await startup?.value
    await withTaskGroup(of: Void.self) { group in
      for driver in drivers { group.addTask { await self.refresh(driver) } }
    }
  }
  /// A CLI update, a provider's model file with other models, or a newer release recorded by
  /// the CLI's own update check, seen on disk: check that harness now.
  func sourceChanged(_ driver: HarnessDriver, _ change: ModelSourceWatcher.Change) {
    if driver == .codex, change != .version, let path = snapshots[.codex]?.path {
      if change == .cli { CodexAppServerProbe.forget(path) }
      // The server lists models again (a new start reads the new CLI and its cache).
      CodexAppServer.existing(path)?.reload()
      if change == .models { return }
    }
    Task { await refresh(driver, force: true) }
  }

  private func captureShellPath() async {
    guard shellPath == nil else { return }
    let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
    let result = await HarnessProbe.run(
      shell, ["-ilc", LoginShellPath.environmentCommand], environment: ProcessInfo.processInfo.environment,
      timeout: 5, grouped: false)
    shellPath = LoginShellPath.parse(result.output)
    shellEnvironment = LoginShellPath.parseEnvironment(result.output)
  }

  // MARK: Settings

  func instance(_ driver: HarnessDriver) -> HarnessInstance { settings.instance(driver) }
  func update(_ instance: HarnessInstance) {
    settings.update(instance)
    if let library { try? settings.save(to: library) }
    Task { await refresh(instance.driver) }
  }
  /// "Use my own setup" on or off (HarnessInstance.ownSetup).
  func setOwnSetup(_ driver: HarnessDriver, _ on: Bool) {
    var i = instance(driver)
    i.ownSetup = on ? true : nil
    update(i)
  }
  /// Puts an instance back exactly as given (checks swap in a fake CLI and restore it after).
  func restore(_ instance: HarnessInstance) {
    settings.update(instance)
    if let library { try? settings.save(to: library) }
    snapshots[instance.driver] = HarnessSnapshot(instance: settings.instance(instance.driver))
  }
  /// The user's own choice; setup never overrides it afterwards.
  func setEnabled(_ driver: HarnessDriver, _ on: Bool) {
    var i = instance(driver)
    i.enabled = on
    i.userChose = true
    update(i)
  }
  /// First-run setup: probes every installed harness (also the ones that are off), then turns on
  /// the detected ones that are signed in and offered for Answer or Research, unless the user
  /// already chose. Returns the drivers it turned on.
  @discardableResult func detectForSetup() async -> [HarnessDriver] {
    await refreshAll(includeDisabled: true)
    var turnedOn: [HarnessDriver] = []
    for instance in settings.instances where HarnessSetup.shouldAutoEnable(instance, snapshot: snapshots[instance.driver]) {
      var updated = instance
      updated.enabled = true
      settings.update(updated)
      turnedOn.append(instance.driver)
    }
    if !turnedOn.isEmpty {
      if let library { try? settings.save(to: library) }
      for driver in turnedOn { await refresh(driver) }
    }
    return turnedOn
  }

  // MARK: API keys

  /// Instances whose API key item may exist in Keychain (Settings › AI apps › API key): the model
  /// list's "your key". Only the item's presence is kept; the key is read only when a CLI starts.
  @Published private(set) var keyed: Set<HarnessDriver> = []
  /// Distinct per library, as ProviderStore's, so checks and previews with their own library
  /// never read or change the person's real key.
  private func keyItem(_ driver: HarnessDriver) -> KeychainItem {
    KeychainItem(service: "local.serein.harness-key", account: "\(library?.root.path ?? "unconfigured")#\(instance(driver).id)")
  }
  func hasKey(_ driver: HarnessDriver) -> Bool { keyed.contains(driver) }
  /// Existence only (KeychainItem.mayExist): a locked keychain counts as present (when in doubt,
  /// the paid label).
  private func checkKeys() {
    keyed = Set(HarnessDriver.allCases.filter { keyItem($0).mayExist })
  }
  /// Replaces the instance's key (this Mac only, readable while it is unlocked) and records the
  /// variable it is given as; that name also leaves the plain-text environment. The key is never
  /// logged and never written anywhere but Keychain.
  func saveKey(_ value: String, name: String, for driver: HarnessDriver) throws {
    let name = name.trimmingCharacters(in: .whitespaces)
    guard ModelRoutes.isKeyName(name), HarnessEnvironment.allowed(name: name, driver: driver) else {
      throw SereinError.invalid("Name the variable the key goes in, ending in _API_KEY.")
    }
    guard !value.isEmpty else { throw SereinError.invalid("Enter the key.") }
    guard let library else { throw SereinError.invalid("Serein's library is unavailable.") }
    guard keyItem(driver).replace(with: value) else {
      checkKeys()
      throw SereinError.invalid("Could not save the key in Keychain.")
    }
    keyed.insert(driver)
    var i = instance(driver)
    i.keyName = name
    i.environment[name] = nil
    settings.update(i)
    reloadCodex(driver)
    Task { await refresh(driver) }
    // A plain-text copy still on disk must not look moved.
    do { try settings.save(to: library) } catch {
      throw SereinError.invalid("The key is in Keychain, but \(name) is still in Serein's library: \(error.localizedDescription)")
    }
  }
  func removeKey(_ driver: HarnessDriver) throws {
    guard keyItem(driver).replace(with: nil) else {
      throw SereinError.invalid("Could not remove the key from Keychain.")
    }
    keyed.remove(driver)
    var i = instance(driver)
    i.keyName = nil
    update(i)
    reloadCodex(driver)
  }
  /// Codex's app server keeps the environment it started with: an idle one starts again with the
  /// new key (a busy one after its turns).
  private func reloadCodex(_ driver: HarnessDriver) {
    if driver == .codex, let path = snapshots[.codex]?.path { CodexAppServer.existing(path)?.reload() }
  }
  /// API key names still in the instance's plain-text environment (saved before the key field).
  /// Nothing moves them on its own: Settings shows a warning with Move to Keychain.
  static func plainKeys(_ instance: HarnessInstance) -> [String] {
    instance.environment.keys.filter { ModelRoutes.isKeyName($0) }.sorted()
  }
  /// Move to Keychain: the first plain-text key goes into the key field's item and out of the
  /// library's JSON. It never replaces a saved key under another name, which would be lost.
  func moveKeyToKeychain(_ driver: HarnessDriver) throws {
    let i = instance(driver)
    guard let name = Self.plainKeys(i).first, let value = i.environment[name] else { return }
    if keyed.contains(driver), let saved = i.keyName, saved != name {
      throw SereinError.invalid("\(saved) is already in Keychain for \(i.name). Remove it first to move \(name).")
    }
    try saveKey(value, name: name, for: driver)
  }
  /// The variable the person's Keychain key for this harness is given as; nil without a driver,
  /// a saved item, a name, or with a name Serein keeps for itself.
  func keyVariable(_ provider: Provider) -> String? {
    guard let driver = provider.driver, keyed.contains(driver), let name = instance(driver).keyName,
      HarnessEnvironment.allowed(name: name, driver: driver)
    else { return nil }
    return name
  }
  /// The person's Keychain key under its variable, for that harness's child only; [:] when there
  /// is none. The only place the key is read.
  func keyEnvironment(_ provider: Provider) -> [String: String] {
    guard let name = keyVariable(provider), let driver = provider.driver, let value = keyItem(driver).read() else {
      return [:]
    }
    return [name: value]
  }
  /// The user's extra variables plus the Keychain key: what a CLI Serein starts through
  /// `environment` (a run, a helper, a probe) gets.
  private func childExtra(_ instance: HarnessInstance) -> [String: String] {
    instance.safeEnvironment.merging(keyEnvironment(Provider(instance.driver))) { _, key in key }
  }
  /// What a driver adds to its CLI's environment (TurnRequest.environment): `childExtra`, the
  /// login shell's PATH, and under `ownSetup` the login shell's environment, as `environment` gives
  /// the app's own launches. A model of a provider connection (ProviderStore.run) also gets that
  /// connection's variables and the id its CLI takes; for Claude Code none of the person's own
  /// routing variables (ProviderRun.routesClaude), and the driver drops the app's (providerTurn).
  func prepare(_ request: inout TurnRequest, ownSetup: Bool) throws {
    let driver = request.cli
    var env = ownSetup ? shellEnvironment.filter { HarnessEnvironment.allowed(name: $0.key, driver: driver) } : [:]
    env.merge(childExtra(instance(driver))) { _, mine in mine }
    if let table = try ProviderStore.shared.run(driver, model: request.model) {
      if driver == .claude { env = env.filter { !ProviderRun.routesClaude($0.key) } }
      env.merge(table.environment) { _, table in table }
      request.model = table.model
      request.providerTurn = true
      request.directHTTP = table.direct
    }
    env["PATH"] = shellPath
    request.environment = env
  }

  /// UI previews: fixed snapshots, no probes.
  func installPreview(_ snapshots: [HarnessDriver: HarnessSnapshot], settings: HarnessSettings) {
    probesEnabled = false
    self.settings = settings
    self.snapshots = snapshots
    onChange?()
  }

  // MARK: Lookups

  func name(_ provider: Provider) -> String {
    guard let driver = provider.driver else { return provider.rawValue }
    return instance(driver).name
  }
  func snapshot(_ provider: Provider) -> HarnessSnapshot? { provider.driver.flatMap { snapshots[$0] } }
  #if DEBUG
  /// Checks: what a probe would have found, with no probe run; nil forgets it.
  func assume(_ driver: HarnessDriver, _ snapshot: HarnessSnapshot?) { snapshots[driver] = snapshot }
  #endif
  /// The app's own answer said it is signed out (AgentHub.finish). It counts as signed out until
  /// its next check, so a message waits for its sign-in and does not fail again.
  func markSignedOut(_ provider: Provider) {
    guard let driver = provider.driver, var snapshot = snapshots[driver], snapshot.signedIn != false else { return }
    snapshot.signedIn = false
    snapshot.status = .needsSignIn
    snapshot.message = driver.signedOutReason ?? "Not signed in"
    snapshots[driver] = snapshot
    // Gemini's kept session probe would read it as signed in again at the next check.
    if driver == .gemini { sessionProbes.removeAll() }
  }
  /// Enabled instances, in driver order (the picker rail and the Tasks menu).
  /// Instances checked and found missing are left out (they stay in Settings and setup).
  var enabledProviders: [Provider] {
    settings.instances.filter { instance in
      if instance.driver == .opencode, ProviderStore.shared.enabled.contains(where: { $0.directHTTP == true }) { return true }
      guard instance.enabled else { return false }
      guard let s = snapshots[instance.driver], s.checkedAt != nil else { return true }
      return s.installed
    }.map { Provider($0.driver) }
  }
  /// The executable for an enabled, installed instance.
  func executable(_ provider: Provider) -> String? {
    guard let driver = provider.driver, instance(driver).enabled, let s = snapshots[driver], s.installed else {
      return nil
    }
    return s.path
  }
  /// The harness's models; New also for two weeks after a model first appeared in its list.
  func models(_ provider: Provider) -> [HarnessModel] {
    guard let driver = provider.driver else { return [] }
    // Every model list reads through here (the composer, the picker, Settings); a Task, so a
    // view's body never publishes.
    if deferred.contains(driver) { Task { self.probeDeferred([driver]) } }
    let listed: [HarnessModel]
    switch driver {
    case .codex:
      listed = HarnessParse.codexModels(CodexCatalog.shared.models)
    case .claude:
      let models = snapshots[driver]?.models ?? []
      // Anthropic-wire connections' models come after Claude Code's own (ProviderStore).
      listed = Self.ownDefault(models.isEmpty ? Self.claudeManifest?.models(cliVersion: nil) ?? [] : models, own: Self.claudeOwn)
        + ProviderStore.shared.claudeModels
    default:
      listed = snapshots[driver]?.models ?? []
    }
    var all = listed
    if driver == .opencode {
      let known = Set(listed.map(\.id))
      for c in ProviderStore.shared.enabled where c.directHTTP == true && c.wire == .openai {
        for model in c.models where !known.contains(c.openCodeID + "/" + model) {
          all.append(HarnessModel(id: c.openCodeID + "/" + model, name: model))
        }
      }
    }
    let now = Date()
    return ProviderStore.shared.decorate(all, driver: driver).map { model in
      var model = model
      if !model.isNew, watch.isNew(provider.rawValue, model.id, now: now) { model.isNew = true }
      return model
    }
  }
  /// The model a Claude Code run gets when the chat picked none: the list's default, named on the
  /// pill. Empty when the person's own setting names a model the list lacks: Claude Code picks.
  static var claudeStandard: String {
    ownDefault(claudeManifest?.models(cliVersion: nil) ?? [], own: claudeOwn).first(where: \.isDefault)?.id ?? ""
  }
  /// Claude Code's own model setting, read once: ANTHROPIC_MODEL, else `model` in its user settings.
  nonisolated static let claudeOwn: String? = claudeOwnModel()
  nonisolated static func claudeOwnModel(env: [String: String] = ProcessInfo.processInfo.environment,
                             home: String = NSHomeDirectory()) -> String? {
    if let model = env["ANTHROPIC_MODEL"], !model.isEmpty { return model }
    let path = (env["CLAUDE_CONFIG_DIR"] ?? home + "/.claude") + "/settings.json"
    guard let data = FileManager.default.contents(atPath: path),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let model = json["model"] as? String, !model.isEmpty else { return nil }
    return model
  }
  /// The person's own model is the default row; an alias ("opus") is its newest listed model.
  /// One the list lacks leaves no default, so nothing is named that will not run.
  nonisolated static func ownDefault(_ listed: [HarnessModel], own: String?) -> [HarnessModel] {
    guard let own else { return listed }
    let base = ClaudeModelID.split(own).base.lowercased()
    let id = listed.first { $0.id == base }?.id ?? listed.first { !$0.isLegacy && $0.id.contains("-\(base)-") }?.id
    return listed.map { var model = $0; model.isDefault = model.id == id; return model }
  }
  /// The listed model a chat's model id stands for; no id is the harness's listed default.
  func chosen(_ provider: Provider, _ id: String) -> HarnessModel? {
    let base = ClaudeModelID.split(id).base
    let listed = models(provider)
    return listed.first { $0.id == base } ?? (base.isEmpty ? listed.first(where: \.isDefault) : nil)
  }
  /// Records the harness's current list; models it added since the last list go to onModelsListed.
  func noteModels(_ provider: Provider) {
    let before = watch
    let ids = models(provider).map(\.id)
    let arrived = Set(watch.record(provider.rawValue, ids: ids, now: Date()))
    if watch != before, let library {
      try? FileManager.default.createDirectory(
        at: library.root.appendingPathComponent("agents"), withIntermediateDirectories: true)
      try? library.save(watch, to: ModelWatch.path)
    }
    onModelsListed?(provider, models(provider).filter { arrived.contains($0.id) })
  }
  /// Models the CLI refused this session ("provider:model"), shown as Unavailable in the picker.
  @Published private(set) var unavailableModels: Set<String> = []
  func isUnavailable(_ provider: Provider, _ model: String) -> Bool {
    unavailableModels.contains(provider.rawValue + ":" + ClaudeModelID.split(model).base)
  }
  /// After a run: when the CLI refused the chosen model, mark it for the rest of the session.
  /// The CLI's own message stays as the run's error in the task panel. `failing` is the call that
  /// decides the turn's outcome (AgentHub.complete): there a short reply counts only when the turn
  /// ran no tool step, so an answer that merely mentions a missing model does not fail the turn.
  func noteModelRejection(_ run: AgentRun, failing: Bool = false) {
    let model = ClaudeModelID.split(run.spec.model).base
    guard !model.isEmpty else { return }
    let last = run.transcript.last { $0.role == "assistant" }
    let reply = last?.text ?? ""
    // Any tracked activity (CLI or browser step) means the model ran, so its text is an answer.
    let ranTools = !run.steps.isEmpty || run.nowAt != nil || !(last?.activities ?? []).isEmpty
    let replyCounts = reply.count < 600 && !(failing && ranTools)
    let text = (run.error ?? "") + "\n" + (replyCounts ? reply : "")
    guard HarnessParse.modelRejected(text) else { return }
    unavailableModels.insert(run.spec.provider.rawValue + ":" + model)
    if run.error == nil { run.error = String(reply.prefix(400)) }
  }
  func capabilities(_ provider: Provider) -> HarnessCapabilities {
    provider.driver.map { snapshots[$0]?.capabilities ?? .base($0) } ?? HarnessCapabilities()
  }
  func verdict(_ provider: Provider, mode: String, edits: Bool, permission: RunPermissionMode, relay: Bool = false) -> HarnessVerdict {
    guard let driver = provider.driver else { return .refused("Unknown agent \(provider.rawValue).") }
    if let reason = HarnessVersionGate.refusal(driver: driver, version: snapshot(provider)?.version, mode: mode) {
      return .refused(reason)
    }
    // Gemini CLI: no ACP mode to start, or a probe whose session asked for sign-in (Serein never
    // signs in for it): nothing starts.
    if snapshot(provider)?.lacksACPMode == true { return .refused(HarnessSnapshot.noACPMode) }
    if let reason = driver.signedOutReason, snapshot(provider)?.signedIn == false { return .refused(reason) }
    return HarnessPolicy.verdict(
      driver: driver, capabilities: capabilities(provider), mode: mode, edits: edits, permission: permission, relay: relay)
  }

  /// The environment for probes and runs: PATH with the executable's folder and the login
  /// shell's PATH, the driver's no-update switches, and the user's extra variables.
  nonisolated static func environment(
    executable: String, driver: HarnessDriver, shellPath: String?, extra: [String: String],
    shell: [String: String] = [:]
  ) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for (k, v) in shell where HarnessEnvironment.allowed(name: k, driver: driver) { env[k] = v }
    for (k, v) in extra where HarnessEnvironment.allowed(name: k, driver: driver) { env[k] = v }
    let dirs =
      [URL(fileURLWithPath: executable).deletingLastPathComponent().path]
      + LoginShellPath.searchPath(shell: shellPath, inherited: env["PATH"], home: NSHomeDirectory())
    var seen = Set<String>()
    env["PATH"] = dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
    for (k, v) in driver.quietEnvironment { env[k] = v }
    env.removeValue(forKey: "CLAUDECODE")
    env.removeValue(forKey: "CODEX_THREAD_ID")
    return env
  }
  /// `ownSetup`: a run whose grant says own setup (OwnSetup.applies), which alone gets the login
  /// shell's environment; helpers, probes and every other run never do. The instance's Keychain
  /// key is added here (childExtra), never stored with the environment.
  func environment(_ provider: Provider, executable: String, ownSetup: Bool = false) -> [String: String] {
    guard let driver = provider.driver else { return ProcessInfo.processInfo.environment }
    return Self.environment(
      executable: executable, driver: driver, shellPath: shellPath, extra: childExtra(instance(driver)),
      shell: ownSetup ? shellEnvironment : [:])
  }

  nonisolated static func locate(_ driver: HarnessDriver, override: String?, shellPath: String?) -> String? {
    let fm = FileManager.default
    if let override, override.hasPrefix("/") {
      return fm.isExecutableFile(atPath: override) ? override : nil
    }
    let dirs = LoginShellPath.searchPath(
      shell: shellPath, inherited: ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory())
    for name in driver.binaries {
      if let hit = dirs.map({ $0 + "/" + name }).first(where: { fm.isExecutableFile(atPath: $0) }) {
        return hit
      }
    }
    return nil
  }

  static let claudeManifest: ClaudeManifest? = {
    guard let url = Bundle.assets.url(forResource: "ClaudeModels", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? ClaudeManifest.decode(data)
  }()

  // MARK: Floor updates

  /// A Claude Code or Codex below Serein's floor (HarnessDriver.minimumCLIVersion) updates itself
  /// with its own update command when something is about to be sent to it, never from a probe, and
  /// once per launch: a failed update is not retried by itself. Its Update button (Settings › AI
  /// apps) and Connect in Serein run it again where the person can see it.
  private var floorUpdates: [HarnessDriver: Task<Void, Never>] = [:]
  private var floorTried: Set<HarnessDriver> = []
  /// The update a send should wait for: one already running, or one this call starts because the
  /// probed CLI is below its floor. nil when there is nothing to wait for.
  func autoUpdate(_ driver: HarnessDriver) -> Task<Void, Never>? {
    if let running = floorUpdates[driver] { return running }
    // probesEnabled: previews and checks hold fixed snapshots, never a CLI to update.
    guard probesEnabled, !floorTried.contains(driver), let s = snapshots[driver], s.enabled, let path = s.path,
      // A copy inside the ChatGPT app is that app's to update, never Serein's (README, Detection).
      BundledCLI.app(path) == nil,
      let minimum = driver.minimumCLIVersion, let version = s.version, HarnessParse.isOlder(version, than: minimum)
    else { return nil }
    floorTried.insert(driver)
    var env = Self.environment(executable: path, driver: driver, shellPath: shellPath, extra: instance(driver).safeEnvironment)
    env["TERM"] = "dumb"
    let arguments = HarnessCommands.update(driver).arguments
    let task = Task { @MainActor in
      await Task.detached(priority: .utility) { Self.runUpdate(path, arguments, env) }.value
      if driver == .codex {
        CodexAppServerProbe.forget(path)
        CodexAppServer.existing(path)?.reload()
      }
      await self.refresh(driver, force: true)
      self.floorUpdates[driver] = nil
    }
    floorUpdates[driver] = task
    return task
  }
  /// The floor update running now, if any: `autoUpdate` without starting one.
  func floorUpdate(_ driver: HarnessDriver) -> Task<Void, Never>? { floorUpdates[driver] }
  /// Below the floor with its one automatic update over: only an update the person starts can
  /// help now, so Serein does not count it as an AI app it can think with (`AgentModel.canThink`).
  func stuckBelowFloor(_ driver: HarnessDriver) -> Bool {
    // A copy inside another app gets no automatic update, so it is stuck from the start.
    snapshots[driver]?.tooOld == true && floorUpdates[driver] == nil
      && (floorTried.contains(driver) || BundledCLI.app(snapshots[driver]?.path) != nil)
  }
  /// The CLI's own update with no terminal: no input (a prompt fails instead of waiting), output
  /// dropped, and the whole process group ended after five minutes.
  nonisolated private static func runUpdate(_ path: String, _ arguments: [String], _ env: [String: String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    p.environment = env
    p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? ProcessGroup.configure(p)) != nil, (try? p.run()) != nil else { return }
    let timeout = DispatchWorkItem { ProcessGroup.terminate(p) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
    p.waitUntilExit()
    timeout.cancel()
  }

  // MARK: Refresh

  private var lastFullRefresh: Date?
  /// Gemini CLI's last signed-in ACP probe per resolved executable (HarnessProbe.SessionProbe).
  private var sessionProbes: [String: HarnessProbe.SessionProbe] = [:]
  /// Called when Serein becomes active: re-probes unless a full refresh ran in the last minute.
  func refreshIfStale() {
    guard probesEnabled, startup != nil, let last = lastFullRefresh, Date().timeIntervalSince(last) > 60 else {
      return
    }
    Task { await refreshAll(except: deferred) }
  }

  /// `skipped`: left unprobed (`deferred` at launch and when Serein becomes active).
  func refreshAll(includeDisabled: Bool = false, except skipped: Set<HarnessDriver> = []) async {
    lastFullRefresh = Date()
    await withTaskGroup(of: Void.self) { group in
      for driver in HarnessDriver.allCases where !skipped.contains(driver) {
        group.addTask { await self.refresh(driver, includeDisabled: includeDisabled) }
      }
    }
  }

  /// Disabled instances are only located unless `includeDisabled` (setup, Settings' Check All).
  /// `force` waits for a refresh already running and then probes again (after a sign-in, the
  /// earlier answer is stale).
  func refresh(_ driver: HarnessDriver, includeDisabled: Bool = false, force: Bool = false) async {
    guard probesEnabled else { return }
    deferred.remove(driver)
    if force {
      for _ in 0..<300 where refreshing.contains(driver) { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
    guard !refreshing.contains(driver) else { return }
    let instance = instance(driver)
    refreshing.insert(driver)
    defer { refreshing.remove(driver) }
    var snapshot = snapshots[driver] ?? HarnessSnapshot(instance: instance)
    snapshot.enabled = instance.enabled
    let shellPath = shellPath
    let found = await Task.detached(priority: .utility) {
      Self.locate(driver, override: instance.binaryPath, shellPath: shellPath)
    }.value
    snapshot.path = found
    snapshot.installed = found != nil
    if let found, instance.enabled || includeDisabled {
      // The probe sees what a run sees: the Keychain key, so a CLI that runs on it reports its
      // sign-in, and none of the keys Serein inherited that runs never get (AgentFileGuard).
      let env = AgentFileGuard.environment(
        Self.environment(executable: found, driver: driver, shellPath: shellPath, extra: childExtra(instance)),
        driver: driver, ownKey: keyVariable(Provider(driver)))
        .merging(driver == .opencode ? ProviderStore.shared.openCodeProbeEnvironment() : [:]) { _, table in table }
      // Gemini CLI opens an ACP session (which starts the user's MCP servers) only while it is on,
      // and not again while its binary, version and sign-in are unchanged; `force` (a sign-in, a
      // run that found it signed out) checks again.
      let resolved = URL(fileURLWithPath: found).resolvingSymlinksInPath().path
      let probed = await HarnessProbe.probe(
        driver, executable: found, environment: env, session: instance.enabled,
        reuse: force ? nil : sessionProbes[resolved])
      if driver == .gemini { sessionProbes[resolved] = probed.sessionProbe }
      snapshot.version = probed.version
      // A help run that timed out opened no session: the last sign-in and models stand.
      if !probed.helpTimedOut {
        snapshot.signedIn = probed.auth.signedIn
        snapshot.signInProblem = probed.auth.problem
      }
      snapshot.account = probed.auth.account
      snapshot.latestVersion = probed.latest
      // A copy inside a Mac app (Codex in the ChatGPT app) is the app's to keep current.
      snapshot.needsUpdate = BundledCLI.app(found) == nil && (probed.updateDue
        || probed.latest.map { latest in probed.version.map { HarnessParse.isOlder($0, than: latest) } ?? false } ?? false)
      if !probed.helpTimedOut {
        snapshot.models = driver == .claude ? (Self.claudeManifest?.models(cliVersion: probed.version) ?? []) : probed.models
      }
      snapshot.capabilities = probed.capabilities
      // A help run that timed out says nothing about ACP mode: the last answer stands.
      snapshot.acpArguments = probed.helpTimedOut ? snapshot.acpArguments : probed.acpArguments
      // Codex's app server starts on the first Codex run (AgentModel.send waits for it), not here.
    } else {
      snapshot.models = []
      snapshot.capabilities = .base(driver)
    }
    let (status, message) = HarnessSnapshot.summarize(snapshot, name: instance.name)
    snapshot.status = status
    snapshot.message = message
    snapshot.checkedAt = Date()
    snapshots[driver] = snapshot
    if probesEnabled {
      let watched = instance.enabled ? found : nil
      ModelSourceWatcher.shared.watch(
        driver, executable: watched,
        environment: watched.map {
          Self.environment(executable: $0, driver: driver, shellPath: shellPath, extra: instance.safeEnvironment)
        } ?? [:])
    }
    onChange?()
    // Codex's list comes from its app server (CodexCatalog.update), not from this probe.
    if driver != .codex { noteModels(Provider(driver)) }
  }
}

/// Which AI apps launch probes: the one new chats start with and the one Serein thinks with.
/// With no thinking app chosen, Serein falls back to Claude Code, then Codex
/// (RelayOrchestrator.provider), and helpers do the same for an app that answers none
/// (AgentModel.helperProvider): those two come too. Nothing chosen (a first launch): every app.
enum HarnessLaunchProbes {
  static func drivers(newChats: Provider?, relay: Provider?, helpers: Set<HarnessDriver>) -> Set<HarnessDriver> {
    let chosen = Set([newChats, relay].compactMap { $0?.driver })
    guard !chosen.isEmpty else { return Set(HarnessDriver.allCases) }
    guard relay?.driver == nil || !chosen.isSubset(of: helpers) else { return chosen }
    return chosen.union([.claude, .codex])
  }
}

// MARK: - Probes

/// Runs one non-model probe command with a timeout, in its own process group.
enum HarnessProbe {
  struct Result {
    var code: Int32
    var output: String
    var timedOut: Bool
  }
  struct Probed {
    var version: String?
    var latest: String?
    /// An update without a release number (Gemini CLI: no ACP mode).
    var updateDue = false
    /// Gemini CLI's ACP launch switches, from its own help (HarnessSnapshot.acpArguments).
    var acpArguments: [String]?
    /// Its help gave no answer in time: `acpArguments` is unknown, not missing.
    var helpTimedOut = false
    /// A signed-in Gemini CLI session probe to keep (HarnessRegistry.sessionProbes).
    var sessionProbe: SessionProbe?
    var auth = HarnessParse.Auth(signedIn: nil)
    var models: [HarnessModel] = []
    var capabilities: HarnessCapabilities
  }

  /// What a signed-in Gemini CLI probe found, kept while `stamp` (its resolved file's path, date
  /// and size, and its version) is unchanged, so its ACP session is not opened on every refresh.
  struct SessionProbe: Sendable {
    var stamp: String
    var acpArguments: [String]
    var models: [HarnessModel]
  }
  nonisolated static func stamp(_ executable: String, version: String?) -> String {
    let real = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    let attributes = try? FileManager.default.attributesOfItem(atPath: real)
    let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    return [real, String(date), String(size), version ?? ""].joined(separator: "|")
  }

  /// Output kept per probe: enough for a router's full model list with metadata (OpenCode's
  /// verbose list is about 1 KB a model), so the list is never cut short.
  nonisolated static let outputLimit = 64_000_000

  static func run(
    _ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval,
    cwd: URL? = nil, grouped: Bool = true
  ) async -> Result {
    await Task.detached(priority: .utility) {
      runSync(executable, arguments, environment: environment, timeout: timeout, cwd: cwd, grouped: grouped)
    }.value
  }

  nonisolated static func runSync(
    _ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval,
    cwd: URL? = nil, grouped: Bool = true
  ) -> Result {
    let child = Process()
    let out = Pipe()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = arguments
    child.environment = environment
    child.currentDirectoryURL = cwd ?? FileManager.default.temporaryDirectory
    child.standardOutput = out
    child.standardError = out
    child.standardInput = FileHandle.nullDevice
    if grouped { try? ProcessGroup.configure(child) }
    do { try child.run() } catch { return Result(code: -1, output: "", timedOut: false) }
    let box = ProbeOutput()
    let reader = DispatchGroup()
    reader.enter()
    // Its own thread: on a loaded Mac a pooled reader started too late and its output was lost.
    let thread = Thread {
      var data = Data()
      while case let chunk = out.fileHandleForReading.availableData, !chunk.isEmpty {
        if data.count < Self.outputLimit { data.append(chunk) }
      }
      box.set(String(decoding: data.prefix(Self.outputLimit), as: UTF8.self))
      reader.leave()
    }
    thread.qualityOfService = .userInitiated
    thread.start()
    let deadline = Date().addingTimeInterval(timeout)
    while child.isRunning && Date() < deadline { usleep(30_000) }
    let timedOut = child.isRunning
    if timedOut { ProcessGroup.terminate(child) }
    _ = reader.wait(timeout: .now() + 3)
    return Result(code: timedOut ? -1 : child.terminationStatus, output: box.get(), timedOut: timedOut)
  }

  /// `session`: Gemini CLI may open its ACP session (the instance is on). `reuse`: its last
  /// signed-in session probe for this executable.
  static func probe(
    _ driver: HarnessDriver, executable: String, environment env: [String: String], session: Bool = true,
    reuse: SessionProbe? = nil
  ) async -> Probed {
    await Task.detached(priority: .utility) {
      probeSync(driver, executable: executable, environment: env, session: session, reuse: reuse)
    }.value
  }

  nonisolated static func probeSync(
    _ driver: HarnessDriver, executable: String, environment env: [String: String], session: Bool = true,
    reuse: SessionProbe? = nil
  ) -> Probed {
    let q = driver.quietArguments
    func run(_ args: [String], _ timeout: TimeInterval = 8) -> Result {
      runSync(executable, q + args, environment: env, timeout: timeout)
    }
    func confirm(_ auth: HarnessParse.Auth, _ result: Result, _ args: [String]) -> HarnessParse.Auth {
      HarnessParse.confirmed(
        auth, code: result.code, timedOut: result.timedOut,
        command: ([URL(fileURLWithPath: executable).lastPathComponent] + args).joined(separator: " "))
    }
    var p = Probed(capabilities: .base(driver))
    let home = NSHomeDirectory()
    switch driver {
    case .claude:
      p.version = HarnessParse.version(run(["--version"], 4).output)
      let status = run(["auth", "status"])
      p.auth = confirm(HarnessParse.claudeAuth(status.output), status, ["auth", "status"])
    case .codex:
      p.version = HarnessParse.version(run(["--version"], 4).output)
      let login = run(["login", "status"])
      p.auth = confirm(HarnessParse.codexAuth(login.output), login, ["login", "status"])
    case .cursor:
      let aboutRun = run(["about", "--format", "json"])
      let about = HarnessParse.cursorAbout(aboutRun.output)
      p.version = about.version
      p.latest = about.latest
      p.auth = confirm(about.auth, aboutRun, ["about"])
      if about.auth.signedIn == nil {
        let status = run(["status"])
        p.auth = confirm(HarnessParse.cursorStatus(status.output), status, ["status"])
        p.auth.account = about.auth.account
      }
      if p.auth.signedIn == true, CursorPreflight.problem(home: home, environment: env) == nil {
        p.models = ACPProbe.cursorModels(executable: executable, quiet: q, environment: env)
      }
      if let problem = CursorPreflight.problem(home: home, environment: env, isolated: true) {
        p.capabilities.canIsolateUserConfig = false
        p.capabilities.notes.insert(problem, at: 0)
      }
    case .opencode:
      p.version = HarnessParse.version(run(["--version"], 4).output)
      let api = OpenCodeAPI(version: p.version)
      // 2.x lists models from the same empty config folder its runs use (HelperFolder.openCodeConfig), so the
      // picker offers only models a run can reach.
      var listEnv = env
      if api == .v2 { listEnv["OPENCODE_CONFIG_DIR"] = HelperFolder.openCodeConfig }
      let listed = runSync(executable, q + api.modelArguments, environment: listEnv, timeout: 25)
      p.models = api.models(listed.output)
      // Free models make it ready with no account; the label is set only when one is connected,
      // and Settings › AI apps offers Sign in while it is not (HarnessSettings).
      let accounts = HarnessParse.openCodeAccounts(run(api.accountArguments).output) ?? []
      let console = api.consoleArguments.map { HarnessParse.openCodeConsoleSignedIn(run($0).output) } ?? false
      let account = HarnessParse.openCodeAccountLabel(credentials: accounts, console: console)
      p.auth = confirm(HarnessParse.Auth(signedIn: !p.models.isEmpty, account: account), listed, api.modelArguments)
    case .pi, .ohMyPi:
      p.version = HarnessParse.version(run(["--version"], 4).output)
      // Its Update button then runs the npm swap (HarnessCommands.update).
      if driver == .pi, HarnessCommands.piOldPackage(URL(fileURLWithPath: executable).resolvingSymlinksInPath().path) {
        p.updateDue = true
      }
      // Pi keeps its settings beside the model list it writes (ModelSources).
      let settings = ModelSources.files(.pi, environment: env, home: home).models
        .map { ($0 as NSString).deletingLastPathComponent + "/settings.json" }
      let listArgs = driver == .ohMyPi ? ["models", "--json"] : ["--list-models"]
      let listed = run(listArgs, 15)
      p.models = driver == .ohMyPi
        ? HarnessParse.ohMyPiModels(listed.output)
        : HarnessParse.piModels(
          listed.output, own: HarnessParse.piOwnModel(settings.flatMap { FileManager.default.contents(atPath: $0) }))
      p.auth = confirm(HarnessParse.Auth(signedIn: !p.models.isEmpty), listed, listArgs)
    case .grok:
      p.version = HarnessParse.version(run(["--version"], 4).output)
      // Grok's own answer, from the environment its runs get; a key merely set is not a sign-in.
      let modelsRun = run(["models"], 10)
      let listed = HarnessParse.grokModels(modelsRun.output)
      p.models = listed.models
      p.auth = confirm(listed.auth, modelsRun, ["models"])
      // Each model's own name and effort levels are in its ACP `initialize` reply. No session is
      // opened, so nothing is saved and none of the user's MCP servers start.
      if !p.models.isEmpty,
        let reply = ACPProbe.grokInitialize(executable: executable, arguments: q + HelperWire.grokArguments, environment: env)
      {
        p.models = HarnessParse.grokEfforts(p.models, reply: reply)
      }
    case .gemini:
      p.version = HarnessParse.version(run(["--version"], 6).output)
      let fileStamp = Self.stamp(executable, version: p.version)
      if let reuse, reuse.stamp == fileStamp {
        p.acpArguments = reuse.acpArguments
        p.models = reuse.models
        p.auth = HarnessParse.Auth(signedIn: true)
        p.sessionProbe = reuse
        break
      }
      // Its ACP switch was renamed across versions: its own help names the one this copy has, and
      // none is an update due; a help that does not answer in time decides nothing.
      // A cold node start can miss the first deadline: one more try before it counts as no answer.
      var help = run(["--help"], 15)
      if help.timedOut || help.output.isEmpty { help = run(["--help"], 15) }
      if help.timedOut || help.output.isEmpty {
        p.helpTimedOut = true
      } else {
        p.acpArguments = HarnessParse.geminiACPArguments(help.output)
        if p.acpArguments == nil { p.updateDue = true }
      }
      // Sign-in and models come from an ACP session (ACPProbe), started under the sandbox profile
      // its runs get, so it sees the sign-in a run can use. Serein never reads its sign-in or key.
      if session, let acp = p.acpArguments {
        let profile = AgentFileGuard.ownSetupProfile(home: URL(fileURLWithPath: home), driver: .gemini)
        let found = ACPProbe.geminiSession(
          executable: "/usr/bin/sandbox-exec", arguments: ["-p", profile, executable] + q + acp, environment: env)
        p.auth = found.auth
        p.models = found.models
        if found.auth.signedIn == true { p.sessionProbe = SessionProbe(stamp: fileStamp, acpArguments: acp, models: found.models) }
      }
    }
    // The newest release the CLI's own update check recorded on this Mac (Codex, Grok). A missing
    // or unreadable record shows no update.
    if p.latest == nil, let file = ModelSources.files(driver, environment: env, home: home).latest,
      let data = FileManager.default.contents(atPath: file)
    {
      p.latest = ModelSources.latest(driver, data)
    }
    return p
  }
}

/// The whole output of a probe (TextBox keeps only a tail).
final class ProbeOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var value = ""
  func set(_ s: String) {
    lock.lock()
    value = s
    lock.unlock()
  }
  func get() -> String {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

// MARK: - ACP model probes (Cursor, Gemini CLI, Grok)

/// Starts a harness's ACP agent just long enough to read its models; no prompt is sent. Cursor:
/// initialize and `cursor/list_available_models`, with no session and never `authenticate`, which
/// would open its sign-in page. Gemini CLI:
/// initialize and `session/new` in a scratch folder, whose reply carries its sign-in and models.
/// Grok: initialize only.
enum ACPProbe {
  nonisolated static func cursorModels(executable: String, quiet: [String], environment: [String: String]) -> [HarnessModel] {
    exchange(executable: executable, arguments: quiet + ["acp"], environment: environment) { (call) -> [HarnessModel] in
      guard call(1, "initialize", ACPMessages.initialize(.cursor), 8) != nil else { return [] }
      guard let list = call(2, "cursor/list_available_models", [:], 8) else { return [] }
      return HarnessParse.cursorModels(list)
    } ?? []
  }

  /// Never `authenticate`: Serein does not sign in for Gemini CLI. Its session gets no MCP server
  /// from Serein; no reply leaves the sign-in unknown, and says so.
  nonisolated static func geminiSession(executable: String, arguments: [String], environment: [String: String])
    -> (auth: HarnessParse.Auth, models: [HarnessModel])
  {
    let unknown = (
      auth: HarnessParse.Auth(signedIn: nil, problem: "Gemini CLI did not answer its session check in time."),
      models: [HarnessModel]()
    )
    return exchange(executable: executable, arguments: arguments, environment: environment) {
      (call) -> (auth: HarnessParse.Auth, models: [HarnessModel]) in
      let folder = FileManager.default.temporaryDirectory.path
      guard call(1, "initialize", ACPMessages.initialize(), 15) != nil,
        let reply = call(2, "session/new", ACPMessages.newSession(cwd: folder, mcp: []), 20)
      else { return unknown }
      return HarnessParse.geminiSession(reply)
    } ?? unknown
  }

  /// Grok's `initialize` reply alone, with no session and no sign-in step (HarnessParse.grokEfforts).
  nonisolated static func grokInitialize(executable: String, arguments: [String], environment: [String: String]) -> Any? {
    exchange(executable: executable, arguments: arguments, environment: environment) { (call) -> Any? in
      call(1, "initialize", ACPMessages.initialize(), 8)
    } ?? nil
  }

  /// Runs `body` against a fresh agent process: `call(id, method, params, timeout)` sends one
  /// request and waits up to `timeout` seconds for its result or error object (nil on none).
  /// The process group ends when `body` returns. nil when the process does not start.
  nonisolated private static func exchange<T>(
    executable: String, arguments: [String], environment: [String: String],
    _ body: ((Int, String, [String: Any], TimeInterval) -> Any?) -> T
  ) -> T? {
    let child = Process()
    let input = Pipe()
    let output = Pipe()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = arguments
    child.environment = environment
    child.currentDirectoryURL = FileManager.default.temporaryDirectory
    child.standardInput = input
    child.standardOutput = output
    child.standardError = FileHandle.nullDevice
    try? ProcessGroup.configure(child)
    guard (try? child.run()) != nil else { return nil }
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    defer { ProcessGroup.terminate(child) }
    let lock = NSLock()
    var responses: [Int: Any] = [:]
    DispatchQueue.global(qos: .utility).async {
      var buffer = Data()
      while case let chunk = output.fileHandleForReading.availableData, !chunk.isEmpty {
        buffer.append(chunk)
        while let i = buffer.firstIndex(of: 10) {
          let line = buffer.prefix(upTo: i)
          buffer.removeSubrange(...i)
          if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = json["id"] as? Int {
            lock.lock()
            responses[id] = json["result"] ?? json["error"] ?? NSNull()
            lock.unlock()
          }
        }
        if buffer.count > 4_000_000 { buffer.removeAll() }
      }
    }
    func call(_ id: Int, _ method: String, _ params: [String: Any], timeout: TimeInterval) -> Any? {
      try? input.fileHandleForWriting.write(contentsOf: Data((ACPMessages.request(id: id, method: method, params: params) + "\n").utf8))
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        lock.lock()
        let hit = responses[id]
        lock.unlock()
        if let hit { return hit }
        usleep(30_000)
      }
      return nil
    }
    return body { call($0, $1, $2, timeout: $3) }
  }
}
