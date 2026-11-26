import CoreImage
import LocalAuthentication
import Security
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

struct Credential: Identifiable, Codable {
  var id: String
  var origin: String
  var username: String
}
@MainActor final class PasswordVault: ObservableObject {
  static let shared = PasswordVault(readOnlyPreview: CommandLine.arguments.contains("--ui-preview"))
  @Published var entries: [Credential] = []
  @Published var error: String?
  /// Logins with a verification code saved (ids only, never the keys).
  @Published private(set) var codes: Set<String> = []
  private let readOnlyPreview: Bool
  let service = "local.serein.browser.passwords"
  /// Cached result of the iCloud Keychain capability probe (see PasswordSyncVault.swift).
  var cachedSyncAvailability: PasswordSync.Availability?
  /// In GateSettings: new saves go to the synchronizable keychain only while it is on (off while
  /// that file cannot be read).
  @Published var syncEnabled = GateSettings.shared.bool(forKey: PasswordVault.syncDefaultsKey)
  init(readOnlyPreview: Bool = false) {
    self.readOnlyPreview = readOnlyPreview
    if readOnlyPreview {
      entries = [
        Credential(id: "preview-site", origin: "https://preview.invalid", username: "layout@example.invalid"),
        Credential(id: "preview-account", origin: "https://accounts.preview.invalid", username: "layout@example.invalid"),
      ]
    } else {
      reload()
    }
  }
  fileprivate func requireKeychainAccess() throws {
    guard !readOnlyPreview else {
      throw SereinError.invalid("Password access is unavailable in UI previews")
    }
  }
  func reload() {
    guard !readOnlyPreview else { return }
    let (rows, status) = keychainRows()
    guard status == errSecSuccess else {
      error = SecCopyErrorMessageString(status, nil) as String?
      return
    }
    var seen = Set<String>()
    entries = rows.compactMap { row in
      guard row[kSecAttrAccount as String] as? String != nil,
        let data = row[kSecAttrGeneric as String] as? Data,
        let item = try? JSONDecoder().decode(Credential.self, from: data),
        seen.insert(item.id).inserted
      else { return nil }
      return item
    }.sorted { $0.origin < $1.origin }
    reloadCodes()
  }
  func save(origin: String, username: String, password: String) throws {
    try requireKeychainAccess()
    _ = try BrowserPolicy.url(origin)
    guard let normalized = CredentialOrigin.normalize(origin), !password.isEmpty else {
      throw SereinError.invalid("Use an HTTPS site and a nonempty password")
    }
    let id =
      entries.first(where: { $0.origin == normalized && $0.username == username })?.id
      ?? UUID().uuidString
    let item = Credential(id: id, origin: normalized, username: username)
    let data = try JSONEncoder().encode(item)
    let label = normalized + " · " + username
    let existing = updateExisting(id: id, secret: Data(password.utf8), generic: data, label: label)
    if existing == errSecItemNotFound {
      let status = addNew(id: id, secret: Data(password.utf8), generic: data, label: label)
      guard status == errSecSuccess else {
        throw SereinError.invalid(
          SecCopyErrorMessageString(status, nil) as String? ?? "Keychain save failed")
      }
    } else if existing != errSecSuccess {
      throw SereinError.invalid("Keychain update failed (\(existing))")
    }
    reload()
  }
  func authenticate(_ reason: String) async throws {
    try requireKeychainAccess()
    let context = LAContext()
    guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    else { throw SereinError.invalid("Authentication required") }
  }
  func secret(_ item: Credential) throws -> String {
    try requireKeychainAccess()
    guard let data = readSecret(id: item.id),
      let password = String(data: data, encoding: .utf8)
    else { throw SereinError.invalid("Could not read this password from Keychain") }
    return password
  }
  func remove(_ item: Credential) throws {
    try requireKeychainAccess()
    guard deleteEverywhere(id: item.id) else {
      throw SereinError.invalid("Could not delete Keychain entry")
    }
    let codeGone = codeItem(item.id).replace(with: nil)
    reload()
    guard codeGone else {
      throw SereinError.invalid("The login was deleted, but its verification code could not be removed from Keychain")
    }
  }
  func fill(_ item: Credential, in tab: BrowserTab) async throws {
    try requireKeychainAccess()
    guard tab.owner == nil, !tab.privateMode else {
      throw SereinError.invalid("Password fill is only available in regular personal tabs")
    }
    try await PasswordCapture.fill(
      AutofillAccount(id: item.id, username: item.username, credential: item), origin: item.origin, in: tab)
  }

