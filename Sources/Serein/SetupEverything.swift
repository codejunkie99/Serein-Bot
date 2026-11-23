import AppKit
import SereinCore
import SwiftUI

/// The automatic part of setup: everything the steps do that needs no decision, one thing after
/// the other, while the person takes the tour or looks at its progress.
///
/// It uses the same readers and writers as the steps. What macOS guards still asks: the keychain
/// prompt for a Chromium browser's key, the confirmation before a saved password is opened, and
/// the confirmation of the default browser. The work waits for each answer, so two prompts
/// never show together. Two things stay the person's choice, each with a button in its row:
/// which sites' sign-ins come (the list of sites, as in Settings › Import), and whether Serein
/// reads the open tabs of the other browser. Mac access and talking need the person and are
/// not here.
@MainActor final class SetupRun: ObservableObject {
  /// One for the app: the work goes on when the setup panel closes, and the control at the top
  /// of the window shows it.
  static let shared = SetupRun()
  enum State: Equatable {
    case waiting
    case running
    /// macOS shows a question for this thing and waits for the person; the text says which.
    case asking(String)
    /// The person's own choice, by the button in the row. It does not hold the other work.
    case choice(String)
    case done(String)
    case skipped(String)
  }
  struct Item: Identifiable {
    let id: String
    let title: String
    var state = State.waiting
    /// The label of a button in the row; `press` does what it says.
    var button: String?
  }
  private static let fresh = [
    Item(id: "agents", title: "Find your coding agents"),
    Item(id: "library", title: "Bring bookmarks and history"),
    Item(id: "signins", title: "Bring sign-ins"),
    Item(id: "passwords", title: "Bring saved passwords"),
    Item(id: "tabs", title: "Bring open tabs"),
  ]
  @Published private(set) var items = SetupRun.fresh
  /// The person looked at the results after the work ended; the control at the top then goes.
  @Published var seen = false
  /// Steps of the tour are still open (the person skipped it or closed it). For this run of the
  /// app only: the control at the top is the way back, and Settings has "Run setup again".
  /// `--ui-setup-pill` shows the control in a UI preview.
  @Published var tourLeft = ["--ui-preview", "--ui-setup-pill"].allSatisfy(CommandLine.arguments.contains)
  /// The browser the work brings from, when it is known.
  @Published private(set) var source: String?
  @Published private(set) var started = false
  @Published private(set) var finished = false
  private var stopped = false
  private weak var browser: BrowserModel?
  /// The sign-ins of the other browser, held for the person's review. Nothing of them is
  /// written before the person chooses sites in the list.
  private var review: SignInImportModel?
  /// The list of sites is on screen; the choice is then not taken away behind it.
  private var reviewOpen = false
  /// The browser whose tabs the person can bring.
  private var tabBrowser: (name: String, id: String)?

  var active: Bool { started && !finished }
  var settled: Int {
    items.filter {
      switch $0.state {
      case .done, .skipped: return true
      default: return false
      }
    }.count
  }
  /// A question of macOS waits for the person.
  var asking: Bool {
    items.contains {
      if case .asking = $0.state { return true }
      return false
    }
  }
  /// A question of macOS or a choice in a row waits for the person.
  var needsYou: Bool {
    asking || items.contains {
      if case .choice = $0.state { return true }
      return false
    }
  }

  /// `synthetic`: the profiles of a preview. With them only the library is brought, into the
  /// preview's own library; nothing of the Mac is read or changed.
  func start(browser: BrowserModel, synthetic: [BrowserImportProfile]?) {
    guard !started else { return }
    started = true
    self.browser = browser
    Task {
      await run(browser: browser, synthetic: synthetic)
      finished = true
      // The tour leaves out what was done here, also after Serein opens again.
      if synthetic == nil, !stopped { UserDefaults.standard.set(true, forKey: SetupProgress.automaticKey) }
    }
  }
  /// The step in hand ends by itself (a prompt of macOS cannot be taken back); the rest is left.
  func stop() { stopped = true }
  /// "Run setup again" in Settings: setup starts at its first page, not where the tour was
  /// left, and results of a run that ended count as looked at.
  func restartTour() {
    tourLeft = false
    if finished {
      seen = true
      leaveChoices()
    }
  }
  /// For "Run setup again": a run that ended can start again.
  func reset() {
    guard !active else { return }
    leaveChoices()
    UserDefaults.standard.removeObject(forKey: SetupProgress.automaticKey)
    items = Self.fresh
    source = nil
    started = false
    finished = false
    stopped = false
    seen = false
  }

