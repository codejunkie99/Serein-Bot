import AppKit
import SereinCore
import SwiftUI

/// Settings › AI apps: one row per AI app (its logo, status and its one action or Use switch;
/// `HarnessCard`), whose chevron opens that app's own page (`HarnessAppSettings`), so no app is
/// drawn twice. Status and setup actions stay on the row.
struct HarnessSettingsSection: View {
  @ObservedObject var agent: AgentModel
  @ObservedObject private var registry = HarnessRegistry.shared
  @Environment(\.settingsNavigation) private var nav
  @Environment(\.palette) var p
  private var instances: [HarnessInstance] {
    let all = registry.settings.instances
    return all.filter { registry.snapshots[$0.driver]?.installed == true }
      + all.filter { registry.snapshots[$0.driver]?.installed != true }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsRowList(
        "AI apps on this Mac",
        info: "Serein uses the AI apps on your Mac and your own accounts. Turn off any app you do not want it to use.",
        note: "Install, Sign in and Update use each app’s own setup. Serein never asks for your account password."
      ) {
        ForEach(instances) { instance in
          HarnessCard(instance: instance, open: { nav.push(instance.driver.rawValue) })
            .padding(.horizontal, 16).padding(.vertical, 8)
            .settingsRowHairline()
        }
      }
      HStack {
        Text("Checked when Serein comes to the front and when an app signs in or updates. Checking never updates an app or changes its settings.")
          .role(.meta)
        Spacer()
        Button("Check All Again") { Task { await registry.refreshAll(includeDisabled: true) } }
          .disabled(!registry.refreshing.isEmpty)
      }.padding(.horizontal, 2)
    }
    // Apps left unchecked at launch (HarnessRegistry.deferred) are checked when this page opens,
    // so no row waits on "Not checked yet" for Check All Again.
    .task { registry.probeDeferred() }
  }
}

/// AI apps › {App}: its row again, then where it is and its configuration (name, executable,
/// environment, the API key in Keychain, Move to Keychain), Use my own setup (it asks first), what
/// it has installed and what it is offered for: `HarnessCard`'s own settings.
struct HarnessAppSettings: View {
  @ObservedObject var agent: AgentModel
  /// Its driver's raw value, the sub-page's key.
  let key: String
  @ObservedObject private var registry = HarnessRegistry.shared
  var body: some View {
    if let instance = registry.settings.instances.first(where: { $0.driver.rawValue == key }) {
      VStack(alignment: .leading, spacing: 24) {
        SettingsPageHeader(instance.name, sentence: "How Serein starts \(instance.name), and what it may use.")
        SettingsRowList {
          HarnessCard(instance: instance)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .settingsRowHairline()
        }
        SettingsBlock("Setup") {
          HarnessCard(instance: instance, projects: agent.browser?.shareableProjects ?? [], advanced: true)
        }
      }
    } else {
      SettingsPageHeader("Not on this Mac", sentence: "Serein does not know this AI app any more.")
    }
  }
  @MainActor static func title(_ key: String) -> String {
    HarnessRegistry.shared.settings.instances.first { $0.driver.rawValue == key }?.name ?? "AI apps"
  }
}

