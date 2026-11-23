import AppKit
import SereinCore
import SwiftUI

/// Apps connected by their MCP server's address, one card: a row per connection (its address,
/// sign-in and tools on the status line, its switch, and under the chevron "Reads go ahead without
/// asking", "Scheduled tasks may use this", sign-in or token, Review tools and Remove…), then Add
/// an MCP server…. All of it runs through the plugin system (PluginHost).
struct MCPConnectionsRows: View {
  @ObservedObject private var host = PluginHost.shared
  @Environment(\.palette) var p
  @State private var message: String?
  @State private var sheet: SheetRequest?

  /// The sheet: a new address (no draft), or an added connection's tools reviewed again.
  struct SheetRequest: Identifiable {
    let id = UUID()
    let draft: PluginHost.Draft?
  }

  var body: some View {
    let connections = host.packages.filter { host.isConnection($0) }
    VStack(alignment: .leading, spacing: 8) {
      SettingsCaption(
        "Apps by address",
        info: "An app’s MCP address is the link it gives so AI apps can use it. What Serein reads from a connected app is sent to the AI app you chose for this assistant so it can answer. Serein asks you before each call that changes, sends or deletes, and shows exactly what it sends; reads go ahead where you allowed that. Only assistants that can use Connected apps see these tools.")
      VStack(spacing: 0) {
        ForEach(Array(connections.enumerated()), id: \.element.id) { index, package in
          MCPConnectionRow(package: package, first: index == 0, message: $message) { sheet = SheetRequest(draft: $0) }
        }
        HStack {
          Text(connections.isEmpty ? "No apps added. Add any app by its MCP address." : "Add any app by its MCP address.")
            .role(.meta).fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button("Add by Address…") { sheet = SheetRequest(draft: nil) }.disabled(host.busy != nil)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { if !connections.isEmpty { Rectangle().fill(p.hairline).frame(height: 0.5) } }
      }.frame(maxWidth: .infinity, alignment: .leading).settingsCard()
      if let message { Text(message).role(.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 2) }
    }
    .sheet(item: $sheet) { request in
      MCPConnectSheet(start: request.draft) { note in
        sheet = nil
        if let note { message = note }
      }
    }
  }
}

extension PluginHost {
  /// A connection's plain state from what Serein keeps for it (ConnectionState): a test running,
  /// a tool list that changed since the review, a sign-in that is missing, or on or off.
  func connectionState(_ package: PluginPackage) -> ConnectionState {
    let signedOut: Bool = package.manifest.map { $0.mcp?.auth == "oauth2" && !PluginSignIn.signedIn($0.id) } ?? false
    let problem: String? = states[package.id]?.held == true ? "Its tools changed. Review them to turn it on."
      : signedOut ? "Not signed in." : nil
    return .of(on: isEnabled(package), testing: busy == package.id, problem: problem)
  }
}

/// What a tool's risk lets Serein do, in the words the rows and the card show.
enum RiskWords {
  static func of(_ risk: PluginManifest.Risk) -> String {
    switch risk {
    case .read: return "Read"
    case .write: return "Change"
    case .send: return "Send"
    case .delete: return "Delete"
    case .pay: return "Pay"
    }
  }
  static func count(_ n: Int) -> String { "\(n) tool" + (n == 1 ? "" : "s") }
  /// "Read (4 tools) · Change or delete (2 tools) · asks before each call".
  static func summary(_ tools: [PluginManifest.Tool]) -> String {
    // As the gate judges it: read-rated, and no name raises it.
    let reads = tools.filter { ApprovalGate.pluginEffect(name: $0.gateName, declared: $0.risk, effect: .read) == .read }.count
    let asks = tools.count - reads
    var parts: [String] = []
    if reads > 0 { parts.append("Read (\(count(reads)))") }
    if asks > 0 { parts.append("Change or delete (\(count(asks)))") }
    return parts.isEmpty ? "No tools on" : (parts + ["asks before each call"]).joined(separator: " · ")
  }
}

private struct MCPConnectionRow: View {
  let package: PluginPackage
  var first = false
  @Binding var message: String?
  let review: (PluginHost.Draft) -> Void
  @ObservedObject private var host = PluginHost.shared
  @Environment(\.palette) var p
  @State private var token = ""
  @State private var removing = false
  /// Where "Sign in…" will sign in, found before the button is pressed and held to it.
  @State private var signInHost: String?