  /// The person looked at the results and went on: a choice still open counts as "not now",
  /// and the sign-ins held for it are forgotten.
  func leaveChoices() {
    if !reviewOpen {
      review?.cancel()
      review = nil
    }
    tabBrowser = nil
    for index in items.indices {
      guard case .choice = items[index].state, !(reviewOpen && items[index].id == "signins") else { continue }
      items[index].state = .skipped(
        items[index].id == "signins"
          ? "Not chosen. Settings › Import brings sign-ins at any time." : "Not brought.")
      items[index].button = nil
    }
  }
  /// The button of a row.
  func press(_ id: String) {
    switch (id, items.first { $0.id == id }?.state) {
    case ("signins", .choice): reviewSignIns()
    case ("tabs", .choice): Task { await readTabs() }
    case ("tabs", .done): MacAccess.openSettings(.automation)
    default: break
    }
  }
  /// The list of sites, in the same window as Settings › Import. Only ticked sites are written.
  private func reviewSignIns() {
    guard let model = review else { return }
    // False when the list is already on screen (a second click): the mark then stays as it is.
    let shown = SignInImportWindow.show(prepared: model, ended: { [weak self] stage in
      guard let self else { return }
      // The window is gone, whichever run its sites belonged to.
      self.reviewOpen = false
      guard self.review === model else { return }
      self.review = nil
      switch stage {
      case .done(let summary): self.set("signins", .done(summary))
      case .writing: self.set("signins", .skipped("Stopped before every sign-in was added."))
      default: self.set("signins", .skipped("No sign-ins were brought. Settings › Import brings them at any time."))
      }
    })
    if shown { reviewOpen = true }
  }
  /// Reads the tabs of the other browser's regular windows. macOS asks the person first, and
  /// what they allow stays allowed, so the row says so and has the way to the setting.
  private func readTabs() async {
    guard let from = tabBrowser, let browser,
      // The identifier goes into a script, so it may hold only what an identifier holds.
      from.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
    else { return }
    tabBrowser = nil
    ask("tabs", "macOS asks if Serein can read the tabs of \(from.name). Choose Allow.")
    // A window is regular only when the browser says so and nothing says private: Chrome and
    // its family have `mode`, Arc has `incognito`, and a browser can have both. A window that
    // says neither is left out. A tab with no address is left out.
    let script = """
      tell application id "\(from.id)"
        set out to ""
        repeat with w in windows
          set told to false
          set isPrivate to false
          try
            if (mode of w) is not "normal" then set isPrivate to true
            set told to true
          end try
          try
            if (incognito of w) then set isPrivate to true
            set told to true
          end try
          if told and not isPrivate then
            repeat with t in tabs of w
              try
                set out to out & (URL of t) & linefeed
              end try
            end repeat
          end if
        end repeat
        return out
      end tell
      """
    // Off the main thread: macOS can show its question here, and the window must stay alive.
    let (text, code) = await Task.detached(priority: .userInitiated) { () -> (String?, Int) in
      var error: NSDictionary?
      let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
      return (error == nil ? result?.stringValue : nil, error?[NSAppleScript.errorNumber] as? Int ?? 0)
    }.value
    guard let text else {
      // -1743: the person said no, now or before.
      set(
        "tabs",
        .skipped(
          code == -1743
            ? "macOS does not let Serein read the tabs of \(from.name). You can allow it in System Settings › Privacy & Security › Automation."
            : "\(from.name) did not give its tabs."))
      return
    }
    let count = browser.bringTabs(SetupSource.tabs(text))
    let stays = " macOS now lets Serein control \(from.name); you can take that away."
    set(
      "tabs",
      count > 0
        ? .done("\(count) \(count == 1 ? "tab" : "tabs") from \(from.name). Each loads when you open it." + stays)
        : .done("\(from.name) has no open web pages that Serein does not have." + stays),
      button: "Automation settings…")
  }