private struct HarnessCard: View {
  var instance: HarnessInstance
  var projects: [Project] = []
  var advanced = false
  /// The row on Settings › AI apps: its chevron opens the app's own page.
  var open: (() -> Void)?
  @ObservedObject private var registry = HarnessRegistry.shared
  @Environment(\.palette) var p
  @State private var path = ""
  @State private var env = ""
  @State private var name = ""
  @State private var rejected: [String] = []
  /// API key names typed into the text box, which keeps no keys (HarnessEnvironment.keyFieldMessage).
  @State private var refusedKeys: [String] = []
  @State private var keyName = ""
  /// The key as typed; it goes to Keychain on Save Key and is never shown again.
  @State private var key = ""
  @State private var keyError: String?
  @State private var expanded = false
  @State private var confirmOwnSetup = false
  @State private var capsExpanded = false
  @State private var caps: HarnessCapabilityReport?
  @State private var capsLoading = false
  /// The project whose own skills, commands and servers are shown with the user's; nil for none.
  @State private var capsProject: String?
  var snapshot: HarnessSnapshot? { registry.snapshots[instance.driver] }
  var provider: Provider { Provider(instance.driver) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !advanced {
        HStack(alignment: .top, spacing: 10) {
          HarnessGlyph(provider: provider, size: 18, tinted: true, logo: true).frame(width: 22, height: 22)
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Text(instance.name).font(UIStyle.body)
              if !instance.driver.verifiedLocally {
                Text("Unverified").font(UIStyle.micro).foregroundStyle(p.faint)
                  .padding(.horizontal, 5).padding(.vertical, 1).background(p.track, in: Capsule())
                  .help("Built from the app's own guide. Not yet tried with the real app.")
              }
            }
            HStack(spacing: 6) {
              Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
              Text(statusLine).role(.meta).lineLimit(2)
            }
          }
          Spacer()
          if registry.refreshing.contains(instance.driver) {
            ProgressView().controlSize(.small)
          } else if HarnessPrimaryAction.of(snapshot) != .ready {
            HarnessActionButton(driver: instance.driver)
          } else if instance.driver == .opencode {
            // Free models make OpenCode Ready with no account: Sign in until the probe finds one
            // connected (its account label), then Add account for another.
            let login = HarnessCommands.signIn(.opencode, version: snapshot?.version)
            let connected: Bool = snapshot?.account != nil
            Button(connected ? "Add account" : "Sign in") { HarnessActions.shared.run(login, driver: .opencode) }
              .help(OpenCodeAPI(version: snapshot?.version) == .v2
                ? "Runs \(login.display). Choose a provider in the terminal, then follow its steps."
                : "Runs \(login.display). Open the page in Serein and enter the code it shows. OpenCode Go has no API key.")
          }
          if !instance.enabled, snapshot?.installed == true {
            Button("Enable") { registry.setEnabled(instance.driver, true) }
              .help("Detected on this Mac. Turn it on to use it for tasks.")
          } else {
            Toggle("", isOn: Binding(get: { instance.enabled }, set: { registry.setEnabled(instance.driver, $0) }))
              .toggleStyle(SereinSwitchStyle(labeled: false))
              .accessibilityLabel("Use \(instance.name)")
          }
          if let open {
            Button(action: open) {
              InterfaceIcon(systemName: "chevron.right", size: 12).foregroundStyle(p.secondary).opacity(0.6)
                .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help("Open \(instance.name)'s settings")
            .accessibilityLabel("\(instance.name) settings")
          }
        }
        if let s = snapshot, s.needsUpdate {
          // The status line already says Update available unless another state (sign-in) comes first.
          let said: Bool = statusLine.hasPrefix("Update available")
          let available: String = said ? "" : "Update available\(s.latestVersion.map { " (\($0))" } ?? ""). "
          HStack(spacing: 8) {
            Text(available + "Serein updates an AI app only when you choose Update.")
              .role(.meta)
          }
        }
      }
      plainKeyWarning
      if advanced {
        if instance.enabled {
          limits
          installed
          // ponytail: not for OpenCode, whose run config (permission "*": deny) replaces the user's
          // own rules, so none of their servers' tools could run; offer it once that config merges.
          if instance.driver != .opencode { ownSetup }
        }
        DisclosureGroup(isExpanded: $expanded) {
          VStack(alignment: .leading, spacing: 10) {
            if let path = snapshot?.path {
              Text(path).font(UIStyle.monoMeta).foregroundStyle(p.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            labeled("Display name") {
              TextField(instance.driver.displayName, text: $name).textFieldStyle(.serein)
            }
            labeled("App file") {
              TextField("Found on this Mac", text: $path).textFieldStyle(.serein)
                .font(UIStyle.monoMeta)
            }
            labeled("Extra settings") {
              TextEditor(text: $env).font(UIStyle.monoMeta).frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderStrong))
                .accessibilityLabel("Extra settings, one NAME=value per line")
            }
            if !rejected.isEmpty {
              Text("Ignored: \(rejected.joined(separator: ", ")). Serein sets these itself or they are not valid names.")
                .role(.meta).foregroundStyle(p.warning)
            }
            if !refusedKeys.isEmpty {
              Text("Not saved: \(refusedKeys.joined(separator: ", ")). \(HarnessEnvironment.keyFieldMessage)")
                .role(.meta).foregroundStyle(p.warning)
            }
            Text("One NAME=value per line. Values are stored in Serein's library on this Mac.").role(.meta)
            keyField
            HStack {
              Text(instance.driver.protocolLabel).role(.meta)
              Spacer()
              Button("Check Again") { Task { await registry.refresh(instance.driver) } }
              Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
          }.padding(.top, 6)
        } label: {
          Text("Configuration").role(.meta)
        }
      }
    }.padding(.vertical, 4)
      .onAppear(perform: load)
      .onChange(of: instance) { _, _ in load() }
  }

  /// The instance's API key: its variable name and the key itself, kept in Keychain and given to
  /// the CLI only when Serein starts it (HarnessRegistry.keyEnvironment).
  @ViewBuilder var keyField: some View {
    let saved = registry.hasKey(instance.driver)
    labeled("API key") {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          TextField(Self.keyPlaceholder(instance.driver), text: $keyName).textFieldStyle(.serein)
            .font(UIStyle.monoMeta).frame(maxWidth: 190)
            .accessibilityLabel("Name the \(instance.name) API key is given as")
          SecureField(saved ? "Saved in Keychain" : "Key", text: $key).textFieldStyle(.serein)
            .accessibilityLabel("\(instance.name) API key")
        }
        HStack(spacing: 8) {
          Button("Save Key") { saveKey() }.disabled(key.isEmpty)
            .accessibilityLabel("Save the \(instance.name) API key in Keychain")
          if saved {
            Button("Remove Key") { removeKey() }.accessibilityLabel("Remove the \(instance.name) API key from Keychain")
          }
        }
      }
    }
    Text("Stored in this Mac's Keychain and given to \(instance.name), and the commands it runs, only when Serein starts it.").role(.meta)
    // With a plain-text key the error shows under its warning instead.
    if let keyError, HarnessRegistry.plainKeys(instance).isEmpty { Text(keyError).role(.meta).foregroundStyle(p.warning) }
  }
  static func keyPlaceholder(_ driver: HarnessDriver) -> String { HarnessEnvironment.keyName(driver) }
  /// A key saved as plain text before the key field: one line and Move to Keychain. Nothing moves
  /// without that click.
  @ViewBuilder var plainKeyWarning: some View {
    if let name = HarnessRegistry.plainKeys(instance).first {
      HStack(spacing: 8) {
        Text("\(name) is stored as plain text in Serein's library.").role(.meta).foregroundStyle(p.warning)
          .lineLimit(1).truncationMode(.tail)
        Spacer()
        Button("Move to Keychain") {
          do { try registry.moveKeyToKeychain(instance.driver); keyError = nil } catch { keyError = error.localizedDescription }
        }.help("Moves \(name) into Keychain and removes it from the library.")
          .accessibilityLabel("Move \(name) to Keychain")
      }
      if let keyError { Text(keyError).role(.meta).foregroundStyle(p.warning) }
    }
  }

  @ViewBuilder var limits: some View {
    let caps = snapshot?.capabilities ?? .base(instance.driver)
    let offered = HarnessPolicy.offeredModes(driver: instance.driver, capabilities: caps)
    VStack(alignment: .leading, spacing: 4) {
      Text(
        offered.isEmpty
          ? "Not offered for any task."
          : "Offered for: " + offered.map(HarnessPolicy.modeLabel).joined(separator: ", ") + "."
      ).role(.meta).foregroundStyle(offered.isEmpty ? p.warning : p.secondary)
      ForEach(caps.notes, id: \.self) { note in
        Text(note).role(.meta).fixedSize(horizontal: false, vertical: true)
      }
    }.accessibilityElement(children: .combine)
  }

  /// What this harness has installed: its skills, slash commands and the MCP servers it connects
  /// to, in the user's setup and, when one is picked, a project's own (names and short
  /// descriptions, read on demand). Shown only for harnesses Serein knows where to look.
  @ViewBuilder var installed: some View {
    let sources = instance.driver.capabilitySources
    if !sources.isEmpty {
      DisclosureGroup(isExpanded: $capsExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          if sources.hasProjectScope, !projects.isEmpty {
            SettingsPopUp("Also show", selection: $capsProject,
              choices: [SettingsChoice(value: String?.none, label: "Your setup only")]
                + projects.map { SettingsChoice(value: String?.some($0.path), label: $0.name) })
              .onChange(of: capsProject) { _, _ in loadCaps(force: true) }
          }
          if !sources.verified {
            Text("Read from \(instance.name)'s documentation; not yet checked against a running copy.")
              .role(.meta).foregroundStyle(p.faint).fixedSize(horizontal: false, vertical: true)
          }
          if capsLoading {
            SettingsLoading(retry: { loadCaps(force: true) })
          } else if let caps, !caps.isEmpty {
            capGroup("Skills", caps.skills)
            capGroup("Commands", caps.commands)
            capGroup("Connected tools", caps.mcpServers)
          } else if caps != nil {
            Text("Nothing installed that Serein can see.").role(.meta).foregroundStyle(p.faint)
          }
        }.padding(.top, 4)
      } label: {
        Text("Skills, commands and tools").role(.meta)
      }
      .onChange(of: capsExpanded) { _, open in if open { loadCaps() } }
    }
  }
  @ViewBuilder func capGroup(_ title: String, _ items: [HarnessCapability]) -> some View {
    if !items.isEmpty {
      let off = items.filter { !$0.enabled }.count
      VStack(alignment: .leading, spacing: 2) {
        Text("\(title) (\(items.count)\(off > 0 ? ", \(off) off" : ""))").font(UIStyle.body)
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          (Text(item.name).foregroundStyle(item.enabled ? p.secondary : p.faint)
            + Text(item.scope == .project ? " · project" : "").foregroundStyle(p.warning)
            + Text(item.enabled ? "" : " · off").foregroundStyle(p.faint)
            + Text(item.detail.map { " — \($0)" } ?? "").foregroundStyle(p.faint))
            .role(.meta).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
  func loadCaps(force: Bool = false) {
    guard force || (caps == nil && !capsLoading) else { return }
    capsLoading = true
    let driver = instance.driver
    let project = capsProject
    Task {
      let report = await Task.detached { HarnessCatalog.read(driver, project: project) }.value
      await MainActor.run {
        // A later pick wins over a read that finished after it.
        guard capsProject == project else { return }
        caps = report
        capsLoading = false
      }
    }
  }

  /// "Use my own setup" (HarnessInstance.ownSetup). Turning it on names what goes off and what
  /// stays on; turning it off asks nothing.
  @ViewBuilder var ownSetup: some View {
    let on = instance.usesOwnSetup
    VStack(alignment: .leading, spacing: 4) {
      Toggle(isOn: Binding(get: { on }, set: { want in
        if want { confirmOwnSetup = true } else { registry.setOwnSetup(instance.driver, false) }
      })) {
        Text("Use my own setup").role(.meta)
      }.toggleStyle(SereinSwitchStyle())
      Text(on
        ? "Read-only answers, library and project tasks use your connected tools, connectors and API keys. Web, page, Mac and editing tasks stay isolated."
        : "Off: Serein runs \(instance.name) apart from your connected tools, connectors and API keys.")
        .role(.meta).foregroundStyle(on ? p.warning : p.faint).fixedSize(horizontal: false, vertical: true)
    }
    .alert("Use your own \(instance.name) setup?", isPresented: $confirmOwnSetup) {
      Button("Use My Setup", role: .destructive) { registry.setOwnSetup(instance.driver, true) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(Self.ownSetupWarning(instance.driver))
    }
  }
  static func ownSetupWarning(_ driver: HarnessDriver) -> String {
    let notes: String
    switch driver {
    case .claude: notes = " Claude Code reads your user settings for this, with hooks and skills turned off; a tool runs when your allow rules name it."
    case .codex: notes = " Codex reads your config.toml for this, without its rules, hooks or notify, inside Serein's read-only space; a tool runs when config.toml sets approval_mode = \"approve\" for it."
    case .pi, .ohMyPi: notes = " Pi loads your extensions; Pi never asks before their tools run."
    default: notes = ""
    }
    return """
      Used only in answers, library tasks and project tasks that do not edit files or run commands, with no page, tab, selection or console errors in the turn. Serein adds no web tools there; your own servers can still open web pages. Web, page and Mac tasks, and tasks that edit, use Serein's isolated setup.

      What loads there: your own connected tools, connectors and the API keys of your login shell.\(notes) Only the tools your own settings allow without asking run: nobody can answer an ask in Serein, so Serein says no to it. To use a tool, allow it in your agent's own settings.

      Outside Serein's guards: the tools you allow run as you set them up. They can read your files and use your accounts and keys, and a Mac-control server can operate your Mac. Text in a project's files can ask the agent to call them.

      Stays on: built-in file tools stay read-only and cannot reach your protected folders (keychains, mail, browser data, SSH and cloud keys) or Serein's website data and library.
      """
  }

  var statusLine: String {
    guard let s = snapshot else { return "Not checked yet." }
    if s.status == .missing { return "Not installed." }
    if s.installed && !instance.enabled {
      return "Detected" + (s.version.map { " · v\($0)" } ?? "") + " · Off"
    }
    return s.message
  }
  var statusColor: Color {
    switch snapshot?.status {
    case .ready?: return p.success
    case .needsSignIn?, .needsUpdate?: return p.warning
    case .error?: return p.danger
    default: return p.faint
    }
  }
  func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
    HStack(alignment: .top) {
      Text(title).frame(width: 96, alignment: .leading).role(.meta)
      content()
    }
  }
  func load() {
    path = instance.binaryPath ?? ""
    // A plain-text key stays out of the box (it has its warning); Save keeps it as it is.
    env = HarnessEnvironment.format(instance.environment.filter { !ModelRoutes.isKeyName($0.key) })
    name = instance.displayName ?? ""
    keyName = instance.keyName ?? ""
  }
  func save() {
    var updated = instance
    let trimmed = path.trimmingCharacters(in: .whitespaces)
    updated.binaryPath = trimmed.isEmpty ? nil : trimmed
    let parsed = HarnessEnvironment.parse(env, driver: instance.driver)
    updated.environment = parsed.values.merging(instance.environment.filter { ModelRoutes.isKeyName($0.key) }) { typed, _ in typed }
    rejected = parsed.rejected.filter { !ModelRoutes.isKeyName($0) }
    refusedKeys = parsed.rejected.filter { ModelRoutes.isKeyName($0) }
    let n = name.trimmingCharacters(in: .whitespaces)
    updated.displayName = n.isEmpty ? nil : String(n.prefix(40))
    registry.update(updated)
  }
  func saveKey() {
    // Claude Code and Codex read one known variable: an empty name field means its placeholder.
    let variable = keyName.isEmpty && [.claude, .codex].contains(instance.driver) ? Self.keyPlaceholder(instance.driver) : keyName
    do {
      try registry.saveKey(key, name: variable, for: instance.driver)
      keyError = nil
      key = ""
    } catch {
      keyError = error.localizedDescription
    }
  }
  func removeKey() {
    do {
      try registry.removeKey(instance.driver)
      keyError = nil
    } catch {
      keyError = error.localizedDescription
    }
  }
}
