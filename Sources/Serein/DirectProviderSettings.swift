import SwiftUI
import SereinCore

/// The transport choice belongs to a connection; an API key never replaces a CLI subscription.
struct DirectProviderSettings: View {
  @ObservedObject private var store = ProviderStore.shared
  @State private var connecting: ProviderEntry?
  @State private var directory = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Model providers").font(AssistantType.name)
      ForEach(store.connections.connections) { connection in
        DirectConnectionRow(connection: connection, store: store)
      }
      Button("Connect a provider") { directory = true }
    }
    .sheet(isPresented: $directory) {
      VStack(alignment: .leading) {
        if let connecting {
          ProviderConnectionForm(store: store, entry: connecting)
        } else {
          ProviderDirectory(store: store) { connecting = $0 }
        }
      }
    }.onChange(of: directory) { _, open in if !open { connecting = nil } }
  }
}

private struct ProviderDirectory: View {
  @ObservedObject var store: ProviderStore
  let select: (ProviderEntry) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var showMore = false
  var body: some View {
    let entries = ProviderTable.all(store.catalog)
    VStack(alignment: .leading, spacing: 12) {
      Text("Connect a provider").font(.headline)
      TextField("Search providers", text: $query)
      List {
        ForEach(ProviderSection.allCases, id: \.self) { section in
          let rows = entries.filter { $0.section == section && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)) }
          if !rows.isEmpty {
            Section(section.rawValue.capitalized) {
              if section == .more && query.isEmpty { Toggle("Show additional providers", isOn: $showMore) }
              if section != .more || showMore || !query.isEmpty {
                ForEach(rows) { row in
                  Button { select(row) } label: {
                    HStack {
                      Text(row.name)
                      Spacer()
                      if store.connection(row.id) != nil { Text("Connected") }
                      if row.localPort != nil { Text(store.running.contains(row.id) ? "Running" : "Not running") }
                    }
                  }.buttonStyle(.plain)
                }
              }
            }
          }
        }
      }
      Button("Done") { dismiss() }
    }.padding().frame(width: 480, height: 520)
      .task { await store.probeLocal(connect: false) }
  }
}

private struct DirectConnectionRow: View {
  let connection: ProviderConnection
  @ObservedObject var store: ProviderStore
  @State private var model = ""
  @State private var status = ""
  @State private var checking = false
  @State private var confirmingRemoval = false
  var body: some View {
    VStack(alignment: .leading) {
      Toggle(connection.name, isOn: Binding(get: { connection.enabled }, set: { value in
        do { try store.setEnabled(connection.id, value); status = "" }
        catch { status = error.localizedDescription }
      })).font(.headline)
      if connection.wire == .openai {
        Toggle("Use direct HTTP for " + connection.name, isOn: Binding(get: { connection.directHTTP == true },
        set: { value in
          do { try store.setDirectHTTP(connection.id, enabled: value); status = "" }
          catch { status = error.localizedDescription }
        }))
      }
      if connection.enabled, connection.directHTTP == true, let first = connection.models.first {
        let selected = connection.models.contains(model) ? model : first
        HStack {
          Picker("Model", selection: Binding(get: { selected }, set: { model = $0; status = "" })) {
            ForEach(connection.models, id: \.self) { Text($0).tag($0) }
          }
          Button(checking ? "Testing…" : "Test model") {
            checking = true
            Task { @MainActor in
              defer { checking = false }
              do { try await store.testDirectHTTP(connection, model: selected); status = selected + " answered." }
              catch { status = error.localizedDescription }
            }
          }.help("Sends a short request using this connection.")
        }
      }
      HStack {
        Button("Refresh models") {
          checking = true
          Task { @MainActor in
            defer { checking = false }
            do { try await store.refreshModels(connection); status = "Model list refreshed." }
            catch { status = error.localizedDescription }
          }
        }
        Button("Remove connection", role: .destructive) { confirmingRemoval = true }
      }
      .confirmationDialog("Remove " + connection.name + " and its saved key?", isPresented: $confirmingRemoval) {
        Button("Remove connection", role: .destructive) {
          do { try store.remove(connection.id) } catch { status = error.localizedDescription }
        }
        Button("Cancel", role: .cancel) {}
      }
      if !status.isEmpty { Text(status).font(.caption) }
    }.disabled(checking)
  }
}

private struct ProviderConnectionForm: View {
  @ObservedObject var store: ProviderStore
  @Environment(\.dismiss) private var dismiss
  let entry: ProviderEntry
  @State private var fields: [ProviderField: String] = [:]
  @State private var secret = ""
  @State private var direct = true
  @State private var modelID = ""
  @State private var busy = false
  @State private var error = ""
  var body: some View {
    Form {
        Text(entry.name).font(.headline)
        if let link = entry.keyPage.flatMap(URL.init(string:)) { Link("Get a key", destination: link) }
        ForEach(entry.fields, id: \.self) { field in
          TextField(field == .baseURL ? "Base URL" : field.rawValue.capitalized,
            text: Binding(get: { fields[field] ?? "" }, set: { fields[field] = $0 }))
        }
        if !entry.keyless { SecureField("API key", text: $secret) }
        TextField("Model ID (optional)", text: $modelID)
        if entry.wire == .openai { Toggle("Send requests directly from this Mac", isOn: $direct) }
        if let note = entry.note { Text(note).font(.caption) }
        if !error.isEmpty { Text(error).foregroundStyle(.secondary) }
        HStack {
          Button("Cancel") { dismiss() }
          Button(busy ? "Connecting…" : "Connect") {
            busy = true
            Task { @MainActor in
              defer { busy = false }
              do {
                _ = try await store.connect(entry, fields: fields, key: secret, directHTTP: direct, modelID: modelID)
                secret = ""
                dismiss()
              } catch { self.error = error.localizedDescription }
            }
          }.keyboardShortcut(.defaultAction)
        }
    }.onAppear { direct = store.connection(entry.id).map { $0.directHTTP == true } ?? true }.disabled(busy).padding(24).frame(width: 420)
  }
}