  /// The app that opens web links and the name people know it by; nil when it is Serein.
  static func opener() -> (url: URL, name: String, id: String)? {
    guard let probe = URL(string: "https://example.com"),
      let url = NSWorkspace.shared.urlForApplication(toOpen: probe),
      let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier
    else { return nil }
    let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    return (url, name, id)
  }
  /// The name for the line on the welcome page: the browser Serein would bring from.
  static func sourceName(synthetic: [BrowserImportProfile]?) async -> String? {
    let found = await scan(synthetic: synthetic)
    let name = synthetic == nil ? opener()?.name : nil
    // Only a browser Serein can read: for another one the box would bring nothing.
    return SetupSource.profiles(defaultBrowser: name, found: found).first?.browser
  }
  /// The profiles to bring from, the one the person used last first.
  private static func profiles(defaultBrowser: String?, found: [BrowserImportProfile]) -> [BrowserImportProfile] {
    let profiles = SetupSource.profiles(defaultBrowser: defaultBrowser, found: found)
    guard let first = profiles.first else { return profiles }
    let state = first.directory.deletingLastPathComponent().appendingPathComponent("Local State")
    return SetupSource.lastUsedFirst(profiles, lastUsed: SetupSource.lastUsed(localState: try? Data(contentsOf: state)))
  }
  /// Every browser profile on this Mac that Serein can read, whichever browser it is.
  private static func scan(synthetic: [BrowserImportProfile]?) async -> [BrowserImportProfile] {
    if let synthetic { return synthetic }
    return await Task.detached(priority: .userInitiated) { BrowserProfileScanner.scan() }.value
  }
  /// The browser whose open tabs Serein can read: one of the Chromium family that runs now, the
  /// one that opens links first. Only that family says which of its windows are private.
  private static func tabSource(opener: (url: URL, name: String, id: String)?) -> (name: String, id: String)? {
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    if let opener, SetupSource.tellsPrivateWindows(opener.name),
      running.contains(where: { $0.bundleIdentifier == opener.id })
    {
      return (opener.name, opener.id)
    }
    for app in running where app.bundleIdentifier != Bundle.main.bundleIdentifier {
      guard let name = app.localizedName, let id = app.bundleIdentifier else { continue }
      if SetupSource.tellsPrivateWindows(name) { return (name, id) }
    }
    return nil
  }

  /// The profile whose sign-ins and passwords setup brings: the first one (the one used last)
  /// with a cookie file that Serein can read. One profile, so macOS asks one time for the key.
  private static func signInProfile(_ profiles: [BrowserImportProfile]) -> BrowserImportProfile? {
    profiles.first { profile in
      if profile.bookmarkFormat == .firefoxSQLite {
        return FirefoxCookies.cookiesDatabase(in: profile.directory) != nil
      }
      return ChromiumCookies.safeStorageServices[profile.browser] != nil
        && ChromiumCookies.cookiesDatabase(in: profile.directory) != nil
    }
  }

