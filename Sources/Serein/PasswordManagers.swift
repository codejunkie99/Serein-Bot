import Darwin
import Foundation
import Security
import SereinCore
import SwiftUI

/// The person's own password manager, reached through its command-line tool for Sign in as … on a
/// task's sign-in page only (PasswordManagers). No tool, helper or setting an agent reads reaches it.
enum PasswordManager: String, CaseIterable {
  case onePassword, bitwarden
  var name: String { self == .onePassword ? "1Password" : "Bitwarden" }
  var command: String { self == .onePassword ? "op" : "bw" }
  /// Where the tools' installers put them. Never PATH: an agent's shell or a project could put
  /// another `op` or `bw` first.
  static let folders = ["/opt/homebrew/bin", "/usr/local/bin"]
  /// The maker's Developer ID signature the tool must carry: Apple's anchor, a Developer ID
  /// certificate and the maker's team (1Password: AgileBits Inc.; Bitwarden: Bitwarden Inc).
  /// Owner and mode alone cannot tell the real tool from a script an agent's shell, running as
  /// the person, wrote into the person's own Homebrew folder.
  var requirement: String {
    let team = self == .onePassword ? "2BUA8C4S2C" : "LTZ2PFU5D6"
    return "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
      + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
  }
  /// Why a tool that is there but not the maker's signed one does not run.
  var unsigned: String {
    self == .onePassword
      ? "This op is not 1Password's signed tool, so Serein does not run it. Install the signed 1Password CLI from 1password.com/downloads/command-line (or the Homebrew cask 1password-cli). Nothing was filled."
      : "This bw is not Bitwarden's signed tool, so Serein does not run it. Install the signed Bitwarden CLI for macOS from bitwarden.com/download in /usr/local/bin; Homebrew's bitwarden-cli formula is an unsigned build. Nothing was filled."
  }
  /// Cheap, for drawing (the menu, the Settings line): the first file named for the tool,
  /// followed through its links to a regular executable file that group and others cannot write,
  /// in a folder others cannot write, each owned by root or this user. Never run as found here.
  var installed: URL? { Self.folders.lazy.map { file(in: $0) }.first { Self.trusted($0) } }
  /// The tool Serein runs: the first folder's file that passes `trusted` and carries the maker's
  /// signature (`requirement`), so a fake in /opt/homebrew/bin cannot shadow a real one in
  /// /usr/local/bin; nil when neither does.
  var executable: URL? {
    Self.folders.lazy.map { file(in: $0) }.first { Self.trusted($0) && Self.signed($0, requirement) }
  }
  private func file(in folder: String) -> URL {
    URL(fileURLWithPath: folder).appendingPathComponent(command).resolvingSymlinksInPath()
  }
  /// The file on disk carries a valid signature, strictly validated for every architecture, that
  /// meets `requirement`.
  static func signed(_ file: URL, _ requirement: String) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code,
      let req = compiled(requirement)
    else { return false }
    let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckAllArchitectures))
    return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
  }
  /// The process `pid` runs code that meets `requirement`. Asked for up to a second, since the
  /// process host (ProcessGroup) execs into the tool under the same pid only after it starts.
  static func running(_ pid: pid_t, _ requirement: String) -> Bool {
    guard let req = compiled(requirement) else { return false }
    let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
    for _ in 0..<20 {
      var code: SecCode?
      if SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
        SecCodeCheckValidity(code, [], req) == errSecSuccess
      { return true }
      usleep(50_000)
    }
    return false
  }
  private static func compiled(_ text: String) -> SecRequirement? {
    var req: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess else { return nil }
    return req
  }
  private static func trusted(_ file: URL) -> Bool {
    var info = stat()
    var folder = stat()
    guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_mode & 0o022 == 0,
      info.st_uid == 0 || info.st_uid == getuid(),
      lstat(file.deletingLastPathComponent().path, &folder) == 0, (folder.st_mode & S_IFMT) == S_IFDIR,
      folder.st_mode & 0o002 == 0, folder.st_uid == 0 || folder.st_uid == getuid()
    else { return false }
    return FileManager.default.isExecutableFile(atPath: file.path)
  }
}

/// One login a password manager holds for the page: its id and the words to tell it apart. No
/// password: that is read from the manager only when the person picks the login.
struct ManagerLogin: Identifiable {
  var id: String
  var title: String
  var username: String
  /// Bitwarden asks for the master password again before this login is used.
  var reprompt = false
}

