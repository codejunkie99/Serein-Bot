import Darwin
import Foundation
import Security
import SereinCore
import ServiceManagement

@objc(SereinMacProvisioning) protocol MacProvisioningProtocol {
  func prepare(_ root: FileHandle, image: FileHandle, reply: @escaping (Bool) -> Void)
  func finish(_ root: FileHandle, image: FileHandle, files: [FileHandle], reply: @escaping (Bool) -> Void)
}

final class MacSetupAuthorization: @unchecked Sendable {
  private let service: SMAppService
  private let lock = NSLock()
  private var closed = false
  private init(service: SMAppService) { self.service = service }
  deinit { try? close() }

  /// Collect OS consent before a large download. The service has no work until finish sends
  /// the validated guest volume, and every completion/cancellation unregisters it.
  static func authorize(approvalNeeded: @escaping @Sendable () -> Void) throws -> MacSetupAuthorization {
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/serein-mac-provisioner")
    var main: SecCode?, mainStatic: SecStaticCode?, code: SecStaticCode?, mainInfo: CFDictionary?, helperInfo: CFDictionary?
    guard SecCodeCopySelf([], &main) == errSecSuccess, let main,
      SecCodeCopyStaticCode(main, [], &mainStatic) == errSecSuccess, let mainStatic,
      SecCodeCopySigningInformation(mainStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &mainInfo) == errSecSuccess,
      SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &helperInfo) == errSecSuccess,
      let own = mainInfo as? [String: Any], let tool = helperInfo as? [String: Any],
      let team = own[kSecCodeInfoTeamIdentifier as String] as? String,
      team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
      tool[kSecCodeInfoTeamIdentifier as String] as? String == team else {
      throw SereinError.invalid("A signed Serein installer helper is required to finish automatic Mac setup.")
    }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"serein-mac-provisioner\"" as CFString, [], &requirement) == errSecSuccess,
      let requirement, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
      throw SereinError.invalid("Serein’s Mac installer has an unexpected signing identity.")
    }
    let service = SMAppService.daemon(plistName: "pro.serein.mac-provisioner.plist")
    let authorization = MacSetupAuthorization(service: service)
    if service.status != .enabled && service.status != .requiresApproval {
      do { try service.register() }
      catch {
        guard service.status == .requiresApproval || service.status == .enabled else {
          throw SereinError.invalid("macOS could not register Serein’s Mac installer. Use a signed, notarized Serein build and allow its setup helper in System Settings › Login Items & Extensions.")
        }
      }
    }
    if service.status == .requiresApproval {
      approvalNeeded()
      DispatchQueue.main.async { SMAppService.openSystemSettingsLoginItems() }
    }
    // Keep the same approval request alive until the person approves or cancels setup.
    while service.status == .requiresApproval {
      try Task.checkCancellation()
      Thread.sleep(forTimeInterval: 0.25)
    }
    try Task.checkCancellation()
    guard service.status == .enabled else {
      throw SereinError.invalid("Allow Serein in System Settings › Login Items & Extensions to finish preparing its private Mac.")
    }
    return authorization
  }

  private func volumes(data: URL, disk: URL) throws -> (FileHandle, FileHandle) {
    guard service.status == .enabled else { throw SereinError.invalid("The Mac installer permission changed. Allow Serein in Login Items & Extensions, then retry setup.") }
    // Open with the app's existing volume permission. The system daemon must not reopen
    // removable storage under root's separate TCC identity or request Full Disk Access.
    let directory = open(data.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw SereinError.invalid("Serein could not open its mounted Mac data volume.") }
    let root = FileHandle(fileDescriptor: directory, closeOnDealloc: true)
    let imageFD = open(disk.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard imageFD >= 0 else { try? root.close(); throw SereinError.invalid("Serein could not open its private Mac disk.") }
    let image = FileHandle(fileDescriptor: imageFD, closeOnDealloc: true)
    return (root, image)
  }

  func prepare(data: URL, disk: URL) throws {
    let (root, image) = try volumes(data: data, disk: disk)
    defer { try? root.close(); try? image.close() }
    try call { remote, reply in remote.prepare(root, image: image, reply: reply) }
  }

  func finish(data: URL, disk: URL) throws {
    let (root, image) = try volumes(data: data, disk: disk)
    defer { try? root.close(); try? image.close() }
    // This order is checked independently by the installer; the completion marker is last.
    let names = ["private/var/db/.AppleSetupDone", "private/etc/kcpassword",
      "private/var/db/dslocal/nodes/Default/users/serein.plist",
      "private/var/db/dslocal/nodes/Default/groups/admin.plist", "private/var/db/dslocal/nodes/Default/groups/staff.plist",
      "Library/Preferences/com.apple.loginwindow.plist", "Library/Preferences/com.apple.SetupAssistant.plist",
      "Library/Preferences/com.apple.SetupAssistant.managed.plist", "Library/LaunchAgents/pro.serein.mac-bootstrap.plist",
      "private/var/db/.SereinOfflineSetupDone"]
    var files: [FileHandle] = []
    defer { for file in files { try? file.close() } }
    for name in names {
      let fd = openat(root.fileDescriptor, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw SereinError.invalid("Serein could not open its Mac setup files.") }
      files.append(FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }
    try call { remote, reply in remote.finish(root, image: image, files: files, reply: reply) }
    try close()
  }

  private func call(_ send: (MacProvisioningProtocol, @escaping (Bool) -> Void) -> Void) throws {
    let connection = NSXPCConnection(machServiceName: "pro.serein.mac-provisioner", options: .privileged)
    let interface = NSXPCInterface(with: MacProvisioningProtocol.self)
    interface.setClasses(NSSet(array: [NSArray.self, FileHandle.self]) as! Set<AnyHashable>,
      for: #selector(MacProvisioningProtocol.finish(_:image:files:reply:)), argumentIndex: 2, ofReply: false)
    connection.remoteObjectInterface = interface
    let result = MacSetupAuthorizationResult()
    connection.interruptionHandler = { result.finish(false) }
    connection.invalidationHandler = { result.finish(false) }
    connection.resume()
    defer { connection.invalidate() }
    guard let remote = connection.remoteObjectProxyWithErrorHandler({ _ in result.finish(false) }) as? MacProvisioningProtocol else {
      throw SereinError.invalid("Serein's Mac installer service could not connect.")
    }
    send(remote) { result.finish($0) }
    guard result.wait() else {
      throw SereinError.invalid("macOS could not finish the virtual disk’s ownership setup. Its backup is kept.")
    }
  }

  func close() throws {
    lock.lock(); defer { lock.unlock() }
    guard !closed else { return }
    if service.status != .notRegistered && service.status != .notFound { try service.unregister() }
    closed = true
  }
}

private final class MacSetupAuthorizationResult: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var answer: Bool?
  func finish(_ value: Bool) {
    lock.lock(); defer { lock.unlock() }
    guard answer == nil else { return }
    answer = value; semaphore.signal()
  }
  func wait() -> Bool {
    guard semaphore.wait(timeout: .now() + 120) == .success else { return false }
    lock.lock(); defer { lock.unlock() }
    return answer == true
  }
}
