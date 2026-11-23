#if DEBUG
import AppKit
import SereinCore

/// Opt-in real-VM acceptance. Uses a dedicated external test folder, no provider or host UI
/// automation. The license flag is explicit; it is not part of production setup behavior.
@MainActor func checkOfflineMac(folder: URL, acceptsLicense: Bool) async throws {
  guard acceptsLicense, folder.isFileURL, folder.lastPathComponent.hasPrefix("serein-offline-check-"),
    folder.deletingLastPathComponent().lastPathComponent == "machines",
    GateSettings.shared.fileURL == nil else { throw SereinError.invalid("Use a dedicated serein-offline-check-* folder and explicitly accept the macOS license.") }
  GateSettings.shared.set(true, forKey: ComputerPolicy.enabledKey)
  GateSettings.shared.set(folder.deletingLastPathComponent().deletingLastPathComponent().path, forKey: MacComputerPolicy.storageKey)
  var admitted = true
  var mac: MacVirtualComputer!
  mac = MacVirtualComputer(folder: folder, internet: { false }, progress: { if let line = $0 { print(line); fflush(stdout) } },
    stopped: {}, admission: { admitted ? "local-acceptance" : nil }, personAllowed: { false }, personActed: { _ in },
    setupChanged: { phase in
      if phase == .agreement { mac.approveSetupAgreement() }
    })
  func waitForReady() async throws { try await waitForCheckMac(mac) }
  defer { mac.stopForQuit(paused: false) }
  _ = try await mac.start()
  try await waitForReady()
  print("PASS: fresh offline account, root finalization, automatic guest login, pinned native bridge")
  fflush(stdout)
  // Exercise the same gated control path Serein offers to a permitted task, after setup.
  _ = try await mac.screen("key", ["key": "Cmd+space"])
  try await Task.sleep(nanoseconds: 800_000_000)
  _ = try await mac.screen("type", ["text": "Calculator"])
  try await Task.sleep(nanoseconds: 800_000_000)
  _ = try await mac.screen("key", ["key": "Return"])
  let deadline = Date().addingTimeInterval(20)
  var front = ""
  while Date() < deadline {
    front = (try? await mac.verificationStatus()["frontmostBundle"]) ?? ""
    if front == "com.apple.calculator" { break }
    try await Task.sleep(nanoseconds: 500_000_000)
  }
  guard front == "com.apple.calculator" else { throw SereinError.invalid("Native keyboard/text control did not open Calculator (front: \(front)).") }
  print("PASS: Serein's gated native keyboard and guest-only clipboard opened Calculator")
  fflush(stdout)
  admitted = false
  do { _ = try await mac.screen("key", ["key": "space"]); throw SereinError.invalid("Revoked control was accepted.") }
  catch { guard error.localizedDescription.contains("no longer has control") else { throw error } }
  admitted = true
  print("PASS: revocation prevents further virtual Mac input")
  fflush(stdout)
  try await mac.pause()
  _ = try await mac.start()
  try await waitForReady()
  print("PASS: saved-state resume reconnects without setup")
  fflush(stdout)
  // A power button can display macOS's normal shutdown confirmation. The opt-in
  // fixture has no person data; only its guarded DEBUG path permits a power cycle.
  try await mac.verificationPowerOff()
  _ = try await mac.start()
  try await waitForReady()
  print("PASS: cold boot automatically logs in and reconnects without setup")
  fflush(stdout)
  try await mac.pause()
  print("PASS: offline Mac acceptance complete; disk kept for inspection")
  fflush(stdout)
}

/// Waits for a check Mac's guest helper to answer, printing its state every ten seconds.
@MainActor func waitForCheckMac(_ mac: MacVirtualComputer) async throws {
  let deadline = Date().addingTimeInterval(240)
  var diagnostic = Date()
  while !mac.isReady, Date() < deadline {
    if case .needsPerson(let words) = mac.setupPhase { throw SereinError.invalid(words) }
    if Date().timeIntervalSince(diagnostic) >= 10 {
      diagnostic = Date()
      do {
        let status = try await mac.verificationStatus()
        print("CHECK: guest user=\(status["sessionUser"] ?? "?"), setup=\(status["setupComplete"] ?? "?"), version=\(status["offlineSetupVersion"] ?? "?"); \(mac.verificationDisplay)")
      } catch let timeout as MacMailboxTimeout {
        print("CHECK: guest status timed out, picked up=\(timeout.pickedUp); \(mac.verificationDisplay)")
      } catch { print("CHECK: \(error.localizedDescription); \(mac.verificationDisplay)") }
      fflush(stdout)
    }
    try await Task.sleep(nanoseconds: 500_000_000)
  }
  guard mac.isReady else { throw SereinError.invalid("The real virtual Mac did not become ready.") }
}
#endif