  /// This row's own test: Testing while it runs, then Needs attention with the reason if it failed.
  @State private var test: ConnectionState?
  private var connectionState: ConnectionState {
    let kept = host.connectionState(package)
    // A failed test shows its reason only while the connection is still off.
    if let test, test == .testing || kept == .off { return test }
    return kept
  }
  /// "Working · mcp.notion.com · Read (4 tools) · asks before each call".
  private var statusLine: String {
    var parts: [String] = [connectionState.line]
    if let address = host.states[package.id]?.address.flatMap({ MCPServerConnection.address($0) })?.host { parts.append(address) }
    parts.append(RiskWords.summary(package.manifest?.tools ?? []))
    return parts.joined(separator: " · ")
  }

  var body: some View {
    let state = host.states[package.id]
    let held = state?.held == true
    SettingsListRow(name: package.name, status: statusLine, statusTint: connectionState.needsAttention ? p.warning : nil, divider: !first) {
      SettingsGlyphTile(systemName: "server.rack")
    } trailing: {
      SettingsRowSwitch(label: "Use \(package.name)", isOn: Binding(
        get: { host.isEnabled(package) },
        set: { on in
          guard on else {
            test = nil
            host.setEnabled(package, false)
            message = "\(package.name) is off."
            return
          }
          // On only through a passing test: the server's own tool list, as reviewed.
          let state = connectionState
          guard state.allows(.turnOn) else { return }
          test = state.next(.turnOn)
          message = "Testing \(package.name)…"
          Task {
            do {
              try await host.enable(package)
              test = nil
              message = "\(package.name) is on."
            } catch {
              test = test?.next(.testFailed(reason: error.localizedDescription))
              message = error.localizedDescription
            }
          }
        })).disabled(host.busy != nil || held)
    } live: {
      EmptyView()
    } details: {
      Text(state?.address ?? "").font(UIStyle.monoMeta).foregroundStyle(p.secondary).textSelection(.enabled)
      if held {
        Text("Its tools changed since you reviewed them. It stays off until you review them again.")
          .role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
      }
      Toggle("Reads go ahead without asking", isOn: Binding(
        get: { state?.reads == true }, set: { host.setReads(package, $0) }))
        .toggleStyle(SettingsToggleStyle())
      SettingsNote("The tools you reviewed as Read run without a card. Tools that change, send or delete always ask, and so does the first call after Serein may have read something from outside, such as a web page or a message.")
      Toggle("Scheduled tasks may use this", isOn: Binding(
        get: { state?.scheduled == true }, set: { host.setScheduled(package, $0) }))
        .toggleStyle(SettingsToggleStyle())
      SettingsNote(
        state?.reads == true
          ? "Off unless you turn it on. Then schedules and alerts may only read from \(package.name), without a card; webhooks never use it."
          : "Off unless you turn it on. Then schedules and alerts may only read from \(package.name), and each call still waits for your OK; webhooks never use it.")
      if let manifest = package.manifest, manifest.mcp?.auth == "oauth2" {
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
            if let signInHost { Text("Signs in at \(signInHost)").font(UIStyle.monoMeta).foregroundStyle(p.secondary) }
            Spacer()
            Button("Sign In…") {
              guard let url = state?.address.flatMap({ MCPServerConnection.address($0) }) else { return }
              message = "Opening the browser…"
              Task {
                do {
                  try await PluginSignIn.run(plugin: manifest.id, name: manifest.name, serverURL: url, expectedHost: signInHost)
                  message = "Signed in to \(manifest.name)."
                } catch { message = error.localizedDescription }
              }
            }.disabled(signInHost == nil)
          }
        }
        .task(id: PluginSignIn.signedIn(manifest.id)) {
          guard !PluginSignIn.signedIn(manifest.id), let url = state?.address.flatMap({ MCPServerConnection.address($0) }) else { return }
          signInHost = (try? await PluginOAuth.discover(serverURL: url))?.signInHost
        }
      } else if let manifest = package.manifest, manifest.mcp?.token != nil {
        HStack(spacing: 6) {
          Text("Token").role(.meta)
          Spacer()
          SecureField(PluginHost.secret(plugin: manifest.id, name: MCPServerConnection.tokenName) == nil ? "Not set" : "Saved", text: $token)
            .textFieldStyle(.roundedBorder).frame(width: 220)
            .accessibilityLabel("Token for \(manifest.name)")
            .onSubmit { saveToken(manifest) }
          Button("Save Token") { saveToken(manifest) }.disabled(token.isEmpty)
            .accessibilityLabel("Save the token for \(manifest.name) in Keychain")
        }
      }
      HStack {
        Button("Review Tools…") {
          if let draft = host.draft(for: package) { review(draft) }
        }.disabled(host.busy != nil)
        Spacer()
        Button("Remove…") { removing = true }.foregroundStyle(p.danger)
          .accessibilityLabel("Remove \(package.name)")
      }
    }
    .confirmationDialog("Remove \(package.name)?", isPresented: $removing, titleVisibility: .visible) {
      Button("Remove", role: .destructive) {
        do {
          try host.remove(package)
          message = "Removed \(package.name) and its sign-in."
        } catch { message = error.localizedDescription }
      }
    } message: {
      Text("Serein forgets this app, its reviewed tools and its sign-in. You can add it again by its address.")
    }
  }

  private func saveToken(_ manifest: PluginManifest) {
    guard !token.isEmpty else { return }
    PluginHost.saveSecret(token, plugin: manifest.id, name: MCPServerConnection.tokenName)
    token = ""
    message = "Saved the token for \(manifest.name) in your Keychain."
  }
}

