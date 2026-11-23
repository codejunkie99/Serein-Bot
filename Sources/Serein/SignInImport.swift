import AppKit
import Security
import SereinCore
import SwiftUI
import WebKit

/// Brings website sign-ins (cookies) from Chromium-family browsers, Firefox or Safari into regular
/// Serein tabs. Order: pick a profile, Serein reads a temporary snapshot (Chromium also needs
/// macOS to share the browser's Safe Storage key; for Safari the user picks the cookie file in an
/// open panel, which macOS lets Serein read once), the user reviews the sites, and only the
/// checked sites are written. Serein never asks for Full Disk Access: agent CLIs it starts would
/// inherit it.
@MainActor final class SignInImportModel: ObservableObject {
  enum Stage {
    case choose
    case reading
    case review
    case writing
    case done(String)
  }
  @Published var stage = Stage.choose
  @Published var profiles: [BrowserImportProfile] = []
  @Published var profileID: String?
  @Published var sites: [CookieSite] = []
  @Published var chosen: Set<String> = []
  @Published var query = ""
  @Published var error: String?
  @Published var skipped = 0
  private var work: Task<Void, Never>?

  var profile: BrowserImportProfile? { profiles.first { $0.id == profileID } }

  func load() {
    Task {
      var found = await Task.detached {
        BrowserProfileScanner.scan().filter {
          if $0.bookmarkFormat == .firefoxSQLite {
            return FirefoxCookies.cookiesDatabase(in: $0.directory) != nil
          }
          return ChromiumCookies.safeStorageServices[$0.browser] != nil
            && ChromiumCookies.cookiesDatabase(in: $0.directory) != nil
        }
      }.value
      // Safari's file is in its protected container, so it can't be detected; it is always offered.
      found.append(Self.safariProfile)
      profiles = found
      if profileID == nil { profileID = found.first?.id }
    }
  }

  nonisolated static let safariProfile = BrowserImportProfile(
    browser: "Safari", profile: "Default",
    directory: SafariCookies.folderURL, bookmarks: nil, history: nil,
    bookmarkFormat: nil)

  func read() {
    guard let profile else { return }
    let reader: @Sendable () throws -> CookieReadResult
    if profile.browser == "Safari" {
      // The user chooses the file; that choice is what lets macOS open it. Read once, no bookmark.
      guard let file = Self.chooseSafariFile() else { return }
      reader = { try SafariCookies.read(url: file) }
    } else if profile.bookmarkFormat == .firefoxSQLite,
      let database = FirefoxCookies.cookiesDatabase(in: profile.directory)
    {
      reader = { try FirefoxCookies.read(database: database) }
    } else if let service = ChromiumCookies.safeStorageServices[profile.browser],
      let database = ChromiumCookies.cookiesDatabase(in: profile.directory)
    {
      reader = {
        // Blocks while macOS shows its keychain prompt.
        // Best effort: wipe our own copies of the key material once the read is done.
        var password = try Self.safeStoragePassword(service: service)
        var key = ChromiumCookies.key(safeStoragePassword: password)
        defer {
          password.resetBytes(in: 0..<password.count)
          key.resetBytes(in: 0..<key.count)
        }
        let result = try ChromiumCookies.read(database: database, key: key)
        return CookieReadResult(cookies: result.cookies, skipped: result.skipped)
      }
    } else {
      return
    }
    error = nil
    stage = .reading
    work = Task {
      do {
        let result = try await Task.detached(priority: .userInitiated, operation: reader).value
        guard !Task.isCancelled else { return }
        sites = CookieSites.group(result.cookies)
        // Nothing is preselected: the user picks each site, or "All".
        chosen = []
        skipped = result.skipped
        stage = sites.isEmpty ? .done("\(profile.browser) has no sign-ins to bring over.") : .review
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
        stage = .choose
      }
    }
  }