  // MARK: Sign in as … on a task's sign-in page

  /// Saved logins Sign in as … may fill on a task's tab: the tab still belongs to the task, is on the
  /// agent board and stopped at a sign-in page (needs you), it is never a private window's, its page
  /// is HTTPS, and the login was saved for exactly that origin. A look-alike host or plain HTTP gets
  /// none, so only Do it myself shows; so does a page that asks only for a code, for a login with
  /// no code saved. Read while drawing; the certificate is checked on the tap.
  func taskAccounts(for tab: BrowserTab, browser: BrowserModel) -> [Credential] {
    guard let state = taskSignIn(for: tab, browser: browser) else { return [] }
    let page = tab.web.url?.absoluteString
    return entries.filter { CredentialOrigin.matchesForTask($0.origin, page: page) }
      .filter { !state.signInCodeOnly || codes.contains($0.id) }
  }
  /// The task's sign-in page Sign in as … may fill (see `taskAccounts`), or nil.
  private func taskSignIn(for tab: BrowserTab, browser: BrowserModel) -> TabAgentState? {
    guard !readOnlyPreview, tab.owner != nil, !tab.sleeping,
      let state = browser.agentState(for: tab), state.onBoard, state.status == .needsYou, state.signIn != nil,
      PrivateStorePool.shared.userCount(tab.web.configuration.websiteDataStore) == 0
    else { return nil }
    return state
  }
  /// The exact HTTPS origin of a task's sign-in page on which Sign in as … may also offer the
  /// person's password manager (PasswordManagers): the same page `taskAccounts` fills, except one
  /// that asks only for a verification code, which a password manager's login does not fill here.
  func managerOrigin(for tab: BrowserTab, browser: BrowserModel) -> String? {
    guard let state = taskSignIn(for: tab, browser: browser), !state.signInCodeOnly,
      let origin = CredentialOrigin.normalize(tab.web.url?.absoluteString), origin.hasPrefix("https://")
    else { return nil }
    return origin
  }

  /// Sign in as …: the person's tap on a task tab stopped at a sign-in page. A separate entry from
  /// `fill`, which stays for the person's own tabs: here the tab still belongs to the task when the
  /// tap comes. No tool reaches this; consent is the tap plus device authentication, and a cancelled
  /// authentication changes nothing. The tab then becomes the person's (`takeOver`), and the login
  /// and its current code go from Keychain straight into the page (`PasswordCapture.fillForTask`).
  /// Nothing is sent: the person presses the page's own button, and the agent gets the tab back
  /// only afterwards, through Hand back. The fill is tied to the page the person tapped on
  /// (`pageVersion`, read before authentication), so a page that moves on meanwhile gets nothing.
  func signIn(_ item: Credential, taskTab tab: BrowserTab, browser: BrowserModel) async throws {
    try requireKeychainAccess()
    let version = tab.pageVersion
    let offered = {
      self.taskAccounts(for: tab, browser: browser).contains { $0.id == item.id }
        && !PasswordCapture.certificateBypassed(tab) && tab.pageVersion == version
    }
    guard offered() else { throw SereinError.invalid("This sign-in is no longer offered. Nothing was filled.") }
    let host = CredentialOrigin.displayHost(item.origin)
    try await authenticate(item.username.isEmpty ? "sign in on \(host)" : "sign in as \(item.username) on \(host)")
    // The page or the task may have changed while the person authenticated.
    guard offered() else { throw SereinError.invalid("The page changed. Nothing was filled.") }
    browser.takeOver(tab)
    guard tab.owner == nil else { throw SereinError.invalid("The tab could not be handed to you. Nothing was filled.") }
    try await PasswordCapture.fillForTask(
      item, password: { try self.secret(item) }, code: { try self.oneTimeCode(for: item)?.code(at: Date()) },
      pageVersion: version, in: tab)
  }

