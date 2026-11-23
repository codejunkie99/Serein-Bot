import Foundation

/// How a provider's models are reached: an OpenAI-compatible address goes through OpenCode, an
/// Anthropic-compatible one through Claude Code (ProviderRun).
public enum ProviderWire: String, Codable, Sendable { case openai, anthropic }

/// The picker's and Settings' grouping, in display order. `more` is every models.dev provider with
/// an https OpenAI-compatible address that is not hand-listed.
public enum ProviderSection: String, Codable, CaseIterable, Sendable {
  case major, open, fast, router, enterprise, local, custom, more
}

/// An extra input a provider's address needs. The value lands inside a host name or a path, so it
/// is held to `ProviderEntry.safeValue`.
public enum ProviderField: String, Codable, Sendable {
  case baseURL, resource, region, project, location
}

/// One provider Serein can connect: public facts only (its name, public API address, where to get
/// a key). Saved connections live in ProviderConnection; keys only in Keychain.
public struct ProviderEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var section: ProviderSection
  public var wire: ProviderWire
  /// The API address, with `{resource}`, `{region}`, `{project}` or `{location}` to fill; empty
  /// for custom, which takes a whole base URL field.
  public var baseURL: String
  public var fields: [ProviderField]
  /// The models.dev provider id: models, prices and limits when the live list says nothing more.
  public var catalogID: String?
  public var keyPage: String?
  public var keyless: Bool
  /// The fixed port of a server that runs on this Mac (probed by ProviderAPI.probe).
  public var localPort: Int?
  /// False where the provider has no usable model list: the catalog stands in.
  public var lists: Bool
  public var note: String?

  public init(
    _ id: String, _ name: String, _ section: ProviderSection, _ baseURL: String, wire: ProviderWire = .openai,
    fields: [ProviderField] = [], catalog: String? = nil, key: String? = nil, keyless: Bool = false,
    port: Int? = nil, lists: Bool = true, note: String? = nil
  ) {
    self.id = id
    self.name = name
    self.section = section
    self.wire = wire
    self.baseURL = baseURL
    self.fields = fields
    self.catalogID = catalog
    self.keyPage = key
    self.keyless = keyless
    self.localPort = port
    self.lists = lists
    self.note = note
  }

  /// What a field value may be: it is pasted into a host name or a path.
  public static func safeValue(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$", options: .regularExpression) != nil
  }

  /// The address with its fields filled; nil when a field is missing or unsafe. `baseURL` is the
  /// whole address for custom rows, and replaces a local row's fixed one when given.
  public func address(_ values: [ProviderField: String]) -> String? {
    if let typed = values[.baseURL]?.trimmingCharacters(in: .whitespaces), !typed.isEmpty, fields.contains(.baseURL) {
      return typed.hasSuffix("/") ? String(typed.dropLast()) : typed
    }
    guard !baseURL.isEmpty else { return nil }
    var url = baseURL
    for field in fields where field != .baseURL {
      guard let value = values[field], Self.safeValue(value) else { return nil }
      url = url.replacingOccurrences(of: "{\(field.rawValue)}", with: value)
    }
    return url.contains("{") ? nil : url
  }
}

