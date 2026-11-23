import SereinCore
import SwiftUI

/// Settings > Privacy: every site with a saved choice for camera and microphone, location,
/// notifications or autoplay, each one revocable, and a way to forget them all.
struct SiteListSettings: View {
  @ObservedObject private var store = SitePermissionStore.shared
  @State private var confirmForget = false
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Sites with saved choices")
        Spacer()
        Button("Forget all sites…") { confirmForget = true }.disabled(store.entries.isEmpty)
      }
      if store.entries.isEmpty {
        Text("None yet. Sites you allow or block for location, notifications, autoplay, camera or microphone appear here.")
          .font(UIStyle.meta).foregroundStyle(p.secondary)
      }
      ForEach(store.entries) { entry in
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text(URL(string: entry.origin)?.host ?? entry.origin).lineLimit(1).truncationMode(.tail)
            Text("\(entry.feature.label) · \(SiteFeature.valueLabel(entry.value))").role(.meta)
          }
          Spacer()
          Button("Revoke") { store.forget(entry) }
            .accessibilityLabel(
              "Revoke \(entry.feature.label) choice for \(URL(string: entry.origin)?.host ?? entry.origin)")
        }
        Divider().overlay(p.line)
      }
      Text(
        "Private pages and the pages tasks work on always deny location, notifications and autoplay with sound. WebKit has no per-site autoplay switch, so Serein enforces that choice in the page; it applies from the next page load."
      ).font(UIStyle.meta).foregroundStyle(p.secondary)
    }.font(UIStyle.body).foregroundStyle(p.ink).controlSize(.small)
      .confirmationDialog(
        "Forget all site choices?", isPresented: $confirmForget, titleVisibility: .visible
      ) {
        Button("Forget all sites", role: .destructive) { store.forgetAll() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Sites will ask again the next time they want location, notifications or media.")
      }
  }
}

/// Settings > Privacy > Sites Serein treats differently: a lasting rule per site for every task,
/// schedule and alert. Only stricter choices exist (SiteRule); Remove returns a site to Normal.
/// No agent tool reads or writes this list.
struct SiteRuleSettings: View {
  @Environment(\.palette) private var p
  @State private var rules = SiteRules.all()
  @State private var draft = ""
  @State private var draftRule = SiteRule.never
  /// Normal is the absence of a rule, so it is Remove, not a choice.
  static let choices: [SiteRule] = [.ask, .never]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Never: Serein doesn’t open, read or act on the site, and its pages stay out of what Serein sees. Ask every step: every scroll and click there waits for you, whatever Autopilot says. A rule covers the site’s subdomains and applies to every task, schedule and alert. Send, pay, post and delete always ask.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      if rules.isEmpty {
        Text("None. Serein treats every site the same way.").role(.meta)
      }
      ForEach(rules.keys.sorted(), id: \.self) { site in
        HStack(spacing: 8) {
          Text(site).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
          SettingsPopUp("Serein on \(site)", selection: rule(site),
            choices: Self.choices.map { SettingsChoice(value: $0, label: $0.label) }, showsTitle: false)
          Button("Remove") { save(.normal, for: site) }
            .buttonStyle(QuietButton())
            .accessibilityLabel("Remove the rule for \(site)")
        }
      }
      HStack(spacing: 8) {
        TextField("Add a site, such as bank.example.com", text: $draft)
          .textFieldStyle(.roundedBorder)
          .onSubmit { add() }
          .accessibilityLabel("Site Serein treats differently")
        SettingsPopUp("Rule for the new site", selection: $draftRule,
          choices: Self.choices.map { SettingsChoice(value: $0, label: $0.label) }, showsTitle: false)
        Button("Add") { add() }.buttonStyle(QuietButton()).disabled(SitePolicy.site(draft) == nil || !asciiDraft)
          .accessibilityLabel("Add site rule")
      }
    }.font(UIStyle.body).foregroundStyle(p.ink).controlSize(.small)
      .accessibilityElement(children: .contain)
      // The More menu's Serein on This Site writes the same list.
      .onReceive(NotificationCenter.default.publisher(for: GateSettings.changed).receive(on: RunLoop.main)) { _ in
        let now = SiteRules.all()
        if now != rules { rules = now }
      }
  }

  private func rule(_ site: String) -> Binding<SiteRule> {
    Binding(get: { rules[site] ?? .normal }, set: { save($0, for: site) })
  }
  /// WebKit addresses carry the punycode host, so a rule typed in Unicode would never match.
  private var asciiDraft: Bool { draft.unicodeScalars.allSatisfy(\.isASCII) }
  private func add() {
    guard asciiDraft, let site = SitePolicy.site(draft) else { return }
    save(draftRule, for: site)
    draft = ""
  }
  private func save(_ rule: SiteRule, for site: String) {
    SiteRules.set(rule, for: site)
    rules = SiteRules.all()
    // A page just set to Never leaves the chip now, not on the next tab change.
    SereinPageChip.shared.refresh()
  }
}