  // MARK: Verification codes

  /// Each login's verification-code setup is its own Keychain item under this service, in this
  /// Mac's login keychain (never synced, never in the CSV export), keyed by the login's id.
  let codeService = "local.serein.browser.passwords.codes"
  private func codeItem(_ id: String) -> KeychainItem { KeychainItem(service: codeService, account: id) }
  private func reloadCodes() { codes = KeychainItem.accounts(service: codeService) ?? [] }
  func saveCode(_ setup: String, for item: Credential) throws {
    try requireKeychainAccess()
    guard let code = OneTimeCode.parse(setup) else {
      throw SereinError.invalid("Paste the setup key or the otpauth:// link the site shows. Nothing was saved.")
    }
    let saved = codeItem(item.id).replace(with: String(decoding: try JSONEncoder().encode(code), as: UTF8.self))
    reloadCodes()
    guard saved else { throw SereinError.invalid("Could not save the verification code to Keychain") }
  }
  func removeCode(for item: Credential) throws {
    try requireKeychainAccess()
    let removed = codeItem(item.id).replace(with: nil)
    reloadCodes()
    guard removed else { throw SereinError.invalid("Could not delete the verification code from Keychain") }
  }
  /// The saved setup, read from Keychain. Settings authenticates the person first; a task's fill
  /// reads it only for the origin it was saved for (`FillGuard`).
  func oneTimeCode(for item: Credential) throws -> OneTimeCode? {
    try requireKeychainAccess()
    return try codeItem(item.id).read().map { try JSONDecoder().decode(OneTimeCode.self, from: Data($0.utf8)) }
  }
  /// The current code and when it changes, for Settings, after device authentication.
  func currentCode(for item: Credential) async throws -> (code: String, until: Date) {
    try await authenticate("show the verification code for \(CredentialOrigin.displayHost(item.origin))")
    guard let setup = try oneTimeCode(for: item) else {
      throw SereinError.invalid("No verification code is saved for this login.")
    }
    let now = Date()
    return (setup.code(at: now), setup.changes(after: now))
  }
}
/// Settings › Vault (id `Passwords`; docs/demos/simple-settings.decision.md): everything Serein keeps
/// for you in the Keychain, in one list. Sign-ins (`PasswordVault`) and the keys and cards saved on a
/// secure card in the chat (`SecretVault`, which had no list and no way to remove one). A search
/// field, All · Sign-ins · Keys, and New item; each row has a ••• menu. Copy and the current code
/// still need device authentication, and no value reaches a prompt, a tool answer or a file. The
/// saving options and the imports are in the page's Options fold (`PasswordOptions`).
struct PasswordSettings: View {
  enum Kind: String, CaseIterable {
    case all, signIns, keys
    var title: String {
      switch self {
      case .all: return "All"
      case .signIns: return "Sign-ins"
      case .keys: return "Keys"
      }
    }
  }
  @StateObject private var vault = PasswordVault.shared
  @State private var query = ""
  @State private var kind = Kind.all
  @State private var status = ""
  @State private var deletion: Credential?
  @State private var forgetting: SecretRecord?
  @State private var codeFor: Credential?
  @State private var adding = false
  @Environment(\.palette) var p
  private var relay: RelayOrchestrator? { RelayController.shared?.relay }
  /// A synthetic key for a preview's picture; nothing is stored.
  private static let previewKeys: [SecretRecord] = RunMode.previewing
    ? [SecretRecord(id: "preview-key", name: "Stripe key", hosts: ["api.stripe.invalid"], kind: .key, savedAt: Date(timeIntervalSince1970: 0))]
    : []

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        TextField("Find a site, account or key", text: $query).textFieldStyle(.serein)
          .accessibilityLabel("Find in the vault")
        GoalSegments(label: "Show", options: Kind.allCases.map { ($0, $0.title) }, selection: $kind)
        Button("New item") { adding = true }.buttonStyle(PrimaryButton())
      }
      if let desk = relay?.desk {
        VaultSecrets(desk: desk) { saved in list(saved + Self.previewKeys) }
      } else {
        list(Self.previewKeys)
      }
      if !status.isEmpty { Text(status).font(UIStyle.font(12)).foregroundStyle(p.secondary) }
      if let error = vault.error { Text(error).font(UIStyle.font(12)).foregroundStyle(p.danger) }
    }.font(UIStyle.font(13)).foregroundStyle(p.ink).buttonStyle(QuietButton()).controlSize(.small)
      .confirmationDialog(
        "Delete this saved sign-in?",
        isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })
      ) {
        Button("Delete", role: .destructive) {
          if let item = deletion {
            do { try vault.remove(item) } catch { status = error.localizedDescription }
          }
          deletion = nil
        }
      }
      .confirmationDialog(
        "Delete \(forgetting?.name ?? "this key")?",
        isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          if let record = forgetting {
            if let relay {
              status = relay.forgetSecret(record) ?? "Deleted from your Keychain."
            } else {
              status = "Serein is not running in this window yet."
            }
          }
          forgetting = nil
        }
      } message: {
        Text("Serein removes it from your Keychain. A task that needs it asks you for it again.")
      }
      .sheet(item: $codeFor) { item in
        VerificationCodeSheet(vault: vault, item: item) { codeFor = nil }.environment(\.palette, p)
      }
      .sheet(isPresented: $adding) {
        VaultNewItemSheet(vault: vault, relay: relay) { words in
          adding = false
          if let words { status = words }
        }.environment(\.palette, p)
      }
  }

  /// The rows the search and the tab leave, sign-ins first; one line when there are none.
  private func list(_ secrets: [SecretRecord]) -> some View {
    let wanted: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
    func has(_ text: String) -> Bool { wanted.isEmpty || text.localizedCaseInsensitiveContains(wanted) }
    let signIns: [Credential] = kind == .keys ? [] : vault.entries.filter { has($0.origin) || has($0.username) }
    let keys: [SecretRecord] = kind == .signIns ? [] : secrets.filter { record in has(record.name) || record.hosts.contains(where: has) }
    let nothingSaved: Bool = vault.entries.isEmpty && secrets.isEmpty
    return SettingsRowList {
      if signIns.isEmpty && keys.isEmpty {
        SettingsEmptyRow(
          glyph: "key",
          text: nothingSaved
            ? "Nothing saved yet. Serein offers to save a sign-in after you use one, and asks for a key on a secure card when a task needs it."
            : "Nothing matches.")
      }
      ForEach(signIns) { item in signInRow(item) }
      ForEach(keys) { record in secretRow(record) }
    }
  }

  private func signInRow(_ item: Credential) -> some View {
    let site: String = Self.site(item.origin)
    return SettingsListRow(name: site, status: item.username.isEmpty ? "No user name" : item.username, expandable: false) {
      SettingsGlyphTile(systemName: "globe")
    } trailing: {
      SereinMenuButton("More for \(site)", width: 220) {
        SereinMenuItem.action("Copy password", icon: "doc.on.doc") { copy(item) }
        SereinMenuItem.action(
          vault.codes.contains(item.id) ? "Verification code · On" : "Verification code…", icon: "clock"
        ) { codeFor = item }
        SereinMenuItem.divider
        SereinMenuItem.action("Delete…", icon: "trash", destructive: true) { deletion = item }
      } label: {
        more
      }.buttonStyle(.pressable)
    } live: {
      EmptyView()
    } details: {
      EmptyView()
    }
  }

  private func secretRow(_ record: SecretRecord) -> some View {
    let what: String = record.kind == .card ? "Card" : "Key"
    let sites: String = record.hosts.joined(separator: ", ")
    return SettingsListRow(
      name: record.name, status: record.kind == .card ? "\(what) · for \(sites)" : "\(what) · goes only to \(sites)", expandable: false
    ) {
      SettingsGlyphTile(systemName: "key")
    } trailing: {
      SereinMenuButton("More for \(record.name)", width: 220) {
        SereinMenuItem.action("Delete…", icon: "trash", destructive: true) { forgetting = record }
      } label: {
        more
      }.buttonStyle(.pressable)
    } live: {
      EmptyView()
    } details: {
      EmptyView()
    }
  }

  private var more: some View {
    InterfaceIcon(systemName: "ellipsis", size: 14).foregroundStyle(p.secondary)
      .frame(width: 28, height: 28).contentShape(Rectangle())
  }

  /// A saved origin as people read it: the host alone.
  static func site(_ origin: String) -> String { URL(string: origin)?.host ?? origin }

  /// Copies after device authentication; the clipboard clears in 30 seconds if unchanged.
  private func copy(_ item: Credential) {
    Task {
      do {
        try await vault.authenticate("Copy a saved Serein password")
        let value = try vault.secret(item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        let count = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
          if NSPasteboard.general.changeCount == count {
            NSPasteboard.general.clearContents()
          }
        }
        status = "Copied. Clipboard clears in 30 seconds if unchanged."
      } catch { status = error.localizedDescription }
    }
  }
}