public enum ProviderTable {
  /// The hand list. Facts are public (each provider's own API docs); keyless rows are local servers.
  public static let entries: [ProviderEntry] = [
    .init("anthropic", "Anthropic", .major, "https://api.anthropic.com", wire: .anthropic, catalog: "anthropic", key: "https://console.anthropic.com/settings/keys"),
    .init("openai", "OpenAI", .major, "https://api.openai.com/v1", catalog: "openai", key: "https://platform.openai.com/api-keys"),
    .init("google", "Google Gemini", .major, "https://generativelanguage.googleapis.com/v1beta/openai", catalog: "google", key: "https://aistudio.google.com/apikey"),
    .init("xai", "xAI Grok", .major, "https://api.x.ai/v1", catalog: "xai", key: "https://console.x.ai"),
    .init("mistral", "Mistral", .major, "https://api.mistral.ai/v1", catalog: "mistral", key: "https://console.mistral.ai/api-keys"),
    .init("deepseek", "DeepSeek", .major, "https://api.deepseek.com/v1", catalog: "deepseek", key: "https://platform.deepseek.com/api_keys"),
    .init("meta", "Meta Llama", .major, "https://api.meta.ai/v1", catalog: "meta", key: "https://llama.developer.meta.com"),
    .init("perplexity", "Perplexity", .major, "https://api.perplexity.ai", key: "https://www.perplexity.ai/settings/api", lists: false),
    .init("qwen", "Qwen", .open, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", catalog: "alibaba", key: "https://modelstudio.console.alibabacloud.com"),
    .init("moonshot", "Moonshot Kimi", .open, "https://api.moonshot.ai/v1", catalog: "moonshotai", key: "https://platform.moonshot.ai/console/api-keys"),
    .init("zhipu", "Zhipu GLM", .open, "https://api.z.ai/api/paas/v4", catalog: "zai", key: "https://z.ai/manage-apikey/apikey-list"),
    .init("minimax", "MiniMax", .open, "https://api.minimax.io/v1", catalog: "minimax", key: "https://platform.minimax.io", lists: false),
    .init("stepfun", "StepFun", .open, "https://api.stepfun.ai/v1", catalog: "stepfun", key: "https://platform.stepfun.ai"),
    .init("xiaomi", "Xiaomi MiMo", .open, "https://api.xiaomimimo.com/v1", catalog: "xiaomi", key: "https://platform.xiaomimimo.com"),
    .init("arcee", "Arcee", .open, "https://api.arcee.ai/api/v1", catalog: "arcee", key: "https://chat.arcee.ai"),
    .init("ai21", "AI21 Labs", .open, "https://api.ai21.com/studio/v1", catalog: "ai21", key: "https://studio.ai21.com/account/api-key", lists: false),
    .init("upstage", "Upstage Solar", .open, "https://api.upstage.ai/v1/solar", catalog: "upstage", key: "https://console.upstage.ai/api-keys", lists: false),
    .init("groq", "Groq", .fast, "https://api.groq.com/openai/v1", catalog: "groq", key: "https://console.groq.com/keys"),
    .init("cerebras", "Cerebras", .fast, "https://api.cerebras.ai/v1", catalog: "cerebras", key: "https://cloud.cerebras.ai"),
    .init("together", "Together AI", .fast, "https://api.together.xyz/v1", catalog: "togetherai", key: "https://api.together.ai/settings/api-keys"),
    .init("fireworks", "Fireworks AI", .fast, "https://api.fireworks.ai/inference/v1", catalog: "fireworks-ai", key: "https://fireworks.ai/account/api-keys"),
    .init("sambanova", "SambaNova", .fast, "https://api.sambanova.ai/v1", catalog: "sambanova", key: "https://cloud.sambanova.ai/apis"),
    .init("deepinfra", "DeepInfra", .fast, "https://api.deepinfra.com/v1/openai", catalog: "deepinfra", key: "https://deepinfra.com/dash/api_keys"),
    .init("nebius", "Nebius", .fast, "https://api.tokenfactory.nebius.com/v1", catalog: "nebius", key: "https://tokenfactory.nebius.com"),
    .init("novita", "Novita AI", .fast, "https://api.novita.ai/openai", catalog: "novita-ai", key: "https://novita.ai/settings/key-management"),
    .init("siliconflow", "SiliconFlow", .fast, "https://api.siliconflow.com/v1", catalog: "siliconflow", key: "https://cloud.siliconflow.com/account/ak"),
    .init("baseten", "Baseten", .fast, "https://inference.baseten.co/v1", catalog: "baseten", key: "https://app.baseten.co/settings/api_keys"),
    .init("nvidia", "NVIDIA NIM", .fast, "https://integrate.api.nvidia.com/v1", catalog: "nvidia", key: "https://build.nvidia.com"),
    .init("chutes", "Chutes", .fast, "https://llm.chutes.ai/v1", catalog: "chutes", key: "https://chutes.ai/app/api"),
    .init("inception", "Inception Mercury", .fast, "https://api.inceptionlabs.ai/v1", catalog: "inception", key: "https://platform.inceptionlabs.ai"),
    .init("friendli", "Friendli", .fast, "https://api.friendli.ai/serverless/v1", catalog: "friendli", key: "https://friendli.ai/suite"),
    .init("openrouter", "OpenRouter", .router, "https://openrouter.ai/api/v1", catalog: "openrouter", key: "https://openrouter.ai/settings/keys"),
    .init("cohere", "Cohere", .router, "https://api.cohere.ai/compatibility/v1", catalog: "cohere", key: "https://dashboard.cohere.com/api-keys", lists: false),
    .init("vercel", "Vercel AI Gateway", .router, "https://ai-gateway.vercel.sh/v1", catalog: "vercel", key: "https://vercel.com/dashboard/ai-gateway"),
    .init("requesty", "Requesty", .router, "https://router.requesty.ai/v1", catalog: "requesty", key: "https://app.requesty.ai/api-keys"),
    .init("huggingface", "Hugging Face", .router, "https://router.huggingface.co/v1", catalog: "huggingface", key: "https://huggingface.co/settings/tokens"),
    .init("helicone", "Helicone", .router, "https://ai-gateway.helicone.ai/v1", catalog: "helicone", key: "https://us.helicone.ai/settings/api-keys"),
    .init("poe", "Poe", .router, "https://api.poe.com/v1", catalog: "poe", key: "https://poe.com/api_key"),
    .init("nanogpt", "NanoGPT", .router, "https://nano-gpt.com/api/v1", catalog: "nano-gpt", key: "https://nano-gpt.com/api"),
    .init("aimlapi", "AI/ML API", .router, "https://api.aimlapi.com/v1", catalog: "aimlapi", key: "https://aimlapi.com/app/keys"),
    .init("azure", "Azure OpenAI", .enterprise, "https://{resource}.openai.azure.com/openai/v1", fields: [.resource], catalog: "azure",
          key: "https://portal.azure.com", note: "Model ids are your deployment names."),
    .init("bedrock", "AWS Bedrock", .enterprise, "https://bedrock-runtime.{region}.amazonaws.com/openai/v1", fields: [.region],
          catalog: "amazon-bedrock", key: "https://console.aws.amazon.com/bedrock", lists: false, note: "Takes a Bedrock API key."),
    .init("vertex", "Google Vertex AI", .enterprise,
          "https://aiplatform.googleapis.com/v1/projects/{project}/locations/{location}/endpoints/openapi", fields: [.project, .location],
          catalog: "google-vertex", key: "https://console.cloud.google.com", lists: false, note: "Takes a one-hour access token, not a key."),
    .init("digitalocean", "DigitalOcean", .enterprise, "https://inference.do-ai.run/v1", catalog: "digitalocean", key: "https://cloud.digitalocean.com/gen-ai"),
    .init("scaleway", "Scaleway", .enterprise, "https://api.scaleway.ai/v1", catalog: "scaleway", key: "https://console.scaleway.com/iam/api-keys"),
    .init("ovhcloud", "OVHcloud", .enterprise, "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1", catalog: "ovhcloud", key: "https://endpoints.ai.cloud.ovh.net"),
    .init("ollama", "Ollama", .local, "http://127.0.0.1:11434/v1", keyless: true, port: 11434),
    .init("lmstudio", "LM Studio", .local, "http://127.0.0.1:1234/v1", catalog: "lmstudio", keyless: true, port: 1234),
    .init("llamacpp", "llama.cpp", .local, "http://127.0.0.1:8080/v1", fields: [.baseURL], keyless: true, port: 8080),
    .init("vllm", "vLLM", .local, "http://127.0.0.1:8000/v1", fields: [.baseURL], keyless: true, port: 8000),
    .init("jan", "Jan", .local, "http://127.0.0.1:1337/v1", keyless: true, port: 1337),
    .init("cliproxyapi", "CLIProxyAPI", .local, "http://127.0.0.1:8317/v1", fields: [.baseURL], port: 8317),
    .init("custom-openai", "OpenAI-compatible", .custom, "", fields: [.baseURL]),
    .init("custom-anthropic", "Anthropic-compatible", .custom, "", wire: .anthropic, fields: [.baseURL]),
  ]

  static let morePrefix = "catalog:"

  /// The hand list plus `more`: every catalog provider not hand-listed whose address is https and
  /// OpenAI-compatible. Its key page is the provider's docs link.
  public static func all(_ catalog: ModelCatalog) -> [ProviderEntry] {
    let listed = Set(entries.compactMap(\.catalogID))
    let more = catalog.providers.compactMap { id, provider -> ProviderEntry? in
      guard !listed.contains(id), provider.npm == "@ai-sdk/openai-compatible", let api = provider.api,
        ProviderAddress.syntax(api, place: .cloud) == nil
      else { return nil }
      return ProviderEntry(morePrefix + id, provider.name, .more, api.hasSuffix("/") ? String(api.dropLast()) : api,
                           catalog: id, key: provider.doc)
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return entries + more
  }
  /// A hand-listed entry, or a `more` one from the catalog.
  public static func find(_ id: String, catalog: ModelCatalog) -> ProviderEntry? {
    entries.first { $0.id == id } ?? (id.hasPrefix(morePrefix) ? all(catalog).first { $0.id == id } : nil)
  }
}
