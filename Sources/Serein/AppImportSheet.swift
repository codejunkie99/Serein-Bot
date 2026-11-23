import SereinCore
import SwiftUI

/// Settings › Plugins › Import from your AI apps…: the person ticks the apps to read, and only then
/// Serein reads those apps' setup files (AppImport.read). It lists each MCP server (its name, its
/// program or address, the network it may reach, what goes to the Keychain) and each skill, and
/// the person picks what comes in. Skills come in as text by Save as Skill's rules. Each picked
/// server gets its own card: what starts and what it needs, then its tools, each with a switch;
/// it is added off through the plugin install path (PluginHost.importServer).
@MainActor struct AppImportSheet: View {
  let done: (String?) -> Void
  @ObservedObject private var host = PluginHost.shared
  @Environment(\.palette) var p
  @State private var ticked: Set<AppImport.Source> = []
  @State private var found: AppImport.Found?
  /// Picked rows: "server:" or "skill:" and the item's id.
  @State private var picked: Set<String> = []
  @State private var started = false
  /// Picked servers whose card is still to come, and how many were picked.
  @State private var queue: [AppImport.Server] = []
  @State private var total = 0
  @State private var current: PluginHost.ImportDraft?
  @State private var tools: [MCPServerConnection.ReviewTool]?
  /// Values typed for settings the other app reads from its shell, by name, until they go to the
  /// Keychain on List its tools.
  @State private var typed: [String: String] = [:]
  @State private var token = ""
  @State private var signedIn = false
  @State private var working: String?
  @State private var problem: String?
  /// What came in and what did not, for the closing line.
  @State private var added: [String] = []
  @State private var skipped: [String] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let current {
        serverStep(current)
      } else if started {
        EmptyView()
      } else if let found {
        pickStep(found)
      } else {
        chooseStep
      }
      if let working { Text(working).role(.meta) }
      if let problem {
        Text(verbatim: problem).role(.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(20).frame(width: 560)
      // However the sheet closes, a server not added leaves nothing in the Keychain.
      .onDisappear { if let current { host.discardImport(current) } }
  }

  // MARK: steps

  private var chooseStep: some View {
    let home = NSHomeDirectory()
    let environment = ProcessInfo.processInfo.environment
    return VStack(alignment: .leading, spacing: 12) {
      Text("Import from your AI apps").font(UIStyle.bodyStrong)
      Text("Tick the apps to read. Serein opens only these files, only now, and lists the MCP servers and skills it finds for you to pick. Nothing comes in on.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      ForEach(AppImport.Source.allCases) { source in
        let paths: [String] = source.places(home: home, environment: environment)
        let places: String = paths.map { AppImport.shown($0, home: home) }.joined(separator: " · ")
        Toggle(isOn: Binding(
          get: { ticked.contains(source) },
          set: { if $0 { ticked.insert(source) } else { ticked.remove(source) } }
        )) {
          VStack(alignment: .leading, spacing: 2) {
            Text(source.name)
            Text(verbatim: places)
              .font(UIStyle.monoMeta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
          }
        }.toggleStyle(.checkbox).accessibilityLabel("Read \(source.name)")
      }
      HStack {
        Spacer()
        Button("Cancel") { done(nil) }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        Button("Read", action: read).buttonStyle(PrimaryButton()).disabled(ticked.isEmpty || working != nil)
      }
    }
  }

  private func pickStep(_ found: AppImport.Found) -> some View {
    let count = picked.count
    return VStack(alignment: .leading, spacing: 12) {
      Text("What Serein found").font(UIStyle.bodyStrong)
      Text("Pick what comes in. Everything arrives off. A server's settings and tokens go to your Keychain and are never shown. A skill comes in as its text only and gives no access.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if !found.servers.isEmpty { Text("MCP servers").role(.micro) }
          ForEach(found.servers) { serverRow($0) }
          if !found.skills.isEmpty { Text("Skills").role(.micro) }
          ForEach(found.skills) { skillRow($0) }
          ForEach(found.notes, id: \.self) { Text(verbatim: $0).role(.meta) }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 400)
      HStack {
        Button("Back") {
          self.found = nil
          picked = []
        }.buttonStyle(QuietButton())
        Spacer()
        Button("Cancel") { done(nil) }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        Button(count == 1 ? "Import 1 item" : "Import \(count) items", action: start).buttonStyle(PrimaryButton())
          .disabled(count == 0 || working != nil)
      }
    }
  }

  private func serverRow(_ server: AppImport.Server) -> some View {
    Toggle(isOn: pick("server:" + server.id)) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: server.name).font(UIStyle.bodyStrong).lineLimit(1)
          Text(server.source.name).font(UIStyle.micro).foregroundStyle(p.faint)
        }
        Text(verbatim: server.shown).font(UIStyle.monoMeta).foregroundStyle(p.secondary)
          .lineLimit(2).truncationMode(.middle)
        if !server.network.isEmpty { Text(server.network).role(.meta).fixedSize(horizontal: false, vertical: true) }
        if let keys = Self.keychainLine(server) { Text(verbatim: keys).role(.meta).fixedSize(horizontal: false, vertical: true) }
        if let reason = server.problem {
          Text(verbatim: reason).role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
        }
      }
    }.toggleStyle(.checkbox).disabled(server.problem != nil)
      .accessibilityLabel("\(server.name), from \(server.source.name)")
      .accessibilityHint(server.problem ?? server.network)
  }

  private func skillRow(_ skill: AppImport.Skill) -> some View {
    Toggle(isOn: pick("skill:" + skill.id)) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: skill.name).font(UIStyle.bodyStrong).lineLimit(1)
          Text(skill.source.name).font(UIStyle.micro).foregroundStyle(p.faint)
        }
        if !skill.description.isEmpty {
          Text(verbatim: skill.description).role(.meta).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        if let reason = skill.problem {
          Text(verbatim: reason).role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
        }
      }
    }.toggleStyle(.checkbox).disabled(skill.problem != nil)
      .accessibilityLabel("Skill \(skill.name), from \(skill.source.name)")
  }

  /// One picked server: what starts or where it connects, what it needs from the person, then
  /// its tools to review.
  private func serverStep(_ draft: PluginHost.ImportDraft) -> some View {
    let server = draft.server
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        Text(verbatim: server.name).font(UIStyle.bodyStrong).lineLimit(1)
        Text("from \(server.source.name)").role(.meta)
        Spacer()
        Text("Server \(total - queue.count) of \(total)").role(.micro)
      }
      Text(verbatim: server.shown).font(UIStyle.monoMeta).foregroundStyle(p.secondary)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      if let tools {
        reviewCard(draft, tools)
      } else {
        startCard(draft)
      }
    }
  }

  @ViewBuilder private func startCard(_ draft: PluginHost.ImportDraft) -> some View {
    let server = draft.server
    Text(server.network).role(.meta).fixedSize(horizontal: false, vertical: true)
    if draft.connection == nil {
      Text("To list its tools, Serein starts it once in its sandbox, with no internet access and none of your files, and stops it after the list.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
    }
    if let keys = Self.keychainLine(server) { Text(verbatim: keys).role(.meta).fixedSize(horizontal: false, vertical: true) }
    ForEach(server.missing, id: \.self) { name in
      HStack {
        Text(verbatim: name).font(UIStyle.monoMeta)
        Spacer()
        SecureField("Not set", text: Binding(get: { typed[name] ?? "" }, set: { typed[name] = $0 }))
          .textFieldStyle(.serein).frame(width: 240)
          .accessibilityLabel("\(name) for \(server.name)")
      }
    }
    if let connection = draft.connection {
      switch connection.auth {
      case .oauth:
        if let signInHost = connection.signInHost {
          Text("Signs in at \(signInHost)").font(UIStyle.monoMeta).foregroundStyle(p.secondary)
        }
        if signedIn {
          Text("Signed in").role(.meta).foregroundStyle(p.success)
        } else {
          Button("Sign in in your browser…") { signIn(draft, connection) }.buttonStyle(QuietButton())
            .disabled(working != nil)
        }
      case .token where server.secrets.token == nil:
        HStack {
          Text("Token").role(.meta)
          Spacer()
          SecureField("Paste the token you use in \(server.source.name)", text: $token)
            .textFieldStyle(.serein).frame(width: 300)
            .accessibilityLabel("Token for \(server.name)")
        }
      case .token, .none:
        EmptyView()
      }
    }
    HStack {
      Button("Stop importing", action: stop).buttonStyle(QuietButton())
      Spacer()
      Button("Skip", action: skip).buttonStyle(QuietButton())
      Button("List its tools", action: listTools).buttonStyle(PrimaryButton())
        .disabled(!ready(draft) || working != nil)
    }
  }

  @ViewBuilder private func reviewCard(_ draft: PluginHost.ImportDraft, _ rows: [MCPServerConnection.ReviewTool]) -> some View {
    let on = rows.filter(\.on).count
    let page = draft.connection == nil ? "Settings › Plugins" : "Settings › Connections"
    Text("It comes in off; turn it on in \(page). Serein asks you before each call that changes anything. Descriptions are the server’s own words, not checked by Serein.")
      .role(.meta).fixedSize(horizontal: false, vertical: true)
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(rows.indices, id: \.self) { index in
          MCPToolReviewRow(tool: rows[index], on: Binding(
            get: { tools?[index].on ?? false }, set: { tools?[index].on = $0 }))
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.frame(maxHeight: 320)
    let cap: String = on > MCPServerConnection.maxTools ? " · at most \(MCPServerConnection.maxTools) at once" : ""
    let count: String = "\(on) of \(RiskWords.count(rows.count)) on" + cap
    Text(verbatim: count).role(.micro)
    HStack {
      Button("Stop importing", action: stop).buttonStyle(QuietButton())
      Spacer()
      Button("Skip", action: skip).buttonStyle(QuietButton())
      Button("Add, off", action: add).buttonStyle(PrimaryButton())
        .disabled(on == 0 || on > MCPServerConnection.maxTools || working != nil)
    }
  }

  // MARK: actions

  /// Reads the ticked apps' files now, off the main thread; nothing else is opened.
  private func read() {
    let sources = ticked
    working = "Reading…"
    problem = nil
    Task {
      let result = await Task.detached(priority: .userInitiated) { AppImport.read(sources) }.value
      found = result
      picked = []
      working = nil
    }
  }

  /// Picked skills are saved now, off, by Save as Skill's rules; picked servers come one card each.
  private func start() {
    guard let found else { return }
    started = true
    for skill in found.skills where picked.contains("skill:" + skill.id) {
      do {
        let package = try host.saveSkill(skill.draft, importedFrom: skill.source.name)
        added.append(package.name)
      } catch { skipped.append("\(skill.name) (\(error.localizedDescription))") }
    }
    queue = found.servers.filter { picked.contains("server:" + $0.id) && $0.problem == nil }
    total = queue.count
    Task { await next() }
  }

  /// The next picked server's card (its secrets now in the Keychain), or the closing line.
  private func next() async {
    tools = nil
    typed = [:]
    token = ""
    signedIn = false
    problem = nil
    while !queue.isEmpty {
      let server = queue.removeFirst()
      working = "Getting \(server.name) ready…"
      do {
        current = try await host.importDraft(server)
        working = nil
        return
      } catch { skipped.append("\(server.name) (\(error.localizedDescription))") }
    }
    working = nil
    finish()
  }

  private func signIn(_ draft: PluginHost.ImportDraft, _ connection: PluginHost.Draft) {
    working = "Waiting for the browser…"
    problem = nil
    Task {
      do {
        try await PluginSignIn.run(plugin: draft.id, name: connection.name, serverURL: connection.url, expectedHost: connection.signInHost)
        signedIn = true
        working = nil
        listTools()
      } catch {
        working = nil
        problem = error.localizedDescription
      }
    }
  }

  /// Typed values and a pasted token go straight to the Keychain under the server's plugin id,
  /// then its tools are listed: a program started once under its sandbox, an address over the
  /// network with its sign-in.
  private func listTools() {
    guard let draft = current else { return }
    for name in draft.server.missing {
      let value: String = (typed[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      // Left empty: the value a failed listing already saved stays.
      if !value.isEmpty { PluginHost.saveSecret(value, plugin: draft.id, name: name) }
    }
    typed = [:]
    let pasted: String = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if draft.connection?.auth == .token, draft.server.secrets.token == nil, !pasted.isEmpty {
      PluginHost.saveSecret(pasted, plugin: draft.id, name: MCPServerConnection.tokenName)
    }
    token = ""
    working = "Listing \(draft.server.name)’s tools…"
    problem = nil
    Task {
      do { tools = try await host.importTools(draft) } catch { problem = error.localizedDescription }
      working = nil
    }
  }

  private func add() {
    guard let draft = current, let tools else { return }
    working = "Adding \(draft.server.name)…"
    problem = nil
    Task {
      do {
        let package = try await host.importServer(draft, review: tools)
        added.append(package.name)
        current = nil
        await next()
      } catch {
        working = nil
        problem = error.localizedDescription
      }
    }
  }

  private func skip() {
    guard let draft = current else { return }
    host.discardImport(draft)
    skipped.append(draft.server.name)
    current = nil
    Task { await next() }
  }

  /// Ends the import: the open card's server is dropped with its secrets, the rest is not read.
  private func stop() {
    if let draft = current {
      host.discardImport(draft)
      skipped.append(draft.server.name)
    }
    current = nil
    skipped += queue.map(\.name)
    queue = []
    finish()
  }

  private func finish() {
    var lines: [String] = []
    if !added.isEmpty {
      lines.append("Added, off: \(added.joined(separator: ", ")). Turn each on in Settings › Plugins or Settings › Connections.")
    }
    if !skipped.isEmpty { lines.append("Left out: \(skipped.joined(separator: ", ")).") }
    done(lines.isEmpty ? nil : lines.joined(separator: " "))
  }

  // MARK: helpers

  private func pick(_ key: String) -> Binding<Bool> {
    Binding(get: { picked.contains(key) }, set: { if $0 { picked.insert(key) } else { picked.remove(key) } })
  }

  /// Every value it needs is typed now or already in the Keychain (from a listing that failed).
  private func ready(_ draft: PluginHost.ImportDraft) -> Bool {
    for name in draft.server.missing {
      let value: String = typed[name] ?? ""
      let typedNow: Bool = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      if !typedNow && PluginHost.secret(plugin: draft.id, name: name) == nil { return false }
    }
    guard let connection = draft.connection else { return true }
    switch connection.auth {
    case .oauth: return signedIn
    case .token:
      if draft.server.secrets.token != nil { return true }
      if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
      return PluginHost.secret(plugin: draft.id, name: MCPServerConnection.tokenName) != nil
    case .none: return true
    }
  }

  /// What goes to the Keychain and what the person types, by name only; nil when nothing does.
  static func keychainLine(_ server: AppImport.Server) -> String? {
    var parts: [String] = []
    let kept = server.envNames.filter { server.secrets.env[$0] != nil }
    if !kept.isEmpty { parts.append("Moves to your Keychain: " + kept.joined(separator: ", ") + ".") }
    if server.secrets.token != nil { parts.append("Its token moves to your Keychain.") }
    if !server.missing.isEmpty {
      parts.append("\(server.source.name) reads " + server.missing.joined(separator: ", ") + " from its shell; you type it in.")
    }
    if server.needsToken && server.secrets.token == nil {
      parts.append("\(server.source.name) reads its token from its shell; you paste it in.")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }
}