  /// `--probe-setup`: what the automatic part would do on this Mac. It looks only at which
  /// folders and apps are there; it opens no cookie file, no keychain item and no tab list.
  static func plan() async -> [String] {
    let opener = Self.opener()
    let found = await scan(synthetic: nil)
    let profiles = Self.profiles(defaultBrowser: opener?.name, found: found)
    let browsers = Dictionary(grouping: found, by: \.browser).map { "\($0.key) (\($0.value.count))" }.sorted()
    let signIn = signInProfile(profiles)
    let tabs = tabSource(opener: opener)
    return [
      "default browser: \(opener?.name ?? "Serein")",
      "browsers Serein can read: \(browsers.isEmpty ? "none" : browsers.joined(separator: ", "))",
      "brings from: \(profiles.first?.browser ?? "nothing") · profiles: \(profiles.map(\.profile).joined(separator: ", "))",
      "sign-ins (you choose the sites) from: \(signIn.map { "\($0.browser) · \($0.profile)" } ?? "none")"
        + (signIn.map { $0.bookmarkFormat == .firefoxSQLite ? " (no keychain prompt)" : " (keychain prompt: \(ChromiumCookies.safeStorageServices[$0.browser] ?? "?"))" } ?? ""),
      "passwords from: \(signIn.flatMap { p in ChromiumLogins.database(in: p.directory).map { _ in "\(p.browser) · \(p.profile) (same key, then Touch ID or the Mac's password)" } } ?? "a CSV file (this browser's passwords cannot be read)")",
      "open tabs (when you choose) from: \(tabs?.name ?? "no browser of the Chromium family is open")",
    ]
  }