/// The saved keys and cards, read from the assistant desk so the list follows a save or a delete.
/// A record whose card still waits in the chat (`savedAt` nil) is not saved yet, so it is left out.
private struct VaultSecrets<Content: View>: View {
  @ObservedObject var desk: AssistantDesk
  @ViewBuilder var content: ([SecretRecord]) -> Content
  var body: some View { content(desk.secrets.filter { $0.savedAt != nil }) }
}

/// Vault › New item: a sign-in (site, user name, password) or a key (its name, the one address it may
/// go to, the key). Either goes to the Keychain on Save and nowhere else; the person types it here,
/// in Serein's own window, so no model sees it.
private struct VaultNewItemSheet: View {
  enum Kind: String, CaseIterable { case signIn, key }
  @ObservedObject var vault: PasswordVault
  let relay: RelayOrchestrator?
  /// Closes the sheet; the words to show on the page after a save, or nil after Cancel.
  var close: (String?) -> Void
  @State private var kind = Kind.signIn
  @State private var name = ""
  @State private var detail = ""
  @State private var secret = ""
  @State private var problem: String?
  @Environment(\.palette) var p
  var body: some View {
    let key: Bool = kind == .key
    VStack(alignment: .leading, spacing: 12) {
      Text("New item").font(UIStyle.section)
      GoalSegments(label: "Kind", options: [(Kind.signIn, "Sign-in"), (Kind.key, "Key")], selection: $kind)
      TextField(key ? "Name, such as Stripe key" : "Site, such as example.com", text: $name).textFieldStyle(.serein)
        .accessibilityLabel(key ? "Name" : "Site")
      TextField(key ? "Where it may go, such as api.stripe.com" : "User name or email", text: $detail).textFieldStyle(.serein)
        .accessibilityLabel(key ? "The address it may go to" : "User name")
      SecureField(key ? "Key" : "Password", text: $secret).textFieldStyle(.serein)
        .accessibilityLabel(key ? "Key" : "Password")
      if let problem { Text(problem).font(UIStyle.font(12)).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true) }
      Text(key
        ? "Kept in your Mac's Keychain. Serein puts it into a request only for that address, and the AI never sees it."
        : "Kept in your Mac's Keychain. Serein fills it in for you on that site, and the AI never sees it.")
        .font(UIStyle.font(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Spacer()
        Button("Cancel") { close(nil) }.keyboardShortcut(.cancelAction)
        Button("Save", action: save).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
      }
    }.padding(20).frame(width: UIStyle.wide(420)).background(p.panel).foregroundStyle(p.ink)
      .font(UIStyle.font(13)).buttonStyle(QuietButton()).controlSize(.small)
      .onChange(of: kind) { _, _ in problem = nil }
  }
  private func save() {
    let named: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch kind {
    case .signIn:
      guard !named.isEmpty, !secret.isEmpty else {
        problem = "Type the site and the password."
        return
      }
      // People type a site as its name; a saved origin is always HTTPS.
      let origin: String = named.contains("://") ? named : "https://" + named
      do {
        try vault.save(origin: origin, username: detail.trimmingCharacters(in: .whitespacesAndNewlines), password: secret)
        close("Saved to your Keychain.")
      } catch { problem = error.localizedDescription }
    case .key:
      guard !named.isEmpty, !secret.isEmpty else {
        problem = "Type a name and the key."
        return
      }
      guard let relay else {
        problem = "Serein is not running in this window yet."
        return
      }
      var entry = SecretEntry(key: secret)
      entry.service = named
      entry.address = detail
      if let words = relay.savePastedSecret(entry) { problem = words } else { close("Saved to your Keychain.") }
    }
  }
}

