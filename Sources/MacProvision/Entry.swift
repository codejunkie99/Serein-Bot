import Darwin
import Foundation
import Security

@objc(SereinMacProvisioning) protocol MacProvisioningProtocol {
  func prepare(_ root: FileHandle, image: FileHandle, reply: @escaping (Bool) -> Void)
  func finish(_ root: FileHandle, image: FileHandle, files: [FileHandle], reply: @escaping (Bool) -> Void)
}

private final class ProvisioningSession: NSObject, MacProvisioningProtocol {
  let owner: uid_t
  init(owner: uid_t) { self.owner = owner }
  func prepare(_ root: FileHandle, image: FileHandle, reply: @escaping (Bool) -> Void) {
    do { try MacProvision.prepare(owner: owner, root: root, image: image); reply(true) }
    catch {
      NSLog("Serein offline preparation failed at %@", (error as? MacProvision.Failure)?.stage ?? "system")
      reply(false)
    }
  }
  func finish(_ root: FileHandle, image: FileHandle, files: [FileHandle], reply: @escaping (Bool) -> Void) {
    do { try MacProvision.run(owner: owner, root: root, image: image, files: files); reply(true) }
    catch {
      NSLog("Serein offline finalization failed at %@", (error as? MacProvision.Failure)?.stage ?? "system")
      reply(false)
    }
  }
}

private final class ProvisioningListener: NSObject, NSXPCListenerDelegate {
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier >= 501,
      let own = signingInfo(pid: getpid()),
      let team = own[kSecCodeInfoTeamIdentifier as String] as? String,
      team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"local.serein.browser\"" as CFString, [], &requirement) == errSecSuccess,
      let requirement, let client = signingInfo(pid: connection.processIdentifier, requirement: requirement),
      client[kSecCodeInfoTeamIdentifier as String] as? String == team,
      client[kSecCodeInfoIdentifier as String] as? String == "local.serein.browser" else { return false }
    let interface = NSXPCInterface(with: MacProvisioningProtocol.self)
    interface.setClasses(NSSet(array: [NSArray.self, FileHandle.self]) as! Set<AnyHashable>,
      for: #selector(MacProvisioningProtocol.finish(_:image:files:reply:)), argumentIndex: 2, ofReply: false)
    connection.exportedInterface = interface
    connection.exportedObject = ProvisioningSession(owner: connection.effectiveUserIdentifier)
    connection.resume()
    return true
  }
  private func signingInfo(pid: pid_t, requirement: SecRequirement? = nil) -> [String: Any]? {
    var code: SecCode?, reference: SecStaticCode?, info: CFDictionary?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) == errSecSuccess,
      let code, SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
      SecCodeCopyStaticCode(code, [], &reference) == errSecSuccess, let reference,
      SecCodeCopySigningInformation(reference, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
    return info as? [String: Any]
  }
}

/// Installer service registered only during setup, never an agent tool. Only fixed regular files
/// on the Data volume of the calling user's disk image can receive root ownership.
@main enum MacProvision {
  static func main() {
    #if DEBUG
    if CommandLine.arguments.contains("--verify-boundaries"), geteuid() != 0 {
      do { try checkBoundaries(); exit(0) }
      catch { fputs("FAIL: installer boundary checks\n", stderr); exit(1) }
    }
    #endif
    guard geteuid() == 0 else { exit(1) }
    let listener = NSXPCListener(machServiceName: "pro.serein.mac-provisioner")
    let delegate = ProvisioningListener()
    listener.delegate = delegate
    listener.resume()
    withExtendedLifetime(delegate) { RunLoop.current.run() }
  }