  private func run(browser: BrowserModel, synthetic: [BrowserImportProfile]?) async {
    let live = synthetic == nil
    let opener = live ? Self.opener() : nil
    // Any browser will do: the one that opens links when Serein can read its files, else the
    // first one it can read.
    let found = await Self.scan(synthetic: synthetic)
    let profiles = Self.profiles(defaultBrowser: opener?.name, found: found)
    source = profiles.first?.browser ?? opener?.name
    let signIn = live ? Self.signInProfile(profiles) : nil
    let preview = State.skipped("Not in a preview.")
    // `--ui-setup-choices`: a picture of the two rows that wait for a choice.
    let sample = !live && CommandLine.arguments.contains("--ui-setup-choices")

    // Two things need no answer from the person. They work from the start, beside the
    // questions: the agents, and the bookmarks and history.
    set("agents", .running)
    let agents = Task { @MainActor () -> State in
      // Each agent CLI keeps its own sign-in. Serein reads whether one is there; it opens no
      // sign-in page by itself. An agent that is not signed in is left out and named.
      if live { await HarnessRegistry.shared.refreshAll() }
      let states = HarnessDriver.allCases.map {
        ($0.displayName, HarnessPrimaryAction.of(HarnessRegistry.shared.snapshots[$0]))
      }
      let ready = states.filter { $0.1 == .ready }.map(\.0)
      let left = states.filter { $0.1 == .signIn || $0.1 == .update }.map(\.0)
      let leftOut = left.isEmpty
        ? "" : " Left out (not signed in, or out of date): \(left.joined(separator: ", "))."
      return ready.isEmpty
        ? .skipped("No agent on this Mac is signed in. Connect one in Settings › AI apps." + leftOut)
        : .done(ready.joined(separator: ", ") + (ready.count == 1 ? " is ready." : " are ready.") + leftOut)
    }
    set("library", .running)
    let library = Task { @MainActor () -> State in
      guard !profiles.isEmpty else {
        return .skipped(
          opener?.name == "Safari"
            ? "Safari keeps its bookmarks and history in a protected folder. macOS lets Serein read them only when you choose them: Settings › Import."
            : "No browser that Serein can read was found on this Mac.")
      }
      let model = BrowserImportModel(profiles: profiles)
      model.load()
      model.preview()
      await self.idle { model.busy }
      guard model.hasPreview else { return .skipped(model.phase) }
      // A profile that could not be read gives a preview with only its error.
      let read = Array(model.previews.values)
      if read.allSatisfy({ $0.bookmarks.isEmpty && $0.visits.isEmpty }),
        let message = read.flatMap(\.messages).first
      {
        return .skipped(message)
      }
      model.importPreview(into: browser)
      await self.idle { model.busy }
      return model.completed ? .done(model.result ?? "Done.") : .skipped(model.result ?? model.phase)
    }

    // 1. THE QUESTIONS. What macOS asks comes now, one question after the other, while the
    // person is still here; each row says what its question is.
    //
    // A Chromium browser seals its cookies and its saved passwords with one key. Serein asks
    // macOS for it one time, reads both with it, and wipes its copy before the next thing.
    var browserKey: Data?
    defer { if let count = browserKey?.count { browserKey?.resetBytes(in: 0..<count) } }
    var keyRefused: String?
    var signInsEnd: State?
    var fresh: [PasswordImport] = []
    var passwordsEnd: State?
    var passwordsAlready = 0
    var passwordsLeftOut = 0

    if live, !stopped, let profile = signIn,
      let service = ChromiumCookies.safeStorageServices[profile.browser]
    {
      ask("signins", "macOS asks for your Mac password, to share the key of \(profile.browser). Choose Allow.")
      do {
        // Off the main thread: this waits while macOS shows its keychain prompt.
        browserKey = try await Task.detached(priority: .userInitiated) { () -> Data in
          var password = try SignInImportModel.safeStoragePassword(service: service)
          defer { password.resetBytes(in: 0..<password.count) }
          return ChromiumCookies.key(safeStoragePassword: password)
        }.value
      } catch { keyRefused = error.localizedDescription }
      set("signins", .running)
      // The sign-ins are read for the person's review. Not one is written here.
      if let key = browserKey, let database = ChromiumCookies.cookiesDatabase(in: profile.directory) {
        do {
          let cookies = try await Task.detached(priority: .userInitiated) {
            try ChromiumCookies.read(database: database, key: key)
          }.value
          let model = SignInImportModel()
          model.profiles = [profile]
          model.profileID = profile.id
          model.sites = CookieSites.group(cookies.cookies)
          model.skipped = cookies.skipped
          if model.sites.isEmpty {
            signInsEnd = .skipped("\(profile.browser) has no sign-ins to bring over.")
          } else {
            model.stage = .review
            review = model
          }
        } catch { signInsEnd = .skipped(error.localizedDescription) }
      } else {
        signInsEnd = .skipped(keyRefused ?? "macOS did not share the key of \(profile.browser).")
      }
    }

    if live, !stopped {
      // Other browsers do not let another app read their passwords; a file is the way.
      let byFile =
        source == "Safari" || source == nil
        ? "Safari keeps passwords in iCloud Keychain, which no other browser can read. In the Passwords app choose File › Export All Passwords, then Settings › Passwords › Import CSV here."
        : "Export the passwords to a CSV file in \(source ?? "your browser"), then use Settings › Passwords › Import CSV here."
      if let key = browserKey, let profile = signIn,
        let database = ChromiumLogins.database(in: profile.directory)
      {
        do {
          // The count opens no password. The person confirms before Serein opens one.
          let saved = try await Task.detached(priority: .userInitiated) {
            try ChromiumLogins.count(database: database)
          }.value
          if saved == 0 {
            passwordsEnd = .skipped("\(profile.browser) has no saved passwords.")
          } else {
            ask("passwords", "Confirm with Touch ID or your Mac's password, to bring the saved passwords of \(profile.browser).")
            var confirmed = false
            do {
              try await PasswordVault.shared.authenticate("bring the saved passwords of \(profile.browser) into Serein")
              confirmed = true
            } catch { passwordsEnd = .skipped("Not confirmed, so no password was brought.") }
            set("passwords", .waiting)
            if confirmed {
              let read = try await Task.detached(priority: .userInitiated) {
                try ChromiumLogins.read(database: database, key: key)
              }.value
              // A password that Serein already has for a site and a name stays as it is: the
              // one in the other browser can be the older one.
              let have = Set(PasswordVault.shared.entries.map { $0.origin + "\u{0}" + $0.username })
              var unusable = 0
              for entry in read.entries {
                guard let origin = CredentialOrigin.normalize(entry.origin) else {
                  unusable += 1
                  continue
                }
                if have.contains(origin + "\u{0}" + entry.username) {
                  passwordsAlready += 1
                } else {
                  fresh.append(entry)
                }
              }
              passwordsLeftOut = read.skipped + unusable
              if fresh.isEmpty {
                passwordsEnd = .skipped(
                  passwordsAlready > 0
                    ? "Serein already has the \(passwordsAlready) saved \(passwordsAlready == 1 ? "password" : "passwords") of \(profile.browser)."
                    : "\(profile.browser) has no saved passwords that Serein can keep.")
              }
            }
          }
        } catch { passwordsEnd = .skipped(error.localizedDescription) }
      } else {
        passwordsEnd = .skipped(keyRefused ?? byFile)
      }
    }
    // Both reads are over: the key goes before anything else is asked.
    if let count = browserKey?.count { browserKey?.resetBytes(in: 0..<count) }
    browserKey = nil


    // 2. THE WORK, and the two things that stay the person's choice.
    await step("signins") {
      if sample {
        self.setButton("signins", "Choose sites…")
        return .choice("Arc has sign-ins for 48 sites. Not one is added until you choose the sites.")
      }
      guard live else { return preview }
      if let signInsEnd { return signInsEnd }
      if let model = self.review {
        let count = model.sites.count
        self.setButton("signins", "Choose sites…")
        return .choice(
          "\(signIn?.browser ?? "Your browser") has sign-ins for \(count) \(count == 1 ? "site" : "sites"). Not one is added until you choose the sites.")
      }
      guard let profile = signIn else {
        return .skipped(
          self.source == "Safari"
            ? "Safari keeps its sign-ins in a protected file. Bring them from Settings › Import, where you choose the file."
            : "No sign-ins that Serein can read were found.")
      }
      // Firefox: its cookie file needs no key. Serein reads it when the person asks for the list.
      let model = SignInImportModel()
      model.profiles = [profile]
      model.profileID = profile.id
      self.review = model
      self.setButton("signins", "Choose sites…")
      return .choice("Serein can read the sign-ins of \(profile.browser). Not one is read or added until you choose.")
    }

    await step("passwords") {
      guard live else { return preview }
      if let passwordsEnd { return passwordsEnd }
      var kept = 0
      for entry in fresh {
        if (try? PasswordVault.shared.save(
          origin: entry.origin, username: entry.username, password: entry.password)) != nil {
          kept += 1
        }
        // Each save is a write to the Keychain; the window stays alive between them.
        await Task.yield()
      }
      let failed = fresh.count - kept
      return .done(
        "\(kept) \(kept == 1 ? "password" : "passwords") from \(signIn?.browser ?? "your browser"), in this Mac's Keychain."
          + (passwordsAlready > 0 ? " \(passwordsAlready) that Serein already had are not changed." : "")
          + (passwordsLeftOut > 0 ? " \(passwordsLeftOut) left out (no password, or an address that is not HTTPS)." : "")
          + (failed > 0 ? " \(failed) could not be saved in the Keychain." : ""))
    }
    // The passwords are in the Keychain now; Serein's own copy goes.
    fresh = []

    await step("tabs") {
      if sample {
        self.setButton("tabs", "Bring tabs")
        return .choice(
          "Serein can bring the tabs of Arc's regular windows. macOS asks first, and that permission stays until you take it away.")
      }
      guard live else { return preview }
      guard let from = Self.tabSource(opener: opener) else {
        return .skipped(
          opener.map { !SetupSource.tellsPrivateWindows($0.name) } == true
            ? "\(opener?.name ?? "Your browser") cannot tell Serein which of its windows are private, so Serein does not read its tabs."
            : "No browser that Serein can read tabs from is open.")
      }
      self.tabBrowser = from
      self.setButton("tabs", "Bring tabs")
      return .choice(
        "Serein can bring the tabs of \(from.name)'s regular windows. macOS asks first, and that permission stays until you take it away.")
    }

    set("library", await library.value)
    set("agents", await agents.value)
  }

