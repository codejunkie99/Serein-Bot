#if DEBUG
import Foundation
import CoreGraphics
import SereinCore

extension AssistantCoreChecks {
  static func macComputer(_ check: Check) throws {
    // Core checks run before the real gate file opens. Never alter a live user's choice.
    let settings = GateSettings.shared
    try check(settings.fileURL == nil, "Mac storage checks use in-memory gates")
    var upfront = SereinChatSetupState()
    try check(upfront.begin(in: "first-mac", needsComputer: true) && upfront.phase == .computer,
              "First-run setup prepares the Mac before choosing an AI account")
    try check(!upfront.selectPersonName("Sam", in: "first-mac")
      && !upfront.selectHarness(.claude, in: "first-mac", needsConnection: false),
              "An incomplete Mac cannot advance the account questions")
    try check(upfront.holdsCheckIns(firstRunFinished: true), "Mac preparation holds check-ins and provider work")
    try check(!upfront.computerReady(in: "other-chat"), "A foreign callback cannot finish Mac preparation")
    let reloadedUpfront = try JSONDecoder().decode(SereinChatSetupState.self, from: JSONEncoder().encode(upfront))
    try check(reloadedUpfront == upfront, "Relaunch keeps the initial Mac preparation step")
    try check(upfront.computerReady(in: "first-mac") && upfront.phase == .name,
              "Verified Mac preparation resumes the welcome questions")
    try check(upfront.begin(in: "first-mac", needsComputer: true) && upfront.phase == .name,
              "A completed initial Mac step is not replayed within setup")
    let image = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    image.setFillColor(CGColor(gray: 0, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
    try check(!MacNativeDisplay.hasContent(image.makeImage()!), "A black renderer cannot publish Mac readiness")
    image.setFillColor(CGColor(gray: 0.7, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: 64, height: 10))
    try check(MacNativeDisplay.hasContent(image.makeImage()!), "A rendered desktop passes the guest-only frame check")

    for password in ["local-test", "123456789012", "longer-unique-test-value-123!"] {
      let encoded = MacOfflineSetup.loginPassword(password)
      try check(encoded.count % 12 == 0 && encoded.count > password.utf8.count,
                "Autologin includes a padded NUL terminator")
      try check(MacOfflineSetup.decodeLoginPassword(encoded) == password,
                "Offline autologin password round-trips without truncation")
    }
    try check(MacOfflineSetup.decodeLoginPassword(Data()) == nil
      && MacOfflineSetup.decodeLoginPassword(Data(repeating: 1, count: 12)) == nil,
              "Malformed guest autologin data is refused")
    let agent = MacOfflineSetup.loginAgent
    try check(agent["ProgramArguments"] as? [String] == [MacOfflineSetup.executable, "--native-host", "--offline-setup"],
              "The login service starts only Serein's fixed guest helper")
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("serein-offline-paths-" + UUID().uuidString)
    let users = fixture.appendingPathComponent("private/var/db/dslocal/nodes/Default/users")
    try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
    let foreign = users.appendingPathComponent("person.plist")
    let original = try PropertyListSerialization.data(fromPropertyList: ["uid": ["502"], "name": ["person"]], format: .binary, options: 0)
    try original.write(to: foreign)
    var pathError = ""
    do { try MacOfflineProvisioning.patch(root: fixture, helper: URL(fileURLWithPath: "/not-used"), password: "synthetic-test", build: "24G90", product: "15.6.1") }
    catch { pathError = error.localizedDescription }
    try check(pathError.contains("another account") && (try Data(contentsOf: foreign)) == original,
              "Offline setup refuses another person's account before modifying its disk")
    let linked = fixture.appendingPathComponent("linked")
    try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("private"), withDestinationURL: fixture.appendingPathComponent("private"))
    pathError = ""
    do { try MacOfflineProvisioning.patch(root: linked, helper: URL(fileURLWithPath: "/not-used"), password: "synthetic-test", build: "24G90", product: "15.6.1") }
    catch { pathError = error.localizedDescription }
    try check(pathError.contains("unexpected link") && (try Data(contentsOf: foreign)) == original,
              "Guest symlinks cannot redirect offline writes outside the selected data volume")
    // Small synthetic fixtures stay in the system temp directory; no broad cleanup runs.

    let previous = settings.object(forKey: MacComputerPolicy.storageKey)
    defer { settings.set(previous, forKey: MacComputerPolicy.storageKey) }
    let external = URL(fileURLWithPath: "/Volumes/Serein Test SSD/Serein Macs", isDirectory: true)
    settings.set(external.path, forKey: MacComputerPolicy.storageKey)
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    try check(AgentFileGuard.sereinPrivateRoots(home: home, library: nil).contains(external),
              "External Mac disks remain private without a library root")
    let profile = AgentFileGuard.sereinDataProfile(home: home, library: nil)
    try check(profile.contains("/Volumes/Serein Test SSD/Serein Macs"),
              "Agent sandbox denies the external Mac storage root")
    try check(!ComputerCapabilities.macOS.carriesProxy && ComputerCapabilities.macOS.ownInternetOff,
              "Mac networking cannot be mistaken for the Linux proxy")
    try check(ComputerPolicy.keepsAwakeWhileViewed(place: .macOS, watchers: 1, personHasControl: true),
              "An open person-controlled Mac is not paused while its desktop is visible")
    try check(!ComputerPolicy.keepsAwakeWhileViewed(place: .macOS, watchers: 0, personHasControl: true),
              "Closing the Mac view restores idle pausing")
    try check(!ComputerPolicy.keepsAwakeWhileViewed(place: .macOS, watchers: 1, personHasControl: false),
              "Handing the Mac back restores idle pausing")
    for place in ComputerPlace.allCases where place != .macOS {
      try check(!ComputerPolicy.keepsAwakeWhileViewed(place: place, watchers: 1, personHasControl: true),
                "Viewing \(place.rawValue) does not bypass its existing idle policy")
    }

    let old = try JSONDecoder().decode(MacVirtualComputer.Record.self,
      from: Data(#"{"cpu":2,"memory":4294967296,"installed":true}"#.utf8))
    try check(!old.needsAccountProvisioning, "Existing Mac records never create another account")
    try check(old.managedSetup == nil && old.needsSetupAccount,
              "An older incomplete VM resumes app-owned account setup at the initial account page")
    var prepared = old
    prepared.prepared = true
    try check(!prepared.needsSetupAccount, "A prepared VM never creates another setup account")
    prepared.prepared = nil
    prepared.automaticAccount = true
    try check(!prepared.needsSetupAccount, "A provisioned account cannot be created twice")
    prepared.automaticAccount = nil
    prepared.installed = false
    try check(!prepared.needsSetupAccount, "Account setup waits for macOS installation")
    var firstBoot = MacVirtualComputer.Record(cpu: 2, memory: 4_294_967_296, installed: true, osMajor: 27)
    try check(firstBoot.needsAccountProvisioning, "A new macOS 27 guest provisions its first account")
    firstBoot.hasStarted = true
    let saved = try JSONDecoder().decode(MacVirtualComputer.Record.self, from: JSONEncoder().encode(firstBoot))
    try check(!saved.needsAccountProvisioning, "Account provisioning is not repeated after a guest has booted")
    firstBoot.hasStarted = nil
    firstBoot.osMajor = 26
    try check(!firstBoot.needsAccountProvisioning, "Older guests never receive unsupported account options")
    if !MacGuestProvisioning.available {
      try check(try MacGuestProvisioning.startOptions(storage: external) == nil,
                "Unsupported hosts skip provisioning before touching the guest Keychain")
    }
    let accepted = MacProvisioningFixture()
    let options = NSObject()
    try MacGuestProvisioning.apply(options, to: accepted)
    try check(accepted.received === options, "Public provisioning selector passes the account options to validation")
    let refused = MacProvisioningFixture()
    refused.accepts = false
    var refusedMessage: String?
    do {
      try MacGuestProvisioning.apply(options, to: refused)
    } catch {
      refusedMessage = error.localizedDescription
    }
    try check(refusedMessage != nil, "Rejected account options must stop first boot")
    try check(refusedMessage?.contains("sensitive-sentinel") == false, "Account validation errors do not reveal credentials")
    var missingMessage: String?
    do {
      try MacGuestProvisioning.apply(options, to: NSObject())
    } catch {
      missingMessage = error.localizedDescription
    }
    try check(missingMessage?.contains("unavailable") == true, "Missing account APIs fail without an Objective-C exception")

    try check(MacSetupPhase.agreement.needsPerson && !MacSetupPhase.account.needsPerson && !MacSetupPhase.ready.needsPerson,
              "Serein owns account setup while agreement approval stays a person step")
    try check(MacSetupPhase.account.working, "Account creation remains an automatic setup phase")
    let licenseSuite = "serein.check.macos-license.\(UUID().uuidString)"
    if let store = UserDefaults(suiteName: licenseSuite) {
      defer { store.removePersistentDomain(forName: licenseSuite) }
      try check(!ComputerPolicy.acceptedMacOSLicense(defaults: store), "Apple's macOS license is not accepted until the person agrees in Mac setup")
      store.set(true, forKey: ComputerPolicy.macOSLicenseKey)
      try check(ComputerPolicy.acceptedMacOSLicense(defaults: store), "The saved Mac setup agreement reads back as accepting Apple's macOS license")
    }
    try check(MacSetupPhase.ready.message == nil, "A ready Mac has no setup instructions")
    let ascii = String((32...126).compactMap(UnicodeScalar.init).map(Character.init))
    try check(MacGuestKeyboard.strokes(ascii)?.count == 95, "The bootstrap keyboard covers every printable US key")
    try check(MacGuestKeyboard.strokes("safe prefix 🔐") == nil,
              "Unsupported bootstrap text is rejected before any prefix is typed")
    try check(MacGuestKeyboard.strokes("A") == [MacKey(code: 0, shift: true)], "Bootstrap capitals hold Shift")
    try check(MacGuestKeyboard.strokes("!") == [MacKey(code: 18, shift: true)], "Bootstrap punctuation uses its physical key")
    let tools = ToolSchema.offered(["--computer", "--computer-mac", "--mac"])
    let names = Set(tools.compactMap { $0["name"] as? String })
    try check(names.contains("mac_observe") && names.contains("mac_act") && names.contains("computer_screenshot"),
              "A permitted assistant can be offered both actual-Mac and virtual-Mac tools")
    try check(names.isSuperset(of: ["computer_run", "computer_read_file", "computer_send_file"]) && !names.contains("computer_tree"),
              "A virtual Mac offers shell and files, and no accessibility tree")
    let run: [String: Any] = tools.first { $0["name"] as? String == "computer_run" } ?? [:]
    let schema: [String: Any] = run["inputSchema"] as? [String: Any] ?? [:]
    let runFields: [String: Any] = schema["properties"] as? [String: Any] ?? [:]
    let runWords: String = run["description"] as? String ?? ""
    try check(!runFields.keys.contains("detach"), "The virtual Mac's run has no detach")
    try check(runWords.contains("virtual Mac as its own user"), "The virtual Mac's run says it runs as the Mac's user")
    try check(MacComputerPolicy.tools.isSuperset(of: MacComputerPolicy.screenTools.union(MacComputerPolicy.shellTools))
              && !MacComputerPolicy.tools.contains("computer_tree"), "The Mac answers screen, shell and file tools")
    try macShellChecks(check)
    try check(!ToolSchema.offered(["--computer-mac"]).contains(where: { ($0["name"] as? String)?.hasPrefix("computer_") == true }),
              "The Mac kind flag cannot enable computer access by itself")
    try check((ToolSchema.macObserveTool["description"] as? String)?.contains("person's actual Mac") == true,
              "Host observations explicitly name the actual computer")
    try check(ComputerTargets.guidance.contains("Personal-read exclusions"), "Dual target guidance preserves personal-data boundaries")
  }
}

private final class MacProvisioningFixture: NSObject {
  var accepts = true
  var received: NSObject?
  @objc(setGuestProvisioningOptions:error:)
  func setGuestProvisioningOptions(_ options: NSObject, error: NSErrorPointer) -> Bool {
    if accepts { received = options; return true }
    error?.pointee = NSError(domain: "MacProvisioningFixture", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "sensitive-sentinel"])
    return false
  }
}
extension AssistantCoreChecks {
  /// MacGuestShell's pure parts: paths, output cuts and file slices. Each comparison is typed on
  /// its own so the checks stay cheap to compile.
  static func macShellChecks(_ check: Check) throws {
    let home = "/Users/serein"
    let tilde: String? = MacGuestShell.resolve("~", home: home)
    let inHome: String? = MacGuestShell.resolve("~/a.txt", home: home)
    let absolute: String? = MacGuestShell.resolve("/tmp/x", home: home)
    try check(tilde == home, "Mac paths: ~ is the Mac user's home")
    try check(inHome == "/Users/serein/a.txt", "Mac paths: ~/ names a file in the home")
    try check(absolute == "/tmp/x", "Mac paths: an absolute path stays")
    let relative: String? = MacGuestShell.resolve("notes.txt", home: home)
    let empty: String? = MacGuestShell.resolve("", home: home)
    let nul: String? = MacGuestShell.resolve("/a\u{0}b", home: home)
    try check(relative == nil, "Mac paths: a relative path is refused")
    try check(empty == nil, "Mac paths: an empty path is refused")
    try check(nul == nil, "Mac paths: a path with NUL is refused")
    let limit: Int = MacGuestShell.textLimit
    let long = Data(String(repeating: "é", count: limit + 5).utf8)
    let cutLong = MacGuestShell.cut(long)
    try check(cutLong.text.count == limit, "Mac command output is cut at the limit in whole characters")
    try check(cutLong.cut, "Cut output says so")
    let short = MacGuestShell.cut(Data("ok".utf8))
    try check(short.text == "ok", "Short output stays whole")
    try check(!short.cut, "Short output is not cut")
    try check(MacGuestShell.cut(Data("ok".utf8), truncated: true).cut, "Output dropped past the byte limit still reads as cut")
    let first = MacGuestShell.slice(long, start: 0) ?? ("", nil)
    let firstNext: Int = first.next ?? -1
    try check(first.text.count == limit, "A long Mac file's first part has the limit's characters")
    try check(firstNext == limit * 2, "Its next part starts on a character boundary")
    let second = MacGuestShell.slice(long, start: firstNext) ?? ("", nil)
    try check(second.text.count == 5, "The next part reads the rest")
    try check(second.next == nil, "The last part has no next")
    try check(MacGuestShell.slice(long, start: long.count + 1)?.text.isEmpty == true, "Past the end reads nothing")
    let broken = Data([0x6F, 0x6B, 0xFF, 0xFE, 0x21])
    try check(MacGuestShell.slice(broken, start: 0) == nil, "Bytes that are not UTF-8 are refused, not read with drifting offsets")
    try check(MacGuestShell.detachRefusal.contains("nohup"), "Long jobs on the Mac say how")
    // A window that cuts "é" (C3 A9) after its first byte leaves it for the next part.
    let cutWindow = Data("ab".utf8) + Data([0xC3])
    let windowPage = MacGuestShell.page(cutWindow, start: 10, atEnd: false)
    try check(windowPage?.text == "ab", "A window's cut character is left for the next part")
    try check(windowPage?.next == 12, "The next part starts at the cut character")
    let endPage = MacGuestShell.page(Data("ab".utf8), start: 0, atEnd: true)
    try check(endPage?.next == nil, "The window at the end has no next part")
    try shellRunnerChecks(check)
    try fileKindChecks(check)
    let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()
    try check(MacGuestShell.outName(zero) == "out-00000000-0000-0000-0000-000000000000.bin", "A file out has one exchange name")
  }

  /// ShellRunner for real: exit codes, a time limit that stops the whole group, and a background
  /// job that outlives a command that ended by itself.
  static func shellRunnerChecks(_ check: Check) throws {
    let home = NSTemporaryDirectory()
    let exited = try ShellRunner.run("exit 3", home: home, timeout: 10)
    try check(exited.code == 3, "A command's exit code comes back")
    let stopped = try ShellRunner.run("sleep 31.371 & sleep 31.372", home: home, timeout: 1)
    try check(stopped.code == ShellRunner.timedOutCode && stopped.output.contains("stopped after 1 seconds"),
              "A command past its limit is stopped and says so")
    let left = try ShellRunner.run("pgrep -f 'sleep 31.37[12]' | wc -l", home: home, timeout: 10)
    try check(left.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0",
              "Stopping a command stops everything it started")
    _ = try ShellRunner.run("nohup sleep 31.373 >/dev/null 2>&1 &", home: home, timeout: 10)
    let kept = try ShellRunner.run("pgrep -f 'sleep 31.373' | wc -l", home: home, timeout: 10)
    try check(kept.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              "A background job outlives a command that ended by itself")
    _ = try ShellRunner.run("pkill -f 'sleep 31.37'", home: home, timeout: 10)
  }

  /// A symlink reads as its target: its size and its kind.
  static func fileKindChecks(_ check: Check) throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("serein-kind-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: folder) }
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = folder.appendingPathComponent("big.txt")
    try Data(repeating: 0x61, count: 50_000).write(to: target)
    let link = folder.appendingPathComponent("link.txt")
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    try check(MacGuestShell.fileKind(link.path) == .file(size: 50_000), "A symlink reads as its target's size")
    let folderLink = folder.appendingPathComponent("dir-link")
    try fm.createSymbolicLink(at: folderLink, withDestinationURL: folder)
    try check(MacGuestShell.fileKind(folderLink.path) == .folder, "A symlink to a folder reads as a folder")
    let broken = folder.appendingPathComponent("broken")
    try fm.createSymbolicLink(atPath: broken.path, withDestinationPath: folder.appendingPathComponent("gone").path)
    try check(MacGuestShell.fileKind(broken.path) == nil, "A broken symlink reads as nothing there")
  }
}
#endif