/// Sign in as … › 1Password… or Bitwarden…, as the person chose it on a task's sign-in page: the
/// manager, the tab, its exact HTTPS origin and the page version then (`pageVersion`), so a page
/// that moves on gets nothing.
struct ManagerSignIn: Identifiable {
  let id = UUID()
  let manager: PasswordManager
  let tab: BrowserTab
  let browser: BrowserModel
  let origin: String
  let pageVersion: String
}

/// Logins from 1Password (`op`, unlocked by its app) and Bitwarden (`bw`, unlocked by the master
/// password the person types in Serein's sheet) for Sign in as … on a task's sign-in page, when
/// Settings › Passwords turns it on. Only the person's pick in that menu starts it; the fill is
/// `PasswordCapture.fillForTask`'s, as for a saved login: the same origin checks, nothing is sent,
/// then Hand back. The tools run from a fixed, checked path with a minimal environment of their
/// own; Bitwarden's session key lives only here and only for ten minutes; nothing they print is
/// logged or kept.
@MainActor final class PasswordManagers: ObservableObject {
  static let shared = PasswordManagers()
  /// Settings › Passwords › Password managers (GateSettings; off, and off while that file cannot
  /// be read).
  static let enabledKey = "serein.passwords.managers"
  static var enabled: Bool { GateSettings.shared.bool(forKey: enabledKey) }
  /// How long a Bitwarden unlock lasts, from the unlock.
  static let sessionLife: TimeInterval = 600
  /// The sign-in the person opened from Sign in as …, shown as a sheet over the window.
  @Published var request: ManagerSignIn?
  /// Bitwarden's session key: in memory only, never on disk or in Keychain, passed only to the
  /// `bw` it starts, and dropped at `until` or when the switch goes off.
  private var session: (key: String, until: Date)?
  private var expiry: Task<Void, Never>?
  /// The `bw lock` that `dropSession` started; an unlock waits for it, so it cannot lock the new
  /// session.
  private var locking: Task<Void, Never>?

  /// The managers Sign in as … lists on this tab: the switch is on, the page is one it fills and
  /// the tool is installed. Read while drawing; nothing runs.
  func offered(for tab: BrowserTab, browser: BrowserModel) -> [PasswordManager] {
    guard Self.enabled, PasswordVault.shared.managerOrigin(for: tab, browser: browser) != nil else { return [] }
    return PasswordManager.allCases.filter { $0.installed != nil }
  }

  /// The person chose 1Password… or Bitwarden… in Sign in as …: the sheet opens for this page.
  func begin(_ manager: PasswordManager, tab: BrowserTab, browser: BrowserModel) {
    if manager.installed != nil, manager.executable == nil {
      browser.notice = manager.unsigned
      return
    }
    guard Self.enabled, manager.executable != nil,
      let origin = PasswordVault.shared.managerOrigin(for: tab, browser: browser)
    else {
      browser.notice = "This sign-in is no longer offered. Nothing was filled."
      return
    }
    request = ManagerSignIn(manager: manager, tab: tab, browser: browser, origin: origin, pageVersion: tab.pageVersion)
  }

  /// Still the page the person chose this on: the sheet is still open for it (Cancel ends a
  /// sign-in in flight), the switch is on, the task's tab is at the same sign-in page and origin,
  /// and its certificate was not bypassed.
  private func stillOffered(_ request: ManagerSignIn) -> Bool {
    self.request?.id == request.id && Self.enabled && request.tab.pageVersion == request.pageVersion
      && PasswordVault.shared.managerOrigin(for: request.tab, browser: request.browser) == request.origin
      && !PasswordCapture.certificateBypassed(request.tab)
  }
  private static let noLonger = SereinError.invalid("This sign-in is no longer offered. Nothing was filled.")
  private static let changed = SereinError.invalid("The page changed. Nothing was filled.")

  // MARK: Bitwarden's unlock

