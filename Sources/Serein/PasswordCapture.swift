import AppKit
import ObjectiveC
import SereinCore
import Security
import WebKit

/// Saves, updates and fills passwords for the user's own tabs.
///
/// One instance per tab acts as the `sereinPasswords` message handler. WebKit retains message
/// handlers, so this object holds the tab weakly. It is never installed in agent-owned tabs.
/// Private tabs keep what they save in `MemoryCredentialStore` and never touch the Keychain.
@MainActor final class PasswordCapture: NSObject, WKScriptMessageHandler {
  static let world = WKContentWorld.world(name: "SereinPasswords")
  static let handlerName = "sereinPasswords"
  static let marker = "__sereinPasswords"
  private static let source: String? = {
    guard let url = Bundle.assets.url(forResource: "PasswordCapture", withExtension: "js") else {
      return nil
    }
    return (try? String(contentsOf: url)).map(SensitiveFields.script)
  }()
  /// Page-world probe: WebAuthn calls happen in the page's own world, so this tiny wrapper
  /// raises a DOM event that the isolated helper relays. It changes nothing else.
  static let passkeyProbe = """
    (()=>{try{const c=navigator.credentials;if(!c||!window.PublicKeyCredential)return;for(const op of ['get','create']){const original=c[op];if(typeof original!=='function')continue;Object.defineProperty(c,op,{configurable:true,writable:true,value:function(options){try{if(options&&options.publicKey&&options.mediation!=='conditional')document.dispatchEvent(new CustomEvent('serein:passkey',{detail:op}))}catch(_){}return original.apply(this,arguments)}})}}catch(_){}})();
    """

  weak var tab: BrowserTab?
  let prompts = PasswordPrompts()
  private var lastPasskeyNotice = Date.distantPast

  private init(tab: BrowserTab) {
    self.tab = tab
    super.init()
  }