/// Add an MCP server from outside Settings (a registry result in Connect Apps): the same sheet
/// with its address filled in. The person still finds the server, signs in and reviews every tool.
struct MCPAddServerSheet: View {
  let address: String
  let done: (String?) -> Void
  var body: some View { MCPConnectSheet(start: nil, initialAddress: address, done: done) }
}

/// Add an MCP server: the address, then the sign-in, then one review card with every tool, its
/// risk and its description (the server's own words, fenced), each with a switch. Nothing is
/// on until Connect. `start` reviews an added connection again from the card; `initialAddress`
/// fills in the address step for a new one.
private struct MCPConnectSheet: View {
  let start: PluginHost.Draft?
  var initialAddress: String? = nil
  let done: (String?) -> Void
  @ObservedObject private var host = PluginHost.shared
  @Environment(\.palette) var p
  @State private var address = ""
  @State private var draft: PluginHost.Draft?
  @State private var token = ""
  @State private var tools: [MCPServerConnection.ReviewTool]?
  @State private var working: String?
  @State private var problem: String?
  /// Set once Connect succeeded, so closing the sheet keeps the new sign-in.
  @State private var connected = false
  /// "Reads go ahead without asking", for a new connection: offered here once, with the tools,
  /// and off unless the person turns it on.
  @State private var readsGoAhead = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if tools != nil {
        reviewCard
      } else if let draft {
        signIn(draft)
      } else {
        addressStep
      }
      if let working { Text(working).role(.meta) }
      if let problem {
        Text(problem).role(.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(20).frame(width: 520)
      .task {
        guard let start, draft == nil else { return }
        var reviewed = start
        // A re-review that needs a new sign-in shows where it signs in, as a new one does.
        if start.canSignIn { reviewed.signInHost = (try? await PluginOAuth.discover(serverURL: start.url))?.signInHost }
        draft = reviewed
        await loadTools()
      }
      .onAppear {
        if start == nil, address.isEmpty, let initialAddress { address = initialAddress }
      }
      // However the sheet closes, a new draft's sign-in or token does not stay behind.
      .onDisappear {
        if start == nil, !connected, let draft { host.discard(draft) }
      }
  }

  private var addressStep: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add an app by address").font(UIStyle.body)
      Text("Paste the app’s MCP address, or pick an official one. Serein lists its tools for you to review before anything is on.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      TextField("https://mcp.example.com/mcp", text: $address).textFieldStyle(.roundedBorder)
        .onSubmit(findServer).accessibilityLabel("MCP address")
      Text("Official addresses").role(.micro)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 6) {
        ForEach(MCPServerConnection.known, id: \.name) { server in
          Button(server.name) {
            address = server.address
            findServer()
          }.buttonStyle(QuietButton()).help(server.address).disabled(working != nil)
        }
      }
      HStack {
        Spacer()
        Button("Cancel") { done(nil) }.buttonStyle(QuietButton())
        Button("Continue", action: findServer).buttonStyle(PrimaryButton())
          .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || working != nil)
      }
    }
  }

  private func signIn(_ draft: PluginHost.Draft) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Connect \(draft.name)").font(UIStyle.body)
      Text(draft.url.absoluteString).font(UIStyle.monoMeta).foregroundStyle(p.secondary).textSelection(.enabled)
      if draft.canSignIn {
        if let signInHost = draft.signInHost {
          Text("Signs in at \(signInHost)").font(UIStyle.monoMeta).foregroundStyle(p.secondary)
        }
        Text("Sign in once in your browser. Serein keeps the sign-in in your Keychain and the server never sees a password.")
          .role(.meta).fixedSize(horizontal: false, vertical: true)
        Button("Sign in in your browser…") { signInNow(draft) }.buttonStyle(PrimaryButton()).disabled(working != nil)
        Text("Or paste a token you made in \(draft.name) instead:").role(.meta)
      } else {
        Text("\(draft.name) does not offer Serein a browser sign-in. Paste a token you made in its settings. Serein keeps it in your Keychain on this Mac only.")
          .role(.meta).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        SecureField("Token", text: $token).textFieldStyle(.roundedBorder).onSubmit { useToken(draft) }
          .accessibilityLabel("Token for \(draft.name)")
        Button("Use token") { useToken(draft) }.buttonStyle(QuietButton())
          .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || working != nil)
      }
      HStack {
        Spacer()
        Button("Cancel", action: cancel).buttonStyle(QuietButton())
      }
    }
  }

  private var reviewCard: some View {
    let rows = tools ?? []
    let on = rows.filter(\.on).count
    return VStack(alignment: .leading, spacing: 10) {
      Text("Review \(draft?.name ?? "the app")’s tools").font(UIStyle.body)
      Text("Nothing is on until you \(start == nil ? "connect" : "save"). Serein asks you before each call that changes, sends or deletes, and shows exactly what it sends. Descriptions are the app’s own words, not checked by Serein.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      if start == nil {
        Toggle("Reads go ahead without asking", isOn: $readsGoAhead).toggleStyle(SettingsToggleStyle())
          .help("The tools marked Read run without a card. Turn this off to be asked before every call.")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(rows.indices, id: \.self) { index in
            MCPToolReviewRow(tool: rows[index], on: Binding(
              get: { tools?[index].on ?? false }, set: { tools?[index].on = $0 }))
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 380)
      let cap: String = on > MCPServerConnection.maxTools ? " · at most \(MCPServerConnection.maxTools) at once" : ""
      let count: String = "\(on) of \(RiskWords.count(rows.count)) on"
      Text(count + cap)
        .role(.micro)
      Text("What Serein reads from \(draft?.name ?? "this app") is sent to the AI app you chose for this assistant so it can answer. Sending, changing or deleting anything always asks you first.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", action: cancel).buttonStyle(QuietButton())
        Button(start == nil ? "Connect" : "Save review", action: confirm).buttonStyle(PrimaryButton())
          .disabled(on == 0 || on > MCPServerConnection.maxTools || working != nil)
      }
    }
  }

  private func findServer() {
    let text = address
    working = "Looking up the app…"
    problem = nil
    Task {
      do {
        let found = try await host.draft(text)
        draft = found
        working = nil
        if found.auth == .none { await loadTools() }
      } catch {
        working = nil
        problem = error.localizedDescription
      }
    }
  }

  private func signInNow(_ draft: PluginHost.Draft) {
    working = "Waiting for the browser…"
    problem = nil
    Task {
      do {
        try await PluginSignIn.run(plugin: draft.id, name: draft.name, serverURL: draft.url, expectedHost: draft.signInHost)
        var signedIn = draft
        signedIn.auth = .oauth
        self.draft = signedIn
        working = nil
        await loadTools()
      } catch {
        working = nil
        problem = error.localizedDescription
      }
    }
  }

  /// A pasted token goes straight to the Keychain and replaces a browser sign-in.
  private func useToken(_ draft: PluginHost.Draft) {
    let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    PluginHost.saveSecret(value, plugin: draft.id, name: MCPServerConnection.tokenName)
    PluginHost.saveOAuth(plugin: draft.id, tokens: nil)
    token = ""
    var withToken = draft
    withToken.auth = .token
    self.draft = withToken
    Task { await loadTools() }
  }

  private func loadTools() async {
    guard let draft else { return }
    working = "Listing \(draft.name)’s tools…"
    problem = nil
    do { tools = try await host.review(draft) } catch { problem = error.localizedDescription }
    working = nil
  }

  private func confirm() {
    guard let draft, let tools else { return }
    working = start == nil ? "Connecting \(draft.name)…" : "Saving the review…"
    problem = nil
    Task {
      do {
        try await host.connect(draft, review: tools, readsGoAhead: start == nil ? readsGoAhead : nil)
        connected = true
        working = nil
        done("\(draft.name) is on with \(RiskWords.count(tools.filter(\.on).count)).")
      } catch {
        working = nil
        problem = error.localizedDescription
      }
    }
  }

  private func cancel() {
    if start == nil, let draft { host.discard(draft) }
    done(nil)
  }
}