  private func setButton(_ id: String, _ label: String?) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].button = label
  }
  private func set(_ id: String, _ state: State, button: String?) {
    set(id, state)
    setButton(id, button)
  }
  private func set(_ id: String, _ state: State) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].state = state
    // The button belonged to the choice; a row that is past it has none, unless it gets one.
    if case .choice = state {} else { items[index].button = nil }
  }
  /// A question of macOS is on the way for this row. The Dock icon asks for attention when
  /// Serein is behind another app, so the question is not missed.
  private func ask(_ id: String, _ what: String) {
    set(id, .asking(what))
    if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
  }
  private func step(_ id: String, _ work: @MainActor () async -> State) async {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    if stopped {
      items[index].state = .skipped("Stopped before this.")
      // The row has no button then, so the sign-ins held for the choice go too.
      if id == "signins", !reviewOpen {
        review?.cancel()
        review = nil
      }
      return
    }
    items[index].state = .running
    items[index].state = await work()
  }
  private func idle(_ busy: @MainActor () -> Bool) async {
    while busy() { try? await Task.sleep(nanoseconds: 80_000_000) }
  }
}

extension SignInImportModel {
  /// True while it reads the browser's cookies or writes the chosen ones.
  var working: Bool {
    switch stage {
    case .reading, .writing: return true
    default: return false
    }
  }
}