  var bitwardenLocked: Bool { currentSession() == nil }
  private func currentSession() -> String? {
    guard let session, session.until > Date() else {
      dropSession()
      return nil
    }
    return session.key
  }
  /// Forgets the Bitwarden session key (its time is up, it stopped working, or the switch went off)
  /// and locks Bitwarden's tool, so a copy of the key (another process of the person's user can
  /// read a child's environment) stops opening the vault too. Errors are ignored.
  func dropSession() {
    let held = session != nil
    session = nil
    expiry?.cancel()
    expiry = nil
    guard held, let tool = PasswordManager.bitwarden.executable else { return }
    let requirement = PasswordManager.bitwarden.requirement
    locking = Task.detached {
      _ = try? await ManagerCLI.run(tool, ["lock", "--nointeraction"], requirement: requirement, timeout: 30)
    }
  }
  /// The master password goes to `bw unlock` on its standard input, once; Serein keeps only the
  /// session key it prints, for `sessionLife`.
  func unlockBitwarden(_ master: String) async throws {
    guard Self.enabled, let tool = PasswordManager.bitwarden.executable else { throw Self.noLonger }
    guard !master.isEmpty else { throw SereinError.invalid("Type your Bitwarden master password.") }
    await locking?.value
    locking = nil
    let output: Data
    do {
      output = try await ManagerCLI.run(
        tool, ["unlock", "--raw", "--nointeraction", "--passwordfile", "/dev/stdin"],
        input: Data((master + "\n").utf8), requirement: PasswordManager.bitwarden.requirement, timeout: 60)
    } catch {
      throw SereinError.invalid(
        "Bitwarden did not unlock. Check the master password, and that this Mac is signed in to Bitwarden (bw login in Terminal).")
    }
    let key = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key.count <= 1024, !key.contains(where: { $0.isWhitespace }) else {
      throw SereinError.invalid("Bitwarden did not unlock.")
    }
    let until = Date().addingTimeInterval(Self.sessionLife)
    session = (key, until)
    expiry?.cancel()
    expiry = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(PasswordManagers.sessionLife * 1e9))
      guard !Task.isCancelled else { return }
      self?.dropSession()
    }
  }

  // MARK: Logins

  /// The manager's logins with a URL entry for exactly the page's HTTPS origin. 1Password unlocks
  /// with its own app here; Bitwarden needs `unlockBitwarden` first.
  func logins(for request: ManagerSignIn) async throws -> [ManagerLogin] {
    guard stillOffered(request), let tool = request.manager.executable else { throw Self.noLonger }
    let found: [ManagerLogin]
    switch request.manager {
    case .onePassword:
      let output: Data
      do {
        output = try await ManagerCLI.run(
          tool, ["item", "list", "--categories", "Login", "--format", "json"],
          requirement: request.manager.requirement, timeout: 120)
      } catch {
        throw SereinError.invalid("1Password did not answer. Unlock it, and turn on its command-line integration in 1Password's settings.")
      }
      guard let items = try? Self.snakeCase.decode([OnePasswordItem].self, from: output) else {
        throw SereinError.invalid("1Password's answer could not be read. Nothing was filled.")
      }
      found = items.filter { Self.safeID($0.id) && $0.matches(request.origin) }
        .map { ManagerLogin(id: $0.id, title: $0.title ?? "", username: $0.additionalInformation ?? "") }
    case .bitwarden:
      // The manager's own match on the address narrows the list; the exact origin decides.
      let items: [BitwardenItem] = try await bitwarden(tool, ["list", "items", "--url", request.origin])
      found = items.filter { Self.safeID($0.id) && $0.matches(request.origin) }
        .map { ManagerLogin(id: $0.id, title: $0.name ?? "", username: $0.login?.username ?? "", reprompt: $0.reprompt == 1) }
    }
    return found.sorted { ($0.username, $0.title) < ($1.username, $1.title) }
  }

  /// The person picked `login`. Unless they typed Bitwarden's master password in this sheet just
  /// now (`unlockedNow`), device authentication comes first, as for a saved login. The login is
  /// read again from the manager and must still name exactly this origin; the tab then becomes the
  /// person's (`takeOver`) and `PasswordCapture.fillForTask` fills it, sending nothing. The
  /// password is held only for the fill.
  func signIn(_ login: ManagerLogin, request: ManagerSignIn, unlockedNow: Bool) async throws {
    let tab = request.tab
    guard stillOffered(request), Self.safeID(login.id), let tool = request.manager.executable else {
      throw Self.noLonger
    }
    guard !login.reprompt || unlockedNow else {
      throw SereinError.invalid("Bitwarden asks for your master password for this login. Nothing was filled.")
    }
    if !unlockedNow {
      let host = CredentialOrigin.displayHost(request.origin)
      try await PasswordVault.shared.authenticate(
        (login.username.isEmpty ? "sign in on \(host)" : "sign in as \(login.username) on \(host)")
          + " with \(request.manager.name)")
      guard stillOffered(request) else { throw Self.changed }
    }
    let password: String?
    let username: String
    switch request.manager {
    case .onePassword:
      let output: Data
      do {
        output = try await ManagerCLI.run(
          tool, ["item", "get", login.id, "--reveal", "--format", "json"],
          requirement: request.manager.requirement, timeout: 120)
      } catch { throw SereinError.invalid("1Password did not give this login. Nothing was filled.") }
      guard let item = try? Self.snakeCase.decode(OnePasswordItem.self, from: output), item.id == login.id,
        item.matches(request.origin)
      else { throw SereinError.invalid("This login is not saved for this site in 1Password. Nothing was filled.") }
      password = item.fields?.first { $0.purpose == "PASSWORD" }?.value
      username = item.fields?.first { $0.purpose == "USERNAME" }?.value ?? item.additionalInformation ?? ""
    case .bitwarden:
      let item: BitwardenItem = try await bitwarden(tool, ["get", "item", login.id])
      guard item.id == login.id, item.matches(request.origin) else {
        throw SereinError.invalid("This login is not saved for this site in Bitwarden. Nothing was filled.")
      }
      password = item.login?.password
      username = item.login?.username ?? ""
    }
    guard let secret = password, !secret.isEmpty, secret.count <= 1024 else {
      throw SereinError.invalid("This login has no password in \(request.manager.name). Nothing was filled.")
    }
    // The page or the task may have changed while the manager answered.
    guard stillOffered(request) else { throw Self.changed }
    request.browser.takeOver(tab)
    guard tab.owner == nil else { throw SereinError.invalid("The tab could not be handed to you. Nothing was filled.") }
    let item = Credential(id: request.manager.rawValue + ":" + login.id, origin: request.origin, username: username)
    try await PasswordCapture.fillForTask(
      item, password: { secret }, code: { nil }, pageVersion: request.pageVersion, in: tab)
  }

  /// One `bw` command with the session key in its own environment, decoded. A failure drops the
  /// key (it was locked elsewhere, or its time is up), so the sheet asks for the master password.
  private func bitwarden<T: Decodable>(_ tool: URL, _ arguments: [String]) async throws -> T {
    guard let key = currentSession() else {
      throw SereinError.invalid("Bitwarden is locked. Type your master password.")
    }
    do {
      let output = try await ManagerCLI.run(
        tool, arguments + ["--nointeraction"], session: key, requirement: PasswordManager.bitwarden.requirement,
        timeout: 30)
      return try JSONDecoder().decode(T.self, from: output)
    } catch {
      dropSession()
      throw SereinError.invalid("Bitwarden is locked. Type your master password.")
    }
  }

  /// Ids go on the tool's command line, so only letters, digits and hyphens, never a leading one.
  private static func safeID(_ id: String) -> Bool {
    guard !id.isEmpty, id.count <= 64, id.first != "-" else { return false }
    return id.allSatisfy { (c: Character) -> Bool in c.isASCII && (c.isLetter || c.isNumber || c == "-") }
  }
  private static let snakeCase: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  /// A manager's URL entry against the page: exact HTTPS origin only. An entry with no scheme
  /// ("example.com") means HTTPS; another scheme or port, a subdomain or a look-alike is no match.
  nonisolated static func matches(_ entry: String?, _ origin: String) -> Bool {
    guard let raw = entry?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
    return CredentialOrigin.matchesForTask(raw.contains("://") ? raw : "https://" + raw, page: origin)
  }
}