  private static func boundVolume(owner: uid_t, root: FileHandle, image: FileHandle) throws -> (info: stat, device: String, roots: [String]) {
    guard geteuid() == 0, owner >= 501, owner < 60000,
      let user = getpwuid(owner) else { throw Failure("caller") }
    let home = String(cString: user.pointee.pw_dir)
    let rootFD = root.fileDescriptor, imageFD = image.fileDescriptor
    let rootPath = try filePath(rootFD), imagePath = try filePath(imageFD)
    guard rootPath.hasPrefix(home + "/Library/Caches/Serein/mac-setup-"),
      URL(fileURLWithPath: rootPath).standardizedFileURL.path == rootPath,
      URL(fileURLWithPath: imagePath).lastPathComponent == "disk.img" else { throw Failure("request") }
    var imageInfo = stat(), imageFS = statfs()
    guard fstat(imageFD, &imageInfo) == 0, imageInfo.st_mode & S_IFMT == S_IFREG,
      fstatfs(imageFD, &imageFS) == 0, imageInfo.st_nlink == 1,
      fcntl(imageFD, F_GETFL) & O_ACCMODE == O_RDWR,
      // An external volume with owners disabled does not report meaningful ownership.
      // The writable descriptor proves the signed caller already had disk write access.
      imageInfo.st_uid == owner || imageFS.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 else {
      NSLog("Serein disk descriptor rejected: uid=%u links=%llu mode=%u flags=%d mount=%u",
        imageInfo.st_uid, UInt64(imageInfo.st_nlink), UInt32(imageInfo.st_mode), fcntl(imageFD, F_GETFL), imageFS.f_flags)
      throw Failure("disk")
    }
    var rootInfo = stat(), filesystem = statfs()
    guard fstat(rootFD, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
      fstatfs(rootFD, &filesystem) == 0 else { throw Failure("mount") }
    let device = withUnsafePointer(to: &filesystem.f_mntfromname) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
    }
    guard device.range(of: "^/dev/disk[0-9]+s[0-9]+$", options: .regularExpression) != nil else { throw Failure("device") }
    // Tie the mounted filesystem back to that exact regular disk image. Physical host
    // volumes, unmounted directories and images belonging to other users are refused.
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); process.arguments = ["info", "-plist"]
    let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0, data.count < 4_194_304,
      let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let images = info["images"] as? [[String: Any]],
      let attached = images.first(where: { entry in
        entry["image-path"] as? String == imagePath
          && (entry["system-entities"] as? [[String: Any]])?.contains(where: { $0["dev-entry"] as? String == device }) == true
      }) else { throw Failure("image-binding") }
    // APFS firmlinks can report a Data file through this image's System mount. Accept
    // only mount aliases independently listed for that same image, under its private
    // mount directory; every file must still have the Data volume's exact device ID.
    let mountParent = URL(fileURLWithPath: rootPath).deletingLastPathComponent().path
    let roots = (attached["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }.filter {
      URL(fileURLWithPath: $0).deletingLastPathComponent().path == mountParent
        && URL(fileURLWithPath: $0).standardizedFileURL.path == $0
    }
    guard roots.contains(rootPath) else { throw Failure("mount-aliases") }
    return (rootInfo, device, roots)
  }

  fileprivate static func prepare(owner: uid_t, root: FileHandle, image: FileHandle) throws {
    let volume = try boundVolume(owner: owner, root: root, image: image)
    // A retry may attach a guest volume whose ownership was enabled by the previous
    // finalization. Only this exact private image is made writable for offline setup.
    try setOwnership(false, device: volume.device, root: root.fileDescriptor)
  }

  fileprivate static func run(owner: uid_t, root: FileHandle, image: FileHandle, files: [FileHandle]) throws {
    let volume = try boundVolume(owner: owner, root: root, image: image)
    let roots = volume.roots, rootInfo = volume.info
    let expected: [(String, mode_t)] = [
      ("private/var/db/.AppleSetupDone", 0o644), ("private/etc/kcpassword", 0o600),
      ("private/var/db/dslocal/nodes/Default/users/serein.plist", 0o600),
      ("private/var/db/dslocal/nodes/Default/groups/admin.plist", 0o600),
      ("private/var/db/dslocal/nodes/Default/groups/staff.plist", 0o600),
      ("Library/Preferences/com.apple.loginwindow.plist", 0o644),
      ("Library/Preferences/com.apple.SetupAssistant.plist", 0o644),
      ("Library/Preferences/com.apple.SetupAssistant.managed.plist", 0o644),
      ("Library/LaunchAgents/pro.serein.mac-bootstrap.plist", 0o644),
      ("private/var/db/.SereinOfflineSetupDone", 0o644),
    ]
    guard files.count == expected.count else { throw Failure("file-count") }
    // Validate all descriptors before making any change. Their kernel paths must be the
    // fixed guest files on that exact mounted image, never arbitrary caller-supplied paths.
    for (index, file) in files.enumerated() {
      guard validFile(file.fileDescriptor, device: rootInfo.st_dev, owner: owner,
        paths: roots.map { $0 + "/" + expected[index].0 }) else {
        var info = stat(), fs = statfs()
        let status = fstat(file.fileDescriptor, &info), fsStatus = fstatfs(file.fileDescriptor, &fs)
        let matches = roots.contains { (try? filePath(file.fileDescriptor)) == $0 + "/" + expected[index].0 }
        NSLog("Serein file descriptor rejected: index=%d stat=%d fs=%d uid=%u links=%llu mode=%u sameDevice=%d flags=%d mount=%u path=%d",
          index, status, fsStatus, info.st_uid, UInt64(info.st_nlink), UInt32(info.st_mode),
          info.st_dev == rootInfo.st_dev ? 1 : 0, fcntl(file.fileDescriptor, F_GETFL), fs.f_flags, matches ? 1 : 0)
        throw Failure("file-\(index)")
      }
    }
    // chown can succeed without persisting a new owner on an ownership-ignored mount.
    // Enable ownership only on this validated private guest Data volume, never on the
    // host disk or external SSD. All caller-provided handles have been validated above.
    try setOwnership(true, device: volume.device, root: root.fileDescriptor)
    for (index, file) in files.enumerated() {
      guard fchown(file.fileDescriptor, 0, 0) == 0, fchmod(file.fileDescriptor, expected[index].1) == 0,
        fsync(file.fileDescriptor) == 0 else { throw Failure("ownership-\(index)") }
      var stored = stat()
      guard fstat(file.fileDescriptor, &stored) == 0, stored.st_uid == 0,
        stored.st_gid == 0, stored.st_mode & 0o777 == expected[index].1 else { throw Failure("stored-owner-\(index)") }
    }
  }