extension BrowserModel {
  /// Tabs brought from another browser. Each is asleep, like a tab of a restored session: it
  /// loads when it is first opened. An address that a tab already has is not added again.
  @discardableResult func bringTabs(_ addresses: [String]) -> Int {
    var added = 0
    for address in addresses
    where (try? BrowserPolicy.url(address)) != nil && !tabs.contains(where: { $0.address == address }) {
      let tab = BrowserTab()
      attach(tab)
      tab.rest(at: address, title: URL(string: address)?.host ?? address)
      tabs.append(tab)
      added += 1
    }
    if added > 0 { persist() }
    return added
  }
}

/// The card at the top of the welcome page: the film of the Serein logo (particles turn into
/// the mark, the name comes, the mark grows), on a loop with no end and no still part. Where a
/// film does not play (Reduce Motion, reduced effects) the mark and the name are drawn.
struct SetupArt: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sereinReducedEffects) private var reducedEffects
  static let url = Bundle.module.url(forResource: "setup-logo", withExtension: "mp4", subdirectory: "Wallpapers")
  var body: some View {
    // A UI preview draws the still version, so captures do not change from run to run;
    // `--ui-film` shows the film there too.
    let preview = CommandLine.arguments.contains("--ui-preview") && !CommandLine.arguments.contains("--ui-film")
    if !reduceMotion, !reducedEffects, !preview, let url = Self.url {
      // The film's own ground, for the moment before its first frame.
      HeaderFilm(url: url).background(Color(hex: 0x05050A))
    } else {
      ZStack {
        RadialGradient(
          colors: [Color(hex: 0x1B1D3A), Color(hex: 0x0B0B12)], center: .center, startRadius: 6, endRadius: 250)
        HStack(spacing: 12) {
          SereinGlowMark(size: 54)
          Text("Serein").font(.custom("Geist-Medium", size: 28)).tracking(-0.7).foregroundStyle(Color.white)
        }.padding(.trailing, 14)
      }
    }
  }
}