/// Settings > Privacy > Sites Serein stays signed in to (KeptSignIns): each site with its last use,
/// Sign out and Sign out of all. Signing out removes that site's kept cookies and ends every task
/// that used them (TaskStores.signOut). Only Hand back adds a site, and no agent tool reads or
/// writes this list.
struct KeptSignInSettings: View {
  @ObservedObject var browser: BrowserModel
  @Environment(\.palette) private var p
  @State private var kept = KeptSignIns.all()
  static let ago: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("When you sign in on a task's page, Hand back can keep Serein signed in to that site. Only Serein's later tasks on the same site use it, each after you say yes; a scheduled request only when its card named the site. Pages you open yourself and private pages never get it. A sign-in unused for 30 days ends.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      if kept.isEmpty {
        Text("None. Serein keeps no sign-ins.").role(.meta)
      }
      ForEach(kept, id: \.site) { signIn in
        HStack(spacing: 8) {
          Text(signIn.site).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
          Text(lastUsed(signIn)).role(.meta).lineLimit(1)
          Button("Sign out") { signOut(signIn.site) }
            .buttonStyle(QuietButton())
            .accessibilityLabel("Sign Serein out of \(signIn.site)")
        }
      }
      if !kept.isEmpty {
        Button("Sign out of all") { signOut(nil) }
          .buttonStyle(QuietButton())
          .accessibilityLabel("Sign Serein out of every site it stays signed in to")
      }
    }.font(UIStyle.body).foregroundStyle(p.ink).controlSize(.small)
      .accessibilityElement(children: .contain)
      // Hand back, a task's use and the 30-day end change the same list.
      .onReceive(NotificationCenter.default.publisher(for: GateSettings.changed).receive(on: RunLoop.main)) { _ in
        let now = KeptSignIns.all()
        if now != kept { kept = now }
      }
  }

  private func lastUsed(_ signIn: KeptSignIn) -> String {
    let ago: String = Self.ago.localizedString(for: signIn.lastUsed, relativeTo: Date())
    return "Last used " + ago
  }

  private func signOut(_ site: String?) {
    browser.taskStores.signOut(site)
    kept = KeptSignIns.all()
  }
}

/// Settings › Privacy › Routine steps go ahead on: the sites a task's clicks, typing and moves
/// between pages go ahead on without a card, from the card's “Always allow routine steps”. Each
/// has Remove; sending, paying, deleting and forms ask there as everywhere. No agent tool reads or
/// writes this list.
struct RoutineSiteSettings: View {
  @ObservedObject private var watch = GateWatch.shared
  @Environment(\.palette) private var p
  var body: some View {
    let sites = RoutineGrants.sites()
    VStack(alignment: .leading, spacing: 8) {
      if sites.isEmpty {
        SettingsNote("None yet. On a card for a click or typing, “Always allow routine steps on …” adds the site here.")
      } else {
        ForEach(sites, id: \.self) { site in
          HStack {
            Text(site).font(UIStyle.body)
            Spacer()
            Button("Remove") { RoutineGrants.revoke(site) }.controlSize(.small).accessibilityLabel("Remove \(site)")
          }
        }
        SettingsNote("Clicks, typing and moving between pages go ahead there. Sending, paying, deleting, forms and sign-ins still ask, and scheduled runs always ask.")
      }
    }
  }
}