/// Vault › Options: iCloud Keychain sync (only in a build macOS lets sync), the offer to save a
/// sign-in, password managers in Sign in as, and CSV import and export.
struct PasswordOptions: View {
  @StateObject private var vault = PasswordVault.shared
  @State private var status = ""
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Shown only in a build that macOS lets sync: a switch that can never go on is noise.
      if vault.syncAvailability.isAvailable {
        PasswordSyncSettings(vault: vault, status: $status)
        Divider().overlay(p.line)
      }
      PasswordCaptureSettings()
      Divider().overlay(p.line)
      PasswordManagerSettings()
      Divider().overlay(p.line)
      HStack(spacing: 8) {
        Text("Sign-ins as a CSV file")
        Spacer()
        Button("Import CSV…") { importCSV() }
        Button("Export CSV…") { exportCSV() }.disabled(vault.entries.isEmpty)
      }
      if !status.isEmpty { Text(status).font(UIStyle.font(12)).foregroundStyle(p.secondary) }
    }.font(UIStyle.font(13)).foregroundStyle(p.ink).buttonStyle(QuietButton()).controlSize(.small)
  }
  func exportCSV() {
    Task {
      do {
        try vault.requireKeychainAccess()
        try await vault.authenticate("Export your Serein passwords to an unencrypted CSV file")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Serein-passwords.csv"
        panel.message =
          "This file contains unencrypted passwords. Store it securely and remove it after transferring."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var rows = [["url", "username", "password"]]
        for entry in vault.entries {
          rows.append([entry.origin, entry.username, try vault.secret(entry)])
        }
        try CSVTable.encode(rows).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        status = "Exported to the selected file."
      } catch { status = error.localizedDescription }
    }
  }
  func importCSV() {
    do { try vault.requireKeychainAccess() } catch {
      status = error.localizedDescription
      return
    }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 10_000_000 else { throw SereinError.invalid("CSV must be smaller than 10 MB") }
        let file = try PasswordImport.parse(String(contentsOf: url))
        let rows = file.entries
        var left = file.skipped == 0
          ? "" : " \(file.skipped) \(file.skipped == 1 ? "row is" : "rows are") left out: no password, or an address that is not HTTPS."
        if file.repeated > 0 {
          left += " \(file.repeated) \(file.repeated == 1 ? "row repeats" : "rows repeat") a site and user name; the last one is kept."
        }
        guard !rows.isEmpty else {
          status = "No password in this file can be imported." + left
          return
        }
        let alert = NSAlert()
        alert.messageText = "Import \(rows.count) \(rows.count == 1 ? "password" : "passwords") into Serein’s Keychain?"
        alert.informativeText =
          "Existing entries for the same site and username will be updated. The source CSV remains unchanged." + left
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try await vault.authenticate("Import passwords into Serein")
        // One entry that the Keychain refuses must not stop the ones after it.
        var count = 0
        var refused = 0
        var reason = ""
        for row in rows {
          do {
            try vault.save(origin: row.origin, username: row.username, password: row.password)
            count += 1
          } catch {
            refused += 1
            if reason.isEmpty { reason = error.localizedDescription }
          }
        }
        status = "Imported \(count) \(count == 1 ? "entry" : "entries")." + left
          + (refused == 0 ? "" : " \(refused) could not be saved: \(reason)")
      } catch { status = error.localizedDescription }
    }
  }
}

