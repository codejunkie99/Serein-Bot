import AppKit
import SereinCore
import SwiftUI

/// Settings › Plugins: Add Plugin (a folder, a GitHub link or the plugin index), the import from
/// the person's other AI apps, and one card per plugin: its mark, version or origin, its switch,
/// and under the chevron what it may reach, its tools, keys, skills, update and Remove….
struct PluginSettings: View {
  @ObservedObject private var host = PluginHost.shared
  @Environment(\.palette) var p
  @State private var message: String?
  @State private var fetching = false
  @State private var showingIndex = false
  @State private var indexEntries: [PluginIndex.Entry] = []
  @State private var indexNote: String?
  /// The GitHub links chosen in the index sheet, installed by the same pinned flow as paste.
  @State private var indexPicks: [String] = []
  @State private var importing = false

  var body: some View {
    // Servers connected by address live in Settings › Connections.
    let plugins = host.packages.filter { !host.isConnection($0) }
    VStack(alignment: .leading, spacing: 24) {
      HStack(alignment: .top, spacing: 16) {
        Text("Each one shows what it can reach before it runs, stays walled off from your files, and asks you before it sends, deletes or pays for anything.")
          .role(.meta).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Menu {
          Button("From a Folder…", action: add)
          Button("From GitHub…", action: addFromGitHub).disabled(fetching)
          Button("From the Plugin Index…") { showingIndex = true }.disabled(fetching)
        } label: {
          Text("Add Plugin")
        }.menuStyle(.button).buttonStyle(PrimaryButton()).fixedSize()
          .accessibilityLabel("Add a plugin")
      }
      // Bring the servers and skills set up in the person's other AI apps; each arrives off.
      HStack(spacing: 14) {
        HStack(spacing: 6) {
          ForEach([Brand.claude, .codex, .cursor, .gemini], id: \.self) { BrandLogo($0, size: 20) }
        }.accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("Bring your setup from other AI apps")
          Text("Connected tools and skills from Claude Code, Claude Desktop, Codex, Cursor and Gemini CLI arrive switched off.")
            .role(.meta).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Button("Import…") { importing = true }.disabled(fetching || host.busy != nil)
          .accessibilityLabel("Import from your AI apps")
      }
      .padding(16).frame(maxWidth: .infinity, alignment: .leading).card(p)
      .sheet(isPresented: $importing) {
        AppImportSheet { note in
          importing = false
          if let note { message = note }
        }
      }
      if let message { Text(message).role(.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true) }
      VStack(alignment: .leading, spacing: 8) {
        SettingsCaption(plugins.isEmpty ? "Installed" : "Installed · \(plugins.count)")
        if plugins.isEmpty {
          Text("No plugins yet. Serein works fine without any.").role(.meta)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).card(p)
        }
        ForEach(plugins, id: \.id) { package in PluginRow(package: package, message: $message) }
        HStack(spacing: 4) {
          Text("Making your own? See Build a Serein plugin in Serein's docs.").role(.meta)
          Button("Show Plugins Folder") {
            if let root = host.root { NSWorkspace.shared.activateFileViewerSelecting([root]) }
          }.buttonStyle(.link).font(UIStyle.meta)
        }.padding(.leading, 2)
      }
    }
    .sheet(isPresented: $showingIndex) { indexSheet }
    .task(id: showingIndex) {
      guard showingIndex, indexEntries.isEmpty else { return }
      indexNote = "Loading the index…"
      indexEntries = await Self.loadIndex()
      indexNote = indexEntries.isEmpty ? "The index could not be loaded." : nil
    }
  }

  /// The community index: a static, review-by-pull-request file pointing at pinned commits.
  /// The URL is a default so a fork can ship its own.
  static func loadIndex() async -> [PluginIndex.Entry] {
    let raw = UserDefaults.standard.string(forKey: "serein.pluginIndexURL")
      ?? "https://raw.githubusercontent.com/codejunkie99/serein/main/examples/plugins/index.json"
    guard let url = URL(string: raw) else { return [] }
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else { return [] }
    return PluginIndex.decode(data)
  }

  private var indexSheet: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Plugin index").font(UIStyle.meta)
      Text("Reviewed plugins. Adding one shows the same review as pasting a link.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      if let indexNote { Text(indexNote).role(.meta) }
      ForEach(indexEntries, id: \.id) { entry in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 2) {
            Text("\(entry.name) · \(entry.kind)").font(UIStyle.meta)
            Text(entry.description).role(.meta).fixedSize(horizontal: false, vertical: true)
            Text([entry.author, entry.license, PluginIndex.pinned(entry) ? "fixed version" : "follows updates"]
              .compactMap { $0 }.joined(separator: " · ")).role(.meta)
          }
          Spacer()
          Button(indexPicks.contains(entry.id) ? "Added" : "Review") {
            guard !indexPicks.contains(entry.id) else { return }
            indexPicks.append(entry.id)
            installFromIndex(entry)
          }.controlSize(.small).disabled(indexPicks.contains(entry.id))
        }
      }
      HStack { Spacer(); Button("Close") { showingIndex = false } }
    }.padding(20).frame(width: 460)
  }

  private func installFromIndex(_ entry: PluginIndex.Entry) {
    fetching = true
    message = "Fetching \(entry.name)…"
    showingIndex = false
    Task {
      defer { fetching = false }
      do {
        let fetched = try await host.fetch(entry.link)
        defer { try? FileManager.default.removeItem(at: fetched.folder) }
        guard review(fetched.folder, from: fetched.source) else { message = nil; return }
        let package = try host.install(from: fetched.folder, source: fetched.source, link: entry.link, commit: fetched.commit)
        message = "Added \(package.name). Turn it on to check its tools."
      } catch { message = error.localizedDescription }
    }
  }

  private func add() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Review"
    panel.message = "Choose a plugin folder (it holds SKILL.md or serein-plugin.json)."
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    guard review(folder) else { return }
    do {
      let package = try host.install(from: folder)
      message = package.manifest?.mcp == nil ? "Added \(package.name)." : "Added \(package.name). Turn it on to check its tools."
    } catch { message = error.localizedDescription }
  }

  /// Fetches a GitHub plugin at one commit into a private folder, shows the same review, and
  /// installs that exact copy.
  private func addFromGitHub() {
    let alert = NSAlert()
    alert.messageText = "Add a plugin from GitHub"
    alert.informativeText = "Paste a link to the plugin's folder. Serein fetches one fixed version and shows what it may do before anything runs."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    field.placeholderString = "github.com/owner/repo/tree/main/my-plugin"
    alert.accessoryView = field
    alert.addButton(withTitle: "Fetch")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let link = field.stringValue
    fetching = true
    message = "Fetching…"
    Task {
      defer { fetching = false }
      do {
        let fetched = try await host.fetch(link)
        defer { try? FileManager.default.removeItem(at: fetched.folder) }
        guard review(fetched.folder, from: fetched.source) else {
          message = nil
          return
        }
        let package = try host.install(from: fetched.folder, source: fetched.source, link: link, commit: fetched.commit)
        message = "Added \(package.name) from \(fetched.source)." + (package.manifest?.mcp == nil ? "" : " Turn it on to check its tools.")
      } catch { message = error.localizedDescription }
    }
  }

  /// The install review: what the plugin is, what it may reach, each tool's risk. True to add.
  private func review(_ folder: URL, from source: String? = nil) -> Bool {
    let probe = PluginCatalog.load(folder)
    guard !probe.skills.isEmpty || probe.manifest != nil else {
      message = probe.problems.first ?? "That folder is not a plugin."
      return false
    }
    let alert = NSAlert()
    alert.messageText = "Add \(probe.name)?"
    var lines: [String] = []
    if let manifest = probe.manifest {
      lines.append(manifest.description)
      lines.append("Version \(manifest.version)" + (manifest.author.map { " by \($0)" } ?? "") + (manifest.license.map { " · \($0) license" } ?? ""))
      lines += manifest.permissionSummary.map { "• " + $0 }
      for tool in manifest.tools ?? [] {
        // The server's own name when the manifest renames a tool, so a mild name cannot hide it.
        let server: String = tool.remote.map { " (real name: \($0))" } ?? ""
        let asks: String = ["send", "delete", "pay"].contains(tool.risk.rawValue) ? " (always asks)" : ""
        lines.append("• \(tool.name)\(server): \(RiskWords.of(tool.risk))\(asks)")
      }
    }
    if !probe.skills.isEmpty { lines.append("Skills: " + probe.skills.map(\.name).joined(separator: ", ")) }
    lines += probe.problems.map { "⚠︎ " + $0 }
    if let source { lines.append("From " + source) }
    alert.informativeText = lines.joined(separator: "\n")
    alert.addButton(withTitle: "Add")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }
}