/// What `op item list` and `op item get --format json` print, as far as Sign in as … reads it.
private struct OnePasswordItem: Decodable {
  struct Link: Decodable { var href: String? }
  struct Field: Decodable {
    var purpose: String?
    var value: String?
  }
  var id: String
  var title: String?
  /// A login's username in the list.
  var additionalInformation: String?
  var urls: [Link]?
  /// Only in `op item get`.
  var fields: [Field]?
  func matches(_ origin: String) -> Bool { urls?.contains { PasswordManagers.matches($0.href, origin) } == true }
}

/// What `bw list items` and `bw get item` print, as far as Sign in as … reads it.
private struct BitwardenItem: Decodable {
  struct Login: Decodable {
    struct Address: Decodable {
      var uri: String?
      /// Bitwarden's match rule: 4 is a regular expression and 5 is never, so neither counts here.
      var match: Int?
    }
    var username: String?
    var password: String?
    var uris: [Address]?
  }
  var id: String
  /// 1 is a login.
  var type: Int
  var name: String?
  var reprompt: Int?
  var login: Login?
  func matches(_ origin: String) -> Bool {
    type == 1
      && login?.uris?.contains { ![4, 5].contains($0.match ?? 0) && PasswordManagers.matches($0.uri, origin) } == true
  }
}

