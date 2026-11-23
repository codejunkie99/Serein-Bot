#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// `--probe-providers [port]`: prints what the provider table gives a run, on the library in
/// SEREIN_DATA_DIR (a temp one for the proof), with no AI app started and no real provider called.
/// With a local server on `port` (a fake one for the proof): a disabled Local model on it migrates,
/// it is connected the way a found vLLM is, and two test keys on two more connections show that a
/// turn gets only its own model's key and that no key reaches OpenCode's config text. Then a Claude
/// Code turn on an Anthropic-compatible connection against one on its own model (run with fake
/// ANTHROPIC_* variables in the environment), and the Local model upgrade cases, each on its own
/// library: a keyless Tailscale address with tools off, and a row already connected elsewhere.
@MainActor enum ProviderProbe {
  static func run(port: Int?) async throws {
    let library = try Library(root: AgentAccess.defaultRoot)
    let registry = HarnessRegistry.shared
    registry.probesEnabled = false
    registry.configure(library: library)
    // A keyless proxy the person set for Claude Code before the table: it keeps working.
    var claude = registry.instance(.claude)
    claude.environment["ANTHROPIC_BASE_URL"] = "http://192.168.1.10:4000"
    registry.update(claude)
    if let port {
      try FileManager.default.createDirectory(at: library.root.appendingPathComponent("agents"), withIntermediateDirectories: true)
      try Data(#"{"enabled":false,"endpoint":"http://127.0.0.1:\#(port)","model":"fake-model"}"#.utf8)
        .write(to: library.root.appendingPathComponent("agents/local-model.json"))
    }
    let store = ProviderStore.shared
    store.configure(library: library, background: false)
    await store.setup?.value
    let catalog = ModelCatalog.load(root: library.root, bundled: ProviderStore.bundledCatalog)
    let all = ProviderTable.all(catalog)
    print("table: \(ProviderTable.entries.count) hand-listed, \(all.count - ProviderTable.entries.count) more, sections "
      + ProviderSection.allCases.map { section in "\(section.rawValue)=\(all.filter { $0.section == section }.count)" }.joined(separator: " "))
    print("catalog: source=\(catalog.source) providers=\(catalog.providers.count) models=\(catalog.modelCount) bundled=\(ProviderStore.bundledCatalog?.lastPathComponent ?? "missing")")
    print("facts openai/gpt-5: \(catalog.facts(provider: "openai", model: "gpt-5").map(ProviderStore.blurb) ?? "none")")
    await store.probeLocal(connect: false)
    print("local running: \(store.running.sorted())")

    func turn(_ cli: HarnessDriver, _ model: String) throws -> TurnRequest {
      var request = TurnRequest(
        thread: ThreadKey("probe"), cli: cli, executable: URL(fileURLWithPath: "/usr/bin/true"), access: .answer,
        prompt: TurnPrompt(stable: "", volatile: "", message: "", recovery: nil), model: model, effort: nil, resume: nil,
        browser: nil, taskID: "")
      try registry.prepare(&request, ownSetup: false)
      return request
    }
    let person = try turn(.claude, "claude-sonnet-4-5").environment
    print("claude keyless ANTHROPIC_BASE_URL kept: \(person["ANTHROPIC_BASE_URL"] == "http://192.168.1.10:4000"), allowed in the box: "
      + "\(HarnessEnvironment.allowed(name: "ANTHROPIC_BASE_URL", driver: .claude)), token set: \(person["ANTHROPIC_AUTH_TOKEN"] != nil)")

    if let port {
      let migrated = store.connection("custom-openai")
      print("local model migrated: \(migrated?.id ?? "none") enabled=\(migrated?.enabled.description ?? "-") "
        + "keyless=\(migrated?.keyless.description ?? "-") at \(migrated?.baseURL ?? "-") models \(migrated?.models ?? []), "
        + "old file gone: \(!FileManager.default.fileExists(atPath: library.root.appendingPathComponent("agents/local-model.json").path))")
      func at(_ id: String) -> ProviderEntry {
        var entry = ProviderTable.entries.first { $0.id == id }!
        entry.baseURL = "http://127.0.0.1:\(port)/v1"
        return entry
      }
      let local = try await store.connect(at("vllm"), key: "", directHTTP: false)
      print("connected \(local.id) at \(local.baseURL): models \(local.models)")
      let chosenKey = "sk-proof-" + UUID().uuidString, otherKey = "sk-proof-" + UUID().uuidString
      _ = try await store.connect(at("openrouter"), key: chosenKey, directHTTP: false)
      _ = try await store.connect(at("deepseek"), key: otherKey, directHTTP: false)
      let request = try turn(.opencode, "serein-openrouter/fake-model")
      let env = request.environment, text = env["OPENCODE_CONFIG_CONTENT"] ?? ""
      let merged = OpenCodeDriver.config(grant: HarnessGrant(mode: "answer", edits: false, permission: .supervised), stable: "STABLE", providers: text)
      print("turn OPENCODE_CONFIG_CONTENT: \(text)")
      print("turn model: \(request.model ?? "none"), driver config has provider block: \(merged.contains("\"provider\"") && merged.contains("serein-openrouter"))")
      print("only the chosen key: chosen under its variable \(env["SEREIN_OPENROUTER_API_KEY"] == chosenKey), other variable set "
        + "\(env["SEREIN_DEEPSEEK_API_KEY"] != nil), other key anywhere \(env.values.contains { $0.contains(otherKey) }), "
        + "key text in config \(text.contains(chosenKey) || merged.contains(chosenKey))")
      let probe = store.openCodeProbeEnvironment()
      print("probe env: names \(probe.keys.sorted()), any key \(probe.values.contains { $0.contains(chosenKey) || $0.contains(otherKey) })")
      print("saved Local model route fake-model on a disabled move runs as: \(try turn(.opencode, "fake-model").model ?? "none") (vLLM lists it too)")
      // The parent's own Anthropic variables (the proof sets fake ones) reach a Claude Code turn
      // on its own model and never one on a connection's model, own setup or not.
      let anthropicKey = "sk-proof-" + UUID().uuidString
      _ = try await store.connect(at("custom-anthropic"), fields: [.baseURL: "http://127.0.0.1:\(port)"], key: anthropicKey)
      let parent = ProcessInfo.processInfo.environment
      func claudeEnv(_ model: String, own: Bool) throws -> [String: String] {
        let request = try turn(.claude, model)
        return ClaudeDriver.environment(ownSetup: own, cardWait: .seconds(1), executable: request.executable, person: request.environment,
                                        providerTurn: request.providerTurn)
      }
      for own in [false, true] {
        let table = try claudeEnv("serein-custom-anthropic/fake-model", own: own), plain = try claudeEnv("claude-sonnet-4-5", own: own)
        print("claude table turn (own setup \(own)): parent ANTHROPIC_API_KEY \(table["ANTHROPIC_API_KEY"] != nil), "
          + "parent ANTHROPIC_CUSTOM_HEADERS \(table["ANTHROPIC_CUSTOM_HEADERS"] != nil), token is the connection's "
          + "\(table["ANTHROPIC_AUTH_TOKEN"] == anthropicKey), base is the connection's \(table["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:\(port)")")
        print("claude own-model turn (own setup \(own)): parent ANTHROPIC_API_KEY kept "
          + "\(parent["ANTHROPIC_API_KEY"] != nil && plain["ANTHROPIC_API_KEY"] == parent["ANTHROPIC_API_KEY"]), parent ANTHROPIC_CUSTOM_HEADERS kept "
          + "\(parent["ANTHROPIC_CUSTOM_HEADERS"] != nil && plain["ANTHROPIC_CUSTOM_HEADERS"] == parent["ANTHROPIC_CUSTOM_HEADERS"]), "
          + "connection key anywhere \(plain.values.contains { $0.contains(anthropicKey) })")
      }
      try store.remove("custom-anthropic")
      print("key scrubbed by AgentPrivacy: \(!AgentPrivacy.redact("said \(chosenKey)").contains(chosenKey))")
      print("picker rows before an OpenCode probe: \(registry.models(Provider(.opencode)).filter { $0.id.hasPrefix("serein-") }.count)")
      for id in ["openrouter", "deepseek", "vllm", "custom-openai"] { try store.remove(id) }
      try store.remove("vllm")
      print("removed local rows remembered once: \(store.connections.removed ?? [])")

      // Each upgrade case on its own library beside this one.
      func upgrade(_ name: String, local: String, providers: ProviderConnections? = nil, oldKey: String? = nil) async throws -> (Library, KeychainItem) {
        let lib = try Library(root: library.root.deletingLastPathComponent().appendingPathComponent(name))
        try FileManager.default.createDirectory(at: lib.root.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try Data(local.utf8).write(to: lib.root.appendingPathComponent("agents/local-model.json"))
        if let providers { try lib.save(providers, to: ProviderConnections.path) }
        let item = KeychainItem(service: "local.serein.inference", account: lib.root.path)
        if let oldKey { _ = item.replace(with: oldKey) }
        store.configure(library: lib, background: false)
        await store.setup?.value
        return (lib, item)
      }
      let (tail, _) = try await upgrade("tailscale", local: #"{"enabled":true,"endpoint":"http://100.64.0.5:8000","model":"tail-model","tools":false,"images":true}"#)
      let moved = store.connection("custom-openai")
      print("keyless 100.64 Local model migrated: \(moved?.id ?? "none") at \(moved?.baseURL ?? "-") keyless=\(moved?.keyless.description ?? "-") "
        + "enabled=\(moved?.enabled.description ?? "-") tools=\(moved?.tools.map(String.init(describing:)) ?? "nil") "
        + "images=\(moved?.images.map(String.init(describing:)) ?? "nil") old file gone: "
        + "\(!FileManager.default.fileExists(atPath: tail.root.appendingPathComponent("agents/local-model.json").path)), note: \(store.unmoved?.note ?? "none")")
      let tailTurn = try turn(.opencode, "tail-model")
      print("saved route tail-model runs as: \(tailTurn.model ?? "none"), OPENCODE_CONFIG_CONTENT: \(tailTurn.environment["OPENCODE_CONFIG_CONTENT"] ?? "none")")
      print("tool_call false in the OpenCode config: \(tailTurn.environment["OPENCODE_CONFIG_CONTENT"]?.contains(#""tool_call":false"#) == true), "
        + "attachment true: \(tailTurn.environment["OPENCODE_CONFIG_CONTENT"]?.contains(#""attachment":true"#) == true)")
      try store.remove("custom-openai")

      let elsewhere = ProviderConnection(entry: ProviderTable.entries.first { $0.id == "custom-openai" }!, baseURL: "http://127.0.0.1:9/v1", models: ["other"])
      var taken = ProviderConnections(connections: [elsewhere])
      taken.connections[0].keyless = true
      let oldValue = "sk-proof-" + UUID().uuidString
      let (kept, item) = try await upgrade("taken", local: #"{"enabled":true,"endpoint":"http://127.0.0.1:\#(port)/v1","model":"kept-model"}"#,
                                            providers: taken, oldKey: oldValue)
      print("custom-openai already elsewhere: still at \(store.connection("custom-openai")?.baseURL ?? "-"), old Local model key kept "
        + "\(item.read() == oldValue), old file kept \(FileManager.default.fileExists(atPath: kept.root.appendingPathComponent("agents/local-model.json").path))")
      print("route reason on kept-model: \(store.unmovedNote(model: "kept-model") ?? "none"), on another model: \(store.unmovedNote(model: "other") ?? "none")")
      _ = item.replace(with: nil)
      print("same server: localhost=127.0.0.1 \(ProviderAddress.same("http://localhost:11434/v1", "http://127.0.0.1:11434/v1/")), "
        + "[::1]=127.0.0.1 \(ProviderAddress.server("http://[::1]:11434") == ProviderAddress.server("http://127.0.0.1:11434")), "
        + "other port \(ProviderAddress.same("http://127.0.0.1:11435/v1", "http://127.0.0.1:11434/v1"))")
    }

    for address in ["http://169.254.169.254/latest/meta-data", "https://169.254.169.254.nip.io/v1", "http://[fe80::1]/v1",
                    "http://metadata.google.internal/v1", "http://[64:ff9b::a9fe:a9fe]/v1", "http://[2002:a9fe:a9fe::1]/v1",
                    "http://api.openai.com/v1", "https://api.openai.com/v1", "http://mybox:8000/v1", "http://100.64.0.5:8000/v1",
                    "http://127.0.0.1:11434/v1", "http://192.168.1.10:8000/v1", "http://[fd12::5]:8000/v1"] {
      let here = await Task.detached { ProviderAddress.check(address, place: .thisMac) }.value
      let cloud = await Task.detached { ProviderAddress.check(address, place: .cloud) }.value
      let keyless = await Task.detached { ProviderAddress.checkFound(address, place: .thisMac, keyless: true) }.value
      print("address \(address): this Mac=\(here ?? "allowed") | cloud=\(cloud ?? "allowed") | keyless=\(keyless.refused ?? "allowed")"
        + (keyless.found ? "" : " (no verdict kept)"))
    }
  }
}
#endif