private struct PluginRow: View {
  let package: PluginPackage
  @Binding var message: String?
  @ObservedObject private var host = PluginHost.shared
  @Environment(\.palette) var p
  @State private var secrets: [String: String] = [:]
  @State private var updateNote: String?
  @State private var removing = false

  /// A newer commit gets the same review as a first install; the plugin is replaced only on Update.
  private func checkUpdate() {
    updateNote = "Checking…"
    Task {
      do {
        guard let fetched = try await host.checkUpdate(package) else {
          updateNote = "Up to date."
          return
        }
        defer { try? FileManager.default.removeItem(at: fetched.folder) }
        let probe = PluginCatalog.load(fetched.folder)
        let alert = NSAlert()
        alert.messageText = "Update \(package.name)?"
        var lines = ["New version: \(probe.manifest?.version ?? "?") from \(fetched.source)"]
        lines += probe.manifest?.permissionSummary.map { "• " + $0 } ?? []
        for tool in probe.manifest?.tools ?? [] {
          let server: String = tool.remote.map { " (real name: \($0))" } ?? ""
          lines.append("• \(tool.name)\(server): \(RiskWords.of(tool.risk))")
        }
        lines.append("Tools stay off until you turn the plugin on again.")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
          updateNote = nil
          return
        }
        try host.update(package, with: fetched)
        message = "Updated \(package.name). Turn it on to check its tools."
        updateNote = nil
      } catch { updateNote = error.localizedDescription }
    }
  }

  /// Version, author and license; a skill's origin; or what keeps it off.
  private var statusLine: String {
    let state = host.states[package.id]
    if state?.saved == true {
      if state?.enabled == true && !host.isEnabled(package) { return "Changed since you turned it on · read it, then turn it on again" }
      let origin: String = state?.imported.map { "imported from \($0)" } ?? "saved from a task"
      return "Skill · \(origin) · a note, no new access"
    }
    var parts: [String] = []
    if let manifest = package.manifest {
      parts.append("Version \(manifest.version)")
      if let author = manifest.author { parts.append(author) }
      if let license = manifest.license { parts.append(license) }
    } else if !package.skills.isEmpty {
      parts.append(package.skills.count == 1 ? "Skill" : "\(package.skills.count) skills")
    }
    if state?.source != nil { parts.append("from GitHub") }
    if !package.problems.isEmpty { parts.append(package.problems.count == 1 ? "1 problem" : "\(package.problems.count) problems") }
    return parts.joined(separator: " · ")
  }
  private var statusTint: Color? {
    let state = host.states[package.id]
    if !package.problems.isEmpty { return p.danger }
    if state?.saved == true && state?.enabled == true && !host.isEnabled(package) { return p.warning }
    return nil
  }
  /// GitHub's mark for a plugin from GitHub, the AI app's for an imported one, else a plain glyph.
  @ViewBuilder private var mark: some View {
    let state = host.states[package.id]
    if let imported = state?.imported, let brand = Brand.aiApp(imported) {
      BrandLogo(brand)
    } else if state?.source != nil {
      BrandLogo(.github)
    } else {
      SettingsGlyphTile(systemName: package.manifest == nil ? "text.book.closed" : "puzzlepiece.extension")
    }
  }

  /// What it is and may do: description, what it can reach, its tools and its skills (a saved
  /// skill's whole text: turning it on is its review). Shown above the fold while it is off.
  @ViewBuilder private var review: some View {
    let saved: Bool = host.states[package.id]?.saved == true
    if let manifest = package.manifest {
      Text(manifest.description).fixedSize(horizontal: false, vertical: true)
      if !manifest.permissionSummary.isEmpty {
        FlowChips(items: manifest.permissionSummary) { line in
          Text(line).font(UIStyle.micro).foregroundStyle(p.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3).overlay(Capsule().strokeBorder(p.line))
        }
      }
      if let tools = manifest.tools, !tools.isEmpty { toolList(tools) }
    }
    ForEach(package.skills, id: \.name) { skill in
      VStack(alignment: .leading, spacing: 2) {
        Text(skill.name).font(UIStyle.body)
        Text(skill.description).role(.meta).fixedSize(horizontal: false, vertical: true)
        if saved {
          Text(skill.instructions).font(UIStyle.monoMeta).foregroundStyle(p.secondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
      }
    }
  }
  /// Each tool with its risk; sending, deleting and paying always ask.
  private func toolList(_ tools: [PluginManifest.Tool]) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(tools.enumerated()), id: \.element.name) { index, tool in
        let asks: Bool = ["send", "delete", "pay"].contains(tool.risk.rawValue)
        HStack {
          Text(tool.name.replacingOccurrences(of: "_", with: " "))
          Spacer()
          Text(asks ? "\(RiskWords.of(tool.risk)) · asks you" : RiskWords.of(tool.risk))
            .font(UIStyle.micro).foregroundStyle(asks ? p.warning : p.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .overlay(alignment: .top) { if index > 0 { Rectangle().fill(p.line).frame(height: 1) } }
      }
    }.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.line))
  }

  var body: some View {
    SettingsListRow(name: package.name, status: statusLine, statusTint: statusTint, divider: false) {
      mark
    } trailing: {
      SettingsRowSwitch(label: "Use \(package.name)", isOn: Binding(
        get: { host.isEnabled(package) },
        set: { on in
          guard on else { return host.setEnabled(package, false) }
          message = "Checking the tools of \(package.name)…"
          Task {
            do { try await host.enable(package); message = "\(package.name) is on." } catch {
              message = error.localizedDescription
            }
          }
        })).disabled(host.busy != nil)
    } live: {
      // Off: what it can reach, its tools and a saved skill's whole text, before the switch.
      if !host.isEnabled(package) {
        VStack(alignment: .leading, spacing: 12) { review }.padding(.leading, 42)
      }
    } details: {
      if host.isEnabled(package) { review }
      if let manifest = package.manifest {
        if manifest.mcp?.auth == "oauth2" {
          HStack {
            if PluginSignIn.signedIn(manifest.id) {
              Text("Signed in").role(.meta).foregroundStyle(p.success)
              Spacer()
              Button("Sign Out") {
                PluginSignIn.signOut(manifest)
                message = "Signed out of \(manifest.name)."
              }
            } else {
              Text("Not signed in").role(.meta).foregroundStyle(p.warning)
              Spacer()
              Button("Sign In…") {
                message = "Opening the browser…"
                Task {
                  do {
                    try await PluginSignIn.run(manifest: manifest)
                    message = "Signed in to \(manifest.name)."
                  } catch { message = error.localizedDescription }
                }
              }
            }
          }
          SettingsNote("You sign in once in your browser. Serein keeps the sign-in in your Keychain. The app never sees a password.")
        }
        ForEach(manifest.mcp?.env ?? [], id: \.self) { name in
          HStack(spacing: 6) {
            Text(name).font(UIStyle.monoMeta)
            Spacer()
            SecureField(PluginHost.secret(plugin: manifest.id, name: name) == nil ? "Not set" : "Saved in Keychain", text: Binding(
              get: { secrets[name] ?? "" }, set: { secrets[name] = $0 }))
              .textFieldStyle(.serein).frame(width: 220)
              .accessibilityLabel("\(name) for \(manifest.name)")
              .onSubmit { saveSecret(name, manifest) }
            Button("Save Key") { saveSecret(name, manifest) }.disabled((secrets[name] ?? "").isEmpty)
              .accessibilityLabel("Save \(name) for \(manifest.name) in Keychain")
          }
        }
      }
      ForEach(package.problems, id: \.self) { Text($0).role(.meta).foregroundStyle(p.danger) }
      HStack {
        if let source = host.states[package.id]?.source {
          Button("Check for Update") { checkUpdate() }.disabled(host.busy != nil)
            .help("From GitHub: " + source)
        }
        if let updateNote { Text(updateNote).role(.meta) }
        Spacer()
        Button("Remove…") { removing = true }.foregroundStyle(p.danger)
          .accessibilityLabel("Remove \(package.name)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading).settingsCard()
    .confirmationDialog("Remove \(package.name)?", isPresented: $removing, titleVisibility: .visible) {
      Button("Remove", role: .destructive) {
        do { try host.remove(package) } catch { message = error.localizedDescription }
      }
    } message: {
      Text("Serein deletes this plugin's folder and the keys you saved for it. You can add it again later.")
    }
  }

  private func saveSecret(_ name: String, _ manifest: PluginManifest) {
    guard let value = secrets[name], !value.isEmpty else { return }
    PluginHost.saveSecret(value, plugin: manifest.id, name: name)
    secrets[name] = ""
    message = "Saved \(name) for \(manifest.name) in your Keychain."
  }
}