/// One tool on the review card (and on an imported server's, AppImportSheet): its name, risk,
/// whether it is new or changed, its switch, and its description in a fenced box, shown verbatim
/// (never as formatted text).
struct MCPToolReviewRow: View {
  let tool: MCPServerConnection.ReviewTool
  @Binding var on: Bool
  @Environment(\.palette) var p
  /// The gate's view: "Read" only when nothing in either name raises it.
  private var label: String { tool.reads ? "Read" : RiskWords.of(tool.risk == .read ? .write : tool.risk) }

  var body: some View {
    let newWord: String = tool.isNew ? ", new" : ""
    let changedWord: String = tool.changed ? ", changed" : ""
    let spoken: String = "\(tool.serverName), \(label)\(newWord)\(changedWord)"
    VStack(alignment: .leading, spacing: 6) {
      Toggle(isOn: $on) {
        HStack(spacing: 6) {
          Text(verbatim: tool.serverName).font(UIStyle.body).lineLimit(1)
          Text(label).font(UIStyle.micro).foregroundStyle(tool.reads ? p.secondary : p.warning)
          if tool.isNew { Text("new").font(UIStyle.micro).foregroundStyle(p.accent) }
          if tool.changed { Text("changed").font(UIStyle.micro).foregroundStyle(p.warning) }
        }
      }.toggleStyle(SettingsToggleStyle())
        .accessibilityLabel(spoken)
      if !tool.description.isEmpty || !tool.parameters.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          Text("From the app, not checked by Serein").font(UIStyle.micro).foregroundStyle(p.faint)
          if !tool.description.isEmpty {
            Text(verbatim: tool.description).font(UIStyle.monoMeta).foregroundStyle(p.secondary)
              .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          }
          // What the model is told about each value it fills in.
          ForEach(Array(tool.parameters.enumerated()), id: \.offset) { _, parameter in
            Text(verbatim: parameter.description.isEmpty ? "· \(parameter.name)" : "· \(parameter.name): \(parameter.description)")
              .font(UIStyle.monoMeta).foregroundStyle(p.secondary)
              .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
          .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).strokeBorder(p.line, lineWidth: UIStyle.hairline))
          .accessibilityElement(children: .combine)
      }
    }
  }
}
