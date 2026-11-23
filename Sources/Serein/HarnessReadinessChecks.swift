#if DEBUG
import Foundation
import SereinCore

extension SmokeTest {
  /// Harness readiness against fake CLIs (no provider, no model call): Codex's driver, the
  /// refusal of a harness Serein cannot restrict, the terminal sign-in and the floor update. Turns
  /// run on Engines (AssistantCoreChecks.engines).
  @MainActor static func harnessReadiness(browser: BrowserModel, agent: AgentModel) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    let fm = FileManager.default
    let dir = browser.library.root.appendingPathComponent("harness-fake-" + UUID().uuidString.prefix(8))
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    results += try await codexDriver(dir: dir)
    func install(_ name: String, _ script: String) throws -> URL {
      let url = dir.appendingPathComponent(name)
      try script.write(to: url, atomically: true, encoding: .utf8)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      return url
    }
    func waitFor(_ seconds: Double = 15, _ condition: () -> Bool) async throws {
      for _ in 0..<Int(seconds * 10) where !condition() {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    let hub = agent.hub

    // Serein refuses to send to a harness it cannot restrict.
    let saved = (agent.provider, agent.mode, agent.draft, agent.error)
    // Oh My Pi loads its own MCP servers (HarnessCapabilities.base), so an answer is refused.
    // The normal send may switch to another installed app. Isolate this no-stand-in case.
    let registry = HarnessRegistry.shared
    let available = agent.available
    let snapshots = registry.snapshots
    let settings = registry.settings
    let probes = registry.probesEnabled
    registry.installPreview([:], settings: settings)
    agent.available = [Provider(.ohMyPi): dir.appendingPathComponent(HarnessDriver.ohMyPi.rawValue).path]
    agent.provider = Provider(.ohMyPi)
    agent.mode = .answer
    agent.draft = "Hello"
    let before = hub.runs.count
    agent.send()
    let refusal = agent.error ?? ""
    registry.installPreview(snapshots, settings: settings)
    registry.probesEnabled = probes
    agent.available = available
    agent.provider = saved.0
    agent.mode = saved.1
    agent.draft = saved.2
    agent.error = saved.3
    // Grok runs web tasks with its own setup on (the user's choice), never file tasks.
    func grok(_ mode: String) -> Bool {
      HarnessRegistry.shared.verdict(Provider(.grok), mode: mode, edits: mode == "project", permission: .supervised).allowed
    }
    try check(
      hub.runs.count == before && refusal.contains("Oh My Pi")
        && !grok("project") && !grok("library") && grok("research"),
      "A harness Serein cannot restrict is refused before anything starts")
    results += try await harnessSignIn(dir: dir, install: install, waitFor: waitFor)
    results += try await harnessFloorUpdate(dir: dir, install: install, waitFor: waitFor)
    return results
  }

  /// The embedded terminal sign-in: a fake Pi that is not signed in until its interactive start
  /// asks a question and gets an answer. The row's action goes Sign in →
  /// Ready, the harness is turned on, and Cancel ends a running command's process group.
  @MainActor static func harnessSignIn(
    dir: URL, install: (String, String) throws -> URL, waitFor: (Double, () -> Bool) async throws -> Void
  ) async throws -> [String] {
    var results: [String] = []
    func pass(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    let registry = HarnessRegistry.shared
    let actions = HarnessActions.shared
    let fake = try install("pi-login", fakeLoginPi)
    let marker = dir.appendingPathComponent("signed-in")
    let original = registry.instance(.pi)
    let probes = registry.probesEnabled
    registry.probesEnabled = true
    defer {
      actions.close()
      registry.probesEnabled = probes
      registry.restore(original)
    }
    var fakeInstance = original
    fakeInstance.binaryPath = fake.path
    fakeInstance.enabled = false
    fakeInstance.userChose = true
    fakeInstance.environment = ["SEREIN_FAKE_MARKER": marker.path]
    registry.restore(fakeInstance)
    // A key Serein itself inherited is scrubbed from Pi's runs (AgentFileGuard), so the probe
    // must not count it either.
    let inherited = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    setenv("ANTHROPIC_API_KEY", "inherited-by-serein", 1)
    await registry.refresh(.pi, includeDisabled: true, force: true)
    if let inherited { setenv("ANTHROPIC_API_KEY", inherited, 1) } else { unsetenv("ANTHROPIC_API_KEY") }
    try pass(
      HarnessPrimaryAction.of(registry.snapshots[.pi]) == .signIn,
      "A provider key Serein inherited, which Pi's runs never get, does not make Pi read Ready")
    await registry.refresh(.pi, includeDisabled: true, force: true)
    try pass(
      HarnessPrimaryAction.of(registry.snapshots[.pi]) == .signIn
        && registry.snapshots[.pi]?.version == "0.79.2",
      "A detected harness that is not signed in offers Sign in")
    let command = HarnessCommands.signIn(.pi)
    guard let job = actions.run(command, driver: .pi) else {
      throw SereinError.invalid("FAIL: sign-in did not start")
    }
    try pass(
      job.session.launch.path == fake.path && job.session.launch.arguments.isEmpty
        && command.display == "PI_SKIP_VERSION_CHECK=1 pi",
      "Sign-in runs the tool's own command, shown first, with its updater off")
    try await waitFor(10) { job.session.screen.text.contains("Press Return to sign in") }
    job.session.write(TerminalKeys.bytes(.enter))
    try await waitFor(30) { job.state != .running }
    let signedIn =
      job.state == .succeeded && FileManager.default.fileExists(atPath: marker.path)
      && HarnessPrimaryAction.of(registry.snapshots[.pi]) == .ready
      && registry.instance(.pi).enabled
      && job.session.screen.text.contains("Signed in as tester")
    try pass(
      signedIn,
      "The PTY passes keystrokes to the prompt; when it exits Serein re-probes, the row flips to Ready and the harness is on"
        + (signedIn
          ? ""
          : " [\(job.state) marker=\(FileManager.default.fileExists(atPath: marker.path)) action=\(HarnessPrimaryAction.of(registry.snapshots[.pi])) enabled=\(registry.instance(.pi).enabled) text=\(job.session.screen.text.suffix(120))]"))
    // Cancel ends the whole process group of a command that is still running.
    guard let slow = actions.run(HarnessCommands.update(.pi), driver: .pi) else {
      throw SereinError.invalid("FAIL: update did not start")
    }
    try await waitFor(10) { slow.session.screen.text.contains("Updating") }
    let group = slow.session.pid
    actions.cancel()
    // Orphaned members are reaped by launchd a moment after they die.
    try await waitFor(8) { !slow.session.running && kill(-group, 0) != 0 }
    try pass(
      slow.state == .cancelled && !slow.session.running && group > 0 && kill(-group, 0) != 0,
      "Cancel ends the terminal command's process group"
        + (slow.state == .cancelled && !slow.session.running && kill(-group, 0) != 0
          ? "" : " [\(slow.state) running=\(slow.session.running) group=\(group) alive=\(kill(-group, 0) == 0)]"))
    return results
  }

  /// A fake Claude Code below Serein's floor: the probe starts its own update with no terminal,
  /// probes again and the gate opens. A CLI that is still old afterwards is not updated twice.
  @MainActor static func harnessFloorUpdate(
    dir: URL, install: (String, String) throws -> URL, waitFor: (Double, () -> Bool) async throws -> Void
  ) async throws -> [String] {
    var results: [String] = []
    func pass(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    let registry = HarnessRegistry.shared
    let fake = try install("claude-old", fakeOldClaude)
    let marker = dir.appendingPathComponent("updated")
    let original = registry.instance(.claude)
    let probes = registry.probesEnabled
    registry.probesEnabled = true
    defer {
      registry.probesEnabled = probes
      registry.restore(original)
    }
    var fakeInstance = original
    fakeInstance.binaryPath = fake.path
    fakeInstance.enabled = true
    fakeInstance.userChose = true
    fakeInstance.environment = ["SEREIN_FAKE_MARKER": marker.path]
    registry.restore(fakeInstance)
    // A probe only looks, as at launch: nothing updates until something is about to be sent.
    await registry.refresh(.claude, force: true)
    try pass(
      !FileManager.default.fileExists(atPath: marker.path) && registry.snapshots[.claude]?.version == "2.1.250"
        && registry.floorUpdate(.claude) == nil,
      "Probing a Claude Code below the floor changes nothing on the Mac")
    // What every send does first (`AgentModel.send`, `dispatch`, `StructuredAgent`).
    guard let update = registry.autoUpdate(.claude) else {
      throw SereinError.invalid("FAIL: A send to a Claude Code below the floor starts its update")
    }
    await update.value
    try await waitFor(20) { registry.snapshots[.claude]?.version == "2.1.303" }
    let version = registry.snapshots[.claude]?.version
    try pass(
      FileManager.default.fileExists(atPath: marker.path) && version == "2.1.303"
        && HarnessVersionGate.refusal(driver: .claude, version: version, mode: "research") == nil
        && registry.autoUpdate(.claude) == nil,
      "A send to a Claude Code below the floor runs its own update with no terminal first; Serein probes again and the version gate opens [\(version ?? "-")]")
    try FileManager.default.removeItem(at: marker)
    await registry.refresh(.claude, force: true)
    try pass(
      registry.autoUpdate(.claude) == nil && registry.snapshots[.claude]?.version == "2.1.250"
        && HarnessVersionGate.refusal(driver: .claude, version: "2.1.250", mode: "research")?.contains("Choose Update") == true
        && HarnessPrimaryAction.of(registry.snapshots[.claude]) == .update && registry.stuckBelowFloor(.claude),
      "A CLI still old after its update is not updated again by itself; its one action is Update, and the refusal says where to find it")
    return results
  }
}

/// Reports an old version until `update` runs; the update refuses a terminal on its input.
private let fakeOldClaude = #"""
#!/bin/sh
case "$*" in
  *--version*) if [ -f "$SEREIN_FAKE_MARKER" ]; then echo "2.1.303 (Claude Code)"; else echo "2.1.250 (Claude Code)"; fi; exit 0 ;;
  update) [ -t 0 ] && exit 9; touch "$SEREIN_FAKE_MARKER"; exit 0 ;;
esac
exit 1
"""#

private let fakeLoginPi = #"""
#!/bin/sh
marker="$SEREIN_FAKE_MARKER"
case "$*" in
  *--version*) echo "0.79.2"; exit 0 ;;
  *--list-models*)
    if [ -f "$marker" ] || [ -n "$ANTHROPIC_API_KEY" ]; then printf 'provider   model\nanthropic  claude-sonnet-5\n'; fi
    exit 0 ;;
  "update --self") echo "Updating"; sleep 60 & sleep 60; exit 0 ;;
esac
printf 'Welcome. Press Return to sign in: '
read answer
touch "$marker"
echo "Signed in as tester"
exit 0
"""#

#endif