/// Runs one password manager command: the checked executable in a session of its own
/// (ProcessGroup), with a minimal environment (nothing of Serein's or an agent's), standard error
/// discarded, and only the given input. The file's signature is checked against `requirement`
/// again right before it starts, and the running process's before any input goes in or any
/// output counts. Its output is returned and never logged.
enum ManagerCLI {
  struct Failed: Error {}
  static func run(
    _ tool: URL, _ arguments: [String], input: Data? = nil, session: String? = nil, requirement: String,
    timeout: TimeInterval
  ) async throws -> Data {
    let process = Process()
    process.executableURL = tool
    process.arguments = arguments
    var environment = [
      "HOME": NSHomeDirectory(), "USER": NSUserName(), "LOGNAME": NSUserName(),
      "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
      "TMPDIR": NSTemporaryDirectory(),
    ]
    if let session { environment["BW_SESSION"] = session }
    process.environment = environment
    process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    try ProcessGroup.configure(process)
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    return try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        guard PasswordManager.signed(tool, requirement) else {
          done.resume(throwing: Failed())
          return
        }
        do { try process.run() } catch {
          done.resume(throwing: error)
          return
        }
        // The file may have been swapped between the check and the start: the running code counts.
        guard PasswordManager.running(process.processIdentifier, requirement) else {
          ProcessGroup.terminate(process)
          done.resume(throwing: Failed())
          return
        }
        if let input {
          let writer = stdin.fileHandleForWriting
          _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
          try? writer.write(contentsOf: input)
          try? writer.close()
        }
        let deadline = DispatchWorkItem { ProcessGroup.terminate(process) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
          done.resume(throwing: Failed())
          return
        }
        done.resume(returning: output)
      }
    }
  }
}