  private static func setOwnership(_ enabled: Bool, device: String, root: Int32) throws {
    var filesystem = statfs()
    guard fstatfs(root, &filesystem) == 0 else { throw Failure("ownership-mount") }
    if (filesystem.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0) == enabled { return }
    let operation = Process(); operation.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    operation.arguments = [enabled ? "enableOwnership" : "disableOwnership", device]
    operation.standardOutput = FileHandle.nullDevice; operation.standardError = FileHandle.nullDevice
    try operation.run(); operation.waitUntilExit()
    guard operation.terminationStatus == 0, fstatfs(root, &filesystem) == 0,
      (filesystem.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0) == enabled else { throw Failure("ownership-mount") }
  }

  private static func filePath(_ fd: Int32) throws -> String {
    var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &bytes) == 0 else { throw Failure("descriptor-path") }
    return String(cString: bytes)
  }

  private static func validFile(_ fd: Int32, device: dev_t, owner: uid_t, paths: [String]) -> Bool {
    var file = stat(), filesystem = statfs()
    return fstat(fd, &file) == 0 && file.st_mode & S_IFMT == S_IFREG && file.st_nlink == 1
      && file.st_dev == device && fstatfs(fd, &filesystem) == 0
      && fcntl(fd, F_GETFL) & O_ACCMODE == O_RDWR
      && (file.st_uid == owner || file.st_uid == 0 || filesystem.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0)
      && (try? filePath(fd)).map { paths.contains($0) } == true
  }

  #if DEBUG
  private static func checkBoundaries() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("serein-installer-boundaries-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let value = root.appendingPathComponent("value")
    try Data("synthetic".utf8).write(to: value)
    guard let resolved = realpath(root.path, nil) else { throw Failure() }
    let canonical = String(cString: resolved)
    free(resolved)
    let expected = canonical + "/value"
    let file = open(expected, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard file >= 0 else { throw Failure() }
    defer { close(file) }
    var info = stat()
    guard fstat(file, &info) == 0,
      validFile(file, device: info.st_dev, owner: getuid(), paths: [expected]),
      !validFile(file, device: info.st_dev + 1, owner: getuid(), paths: [expected]),
      !validFile(file, device: info.st_dev, owner: getuid() + 1, paths: [expected]) else { throw Failure() }
    print("PASS: installer file validation pins device and owner")
    let readOnly = open(expected, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard readOnly >= 0 else { throw Failure() }
    defer { close(readOnly) }
    guard !validFile(readOnly, device: info.st_dev, owner: getuid(), paths: [expected]) else { throw Failure() }
    print("PASS: read-only caller access cannot authorize ownership changes")
    guard !validFile(file, device: info.st_dev, owner: getuid(), paths: [canonical + "/other"]) else { throw Failure() }
    print("PASS: a descriptor for a different fixed path is refused")
    try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root)
    let redirected = open(canonical + "/escape/value", O_RDWR | O_CLOEXEC)
    guard redirected >= 0 else { throw Failure() }
    defer { close(redirected) }
    guard !validFile(redirected, device: info.st_dev, owner: getuid(), paths: [canonical + "/escape/value"]) else { throw Failure() }
    print("PASS: a symlink cannot redirect a fixed guest file to another kernel path")
    try fm.linkItem(at: value, to: root.appendingPathComponent("hardlink"))
    guard !validFile(file, device: info.st_dev, owner: getuid(), paths: [expected]) else { throw Failure() }
    print("PASS: installer refuses hard-linked files")
  }
  #endif
  fileprivate struct Failure: Error {
    let stage: String
    init(_ stage: String = "path") { self.stage = stage }
  }
}
