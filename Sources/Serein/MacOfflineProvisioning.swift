import CommonCrypto
import Darwin
import Foundation
import Security
import SereinCore

/// Edits only the Data volume of one stopped, app-owned VM. Device identifiers are derived
/// from that exact disk's attachment, never from a volume name or a host-wide volume search.
enum MacOfflineProvisioning {
  private static let fm = FileManager.default

  static func prepare(folder: URL, helper: URL, password: String, authorization: MacSetupAuthorization) throws {
    let disk = folder.appendingPathComponent("disk.img")
    var diskInfo = stat()
    guard lstat(disk.path, &diskInfo) == 0, diskInfo.st_mode & S_IFMT == S_IFREG,
      diskInfo.st_nlink == 1, diskInfo.st_uid == getuid() else {
      throw SereinError.invalid("Automatic setup requires Serein's own regular virtual disk file.")
    }
    // macOS cannot mount this image below its external backing volume. A private internal
    // mount directory stores no disk data and is already excluded by AgentFileGuard.
    let mountRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Serein/mac-setup-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: mountRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let attached = try plist("/usr/bin/hdiutil", ["attach", disk.path, "-readwrite", "-owners", "off", "-nobrowse", "-mountroot", mountRoot.path, "-plist"])
    let entities = attached["system-entities"] as? [[String: Any]] ?? []
    let disks = entities.filter { $0["content-hint"] as? String == "GUID_partition_scheme" }.compactMap { $0["dev-entry"] as? String }
    guard disks.count == 1, let device = disks.first,
      device.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil else {
      throw SereinError.invalid("The virtual Mac disk did not attach as a private device.")
    }
    var attachedLive = true
    defer { if attachedLive { _ = try? run("/usr/bin/hdiutil", ["detach", device]) } }
    let listing = try plist("/usr/sbin/diskutil", ["list", "-plist", device])
    let partitions = (listing["AllDisksAndPartitions"] as? [[String: Any]])?.first?["Partitions"] as? [[String: Any]] ?? []
    let stores = partitions.filter { $0["Content"] as? String == "Apple_APFS" }.compactMap { $0["DeviceIdentifier"] as? String }
    guard stores.count == 1, validDevice(stores[0]) else { throw SereinError.invalid("The virtual Mac's APFS layout is not supported. Its files were left untouched.") }
    let storeInfo = try plist("/usr/sbin/diskutil", ["info", "-plist", stores[0]])
    guard let container = storeInfo["APFSContainerReference"] as? String,
      container.range(of: "^disk[0-9]+$", options: .regularExpression) != nil,
      storeInfo["ParentWholeDisk"] as? String == String(device.dropFirst(5)) else {
      throw SereinError.invalid("The virtual Mac's APFS container could not be identified safely.")
    }
    let apfs = try plist("/usr/sbin/diskutil", ["apfs", "list", "-plist", container])
    let containers = apfs["Containers"] as? [[String: Any]] ?? []
    guard containers.count == 1,
      let physical = containers[0]["PhysicalStores"] as? [[String: Any]],
      physical.contains(where: { $0["DeviceIdentifier"] as? String == stores[0] }),
      let volumes = containers[0]["Volumes"] as? [[String: Any]] else {
      throw SereinError.invalid("The virtual Mac's data volume could not be identified safely.")
    }
    let data = volumes.filter { ($0["Roles"] as? [String])?.contains("Data") == true }
    let system = volumes.filter { ($0["Roles"] as? [String])?.contains("System") == true }
    guard data.count == 1, system.count == 1,
      let dataDevice = data[0]["DeviceIdentifier"] as? String, validDevice(dataDevice),
      let systemDevice = system[0]["DeviceIdentifier"] as? String, validDevice(systemDevice),
      data[0]["FileVault"] as? Bool != true else {
      throw SereinError.invalid("Automatic setup needs one unencrypted virtual Mac data volume.")
    }
    func mounted(_ device: String) throws -> URL {
      let info = try plist("/usr/sbin/diskutil", ["info", "-plist", device])
      guard let path = info["MountPoint"] as? String,
        path.hasPrefix(mountRoot.path + "/") else { throw SereinError.invalid("A virtual Mac volume was not mounted in Serein's private setup folder.") }
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    let dataRoot = try mounted(dataDevice)
    let systemRoot = try mounted(systemDevice)
    try authorization.prepare(data: dataRoot, disk: disk)
    let version = try read(systemRoot.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist"))
    guard let build = version["ProductBuildVersion"] as? String,
      let product = version["ProductVersion"] as? String else { throw SereinError.invalid("The installed macOS version could not be read.") }
    try patch(root: dataRoot, helper: helper, password: password, build: build, product: product)
    try authorization.finish(data: dataRoot, disk: disk)
    // Successful provisioning requires all mounts to be gone before the VM may start.
    _ = try run("/usr/bin/hdiutil", ["detach", device]); attachedLive = false
  }

  static func patch(root: URL, helper: URL, password: String, build: String, product: String) throws {
    guard !password.isEmpty, password.utf8.count <= 256, !password.contains("\n"), !password.contains("\r"),
      getuid() >= 501, getuid() < 60000 else { throw SereinError.invalid("A private guest account could not be prepared.") }
    func path(_ name: String) throws -> URL { try safe(name, in: root) }
    // Apple's fresh directory-service folders can be mode 0600 (root can traverse them).
    // Give their owner search permission while mounting with owners ignored; this never
    // grants group/other access or changes their root ownership on the guest disk.
    for relative in ["private/var/db/dslocal/nodes/Default", "private/var/db/dslocal/nodes/Default/users"] {
      let url = try path(relative)
      let attributes = try fm.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory,
        let mode = attributes[.posixPermissions] as? NSNumber else { throw SereinError.invalid("The Mac account directory is invalid.") }
      if mode.intValue & 0o100 == 0 { try fm.setAttributes([.posixPermissions: mode.intValue | 0o100], ofItemAtPath: url.path) }
    }
    let users = try path("private/var/db/dslocal/nodes/Default/users")
    // Never reset an existing person's account. Only Serein's app-owned account is adoptable.
    let records = try fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil).filter { $0.pathExtension == "plist" }
    for url in records {
      let record = try read(try safe("private/var/db/dslocal/nodes/Default/users/" + url.lastPathComponent, in: root))
      let uid = Int((record["uid"] as? [String])?.first ?? "") ?? 0
      if uid >= 500, (record["name"] as? [String])?.first != MacOfflineSetup.username {
        throw SereinError.invalid("This Mac already has another account. Automatic setup left it untouched.")
      }
    }
    let userPath = try path("private/var/db/dslocal/nodes/Default/users/serein.plist")
    var user = fm.fileExists(atPath: userPath.path) ? try read(userPath) : [:]
    let uid = String(getuid())
    if !user.isEmpty {
      guard user["name"] as? [String] == [MacOfflineSetup.username], user["home"] as? [String] == [MacOfflineSetup.home],
        user["uid"] as? [String] == [uid] else { throw SereinError.invalid("The existing Serein account cannot be adopted safely on this Mac.") }
    } else {
      user = ["name": [MacOfflineSetup.username], "realname": ["Serein"], "uid": [uid], "gid": ["20"],
              "home": [MacOfflineSetup.home], "shell": ["/bin/zsh"], "passwd": ["********"],
              "generateduid": [UUID().uuidString.uppercased()],
              "authentication_authority": [";ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>"],
              "ShadowHashData": [try shadowHash(password)], "record_daemon_version": ["9040000"]]
      try write(user, to: userPath, mode: 0o600)
    }
    guard let uuid = (user["generateduid"] as? [String])?.first else { throw SereinError.invalid("The private Mac account has no identity.") }
    for name in ["admin", "staff"] {
      let url = try path("private/var/db/dslocal/nodes/Default/groups/" + name + ".plist")
      var group = try read(url)
      var members = group["users"] as? [String] ?? []
      var ids = group["groupmembers"] as? [String] ?? []
      if !members.contains("serein") { members.append("serein") }
      if !ids.contains(uuid) { ids.append(uuid) }
      group["users"] = members; group["groupmembers"] = ids
      try write(group, to: url)
    }
    let home = "Users/serein/"
    for relative in ["Applications", "Desktop", "Documents", "Downloads", "Library/Preferences", "Library/Application Support/Serein"] {
      try directory(try path(home + relative), mode: 0o700)
    }
    let installed = try path(home + "Applications/" + MacComputerPolicy.guestAppName)
    try MacGuestIdentity(referenceURL: helper).validate(helper)
    if fm.fileExists(atPath: installed.path) {
      try MacGuestIdentity(referenceURL: helper).validate(installed)
      try fm.moveItem(at: installed, to: installed.deletingLastPathComponent().appendingPathComponent("Serein Computer-before-setup-" + UUID().uuidString + ".app"))
    }
    try fm.copyItem(at: helper, to: installed)
    try MacGuestIdentity(referenceURL: helper).validate(installed)
    let agents = try path("Library/LaunchAgents")
    guard try fm.attributesOfItem(atPath: agents.path)[.type] as? FileAttributeType == .typeDirectory else {
      throw SereinError.invalid("The Mac is missing its standard startup folder.")
    }
    let legacyAgent = try path(home + "Library/LaunchAgents/" + MacOfflineSetup.agent + ".plist")
    if fm.fileExists(atPath: legacyAgent.path) {
      try fm.moveItem(at: legacyAgent, to: path(home + "Library/Application Support/Serein/login-agent-before-system-startup-" + UUID().uuidString + ".plist"))
    }
    let agentData = try PropertyListSerialization.data(fromPropertyList: MacOfflineSetup.loginAgent, format: .xml, options: 0)
    try writeData(agentData, to: path("Library/LaunchAgents/" + MacOfflineSetup.agent + ".plist"), mode: 0o644)
    try write(["version": MacOfflineSetup.version], to: path(String(MacOfflineSetup.marker.dropFirst())), mode: 0o600)
    try write(["nativeHostControl": true, "requestedGuestLoginItem": true],
              to: path(home + "Library/Preferences/" + MacComputerPolicy.guestBundleID + ".plist"))
    let setup = MacOfflineSetup.preferences(build: build, product: product)
    try write(setup, to: path(home + "Library/Preferences/com.apple.SetupAssistant.plist"))
    try write(setup, to: path("Library/Preferences/com.apple.SetupAssistant.plist"))
    try write(["SkipCloudSetup": true, "SkipSiriSetup": true, "SkipPrivacySetup": true,
               "SkipAccessibility": true, "SkipScreenTime": true, "SkipAppearance": true],
              to: path("Library/Preferences/com.apple.SetupAssistant.managed.plist"))
    let loginPath = try path("Library/Preferences/com.apple.loginwindow.plist")
    var login = fm.fileExists(atPath: loginPath.path) ? try read(loginPath) : [:]
    var info = login["AccountInfo"] as? [String: Any] ?? [:]
    info.removeValue(forKey: "FirstLogins"); info["MaximumUsers"] = 1
    login["AccountInfo"] = info; login["autoLoginUser"] = "serein"
    login["GuestEnabled"] = false; login["lastUser"] = "loggedIn"; login["lastUserName"] = "serein"
    try write(login, to: loginPath)
    try writeData(MacOfflineSetup.loginPassword(password), to: path("private/etc/kcpassword"), mode: 0o600)
    try writeData(Data(), to: path("private/var/db/.AppleSetupDone"), mode: 0o644)
    // It is a completion marker only after the installer validates every handle and makes
    // this last file root-owned. A caller-owned marker is never accepted by the guest.
    try writeData(Data(), to: path("private/var/db/.SereinOfflineSetupDone"), mode: 0o644)
  }

  private static func shadowHash(_ password: String) throws -> Data {
    var salt = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else { throw SereinError.invalid("The Mac account could not be secured.") }
    var bytes = [UInt8](repeating: 0, count: 128)
    let rounds: UInt32 = 210_000
    let status = password.withCString { pass in
      CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass, password.utf8.count, salt, salt.count,
                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds, &bytes, bytes.count)
    }
    guard status == kCCSuccess else { throw SereinError.invalid("The Mac account could not be secured.") }
    return try PropertyListSerialization.data(fromPropertyList: ["SALTED-SHA512-PBKDF2":
      ["entropy": Data(bytes), "salt": Data(salt), "iterations": rounds]], format: .binary, options: 0)
  }
  private static func safe(_ relative: String, in root: URL) throws -> URL {
    guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw SereinError.invalid("Invalid Mac setup path.") }
    var url = root
    for part in relative.split(separator: "/") {
      url.appendPathComponent(String(part))
      var info = stat()
      if lstat(url.path, &info) == 0 {
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFDIR || (kind == S_IFREG && info.st_nlink == 1) else {
          throw SereinError.invalid("An unexpected link in the Mac disk prevented automatic setup.")
        }
      } else if errno != ENOENT { throw SereinError.invalid("The Mac setup folder could not be inspected.") }
    }
    return url
  }
  private static func directory(_ url: URL, mode: Int) throws {
    try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
  }
  private static func read(_ url: URL) throws -> [String: Any] {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw SereinError.invalid("A Mac setup property list could not be read.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 1_048_576) ?? Data()
    guard data.count < 1_048_576, let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
      throw SereinError.invalid("A Mac setup property list is invalid.")
    }
    return value
  }
  private static func write(_ value: [String: Any], to url: URL, mode: Int = 0o644) throws {
    try writeData(PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0), to: url, mode: mode)
  }
  private static func writeData(_ data: Data, to url: URL, mode: Int) throws {
    try directory(url.deletingLastPathComponent(), mode: 0o700)
    // Preserve existing system-file inodes and ownership, as loginwindow/launchd expect.
    let fd = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
    guard fd >= 0 else { throw SereinError.invalid("A virtual Mac setup file could not be opened.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try handle.truncate(atOffset: 0); try handle.write(contentsOf: data); try handle.synchronize()
    guard fchmod(fd, mode_t(mode)) == 0 else { throw SereinError.invalid("A virtual Mac setup file could not be secured.") }
    try handle.close()
  }
  private static func validDevice(_ value: String) -> Bool { value.range(of: "^disk[0-9]+s[0-9]+$", options: .regularExpression) != nil }
  private static func plist(_ program: String, _ args: [String]) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: run(program, args), format: nil) as? [String: Any] else {
      throw SereinError.invalid("macOS returned an invalid virtual disk description.")
    }
    return value
  }
  private static func run(_ program: String, _ args: [String]) throws -> Data {
    let process = Process(); process.executableURL = URL(fileURLWithPath: program); process.arguments = args
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
    defer { timeout.cancel() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, data.count < 4_194_304 else { throw SereinError.invalid("macOS could not prepare the private virtual disk (\(URL(fileURLWithPath: program).lastPathComponent) \(args.first ?? ""), \(process.terminationStatus)).") }
    return data
  }
}
