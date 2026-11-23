#if DEBUG
import AppKit
import SereinCore

/// Opt-in real-VM check of the virtual Mac's network, on a dedicated serein-offline-check-* Mac.
/// 1. Setup finishing: its boot has no network card (setup's own boots never do). With the network
///    on by default, the Mac is not handed over offline; it waits for its one restart
///    (ComputerHost.bootOnline, made here), and its first session is online: an address and route,
///    names and an HTTPS page from inside the guest.
/// 2. The person's Off (ComputerHost.setMacInternet's restart): no route, no HTTPS. It pauses with
///    that offline memory saved.
/// 3. On again: that memory is dropped, the Mac boots online, and Safari opens a page, saved as PNG
///    in `shots` for a person to look at.
@MainActor func checkMacNetwork(folder: URL, shots: URL) async throws {
  guard folder.isFileURL, folder.lastPathComponent.hasPrefix("serein-offline-check-"),
    folder.deletingLastPathComponent().lastPathComponent == "machines",
    GateSettings.shared.fileURL == nil else { throw SereinError.invalid("Use a dedicated serein-offline-check-* folder.") }
  GateSettings.shared.set(true, forKey: ComputerPolicy.enabledKey)
  GateSettings.shared.set(folder.deletingLastPathComponent().deletingLastPathComponent().path, forKey: MacComputerPolicy.storageKey)
  try MacNetworkCheck.markSetupFinishing(folder)
  var internet = MacComputerPolicy.networkOn(stored: nil)
  let mac = MacVirtualComputer(folder: folder, internet: { internet }, progress: { if let line = $0 { print(line); fflush(stdout) } },
    stopped: {}, admission: { "local-acceptance" }, personAllowed: { false }, personActed: { _ in }, setupChanged: { _ in })
  defer { mac.stopForQuit(paused: false) }

  _ = try await mac.start()
  try await waitForOnlineBoot(mac)
  pass("setup finished on an offline boot: the Mac waits for its network restart and takes no tools")
  try await timedRestart(mac, shots: shots)
  _ = try await mac.start()
  try await waitForCheckMac(mac)
  pass("first session after setup booted with Apple NAT")
  try await checkOnline(mac)

  internet = false
  try await timedRestart(mac, shots: shots)
  _ = try await mac.start()
  try await waitForCheckMac(mac)
  let offline = try await guestRun(mac, "offline", "route -n get default 2>&1 | grep interface; " + MacNetworkCheck.fetch(seconds: 10))
  guard !offline.hasSuffix("200"), !offline.contains("interface:") else {
    throw SereinError.invalid("The virtual Mac reached the internet with its network switch off.")
  }
  pass("network off: no route and no HTTPS from the guest")
  try await mac.pause()
  pass("paused with its offline memory saved")

  internet = true
  _ = try await mac.start()
  guard !mac.restoredFromSave else { throw SereinError.invalid("Offline memory was restored onto a Mac with a network card.") }
  try await waitForCheckMac(mac)
  pass("network on again: offline memory dropped, booted with Apple NAT")
  try await checkOnline(mac)
  try await saveSafari(mac, to: shots)
  try await mac.pause()
  pass("virtual Mac network check complete")
}