/// Settings › Passwords › Password managers: the switch for 1Password and Bitwarden in Sign in as ….
struct PasswordManagerSettings: View {
  @GateStorage(PasswordManagers.enabledKey) private var enabled = false
  @Environment(\.palette) var p
  var body: some View {
    let found = PasswordManager.allCases.filter { $0.installed != nil }.map(\.name)
    let foundLine: String = found.isEmpty
      ? "Neither tool is installed in /opt/homebrew/bin or /usr/local/bin."
      : "Found: \(found.joined(separator: ", "))."
    VStack(alignment: .leading, spacing: 6) {
      Toggle(
        "Offer 1Password and Bitwarden in Sign in as",
        isOn: Binding(get: { enabled }, set: { on in
          enabled = on
          if !on { PasswordManagers.shared.dropSession() }
        })
      ).toggleStyle(SettingsToggleStyle())
      Text(
        "On a task's sign-in page, Sign in as also offers your logins saved for exactly that HTTPS address in 1Password (unlocked by its app) or Bitwarden (unlocked by your master password; Serein keeps it unlocked in memory for 10 minutes). Each needs its maker's signed command-line tool: 1Password's, or Bitwarden's from bitwarden.com. Serein won't run the Homebrew version of Bitwarden's. Only your click starts it; agents never reach either. "
          + foundLine
      ).font(UIStyle.font(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Sign in as … › 1Password… or Bitwarden…: Bitwarden's master password (when it is locked), the
/// manager's logins for exactly this origin, and the pick, which fills the page
/// (PasswordManagers.signIn). Shown over the window, so it stays when the tab's bubble closes.
struct ManagerSignInSheet: View {
  let request: ManagerSignIn
  @ObservedObject private var managers = PasswordManagers.shared
  @Environment(\.palette) var p
  private enum Phase {
    case waiting, locked, choose([ManagerLogin]), failed
  }
  @State private var phase = Phase.waiting
  @State private var master = ""
  @State private var status = ""
  @State private var busy = false
  /// Bitwarden was unlocked with the master password in this sheet.
  @State private var unlockedHere = false
  /// A login that asked for the master password again; it is filled after the unlock.
  @State private var pending: ManagerLogin?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sign in with \(request.manager.name)").font(UIStyle.section)
      Text(request.origin).font(UIStyle.mono(12)).foregroundStyle(p.secondary)
      switch phase {
      case .waiting:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Waiting for \(request.manager.name)…").foregroundStyle(p.secondary)
        }
      case .locked:
        Text(
          pending == nil
            ? "Type your Bitwarden master password. Serein hands it to Bitwarden's own tool once and does not keep it; Bitwarden stays unlocked for Serein for 10 minutes, in memory only."
            : "Bitwarden asks for your master password again for this login."
        ).font(UIStyle.font(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
        SecureField("Master password", text: $master).textFieldStyle(.plain).textInputCursor().padding(8)
          .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
          .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(p.borderStrong))
          .onSubmit { unlock() }
          .accessibilityLabel("Bitwarden master password")
      case .choose(let logins):
        if logins.isEmpty {
          Text("No login in \(request.manager.name) is saved for exactly \(request.origin).")
            .font(UIStyle.font(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(logins) { login in
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text(login.username.isEmpty ? login.title : login.username).lineLimit(1).truncationMode(.middle)
              if !login.username.isEmpty, !login.title.isEmpty {
                Text(login.title).font(UIStyle.font(12)).foregroundStyle(p.secondary).lineLimit(1)
              }
            }
            Spacer()
            signInButton(login, primary: logins.count == 1)
          }.padding(.vertical, 6).overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }
        }
      case .failed:
        EmptyView()
      }
      Text("Serein fills the sign-in on this page; you press the page's own button. The agent never sees it.")
        .font(UIStyle.font(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        if failed { Button("Try again") { Task { await look() } }.disabled(busy) }
        Spacer()
        Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
        if locked {
          Button("Unlock") { unlock() }.buttonStyle(PrimaryButton()).disabled(master.isEmpty || busy)
        }
      }
      if !status.isEmpty {
        Text(status).font(UIStyle.font(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(20).frame(width: UIStyle.wide(420)).background(p.panel).foregroundStyle(p.ink)
      .font(UIStyle.font(13)).buttonStyle(QuietButton()).controlSize(.small)
      .task { await look() }
      .onDisappear { master = "" }
  }
  /// One white action per sheet: the button is primary only when it is the one login.
  @ViewBuilder private func signInButton(_ login: ManagerLogin, primary: Bool) -> some View {
    let button = Button("Sign in") { pick(login) }.disabled(busy)
      .accessibilityLabel("Sign in as \(login.username.isEmpty ? login.title : login.username)")
    if primary { button.buttonStyle(PrimaryButton()) } else { button }
  }
  private var failed: Bool {
    if case .failed = phase { return true }
    return false
  }
  private var locked: Bool {
    if case .locked = phase { return true }
    return false
  }
  private func close() {
    master = ""
    if managers.request?.id == request.id { managers.request = nil }
  }
  private func look() async {
    if request.manager == .bitwarden && managers.bitwardenLocked {
      phase = .locked
      return
    }
    phase = .waiting
    status = ""
    do { phase = .choose(try await managers.logins(for: request)) } catch {
      status = error.localizedDescription
      phase = request.manager == .bitwarden && managers.bitwardenLocked ? .locked : .failed
    }
  }
  private func unlock() {
    guard !busy, !master.isEmpty else { return }
    let typed = master
    master = ""
    busy = true
    Task {
      do {
        try await managers.unlockBitwarden(typed)
        unlockedHere = true
        status = ""
        busy = false
        if let login = pending {
          pending = nil
          pick(login)
        } else {
          await look()
        }
      } catch {
        status = error.localizedDescription
        busy = false
      }
    }
  }
  private func pick(_ login: ManagerLogin) {
    guard !busy else { return }
    if login.reprompt && !unlockedHere {
      pending = login
      status = ""
      phase = .locked
      return
    }
    busy = true
    Task {
      do {
        try await managers.signIn(login, request: request, unlockedNow: unlockedHere)
        request.browser.filledSignIn(on: request.origin, in: request.tab, from: request.manager.name)
        busy = false
        close()
      } catch {
        status = BrowserModel.signInFailure(error)
        busy = false
      }
    }
  }
}