  func write() {
    let store = WKWebsiteDataStore.default().httpCookieStore
    let current = sites
    let picked = chosen
    stage = .writing
    work = Task {
      let existing = Set(await store.allCookies().map {
        $0.domain.lowercased() + "|" + $0.name + "|" + $0.path
      })
      let plan = CookieSites.selection(current, chosen: picked, existingKeys: existing)
      var written = 0
      for cookie in plan.write {
        if Task.isCancelled { break }
        if let http = Self.httpCookie(cookie) {
          await store.setCookie(http)
          written += 1
        }
      }
      // Forget the values as soon as they are written.
      sites = []
      chosen = []
      let count = picked.count
      var summary =
        "Brought sign-ins for \(count) \(count == 1 ? "site" : "sites") (\(written) cookies)."
      if plan.kept > 0 { summary += " Left \(plan.kept) that Serein already had unchanged." }
      summary += " Some sites, such as Google and banks, may still ask you to sign in again."
      stage = .done(summary)
    }
  }

  /// Opens a panel in Safari's cookie folder so the user picks `Cookies.binarycookies` themselves.
  static func chooseSafariFile() -> URL? {
    let panel = NSOpenPanel()
    panel.directoryURL = SafariCookies.folderURL
    panel.nameFieldStringValue = SafariCookies.fileName
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = false
    panel.prompt = "Read Sign-ins"
    panel.message =
      "Choose Cookies.binarycookies. macOS lets Serein open a protected file only when you pick it yourself."
    return panel.runModal() == .OK ? panel.url : nil
  }

  func cancel() {
    work?.cancel()
    sites = []
    chosen = []
  }

  nonisolated static func safeStoragePassword(service: String) throws -> Data {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
      [
        kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne,
      ] as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data, !data.isEmpty else { fallthrough }
      return data
    case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
      throw SereinError.invalid(
        "macOS didn’t share the key. Try again and choose Allow in the keychain prompt.")
    case errSecItemNotFound:
      throw SereinError.invalid("This browser hasn’t stored a sign-in key on this Mac.")
    default:
      throw SereinError.invalid(
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
    }
  }

  static func httpCookie(_ c: ImportedCookie) -> HTTPCookie? {
    var props: [HTTPCookiePropertyKey: Any] = [
      .domain: c.domain, .path: c.path, .name: c.name, .value: c.value,
    ]
    if c.secure { props[.secure] = "TRUE" }
    if let expires = c.expires { props[.expires] = expires } else { props[.discard] = "TRUE" }
    if c.httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    switch c.sameSite {
    case "Lax": props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
    case "Strict": props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
    default: break
    }
    return HTTPCookie(properties: props)
  }
}

