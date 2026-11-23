#if DEBUG
import AppKit
import ApplicationServices
import Foundation
import SereinCore

/// A Cocoa window with a password field and a code field. Each change of either is one stdout
/// line, so the check sees what the app holds without reading the field through Accessibility.
private let fixtureSource = #"""
  import AppKit
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 160),
                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
  win.title = "Secure fixture"
  let pw = NSSecureTextField(frame: NSRect(x: 20, y: 100, width: 320, height: 24))
  pw.placeholderString = "Password"
  let code = NSTextField(frame: NSRect(x: 20, y: 60, width: 320, height: 24))
  code.placeholderString = "Verification code"
  win.contentView?.addSubview(pw)
  win.contentView?.addSubview(code)
  win.makeKeyAndOrderFront(nil)
  app.activate(ignoringOtherApps: true)
  Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    MainActor.assumeIsolated {
      let state = pw.stringValue + "\t" + code.stringValue + "\n"
      FileHandle.standardOutput.write(Data(state.utf8))
    }
  }
  app.run()
  """#

/// The fixture's text field with this placeholder.
@MainActor private func field(pid: pid_t, placeholder: String) -> AXUIElement? {
  let root = AXUIElementCreateApplication(pid)
  var queue = (MacControl.value(root, kAXWindowsAttribute) as? [AXUIElement] ?? [])
    .filter { MacControl.role($0) == kAXWindowRole }
  var visited = Set<AXUIElement>()
  while !queue.isEmpty, visited.count < 128 {
    let element = queue.removeFirst()
    guard visited.insert(element).inserted else { continue }
    if MacControl.string(element, kAXPlaceholderValueAttribute) == placeholder { return element }
    queue += (MacControl.value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  }
  return nil
}

/// One fixture app with its own executable, name and bundle identifier, run from
/// system temp, outside the test library.
@MainActor private final class FixtureApp {
  let name: String
  let process = Process()
  private var output = ""
  private let folder: URL
  init(name: String, bundleID: String) throws {
    self.name = name
    folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("serein-secure-\(UUID().uuidString)")
    let bundle = folder.appendingPathComponent("\(name).app/Contents")
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let binary = bundle.appendingPathComponent("MacOS/\(name)")
    let source = folder.appendingPathComponent("main.swift")
    try fixtureSource.write(to: source, atomically: true, encoding: .utf8)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = ["swiftc", source.path, "-o", binary.path]
    try compiler.run()
    compiler.waitUntilExit()
    guard compiler.terminationStatus == 0 else { throw SereinError.invalid("Could not build the Mac secure-card fixture.") }
    let plist: [String: String] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleExecutable": name, "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: bundle.appendingPathComponent("Info.plist"))
    process.executableURL = binary
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let text = String(decoding: handle.availableData, as: UTF8.self)
      Task { @MainActor in self?.output += text }
    }
    try process.run()
  }
  /// The fields' values as the app last wrote them: password, then code.
  var fields: [String] {
    let line = output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().last.map(String.init) ?? ""
    return line.components(separatedBy: "\t")
  }
  /// Wait for the app to report its fields again after the card's terminal result.
  func nextFields() async throws -> [String] {
    let before = output.utf8.count
    for _ in 0..<40 {
      if output.utf8.count > before && output.hasSuffix("\n") { return fields }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw SereinError.invalid("The fixture stopped reporting field values.")
  }
  func running() async -> Bool {
    for _ in 0..<100 {
      if (try? MacControl.app(named: name)) != nil, !output.isEmpty { return true }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return false
  }
  func stop() {
    (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    if process.isRunning { process.terminate(); process.waitUntilExit() }
    try? FileManager.default.removeItem(at: folder)
  }
}

/// The Mac secure card through the real `browser.handle` path, against fixture apps. Returns
/// every result and error the task saw, for the caller's leak scan.
@MainActor func checkMacSecureCards(
  _ browser: BrowserModel, taskID id: String, token: String, check: (Bool, String) -> Void, canary: String, code: String,
  answered: (SecureCard.Result, String) async -> Bool
) async throws -> [String] {
  if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
    check(false, "Unlock the Mac to verify secure-card entry and focus changes in a native window.")
    return []
  }
  var seen: [String] = []
  func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
    let out = try await browser.handle(["task": id, "token": token, "name": name, "arguments": arguments])
    seen.append(jsonString(out))
    return out
  }
  func refusal(_ name: String, _ arguments: [String: Any]) async -> String? {
    do {
      _ = try await call(name, arguments)
      return nil
    } catch {
      seen.append(error.localizedDescription)
      return error.localizedDescription
    }
  }

  let fixture = try FixtureApp(name: "SereinSecureFixture", bundleID: "local.serein.secure-fixture")
  let manager = try FixtureApp(name: "1Password Fixture", bundleID: "local.serein.manager-fixture")
  defer {
    fixture.stop()
    manager.stop()
  }
  let up = await fixture.running()
  let managerUp = await manager.running()
  check(up && managerUp, "The fixture apps run")
  guard up, managerUp else { return seen }
  let app = fixture.name

  func observe() async throws -> [[String: Any]] {
    (try await call("mac_observe", ["app": app]))["controls"] as? [[String: Any]] ?? []
  }
  func ref(_ secure: String, in rows: [[String: Any]]) -> String {
    rows.first { $0["secure"] as? String == secure }?["ref"] as? String ?? ""
  }
  /// Starts a call that raises a card, and waits for the card.
  func raising(_ arguments: [String: Any]) async -> (Task<[String: Any], Error>, SecureCards.Card?) {
    let before = browser.secureCards.open.count
    let pending = Task { try await call("mac_act", arguments) }
    for _ in 0..<100 where browser.secureCards.open.count == before {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return (pending, browser.secureCards.open.count > before ? browser.secureCards.open.last : nil)
  }
  func settled(_ index: Int, _ wanted: String) async -> Bool {
    for _ in 0..<40 {
      if fixture.fields.indices.contains(index), fixture.fields[index] == wanted { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
  }

  // The password field is listed as secure, without a value, and a type step raises its card.
  var rows = try await observe()
  let password = ref("password", in: rows)
  check(
    !password.isEmpty && rows.first { $0["ref"] as? String == password }?["value"] == nil
      && ref("code", in: rows) != "",
    "A Mac password field and a code field are listed as secure, without values")
  guard !password.isEmpty, !ref("code", in: rows).isEmpty else {
    throw SereinError.invalid("The native fixture window did not expose both secure controls.")
  }
  var (pending, raised) = await raising(["app": app, "kind": "type", "ref": password, "text": "model-typed"])
  check(
    raised?.kind == .password && raised?.mac != nil && raised?.title == "Sign in to \(app)",
    "type on a Mac password field raises a password card naming the app")
  check(fixture.fields.first == "", "The field stays empty while the card waits")
  if let raised { check(browser.secureCards.submit(raised.id, SecretEntry(key: canary)) == nil, "The person's entry is taken") }
  let filled = try await pending.value
  let notified = await answered(.filled, app)
  let landed = await settled(0, canary)
  check(
    filled["result"] as? String == "asked" && notified && landed && !fixture.fields.contains("model-typed"),
    "Serein sets the person's value in the app's password field; the model's text is dropped")

  // A plain text field labelled for a code takes the code card.
  rows = try await observe()
  (pending, raised) = await raising(["app": app, "kind": "type", "ref": ref("code", in: rows), "text": "000000"])
  check(raised?.kind == .code, "type on a Mac code field raises a code card")
  if let raised { _ = browser.secureCards.submit(raised.id, SecretEntry(key: code)) }
  let coded = try await pending.value
  let codeNotified = await answered(.filled, app)
  let codeLanded = await settled(1, code)
  rows = try await observe()
  check(
    coded["result"] as? String == "asked" && codeNotified && codeLanded
      && rows.first { $0["secure"] as? String == "code" }?["value"] == nil,
    "The code fills the code field, and a later observe lists it without its value")

  // Focus moved to another field before the submit: nothing is filled.
  rows = try await observe()
  (pending, raised) = await raising(["app": app, "kind": "type", "ref": ref("password", in: rows), "text": ""])
  check(raised != nil, "A second password card rises")
  // The person clicks into the other field, as Accessibility would see it.
  guard let other = field(pid: fixture.process.processIdentifier, placeholder: "Verification code"),
    AXUIElementSetAttributeValue(other, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
    MacControl.value(other, kAXFocusedAttribute) as? Bool == true,
    let raised
  else { throw SereinError.invalid("Could not establish the secure-card focus-change fixture.") }
  let original = fixture.fields
  check(original == [canary, code], "Both fixture fields contain their original values before the focus-change submission")
  check(browser.secureCards.submit(raised.id, SecretEntry(key: "Other-entry-1")) == nil, "The stale card submission is processed")
  let moved = try await pending.value
  let rejected = await answered(.pageChanged, app)
  let afterRejection = try await fixture.nextFields()
  check(moved["result"] as? String == "asked" && rejected && afterRejection == original,
    "A focus change reports page changed and preserves both field values")

  // A password manager is refused before anything is read or asked.
  let managerRefusal = await refusal("mac_observe", ["app": manager.name])
  check(
    managerRefusal == MacControl.secretsRefusal(manager.name) && browser.secureCards.open.isEmpty,
    "A password manager app stays refused, with no card")
  return seen
}
#endif