/// The progress of the automatic setup: each thing it does with its state, and the way into
/// the app.
struct SetupEverything: View {
  @ObservedObject var run: SetupRun
  /// Back to the steps, when the tour is not over.
  var tour: (() -> Void)?
  let open: () -> Void
  @FocusState private var onMainButton: Bool
  @Environment(\.palette) private var p

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 9) {
          SereinMark(size: 20)
          Text(run.needsYou ? "Setup needs you" : run.finished ? "Serein is ready" : "Setting up")
            .font(UIStyle.font(16, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
        }.frame(height: 24)
        Text(subtitle).role(.meta).fixedSize(horizontal: false, vertical: true)
      }.padding(.horizontal, 20).padding(.top, 14)
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(p.track)
          Capsule().fill(run.finished ? p.success : p.accent)
            .frame(width: geometry.size.width * CGFloat(run.settled) / CGFloat(max(1, run.items.count)))
        }
      }.frame(height: 2).padding(.horizontal, 20).padding(.top, 12)
        .accessibilityElement()
        .accessibilityLabel("\(run.settled) of \(run.items.count) done")
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(run.items) { item in row(item) }
        }.padding(.horizontal, 20).padding(.top, 8)
      }
      HStack(spacing: 12) {
        if let tour { Button("Back to the tour", action: tour) }
        if run.active { Button("Stop") { run.stop() }.help("Leaves the things that did not start yet.") }
        Spacer()
        Button("Open Serein", action: open).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
          .focused($onMainButton).help(run.finished ? "" : "Setup goes on in the background.")
      }.padding(.horizontal, 20).frame(height: 48)
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .onAppear { DispatchQueue.main.async { onMainButton = true } }
  }

  private var subtitle: String {
    if run.asking { return "macOS asks you a few things first. After that it runs by itself." }
    if run.needsYou { return "A row with a button waits for your choice. You can also leave it." }
    if run.finished { return "Mac access for agents and talking are in Settings." }
    if let source = run.source { return "From \(source). No more questions; it runs by itself." }
    return "Looking at what is on this Mac."
  }

  @ViewBuilder private func row(_ item: SetupRun.Item) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Group {
        switch item.state {
        case .waiting: Circle().strokeBorder(p.track, lineWidth: 1.5)
        case .running: ActivityRing(active: true)
        case .asking, .choice: InterfaceIcon(systemName: "hand.raised", size: 14).foregroundStyle(p.accent)
        case .done: InterfaceIcon(systemName: "checkmark.circle.fill", size: 14).foregroundStyle(p.success)
        case .skipped: InterfaceIcon(systemName: "minus.circle", size: 14).foregroundStyle(p.faint)
        }
      }.frame(width: 14, height: 14).padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).foregroundStyle(item.state == .waiting ? p.secondary : p.ink)
        switch item.state {
        case .done(let text), .skipped(let text):
          Text(text).role(.micro).fixedSize(horizontal: false, vertical: true)
        case .running: Text("Working…").role(.micro)
        case .asking(let text), .choice(let text):
          Text(text).font(UIStyle.micro).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
        case .waiting: EmptyView()
        }
        if let button = item.button {
          // A resting outline: the row's own action must read as a button, not as text.
          Button(button) { run.press(item.id) }
            .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).stroke(p.borderStrong))
            .padding(.top, 6)
        }
      }
      Spacer(minLength: 0)
    }.padding(.vertical, 8).accessibilityElement(children: item.button == nil ? .combine : .contain)
  }
}

/// The control at the top of the window while setup has something to show: the automatic part
/// at work, its results not yet looked at, or steps of the tour still open. A click opens setup
/// there. With nothing to show it is not drawn.
struct SetupPill: View {
  @ObservedObject private var run = SetupRun.shared
  @Environment(\.palette) private var p
  var body: some View {
    if let label {
      Button {
        NotificationCenter.default.post(name: Notification.Name("SereinShowSetup"), object: nil)
      } label: {
        HStack(spacing: 6) {
          if run.active {
            ActivityRing(active: true).frame(width: 12, height: 12)
          } else {
            SereinMark(size: 14)
          }
          Text(label).font(UIStyle.meta).lineLimit(1).fixedSize()
        }.frame(height: 18)
      }.buttonStyle(QuietButton()).help("Open setup").accessibilityLabel(label)
    }
  }
  private var label: String? {
    if run.needsYou { return "Setup needs you" }
    if run.active { return "Setting up · \(run.settled) of \(run.items.count)" }
    if run.started, !run.seen { return "Setup is done" }
    if run.tourLeft { return "Finish setup" }
    return nil
  }
}