struct SignInImportView: View {
  @ObservedObject var model: SignInImportModel
  let close: () -> Void
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Bring sign-ins from your browser").font(UIStyle.font(17, weight: .semibold))
      switch model.stage {
      case .choose: choose
      case .reading:
        progress(
          model.profile?.browser == "Safari" || model.profile?.bookmarkFormat == .firefoxSQLite
            ? "Reading a copy of the sign-ins…"
            : "Waiting for macOS to share the key, then reading a copy…")
      case .review: review
      case .writing: progress("Adding sign-ins to Serein…")
      case .done(let summary):
        Text(summary).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Done", action: close).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
        }
      }
    }.padding(22).frame(width: 520, height: 560, alignment: .topLeading)
      .font(UIStyle.font(13)).foregroundStyle(p.ink).background(p.panel)
      .onAppear { model.load() }
  }

  @ViewBuilder private var choose: some View {
    Text(
      "Stay signed in to your sites without signing in again. Serein copies the browser’s cookie file, reads the copy, and shows you every site before anything is added. Only pages you open in Serein, and a task you start from one of them, use these sign-ins. Private pages and other tasks never see them."
    ).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    if model.profiles.isEmpty {
      Text("No browser profile with sign-ins was found on this Mac.")
        .foregroundStyle(p.secondary)
    } else {
      Picker("Browser", selection: $model.profileID) {
        ForEach(model.profiles) { profile in
          Text("\(profile.browser) — \(profile.profile)").tag(Optional(profile.id))
        }
      }.pickerStyle(.menu)
    }
    VStack(alignment: .leading, spacing: 6) {
      switch model.profile?.browser {
      case "Safari":
        Label("Safari keeps sign-ins in a protected file. You’ll choose that file yourself, because macOS lets Serein open it only when you pick it. Serein reads it once and keeps no access.", systemImage: "safari")
      case "Firefox":
        Label("Firefox keeps cookies unencrypted, so macOS asks for nothing. Passwords stay separate: in Firefox open about:logins, choose Export Logins, then import the file in Settings → Passwords.", systemImage: "flame")
      default:
        Label("macOS will ask whether Serein may use the browser’s “Safe Storage” key. Choose Allow.", systemImage: "lock")
      }
      Label("Quit the browser first so its newest sign-ins are on disk.", systemImage: "arrow.clockwise")
    }.font(UIStyle.font(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    if let error = model.error { Text(error).foregroundStyle(p.danger) }
    Spacer()
    HStack {
      Spacer()
      Button("Cancel", action: close).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
      Button(model.profile?.browser == "Safari" ? "Choose file…" : "Read sign-ins", action: model.read)
        .buttonStyle(PrimaryButton())
        .disabled(model.profile == nil)
    }
  }

  @ViewBuilder private var review: some View {
    let shown = CookieSites.filter(model.sites, query: model.query)
    Text("Check the sites to stay signed in to. Unchecked sites are left out.")
      .foregroundStyle(p.secondary)
    HStack(spacing: 8) {
      TextField("Find a site", text: $model.query).textFieldStyle(.plain).textInputCursor().padding(8)
        .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(p.borderStrong))
      Button("All") { model.chosen.formUnion(shown.map(\.site)) }.buttonStyle(QuietButton())
      Button("None") { model.chosen.subtract(shown.map(\.site)) }.buttonStyle(QuietButton())
    }
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        if shown.isEmpty {
          Text("No site matches.").foregroundStyle(p.secondary).padding(8)
        }
        ForEach(shown) { site in
          Toggle(isOn: Binding(
            get: { model.chosen.contains(site.site) },
            set: { if $0 { model.chosen.insert(site.site) } else { model.chosen.remove(site.site) } }
          )) {
            HStack {
              Text(site.site).font(UIStyle.mono(12))
              Spacer()
              Text("\(site.cookies.count)").font(UIStyle.font(11)).foregroundStyle(p.faint)
                .accessibilityLabel("\(site.cookies.count) cookies")
            }
          }.toggleStyle(.checkbox).padding(.vertical, 5).padding(.horizontal, 8)
        }
      }
    }.background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
    if model.skipped > 0 {
      Text("\(model.skipped) expired, unreadable or site-partitioned cookies were left out.")
        .font(UIStyle.font(12)).foregroundStyle(p.faint)
    }
    HStack {
      Text("\(model.chosen.count) of \(model.sites.count) sites").foregroundStyle(p.secondary)
      Spacer()
      Button("Cancel") {
        model.cancel()
        close()
      }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
      Button(model.chosen.count == 1 ? "Bring 1 site" : "Bring \(model.chosen.count) sites", action: model.write)
        .buttonStyle(PrimaryButton()).disabled(model.chosen.isEmpty)
    }
  }

  private func progress(_ label: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ProgressView().controlSize(.small)
      Text(label).foregroundStyle(p.secondary)
      Spacer()
      HStack {
        Spacer()
        Button("Cancel") {
          model.cancel()
          close()
        }.buttonStyle(QuietButton())
      }
    }
  }
}

@MainActor enum SignInImportWindow {
  private static var window: NSWindow?
  private static var closeObserver: NSObjectProtocol?

  /// `prepared`: a model that has its profile, or its sites already read (setup, which asked
  /// macOS for the browser's key one time). `ended` gets the stage the window closed in.
  /// False when the window was already open: it then keeps its own model.
  @discardableResult
  static func show(prepared: SignInImportModel? = nil, ended: ((SignInImportModel.Stage) -> Void)? = nil) -> Bool {
    if let window {
      window.makeKeyAndOrderFront(nil)
      return false
    }
    let model = prepared ?? SignInImportModel()
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    w.title = "Bring Sign-ins"
    w.isReleasedWhenClosed = false
    w.contentViewController = NSHostingController(
      rootView: SignInImportView(model: model, close: { close() }))
    w.center()
    window = w
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: w, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        let stage = model.stage
        model.cancel()
        window = nil
        // Drop the observer so its closure stops holding the model.
        if let token = closeObserver { NotificationCenter.default.removeObserver(token) }
        closeObserver = nil
        ended?(stage)
      }
    }
    w.makeKeyAndOrderFront(nil)
    return true
  }

  private static func close() { window?.close() }
}
