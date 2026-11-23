#if DEBUG
import Foundation
import SereinCore
import WebKit

/// Headless checks for the password helper (`Serein --verify-passwords`). Uses private and
/// agent tabs with synthetic pages only, so no Keychain item is read or written.
@MainActor
func checkPasswordCapture() async {
  func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      FileHandle.standardError.write(Data("FAIL: password check: \(message)\n".utf8))
      exit(1)
    }
  }
  func installed(_ tab: BrowserTab) -> Bool {
    tab.web.configuration.userContentController.userScripts.contains {
      $0.source.contains(PasswordCapture.marker)
    }
  }
  func load(_ tab: BrowserTab, _ html: String) async {
    tab.web.loadHTMLString(html, baseURL: URL(string: "https://fixture.invalid/login"))
    for _ in 0..<100 {
      try? await Task.sleep(nanoseconds: 50_000_000)
      if !tab.web.isLoading, tab.web.url != nil { break }
    }
    try? await Task.sleep(nanoseconds: 200_000_000)
  }
  func pageJS(_ tab: BrowserTab, _ source: String) async -> Any? {
    try? await tab.web.evaluateJavaScript(source)
  }

  let form = """
    <form action="/session" onsubmit="event.preventDefault()">
    <input id="u" autocomplete="username"><input id="p" type="password">
    <input id="n" type="password" autocomplete="new-password" passwordrules="minlength: 24; required: digit;">
    <button>Sign in</button></form>
    """
  let submitScript =
    "document.getElementById('u').value='synthetic-user';document.getElementById('p').value='synthetic-secret';document.getElementById('n').value='';document.querySelector('form').requestSubmit();true"

  var offers: [SaveOffer] = []
  PasswordCapture.observeOffer = { offers.append($0) }
  defer { PasswordCapture.observeOffer = nil }
  let offerSetting = UserDefaults.standard.object(forKey: "serein.passwords.offerToSave")
  UserDefaults.standard.set(true, forKey: "serein.passwords.offerToSave")
  defer { UserDefaults.standard.set(offerSetting, forKey: "serein.passwords.offerToSave") }

  // Agent-owned tabs never get the helper and never produce an offer.
  let agentTab = BrowserTab(owner: "synthetic-agent", store: .nonPersistent())
  check(!installed(agentTab), "agent tab has no capture script")
  await load(agentTab, form)
  _ = await pageJS(agentTab, submitScript)
  try? await Task.sleep(nanoseconds: 300_000_000)
  check(offers.isEmpty, "agent tab submission is ignored")

  // A scripted submit with no real key press or click is ignored.
  PasswordCapture.trustSyntheticEventsForChecks = false
  let scripted = BrowserTab(privateMode: true, store: .nonPersistent())
  await load(scripted, form)
  _ = await pageJS(scripted, submitScript)
  _ = await pageJS(
    scripted,
    "document.getElementById('p').value='x';document.querySelector('form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));true")
  try? await Task.sleep(nanoseconds: 400_000_000)
  check(offers.isEmpty, "a scripted submit with no user action is ignored")
  PasswordCapture.trustSyntheticEventsForChecks = true
  defer { PasswordCapture.trustSyntheticEventsForChecks = false }

  // A private tab offers to save into memory only.
  let store = WKWebsiteDataStore.nonPersistent()
  let privateTab = BrowserTab(privateMode: true, store: store)
  check(installed(privateTab), "private tab has the capture script")
  await load(privateTab, form)
  _ = await pageJS(privateTab, submitScript)
  for _ in 0..<40 where offers.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
  check(offers.count == 1, "private submission produced one offer (got \(offers.count))")
  check(offers.first?.origin == "https://fixture.invalid", "offer uses WebKit's frame origin")
  check(offers.first?.username == "synthetic-user", "offer has the username")
  check(offers.first?.isPrivate == true && offers.first?.isUpdate == false, "private save offer")

  // Saving into memory, then the same submission again offers nothing.
  do {
    try MemoryCredentialStore.save(
      .init(origin: "https://fixture.invalid", username: "synthetic-user", password: "synthetic-secret"),
      in: store)
  } catch { check(false, "memory store accepts a non-persistent store") }
  check(
    (try? MemoryCredentialStore.save(
      .init(origin: "https://x.invalid", username: "a", password: "b"), in: .default())) == nil,
    "memory store refuses the persistent store")
  check(MemoryCredentialStore.items(in: .default()).isEmpty, "persistent store holds nothing")
  check(
    PasswordCapture.accounts(for: "https://fixture.invalid", in: privateTab).map(\.username)
      == ["synthetic-user"], "private accounts are filtered to the origin")
  check(
    PasswordCapture.accounts(for: "https://other.invalid", in: privateTab).isEmpty,
    "other origins see no accounts")
  try? await Task.sleep(nanoseconds: 4_200_000_000)  // past the helper's duplicate window
  offers.removeAll()
  _ = await pageJS(privateTab, submitScript)
  try? await Task.sleep(nanoseconds: 400_000_000)
  check(offers.isEmpty, "an unchanged saved password is not offered again")
  _ = await pageJS(
    privateTab,
    "document.getElementById('p').value='changed-secret';document.querySelector('form').requestSubmit();true")
  for _ in 0..<40 where offers.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
  check(offers.first?.isUpdate == true, "a changed password offers an update")

  // Generated password goes into the new-password field and honours its rules.
  let rules = PasswordRules.parse("minlength: 24; required: digit;")
  let generated = PasswordGenerator.generate(rules: rules)
  check(generated.count >= 24 && PasswordGenerator.satisfies(generated, rules: rules), "generator")
  _ = await pageJS(privateTab, "document.getElementById('n').focus();true")
  try? await Task.sleep(nanoseconds: 100_000_000)
  do {
    try await PasswordCapture.fillGenerated(generated, origin: "https://fixture.invalid", in: privateTab)
  } catch { check(false, "generated fill: \(error.localizedDescription)") }
  let value = await pageJS(privateTab, "document.getElementById('n').value") as? String
  check(value == generated, "generated password filled the new-password field")
  let current = await pageJS(privateTab, "document.getElementById('p').value") as? String
  check(current == "changed-secret", "current-password field left alone")
  // The page cannot reach the helper.
  let leaked = await pageJS(privateTab, "typeof globalThis.__sereinPasswords") as? String
  check(leaked == "undefined", "helper is invisible to page scripts")
  // A different origin refuses to fill.
  do {
    try await PasswordCapture.fillGenerated(generated, origin: "https://other.invalid", in: privateTab)
    check(false, "cross-origin fill refused")
  } catch {}
}
#endif