/// Settings › Vault › Verification code, for one saved sign-in. The setup key or `otpauth://` link
/// is pasted, or read on this Mac from a QR code in the person's current tab (CoreImage). The key
/// goes only to the Keychain on this Mac (PasswordVault.saveCode); the current code shows after
/// device authentication and only until it changes, and is then dropped.
private struct VerificationCodeSheet: View {
  @ObservedObject var vault: PasswordVault
  var item: Credential
  var close: () -> Void
  @State private var setup = ""
  @State private var shown: (code: String, until: Date)?
  /// A code was shown and has changed since.
  @State private var expired = false
  @State private var status = ""
  @Environment(\.palette) var p
  var body: some View {
    let saved = vault.codes.contains(item.id)
    VStack(alignment: .leading, spacing: 12) {
      Text("Verification code").font(UIStyle.section)
      Text(item.origin + (item.username.isEmpty ? "" : " · " + item.username)).font(UIStyle.mono(12))
        .foregroundStyle(p.secondary)
      Text(
        "Paste the setup key or the otpauth:// link the site shows when you turn on an authenticator app. Serein keeps it in your Keychain on this Mac only, and fills the current code when you choose Sign in as on a task."
      ).font(UIStyle.font(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      SecureField(saved ? "Paste a new key to replace the saved one" : "Setup key or otpauth:// link", text: $setup)
        .textFieldStyle(.plain).textInputCursor().padding(8)
        .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(p.borderStrong))
      Button("Read QR code from the current tab") { readQR() }
        .help("Reads the site's setup QR code from the page in your current tab, on this Mac")
        .accessibilityLabel("Read the setup QR code from the current tab")
      if let shown {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(shown.code).font(UIStyle.mono(20)).textSelection(.enabled)
            Text("Changes in \(max(1, Int(shown.until.timeIntervalSince(context.date).rounded(.up)))) s")
              .font(UIStyle.font(12)).foregroundStyle(p.secondary)
          }
        }
      } else if expired {
        Text("This code has changed. Show it again for the new one.").font(UIStyle.font(12))
          .foregroundStyle(p.secondary)
      }
      HStack(spacing: 8) {
        if saved {
          Button("Show current code") { show() }
          Button(role: .destructive) { remove() } label: { Text("Remove").foregroundStyle(p.danger) }
        }
        Spacer()
        Button("Done", action: close).keyboardShortcut(.cancelAction)
        Button("Save to Keychain") { save() }.buttonStyle(PrimaryButton()).disabled(setup.isEmpty)
      }
      if !status.isEmpty { Text(status).font(UIStyle.font(12)).foregroundStyle(p.secondary) }
    }.padding(20).frame(width: UIStyle.wide(420)).background(p.panel).foregroundStyle(p.ink)
      .font(UIStyle.font(13)).buttonStyle(QuietButton()).controlSize(.small)
      // The code leaves memory as it changes. A new code (or none) cancels the wait.
      .task(id: shown?.until) {
        guard let until = shown?.until else { return }
        do { try await Task.sleep(nanoseconds: UInt64(max(0, until.timeIntervalSinceNow) * 1e9)) } catch { return }
        shown = nil
        expired = true
      }
  }
  private func save() {
    do {
      try vault.saveCode(setup, for: item)
      setup = ""
      shown = nil
      expired = false
      status = "Saved to your Keychain on this Mac."
    } catch { status = error.localizedDescription }
  }
  private func show() {
    Task {
      do {
        shown = try await vault.currentCode(for: item)
        expired = false
      } catch { status = error.localizedDescription }
    }
  }
  /// The person's own current tab only (never a task's or a private window's): a snapshot of it is
  /// searched for a QR code on this Mac, and the first one that is a code setup goes into the hidden
  /// field. Nothing is shown or kept; Save to Keychain stores it.
  private func readQR() {
    Task { @MainActor in
      guard let tab = SereinRouter.browser?.active, tab.owner == nil, !tab.privateMode,
        let image = try? await tab.web.takeSnapshot(configuration: nil),
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let found = CIDetector(
          ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )?.features(in: CIImage(cgImage: cg))
          .lazy.compactMap({ ($0 as? CIQRCodeFeature)?.messageString })
          .first(where: { OneTimeCode.parse($0) != nil })
      else {
        status = "No setup QR code is in the current tab."
        return
      }
      setup = found
      status = "Read the setup from the QR code. Choose Save to Keychain to keep it."
    }
  }
  private func remove() {
    do {
      try vault.removeCode(for: item)
      shown = nil
      expired = false
      status = "Removed from your Keychain."
    } catch { status = error.localizedDescription }
  }
}