  /// Installs the helper in a user-owned tab. Agent-owned tabs are refused.
  static func install(on tab: BrowserTab, controller: WKUserContentController) {
    guard eligible(tab), let source else { return }
    controller.addUserScript(
      WKUserScript(
        source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
    controller.addUserScript(
      WKUserScript(source: passkeyProbe, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    #if DEBUG
    // Headless checks cannot produce real key presses, so they opt in to scripted submits.
    if trustSyntheticEventsForChecks {
      controller.addUserScript(
        WKUserScript(
          source: "globalThis.__sereinPasswordsTrustSynthetic = true;",
          injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
    }
    #endif
    controller.add(PasswordCapture(tab: tab), contentWorld: world, name: handlerName)
  }
  #if DEBUG
  static var trustSyntheticEventsForChecks = false
  #endif

  /// Installs the helper in an agent tab the user just took over, and loads it into the page
  /// already showing, so the user can sign in there.
  static func adopt(_ tab: BrowserTab) {
    let controller = tab.web.configuration.userContentController
    guard eligible(tab), let source,
      !controller.userScripts.contains(where: { $0.source.contains(marker) })
    else { return }
    install(on: tab, controller: controller)
    tab.web.evaluateJavaScript(source, in: nil, in: world) { _ in }
    tab.web.evaluateJavaScript(passkeyProbe, in: nil, in: .page) { _ in }
  }

  static func eligible(_ tab: BrowserTab) -> Bool { tab.owner == nil }

  /// True when an HTTPS page was opened past a certificate warning ("Visit anyway").
  /// Like Chrome, Serein neither saves nor fills passwords on such a page.
  static func certificateBypassed(_ tab: BrowserTab) -> Bool {
    // Network HTTPS loads always carry a server trust; content loaded locally has none.
    guard tab.web.url?.scheme?.lowercased() == "https", let trust = tab.web.serverTrust else {
      return false
    }
    return !SecTrustEvaluateWithError(trust, nil)
  }

  /// Shared by the menu and inline fill paths, before and after device authentication.
  static func requireTrustedOrigin(_ origin: String, in tab: BrowserTab) throws {
    guard PasswordFillPolicy.allows(savedOrigin: origin, page: tab.web.url?.absoluteString,
      personal: eligible(tab), awake: !tab.sleeping, loading: tab.web.isLoading,
      certificateTrusted: !certificateBypassed(tab))
    else { throw SereinError.invalid("The site changed or has a certificate problem. Nothing was filled.") }
  }

  static var offerToSave: Bool {
    get { UserDefaults.standard.object(forKey: "serein.passwords.offerToSave") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "serein.passwords.offerToSave") }
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let tab, Self.eligible(tab), !Self.certificateBypassed(tab), message.webView === tab.web,
      let body = message.body as? [String: Any], let type = body["type"] as? String
    else { return }
    // The origin comes from WebKit, never from the page.
    let o = message.frameInfo.securityOrigin
    // Sign-in submissions and passkey notices count only from the top-level page, so an
    // embedded frame cannot raise a native prompt about the site the user is on.
    guard message.frameInfo.isMainFrame || type == "focus" else { return }
    guard let origin = CredentialOrigin.make(scheme: o.protocol, host: o.host, port: o.port) else {
      if type == "passkey" { showPasskeyNotice(host: o.host) }
      return
    }
    switch type {
    case "submit":
      guard let password = body["password"] as? String, !password.isEmpty, password.count <= 1024
      else { return }
      let username = String((body["username"] as? String ?? "").prefix(512))
      submitted(origin: origin, username: username, password: password, in: tab)
    case "focus":
      guard message.frameInfo.isMainFrame else { return }
      let field = body["field"] as? String ?? "other"
      guard field == "password" || field == "username" else {
        prompts.closeAutofill()
        return
      }
      let rect = body["rect"] as? [String: Any] ?? [:]
      let request = AutofillRequest(
        origin: origin, isNew: body["isNew"] as? Bool ?? false,
        rules: SitePasswordQuirks.shared.effectiveRules(
          page: PasswordRules.parse(String((body["rules"] as? String ?? "").prefix(2000))),
          host: o.host),
        minLength: PasswordGenerator.sane(body["minLength"] as? Int) ?? 0,
        maxLength: PasswordGenerator.sane(body["maxLength"] as? Int) ?? 0,
        rect: CGRect(
          x: rect["x"] as? Double ?? 0, y: rect["y"] as? Double ?? 0,
          width: rect["w"] as? Double ?? 0, height: rect["h"] as? Double ?? 0))
      focused(request, in: tab)
    case "passkey":
      showPasskeyNotice(host: o.host)
    default: return
    }
  }

  // MARK: Save on submit

  private func submitted(origin: String, username: String, password: String, in tab: BrowserTab) {
    guard Self.offerToSave, !PasswordNeverList.contains(origin) else { return }
    let decision: PasswordSaveDecision
    if tab.privateMode {
      let saved = MemoryCredentialStore.items(in: tab.web.configuration.websiteDataStore)
        .filter { $0.origin == origin }
      decision = PasswordSaveDecision.decide(
        username: username, saved: saved.map(\.username),
        samePassword: { name in saved.first { $0.username == name }?.password == password })
    } else {
      let vault = PasswordVault.shared
      let saved = vault.entries.filter { CredentialOrigin.normalize($0.origin) == origin }
      decision = PasswordSaveDecision.decide(
        username: username, saved: saved.map(\.username),
        samePassword: { name in
          guard let item = saved.first(where: { $0.username == name }) else { return false }
          return (try? vault.secret(item)) == password
        })
    }
    let target: String
    switch decision {
    case .none: return
    case .save: target = username
    case .update(let name): target = name
    }
    let offer = SaveOffer(
      origin: origin, username: target, password: password,
      isUpdate: decision != .save, isPrivate: tab.privateMode)
    #if DEBUG
    Self.observeOffer?(offer)
    #endif
    prompts.showSave(offer, in: tab)
  }
  #if DEBUG
  /// Lets the headless check see an offer without showing UI.
  static var observeOffer: ((SaveOffer) -> Void)?
  #endif

  // MARK: Autofill

  private func focused(_ request: AutofillRequest, in tab: BrowserTab) {
    let accounts = Self.accounts(for: request.origin, in: tab)
    guard !accounts.isEmpty || request.isNew else {
      prompts.closeAutofill()
      return
    }
    prompts.showAutofill(request, accounts: accounts, in: tab)
  }

  static func accounts(for origin: String, in tab: BrowserTab) -> [AutofillAccount] {
    if tab.privateMode {
      return MemoryCredentialStore.items(in: tab.web.configuration.websiteDataStore)
        .filter { $0.origin == origin }
        .map { AutofillAccount(id: "memory:" + $0.username, username: $0.username, credential: nil) }
    }
    return PasswordVault.shared.entries
      .filter { CredentialOrigin.normalize($0.origin) == origin }
      .map { AutofillAccount(id: $0.id, username: $0.username, credential: $0) }
  }

  /// Fills a saved account after Touch ID or the Mac's password.
  static func fill(_ account: AutofillAccount, origin: String, in tab: BrowserTab) async throws {
    guard eligible(tab) else { throw SereinError.invalid("Passwords are only filled in your own tabs.") }
    try requireTrustedOrigin(origin, in: tab)
    guard let document = try await tab.web.callAsyncJavaScript(
      "return globalThis.__sereinPasswords.documentID", arguments: [:], in: nil, contentWorld: world) as? String
    else { throw SereinError.invalid("The sign-in page is not ready. Nothing was filled.") }
    let host = CredentialOrigin.displayHost(origin)
    try await PasswordVault.shared.authenticate("fill your saved password for \(host)")
    try requireTrustedOrigin(origin, in: tab)
    let password: String
    if let item = account.credential {
      guard !tab.privateMode, CredentialOrigin.normalize(item.origin) == origin else {
        throw SereinError.invalid("This password belongs to a different site.")
      }
      password = try PasswordVault.shared.secret(item)
    } else {
      guard
        let item = MemoryCredentialStore.items(in: tab.web.configuration.websiteDataStore)
          .first(where: { $0.origin == origin && $0.username == account.username })
      else { throw SereinError.invalid("That password is no longer here.") }
      password = item.password
    }
    _ = try await tab.web.callAsyncJavaScript(
      "return globalThis.__sereinPasswords.fill(origin, username, password, documentID)",
      arguments: ["origin": origin, "username": account.username, "password": password, "documentID": document],
      in: nil, contentWorld: world)
  }

  /// Sign in as … (PasswordVault.signIn, PasswordManagers.signIn), after the person's consent, on a
  /// task's tab the person has just taken over: the login's password (`password`, from Keychain or
  /// the password manager the person chose) and, when one is saved, the current verification code
  /// (`code`), both read only after the origin checks, go into this page's helper, which fills the
  /// sign-in, one-time-code or lone username field and sends nothing; the person presses the page's
  /// own button. `pageVersion` is the page the person tapped on, read before authentication.
  /// Unlike `fill`, an isolated task's tab counts: its store is the task's own, never a private
  /// window's, and goes with the tab.
  static func fillForTask(
    _ item: Credential, password secret: () throws -> String, code: () throws -> String?, pageVersion: String,
    in tab: BrowserTab
  ) async throws {
    guard eligible(tab), CredentialOrigin.matchesForTask(item.origin, page: tab.web.url?.absoluteString),
      let origin = CredentialOrigin.normalize(item.origin)
    else { throw SereinError.invalid("The site changed. Nothing was filled.") }
    try requireTrustedOrigin(origin, in: tab)
    guard let document = try await tab.web.callAsyncJavaScript(
      "return globalThis.__sereinPasswords.documentID", arguments: [:], in: nil, contentWorld: world) as? String
    else { throw SereinError.invalid("The sign-in page is not ready. Nothing was filled.") }
    guard tab.pageVersion == pageVersion else {
      throw SereinError.invalid("The sign-in page changed. Nothing was filled.")
    }
    try requireTrustedOrigin(origin, in: tab)
    let password = try secret()
    let current = try code() ?? ""
    _ = try await tab.web.callAsyncJavaScript(
      "return globalThis.__sereinPasswords.signIn(origin, username, password, code, documentID)",
      arguments: ["origin": origin, "username": item.username, "password": password, "code": current,
        "documentID": document],
      in: nil, contentWorld: world)
  }

  /// Puts a generated password in the form's new-password fields.
  static func fillGenerated(_ password: String, origin: String, in tab: BrowserTab) async throws {
    guard eligible(tab) else { return }
    try requireTrustedOrigin(origin, in: tab)
    guard let document = try await tab.web.callAsyncJavaScript(
      "return globalThis.__sereinPasswords.documentID", arguments: [:], in: nil, contentWorld: world) as? String
    else { throw SereinError.invalid("The sign-in page is not ready. Nothing was filled.") }
    try requireTrustedOrigin(origin, in: tab)
    _ = try await tab.web.callAsyncJavaScript(
      "return globalThis.__sereinPasswords.fillNew(origin, password, documentID)",
      arguments: ["origin": origin, "password": password, "documentID": document], in: nil, contentWorld: world)
  }

  // MARK: Passkeys

  private func showPasskeyNotice(host: String) {
    guard let tab, Date().timeIntervalSince(lastPasskeyNotice) > 10 else { return }
    lastPasskeyNotice = Date()
    prompts.showPasskey(host: host, in: tab)
  }
}

struct AutofillRequest {
  var origin: String
  var isNew: Bool
  var rules: PasswordRules
  var minLength: Int
  var maxLength: Int
  /// The field's rectangle in CSS pixels, relative to the viewport.
  var rect: CGRect
}

struct AutofillAccount: Identifiable {
  var id: String
  var username: String
  /// nil for a private-window entry held in memory.
  var credential: Credential?
}

struct SaveOffer {
  var origin: String
  var username: String
  var password: String
  var isUpdate: Bool
  var isPrivate: Bool
}

/// Sites the user chose "Never for this site" for.
enum PasswordNeverList {
  static let key = "serein.passwords.never"
  static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
  static func contains(_ origin: String) -> Bool { all.contains(origin) }
  static func add(_ origin: String) {
    guard !contains(origin) else { return }
    UserDefaults.standard.set((all + [origin]).sorted(), forKey: key)
  }
  static func remove(_ origin: String) {
    UserDefaults.standard.set(all.filter { $0 != origin }, forKey: key)
  }
}

/// Passwords saved from private windows. They live only in memory, attached to the window's
/// non-persistent website data store, and disappear with it. Nothing is written to Keychain.
@MainActor enum MemoryCredentialStore {
  struct Item {
    var origin: String
    var username: String
    var password: String
  }
  private final class Box: NSObject { var items: [Item] = [] }
  private static var boxKey: UInt8 = 0

  private static func box(_ store: WKWebsiteDataStore, create: Bool) -> Box? {
    if let box = objc_getAssociatedObject(store, &boxKey) as? Box { return box }
    guard create, !store.isPersistent else { return nil }
    let box = Box()
    objc_setAssociatedObject(store, &boxKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return box
  }
  static func items(in store: WKWebsiteDataStore) -> [Item] {
    box(store, create: false)?.items ?? []
  }
  static func save(_ item: Item, in store: WKWebsiteDataStore) throws {
    guard let box = box(store, create: true) else {
      throw SereinError.invalid("Private passwords need a private window.")
    }
    box.items.removeAll { $0.origin == item.origin && $0.username == item.username }
    box.items.append(item)
  }
}