private enum MacNetworkCheck {
  static let page = "https://www.apple.com/library/test/success.html"
  static func fetch(seconds: Int) -> String {
    "curl -sS -m \(seconds) -o /dev/null -w '%{http_code}' \(page) 2>&1"
  }
  /// The virtio card is not always en0, so ask for the port that carries the default route.
  static let address = "ipconfig getifaddr \"$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')\""
  /// The state at the end of setup: the guest is set up but the record is not yet marked so, and
  /// no memory is saved. Only for the dedicated check Mac `checkMacNetwork` was given.
  static func markSetupFinishing(_ folder: URL) throws {
    let record = folder.appendingPathComponent("machine.json")
    guard var values = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any],
      values["offlineSetupVersion"] != nil else { throw SereinError.invalid("The check Mac has not been through Serein's setup.") }
    values["prepared"] = false
    try JSONSerialization.data(withJSONObject: values).write(to: record, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
    for name in ["resume.vzvmsave", "resume.build"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
  }
}

private func pass(_ words: String) {
  print("PASS: " + words)
  fflush(stdout)
}

/// What ComputerHost.bootOnline waits for: setup done and saved, the Mac not ready, so no task
/// command runs on it offline.
@MainActor private func waitForOnlineBoot(_ mac: MacVirtualComputer) async throws {
  let deadline = Date().addingTimeInterval(240)
  while !mac.wantsOnlineBoot, Date() < deadline {
    guard !mac.isReady else { throw SereinError.invalid("Setup finished offline and the Mac was handed over without its network.") }
    if case .needsPerson(let words) = mac.setupPhase { throw SereinError.invalid(words) }
    try await Task.sleep(nanoseconds: 500_000_000)
  }
  guard mac.wantsOnlineBoot, !mac.isReady, mac.hasCompletedSetup else {
    throw SereinError.invalid("Setup finished without asking for the restart that brings the network.")
  }
  guard (try? await mac.shell("run", ["command": "true", "timeout": "5"], timeout: 10)) == nil else {
    throw SereinError.invalid("A command ran on the virtual Mac before its network restart.")
  }
}

/// The restart Serein makes for a network change: a clean shut down from inside, timed.
@MainActor private func timedRestart(_ mac: MacVirtualComputer, shots: URL) async throws {
  let asked = Date()
  do { try await mac.restart() } catch {
    try? await saveScreen(mac, to: shots, named: "virtual-mac-restart.png")
    throw error
  }
  pass("restart shut the guest down in \(Int(Date().timeIntervalSince(asked))) s")
}

@MainActor private func guestRun(_ mac: MacVirtualComputer, _ name: String, _ command: String) async throws -> String {
  let reply = try await mac.shell("run", ["command": command, "timeout": "60"], timeout: 70)
  let output = (reply["output"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  print("CHECK \(name) (exit \(reply["code"] ?? "?")):\n\(output)")
  fflush(stdout)
  return output
}

@MainActor private func checkOnline(_ mac: MacVirtualComputer) async throws {
  // The guest may need a few seconds after login for DHCP; wait for an address before judging.
  var address = ""
  for _ in 0..<30 {
    address = (try? await mac.shell("run", ["command": MacNetworkCheck.address, "timeout": "10"], timeout: 15)["output"])?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !address.isEmpty { break }
    try await Task.sleep(nanoseconds: 2_000_000_000)
  }
  _ = try await guestRun(mac, "interfaces", "route -n get default 2>&1 | grep -E 'gateway|interface'; scutil --dns | grep -m1 nameserver")
  guard !address.isEmpty else { throw SereinError.invalid("The virtual Mac got no network address on its default route.") }
  pass("guest address \(address)")
  let lookup = try await guestRun(mac, "dns", "dscacheutil -q host -a name www.apple.com | grep -m1 address")
  guard lookup.contains("address") else { throw SereinError.invalid("The virtual Mac could not resolve www.apple.com.") }
  pass("DNS resolves")
  let fetch = try await guestRun(mac, "https", MacNetworkCheck.fetch(seconds: 30))
  guard fetch.hasSuffix("200") else { throw SereinError.invalid("HTTPS from the virtual Mac failed: \(fetch)") }
  pass("curl loads an HTTPS page")
}

/// Safari's page is for a person to look at; scripting Safari would ask for Automation access.
@MainActor private func saveSafari(_ mac: MacVirtualComputer, to shots: URL) async throws {
  _ = try await mac.screen("open_url", ["url": "https://example.com"])
  try await Task.sleep(nanoseconds: 12_000_000_000)
  try await saveScreen(mac, to: shots, named: "virtual-mac-safari.png")
}

@MainActor private func saveScreen(_ mac: MacVirtualComputer, to shots: URL, named name: String) async throws {
  guard let png = try await mac.screen("screenshot", [:])["png"] as? String, let data = Data(base64Encoded: png) else {
    throw SereinError.invalid("The virtual Mac's screen could not be read.")
  }
  try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
  let file = shots.appendingPathComponent(name)
  try data.write(to: file)
  print("CHECK: screenshot saved to \(file.path)")
  fflush(stdout)
}
#endif
