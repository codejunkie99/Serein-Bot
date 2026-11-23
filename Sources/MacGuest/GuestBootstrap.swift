import AppKit
import Darwin
import ServiceManagement
import SereinCore

@MainActor enum GuestBootstrap {
  /// The login agent starts this signed helper directly. Finalization is confined to its
  /// own fresh VM account after the installer has finalized file ownership.
  static func finishOfflineSetupIfNeeded() async throws {
    try GuestGuard.requireVirtualMac()
    guard CommandLine.arguments.contains("--offline-setup") else { return }
    let marker = URL(fileURLWithPath: MacOfflineSetup.marker)
    guard FileManager.default.fileExists(atPath: marker.path) else { return }
    guard NSUserName() == MacOfflineSetup.username,
      Bundle.main.bundleURL.path == MacOfflineSetup.home + "/Applications/" + MacComputerPolicy.guestAppName else {
      throw MacGuestFailure("Automatic setup only runs in Serein's private guest account.")
    }
    try MacGuestIdentity().validate(Bundle.main.bundleURL)
    guard offlineFilesReady else {
      throw MacGuestFailure("Finish preparing this Mac in Serein's installer before starting its connection.")
    }
    // Setup Assistant can already have started during the first automatic login. Its
    // preferences and root-owned completion marker are now in place; no UI is driven.
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.SetupAssistant") { app.terminate() }
    if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), configuration: configuration)
    }
    try FileManager.default.removeItem(at: marker)
    UserDefaults.standard.set(MacOfflineSetup.version, forKey: "offlineSetupVersion")
  }

  static var offlineFilesReady: Bool {
    [MacOfflineSetup.completedMarker, "/private/var/db/.AppleSetupDone", "/private/etc/kcpassword"].allSatisfy { path in
      var info = stat()
      return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_uid == 0
    }
  }

  static func installAndRelaunchIfNeeded() async throws -> Bool {
    try GuestGuard.requireVirtualMac()
    guard Bundle.main.bundleIdentifier == MacComputerPolicy.guestBundleID else {
      throw MacGuestFailure("Open Serein Computer.app from the tools folder inside the virtual Mac.")
    }
    let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
    let identity = try MacGuestIdentity()
    try identity.validate(source)
    let applications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    let destination = applications.appendingPathComponent(MacComputerPolicy.guestAppName)
    if source == destination.resolvingSymlinksInPath() { return false }
    let fm = FileManager.default
    try fm.createDirectory(at: applications, withIntermediateDirectories: true)
    let staging = applications.appendingPathComponent("Serein Computer-installing-\(UUID().uuidString).app")
    try fm.copyItem(at: source, to: staging)
    try identity.validate(staging)
    var previous: URL?
    if fm.fileExists(atPath: destination.path) {
      guard Bundle(url: destination)?.bundleIdentifier == MacComputerPolicy.guestBundleID else {
        throw MacGuestFailure("The guest application folder already holds another app; it was left untouched.")
      }
      let running = NSRunningApplication.runningApplications(withBundleIdentifier: MacComputerPolicy.guestBundleID)
        .filter { $0.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() }
      for app in running { app.terminate() }
      for _ in 0..<60 where !running.allSatisfy(\.isTerminated) { try await Task.sleep(nanoseconds: 50_000_000) }
      guard running.allSatisfy(\.isTerminated) else { throw MacGuestFailure("Quit the installed Serein Computer app, then open this copy again.") }
      // Retain the previous helper. Guest updates never remove an existing application folder.
      let backup = applications.appendingPathComponent("Serein Computer-previous-\(UUID().uuidString).app")
      try fm.moveItem(at: destination, to: backup)
      previous = backup
    }
    do { try fm.moveItem(at: staging, to: destination) }
    catch {
      if let previous { try? fm.moveItem(at: previous, to: destination) }
      throw error
    }
    try identity.validate(destination)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    if CommandLine.arguments.contains("--native-host") || UserDefaults.standard.bool(forKey: "nativeHostControl") {
      configuration.arguments = ["--native-host"]
    }
    _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
    return true
  }

  static func updateFromSharedTools(_ tools: URL) {
    let shared = tools.appendingPathComponent(MacComputerPolicy.guestAppName)
    guard Bundle.main.bundleURL.resolvingSymlinksInPath() != shared.resolvingSymlinksInPath(),
      // Read the file itself: Bundle(url:) keeps the first Info.plist it saw for the life of
      // the process, so a helper brought back from saved memory would never see an update.
      let plist = try? Data(contentsOf: shared.appendingPathComponent("Contents/Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
      let available = info["CFBundleVersion"] as? String,
      available != Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    else { return }
    do { try MacGuestIdentity().validate(shared) }
    catch { stderr("Open the updated Serein Computer app in the shared tools folder: \(error.localizedDescription)"); return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    if UserDefaults.standard.bool(forKey: "nativeHostControl") { configuration.arguments = ["--native-host"] }
    NSWorkspace.shared.openApplication(at: shared, configuration: configuration)
  }

  static func registerForGuestLogin() {
    guard !UserDefaults.standard.bool(forKey: "requestedGuestLoginItem") else { return }
    do {
      try SMAppService.mainApp.register()
      UserDefaults.standard.set(true, forKey: "requestedGuestLoginItem")
    } catch { stderr("Allow Serein Computer in this Mac's Login Items to reconnect after login.") }
  }
}
