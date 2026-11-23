import Foundation

/// Pure parsers for each harness's non-model probe output (version, sign-in, model lists).
/// Outputs are untrusted: every string is length-limited and never echoed as an email address.
public enum HarnessParse {
  // MARK: Versions

  /// The first version-like token: semver (1.18.31, 2.1.296) or a dated build
  /// (2026.08.25-3e8eec8).
  public static func version(_ text: String) -> String? {
    let patterns = [#"\d{4}\.\d{2}\.\d{2}(-[0-9a-f]{4,12})?"#, #"\d+\.\d+(\.\d+)?([-.][0-9A-Za-z]+)*"#]
    for pattern in patterns {
      if let r = text.range(of: pattern, options: .regularExpression) {
        return String(text[r].prefix(40))
      }
    }
    return nil
  }
  /// Numeric comparison of dotted versions (date builds compare the same way).
  public static func isOlder(_ a: String, than b: String) -> Bool {
    func parts(_ s: String) -> [Int] {
      let core = s.split(separator: "-").first.map(String.init) ?? s
      return core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    let x = parts(a)
    let y = parts(b)
    for i in 0..<max(x.count, y.count) {
      let l = i < x.count ? x[i] : 0
      let r = i < y.count ? y[i] : 0
      if l != r { return l < r }
    }
    return false
  }

  // MARK: Sign-in

  public struct Auth: Equatable, Sendable {
    public var signedIn: Bool?
    public var account: String?
    /// Why the probe could not tell (it timed out, failed, or said nothing Serein knows); shown
    /// instead of Ready (HarnessSnapshot.summarize).
    public var problem: String?
    public init(signedIn: Bool?, account: String? = nil, problem: String? = nil) {
      self.signedIn = signedIn
      self.account = account
      self.problem = problem
    }
  }
  /// A sign-in counts only from a probe run that finished cleanly; a signed-out answer stands
  /// whatever the exit. Anything else is no answer, and says why.
  public static func confirmed(_ auth: Auth, code: Int32, timedOut: Bool, command: String) -> Auth {
    if auth.signedIn == false { return auth }
    if timedOut { return Auth(signedIn: nil, problem: "`\(command)` did not answer in time.") }
    if code != 0 { return Auth(signedIn: nil, problem: "`\(command)` exited with \(code).") }
    if auth.signedIn == nil, auth.problem == nil {
      return Auth(signedIn: nil, problem: "`\(command)` did not say it is signed in.")
    }
    return auth
  }
  /// `claude auth status` (JSON).
  public static func claudeAuth(_ text: String) -> Auth {
    guard let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      let lower = text.lowercased()
      if lower.contains("not logged in") || lower.contains("not signed in") { return Auth(signedIn: false) }
      return Auth(signedIn: nil)
    }
    let signed = json["loggedIn"] as? Bool
    var account: String?
    if let plan = json["subscriptionType"] as? String, !plan.isEmpty {
      account = "Claude \(plan.prefix(1).uppercased() + plan.dropFirst().prefix(20)) plan"
    } else if let method = json["authMethod"] as? String, method.contains("key") {
      account = "API key"
    } else if (json["apiProvider"] as? String).map({ $0 != "firstParty" }) == true {
      account = String((json["apiProvider"] as? String ?? "").prefix(30))
    }
    return Auth(signedIn: signed, account: account)
  }
  /// A failed turn's error from the AI app itself says it is signed out ("Not logged in · Please
  /// run /login", an invalid key, an expired sign-in), from any harness. Only a short error
  /// counts, so a long log that mentions signing in is not one.
  public static func asksSignIn(_ error: String) -> Bool {
    guard error.count <= 600 else { return false }
    let lower = error.lowercased()
    let phrases = [
      "not logged in", "not signed in", "please run /login", "please log in", "please login",
      "invalid api key", "oauth token has expired", "authentication required", "not authenticated",
      "401 unauthorized", "codex login", "cursor-agent login", "please set an auth method",
      "sign in again", "log in again", "login again", "could not be refreshed", "refresh token",
    ]
    return phrases.contains { lower.contains($0) }
  }
  /// The button words for an AI app that cannot answer yet (`HarnessPrimaryAction`), the same for
  /// every harness. A step Serein does not know yet reads as Connect.
  public static func signInTitle(_ app: String, action: HarnessPrimaryAction) -> String {
    switch action {
    case .install: return "Install \(app)"
    case .signIn: return "Sign in to \(app)"
    case .update: return "Update \(app)"
    case .checking, .ready: return "Connect \(app)"
    }
  }
  /// `codex login status`: "Logged in using ChatGPT" / "Not logged in". Other text says nothing.
  public static func codexAuth(_ text: String) -> Auth {
    let lower = text.lowercased()
    if lower.contains("not logged in") { return Auth(signedIn: false) }
    if lower.contains("logged in") {
      let account = lower.contains("chatgpt") ? "ChatGPT" : lower.contains("api key") ? "API key" : nil
      return Auth(signedIn: true, account: account)
    }
    return Auth(signedIn: nil)
  }
  /// `cursor-agent about --format json`.
  public struct CursorAbout: Equatable, Sendable {
    public var version: String?
    public var latest: String?
    public var auth: Auth
  }
  public static func cursorAbout(_ text: String) -> CursorAbout {
    if let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      // A null email does not mean signed out: cursor-agent 2026.05 prints null while signed in,
      // so only an email decides here and `cursorStatus` settles the rest.
      let email = (json["userEmail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      let tier = (json["subscriptionTier"] as? String).map { "Cursor \($0.prefix(20))" }
      return CursorAbout(
        version: (json["cliVersion"] as? String).map { String($0.prefix(40)) },
        latest: (json["latestVersion"] as? String).map { String($0.prefix(40)) },
        auth: Auth(signedIn: email == nil ? nil : true, account: tier))
    }
    // Plain `about`: "CLI Version   2026.08.25" / "User Email   Not logged in".
    var version: String?
    var signed: Bool?
    for line in text.split(whereSeparator: \.isNewline) {
      let l = line.lowercased()
      if l.contains("cli version") { version = HarnessParse.version(String(line)) }
      if l.contains("user email") { signed = !l.contains("not logged in") }
    }
    return CursorAbout(version: version, latest: nil, auth: Auth(signedIn: signed))
  }

  /// `cursor-agent status`: "Logged in (unable to fetch user details)" / "Not logged in". The
  /// account line holds the email, so nothing from it is kept.
  public static func cursorStatus(_ text: String) -> Auth {
    let lower = text.lowercased()
    if lower.contains("not logged in") { return Auth(signedIn: false) }
    return Auth(signedIn: lower.contains("logged in") ? true : nil)
  }

  // MARK: Models

  /// The CLI refused the requested model (unknown id or no access), as opposed to a failed turn.
  /// Matches Claude Code's, Codex's and the common provider wordings.
  public static func modelRejected(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("issue with the selected model") || lower.contains("api model not found")
      || lower.contains("invalid model name") || lower.contains("model_not_found")
      || lower.contains("unknown model") || lower.contains("model is not supported")
      || (lower.contains("model") && lower.contains("does not exist"))
  }

  /// `opencode models --verbose`: "provider/id" lines each followed by a JSON object.
  public static func openCodeVerboseModels(_ text: String, now: Date = Date()) -> [HarnessModel] {
    var out: [HarnessModel] = []
    var current: String?
    var buffer = ""
    var depth = 0
    func flush() {
      guard let slug = current, let data = buffer.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return }
      out.append(openCodeModel(slug: slug, json: json, providerName: nil, now: now))
    }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(raw)
      if depth == 0, line.range(of: #"^[A-Za-z0-9._-]+/[^\s{}]+$"#, options: .regularExpression) != nil {
        current = line
        buffer = ""
        continue
      }
      guard current != nil else { continue }
      buffer += line + "\n"
      depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
      if depth == 0, !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        flush()
        current = nil
        buffer = ""
      }
    }
    return out
  }
  /// OpenCode 2's `opencode models`: one "provider/id" per line, with no metadata.
  public static func openCodeModelLines(_ text: String, now: Date = Date()) -> [HarnessModel] {
    text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.range(of: #"^[A-Za-z0-9._-]+/[^\s{}]+$"#, options: .regularExpression) != nil }
      .map { openCodeModel(slug: $0, json: [:], providerName: nil, now: now) }
  }
  /// `opencode auth list --format json`: the accounts connected to OpenCode (`[{id, name,
  /// connections}]`), by name. Free models list without one, so only this says whether one is
  /// connected. 1.x has no `--format` and prints the plain list (openCodeCredentials). nil when
  /// the output is neither, so Sign in stays offered.
  public static func openCodeAccounts(_ text: String) -> [String]? {
    guard let data = text.data(using: .utf8),
      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return openCodeCredentials(text) }
    return list.filter { ($0["connections"] as? [Any])?.isEmpty == false }
      .compactMap { ($0["name"] as? String ?? $0["id"] as? String).map { String($0.prefix(40)) } }
  }
  /// `opencode auth list` on 1.x: a "┌  Credentials <path>" section of "●  <name> ESC[90m<type>"
  /// rows ending at "└". Only stored credentials count; an Environment section names keys from
  /// the shell, which a run may not have. nil when there is no Credentials section.
  static func openCodeCredentials(_ text: String) -> [String]? {
    var names: [String]?
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("┌") {
        if names != nil { break }
        if line.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix("Credentials") { names = [] }
        continue
      }
      guard names != nil else { continue }
      if line.hasPrefix("└") { break }
      guard line.hasPrefix("●") else { continue }
      // The name ends where the dimmed type starts; without colour, the type is the last word.
      let row = line.dropFirst().trimmingCharacters(in: .whitespaces)
      let name =
        row.contains("\u{1B}")
        ? String(row.prefix { $0 != "\u{1B}" })
        : row.split(separator: " ").dropLast().joined(separator: " ")
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { names?.append(String(trimmed.prefix(40))) }
    }
    return names
  }
  /// `opencode console orgs` on 1.x: signed in, one row per workspace with the account's email
  /// and its console address; signed out, "No accounts found". The console account, which
  /// Serein's Sign in (`console login`) connects, is not in `auth list`.
  public static func openCodeConsoleSignedIn(_ text: String) -> Bool {
    text.split(whereSeparator: \.isNewline).contains { line in
      line.contains("@") && line.contains("https://")
    }
  }
  /// The account label Settings shows: nil while nothing is connected, so Sign in stays offered.
  public static func openCodeAccountLabel(credentials: [String], console: Bool) -> String? {
    let accounts = credentials + (console ? ["OpenCode Go"] : [])
    guard let first = accounts.first else { return nil }
    return (accounts.count == 1 ? first : "\(accounts.count) accounts") + " connected"
  }
  /// `GET /provider` from `opencode serve`: models of connected providers only.
  public static func openCodeProviders(_ data: Data, now: Date = Date()) -> (models: [HarnessModel], connected: [String]) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], []) }
    let connected = (json["connected"] as? [String] ?? []).map { String($0.prefix(60)) }
    let defaults = json["default"] as? [String: String] ?? [:]
    var out: [HarnessModel] = []
    for provider in json["all"] as? [[String: Any]] ?? [] {
      guard let pid = provider["id"] as? String, connected.contains(pid) else { continue }
      let name = provider["name"] as? String
      let models = provider["models"] as? [String: Any] ?? [:]
      for key in models.keys.sorted() {
        guard let m = models[key] as? [String: Any] else { continue }
        var model = openCodeModel(slug: "\(pid)/\(key)", json: m, providerName: name, now: now)
        model.isDefault = defaults[pid] == key && pid == connected.first
        out.append(model)
      }
    }
    return (out, connected)
  }
  static func openCodeModel(slug: String, json: [String: Any], providerName: String?, now: Date) -> HarnessModel {
    let name = (json["name"] as? String).map { String($0.prefix(60)) } ?? displayName(slug)
    let variants = (json["variants"] as? [String: Any] ?? [:]).keys.sorted { effortRank($0) < effortRank($1) }
    let provider = providerName ?? slug.split(separator: "/").first.map(String.init)
    var options: [HarnessOption] = []
    if !variants.isEmpty { options.append(.effort(variants, default: variants.contains("medium") ? "medium" : variants.first)) }
    // New for 60 days after its release ("yyyy-MM-dd" strings compare in date order).
    let date = json["release_date"] as? String ?? ""
    let cutoff = String(ISO8601DateFormatter().string(from: now.addingTimeInterval(-60 * 24 * 3600)).prefix(10))
    return HarnessModel(
      id: slug, name: name, blurb: provider.map { "Through OpenCode · \($0)" } ?? "Through OpenCode",
      isNew: date >= cutoff, isLegacy: (json["status"] as? String) == "deprecated",
      subProvider: provider, options: options)
  }
  static func effortRank(_ id: String) -> Int {
    ["none", "minimal", "low", "medium", "high", "xhigh", "max"].firstIndex(of: id) ?? 99
  }
  /// `omp models --json`: `{"models": [{provider, id, selector, name, thinking: [levels] | null}]}`.
  /// Oh My Pi has no `--list-models` and stops on that flag. `selector` is what `--model` takes,
  /// and each model names its own thinking levels. The first listed model is the default.
  public static func ohMyPiModels(_ text: String) -> [HarnessModel] {
    guard let start = text.firstIndex(of: "{"),
      let json = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any]
    else { return [] }
    var out = (json["models"] as? [[String: Any]] ?? []).compactMap { m -> HarnessModel? in
      let provider = m["provider"] as? String ?? ""
      guard let id = m["selector"] as? String ?? (m["id"] as? String).map({ provider.isEmpty ? $0 : provider + "/" + $0 }),
        !id.isEmpty
      else { return nil }
      let levels = m["thinking"] as? [String] ?? []
      return HarnessModel(
        id: String(id.prefix(120)), name: String((m["name"] as? String ?? displayName(id)).prefix(60)),
        blurb: provider.isEmpty ? "" : "Through \(provider)", subProvider: provider.isEmpty ? nil : provider,
        options: levels.isEmpty ? [] : [.effort(levels, default: levels.contains("medium") ? "medium" : nil)])
    }
    if !out.isEmpty { out[0].isDefault = true }
    return out
  }
  /// `pi --list-models`: a header row then provider, model, context, max-out, thinking, images
  /// columns. The default is `own` (piOwnModel) when the list has it, else the first listed, so
  /// the picker always names a model that runs.
  public static func piModels(_ text: String, own: String? = nil) -> [HarnessModel] {
    var out: [HarnessModel] = []
    for raw in text.split(whereSeparator: \.isNewline) {
      let cols = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      guard cols.count >= 2, cols[0] != "provider", cols[0].range(of: #"^[a-z0-9._-]+$"#, options: .regularExpression) != nil
      else { continue }
      let thinking = cols.count >= 5 && cols[4] == "yes"
      out.append(
        HarnessModel(
          id: "\(cols[0])/\(cols[1])", name: displayName(cols[1]), blurb: "Through \(cols[0])",
          subProvider: cols[0],
          options: thinking ? [.effort(["minimal", "low", "medium", "high", "xhigh"], default: "medium")] : []))
    }
    if let i = out.firstIndex(where: { $0.id == own }) ?? out.indices.first { out[i].isDefault = true }
    return out
  }
  /// The model Pi starts with by itself: `defaultProvider` and `defaultModel` in its
  /// settings.json, joined as the list's "provider/model" id. nil when either is missing.
  public static func piOwnModel(_ settings: Data?) -> String? {
    guard let settings, let json = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
      let provider = json["defaultProvider"] as? String, let model = json["defaultModel"] as? String
    else { return nil }
    return provider + "/" + model
  }
  /// `grok models` (documented): "Available models:" then one model per line; the login state
  /// is in the text because the command exits 0 either way.
  public static func grokModels(_ text: String) -> (models: [HarnessModel], auth: Auth) {
    let lower = text.lowercased()
    let auth: Auth =
      lower.contains("not logged in") || lower.contains("not authenticated") ? Auth(signedIn: false)
      : lower.contains("you are logged in") ? Auth(signedIn: true)
      : lower.contains("you are using xai_api_key") ? Auth(signedIn: true, account: "xAI API key")
      : Auth(signedIn: nil)
    var models: [HarnessModel] = []
    var listing = false
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.lowercased().hasPrefix("available models") {
        listing = true
        continue
      }
      guard listing else { continue }
      let id = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ")).split(separator: " ").first.map(String.init) ?? ""
      // "magpie/<app>/<model>" are a router's routes to other AI apps, not Grok's own models.
      if id.range(of: #"^[A-Za-z0-9._:/@-]{2,60}$"#, options: .regularExpression) != nil, !id.hasPrefix("magpie/") {
        models.append(HarnessModel(id: id, name: displayName(id), isDefault: line.contains("(default)")))
      }
    }
    // Grok's own default can be one of those routes; then its first own model is the default.
    if !models.isEmpty, !models.contains(where: \.isDefault) { models[0].isDefault = true }
    return (models, auth)
  }
  /// Grok's ACP `initialize` reply names each model's own effort levels and name
  /// (`_meta.modelState.availableModels[]`: `{modelId, name, _meta: {supportsReasoningEffort,
  /// reasoningEffort, reasoningEfforts: [{value, default}]}}`); a `session/new` reply holds the
  /// same list under `models`. Fills them into the models `grok models` listed, lowest level
  /// first; a model the reply does not name, or that lists no levels, keeps no effort control.
  public static func grokEfforts(_ models: [HarnessModel], reply: Any) -> [HarnessModel] {
    let json = reply as? [String: Any] ?? [:]
    let state = (json["_meta"] as? [String: Any])?["modelState"] as? [String: Any] ?? json["models"] as? [String: Any]
    let listed = state?["availableModels"] as? [[String: Any]] ?? []
    return models.map { model in
      guard let found = listed.first(where: { $0["modelId"] as? String == model.id }) else { return model }
      var model = model
      if let name = found["name"] as? String, !name.isEmpty { model.name = String(name.prefix(60)) }
      let meta = found["_meta"] as? [String: Any] ?? [:]
      let efforts = meta["supportsReasoningEffort"] as? Bool == false ? [] : meta["reasoningEfforts"] as? [[String: Any]] ?? []
      let levels = efforts.compactMap { ($0["value"] ?? $0["id"]) as? String }
        .filter { $0.range(of: "^[a-z0-9_-]{1,20}$", options: .regularExpression) != nil }
        .sorted { effortRank($0) < effortRank($1) }
      let marked = efforts.first { $0["default"] as? Bool == true }.flatMap { ($0["value"] ?? $0["id"]) as? String }
      let own = (marked ?? meta["reasoningEffort"] as? String).flatMap { levels.contains($0) ? $0 : nil }
      model.options.removeAll { $0.id == "effort" }
      if !levels.isEmpty { model.options.append(.effort(levels, default: own)) }
      return model
    }
  }
  /// ACP `cursor/list_available_models` result: `{models: [{value, name, configOptions}]}`, or a
  /// bare list (Gemini CLI's `availableModels`).
  public static func cursorModels(_ result: Any) -> [HarnessModel] {
    let list = ((result as? [String: Any])?["models"] as? [[String: Any]]) ?? (result as? [[String: Any]]) ?? []
    return list.compactMap { m in
      guard let id = (m["value"] ?? m["modelId"] ?? m["id"]) as? String, !id.isEmpty else { return nil }
      var options: [HarnessOption] = []
      for o in m["configOptions"] as? [[String: Any]] ?? [] {
        let oid = (o["id"] as? String ?? "").lowercased()
        let oname = (o["name"] as? String ?? "").lowercased()
        let values = (o["options"] as? [[String: Any]] ?? []).compactMap { v -> HarnessOption.Choice? in
          guard let value = (v["value"] ?? v["id"]) as? String else { return nil }
          return HarnessOption.Choice(value, String(((v["name"] as? String) ?? value).prefix(30)))
        }
        let current = o["currentValue"] as? String
        if oid.contains("effort") || oid.contains("reasoning") || oname.contains("effort") || o["category"] as? String == "thought_level" {
          var effort = HarnessOption.select("effort", "Reasoning", values, default: current)
          effort.nativeID = o["id"] as? String
          options.append(effort)
        } else if oid.contains("context") {
          options.append(.select("context", "Context window", values, default: current))
        } else if oid.contains("fast") {
          options.append(.toggle("fast", "Fast mode", default: current == "true"))
        }
      }
      return HarnessModel(
        id: String(id.prefix(80)), name: String(((m["name"] as? String) ?? id).prefix(60)),
        isDefault: m["isDefault"] as? Bool ?? false, options: options)
    }
  }
  /// Gemini CLI's own `--help`: the switch that starts its ACP mode (`--acp`; `--experimental-acp`
  /// before it), led by `--approval-mode default` where the help lists that switch, so a config
  /// that approves edits by itself still asks Serein. nil when the help lists no ACP mode.
  public static func geminiACPArguments(_ help: String) -> [String]? {
    func lists(_ flag: String) -> Bool {
      help.range(of: #"(?m)(^|[\s,])"# + flag + #"(?=[\s,=]|$)"#, options: .regularExpression) != nil
    }
    guard let acp = ["--acp", "--experimental-acp"].first(where: lists) else { return nil }
    return (lists("--approval-mode") ? ["--approval-mode", "default"] : []) + [acp]
  }
  /// An ACP error that asks for sign-in: the protocol's auth-required code (-32000), or its
  /// message, "Authentication required". Other errors (an MCP server's "unauthorized") do not.
  /// Gemini CLI answers -32000 whenever its start fails (no network, no quota left), so for it
  /// only the words count: a signed-out error (asksSignIn) or its own "API key is missing".
  public static func acpNeedsSignIn(code: Int?, message: String, driver: HarnessDriver? = nil) -> Bool {
    if driver == .gemini {
      return asksSignIn(message) || message.range(of: "api key is missing", options: .caseInsensitive) != nil
    }
    return code == -32000 || message.range(of: "authentication required", options: .caseInsensitive) != nil
  }
  /// Gemini CLI's ACP `session/new` reply (its result, or its error object): a session id means it
  /// is signed in, and newer versions list their models in `models: {availableModels: [{modelId,
  /// name}], currentModelId}`, read as Cursor's list. An error asking for sign-in means it is
  /// signed out; any other error (it is offline, or out of quota) leaves the sign-in unknown. Its current model is the default; a version that lists none still offers its own
  /// default as one route.
  public static func geminiSession(_ reply: Any) -> (auth: Auth, models: [HarnessModel]) {
    let json = reply as? [String: Any] ?? [:]
    guard json["sessionId"] is String else {
      let message = json["message"] as? String ?? ""
      if acpNeedsSignIn(code: json["code"] as? Int, message: message, driver: .gemini) { return (Auth(signedIn: false), []) }
      return (Auth(signedIn: nil, problem: "Gemini CLI could not open a session: \(message.prefix(200))"), [])
    }
    let models = json["models"] as? [String: Any]
    var listed = cursorModels(models?["availableModels"] as? [[String: Any]] ?? [])
    guard !listed.isEmpty else { return (Auth(signedIn: true), []) }
    let current = models?["currentModelId"] as? String
    for i in listed.indices { listed[i].isDefault = listed[i].id == current }
    if !listed.contains(where: \.isDefault) { listed[0].isDefault = true }
    return (Auth(signedIn: true), listed)
  }
  /// Turns a slug into a readable name: "claude-sonnet-5" → "Claude Sonnet 5".
  public static func displayName(_ slug: String) -> String {
    let last = slug.split(separator: "/").last.map(String.init) ?? slug
    return String(
      last.split(separator: "-").map { part -> String in
        let s = String(part)
        if ["gpt", "glm", "ai"].contains(s.lowercased()) { return s.uppercased() }
        return s.prefix(1).uppercased() + s.dropFirst()
      }.joined(separator: " ").prefix(60))
  }

  // MARK: Codex

  public static func codexModels(_ choices: [ModelChoice]) -> [HarnessModel] {
    // Codex's real models, with the one it marks default (else its first) as the default. Each
    // has the effort levels Codex lists for it; one with none has no effort control.
    let marked = choices.contains(where: \.isDefault)
    return choices.enumerated().map { index, choice in
      let levels = choice.efforts
      return HarnessModel(
        id: choice.model, name: choice.name, blurb: choice.blurb, isDefault: marked ? choice.isDefault : index == 0,
        options: levels.isEmpty ? [] : [.effort(levels, default: choice.defaultEffort.flatMap { levels.contains($0) ? $0 : nil } ?? (levels.contains("medium") ? "medium" : levels[0]))])
    }
  }
}

// MARK: - Claude manifest

/// Serein's own Claude Code model list (a bundled JSON resource; never fetched at runtime).
public struct ClaudeManifest: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var blurb: String
    public var efforts: [String]
    public var defaultEffort: String
    /// The CLI accepts "<id>[1m]" for a 1M-token context window.
    public var supportsLongContext: Bool?
    public var isNew: Bool?
    public var isLegacy: Bool?
    public var isDefault: Bool?
    public var minVersion: String?
  }
  public var updatedAt: String
  public var models: [Entry]
  public static func decode(_ data: Data) throws -> ClaudeManifest {
    try JSONDecoder().decode(ClaudeManifest.self, from: data)
  }
  /// Models the installed CLI supports. `version` nil keeps all.
  public func models(cliVersion version: String?) -> [HarnessModel] {
    models.filter { e in
      guard let min = e.minVersion, let version else { return true }
      return !HarnessParse.isOlder(version, than: min)
    }.map { e in
      var options: [HarnessOption] = e.efforts.isEmpty ? [] : [.effort(e.efforts, default: e.defaultEffort)]
      if e.supportsLongContext == true {
        options.append(.select("context", "Context window", [.init("200k", "200K"), .init("1m", "1M")], default: "200k"))
      }
      return HarnessModel(
        id: e.id, name: e.name, blurb: e.blurb, isNew: e.isNew ?? false, isLegacy: e.isLegacy ?? false,
        isDefault: e.isDefault ?? false, options: options)
    }
  }
}

/// A Claude model id with its 1M context suffix ("opus[1m]").
public enum ClaudeModelID {
  public static func split(_ id: String) -> (base: String, longContext: Bool) {
    id.hasSuffix("[1m]") ? (String(id.dropLast(4)), true) : (id, false)
  }
  public static func join(_ base: String, longContext: Bool) -> String {
    base.isEmpty ? base : longContext ? base + "[1m]" : base
  }
}

// MARK: - Login-shell PATH

public enum LoginShellPath {
  public static let marker = "__SEREIN_PATH__"
  /// The command a login shell runs to print PATH between markers (anything a profile prints
  /// before or after is ignored).
  public static var command: String { "printf '\(marker)%s\(marker)' \"$PATH\"" }
  public static func parse(_ output: String) -> String? {
    let parts = output.components(separatedBy: marker)
    guard parts.count >= 3 else { return nil }
    let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    let dirs = path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    return dirs.isEmpty ? nil : dirs.joined(separator: ":")
  }
  /// The login shell's environment, as `env -0` prints it between markers, for agents that run
  /// with their own setup (API keys and tokens their MCP servers read). Shell bookkeeping and
  /// names Serein sets itself are left out.
  public static let environmentMarker = "__SEREIN_ENV__"
  public static var environmentCommand: String {
    command + "; printf '\(environmentMarker)'; /usr/bin/env -0; printf '\(environmentMarker)'"
  }
  public static func parseEnvironment(_ output: String) -> [String: String] {
    let parts = output.components(separatedBy: environmentMarker)
    guard parts.count >= 3 else { return [:] }
    var out: [String: String] = [:]
    for entry in parts[1].split(separator: "\0") {
      guard let eq = entry.firstIndex(of: "=") else { continue }
      let name = String(entry[..<eq])
      guard !["PWD", "OLDPWD", "SHLVL", "_"].contains(name),
        HarnessEnvironment.allowed(name: name, driver: .claude)
      else { continue }
      out[name] = String(entry[entry.index(after: eq)...])
    }
    return out
  }
  /// Login-shell PATH first, then the usual install folders and the CLIs that ship inside Mac
  /// apps (`BundledCLI`), without duplicates: a copy the person installed always comes first.
  public static func searchPath(shell: String?, inherited: String?, home: String) -> [String] {
    var out: [String] = []
    let extra = [
      "/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.bun/bin",
      home + "/.volta/bin", home + "/.npm-global/bin", home + "/Library/pnpm",
      home + "/.cursor/bin", home + "/.opencode/bin",
    ] + BundledCLI.folders(home: home) + ["/usr/bin", "/bin"]
    for dir in (shell ?? "").split(separator: ":").map(String.init)
      + (inherited ?? "").split(separator: ":").map(String.init) + extra
    where dir.hasPrefix("/") && !out.contains(dir) {
      out.append(dir)
    }
    return out
  }
}

// MARK: - Cursor preflight

/// Grok's ~/.grok/config.toml, read before a helper request goes to Grok.
public enum GrokPreflight {
  /// Grok's config can approve calls before Grok asks Serein (an allow rule in `[permission]`),
  /// add servers, or turn asking off (`permission_mode` or the older `approval_mode` set to
  /// anything but asking, `yolo = true`). That the flag beats such a mode is not proven for
  /// this Grok, so it is refused too. Only these keys are read; nothing of the file is kept.
  public static func problem(config: String?) -> String? {
    guard let config else { return nil }
    for line in config.split(whereSeparator: \.isNewline) {
      let text = line.trimmingCharacters(in: .whitespaces)
      if text.hasPrefix("[mcp") || text.hasPrefix("[[mcp") || text.hasPrefix("mcp_servers") {
        return "Grok has MCP servers in ~/.grok/config.toml. Serein will not send it helper requests until they are removed."
      }
      let pair = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      let key = pair.first?.split(separator: ".").last.map(String.init) ?? ""
      let value = (pair.count == 2 ? pair[1] : "").split(separator: "#").first.map(String.init)?
        .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased() ?? ""
      let modeOff = ["permission_mode", "approval_mode"].contains(key) && !["ask", "default"].contains(value)
      if text.hasPrefix("[permission") || text.hasPrefix("[[permission") || text.hasPrefix("allow")
        || text.hasPrefix("always_approve") || modeOff || (key == "yolo" && value == "true")
      {
        return "Grok's config allows tools without asking. Serein will not send it helper requests until that is removed."
      }
    }
    return nil
  }
}

/// Checks every file Cursor Agent reads for hooks, plugins, MCP servers, allow rules and its
/// approval mode for anything that could act without Serein answering first. The paths are the ones Cursor
/// Agent 2026.05.28 reads. Only keys are read; a message names the file, never its contents.
public enum CursorPreflight {
  /// Commands an allow list may name without letting Cursor change anything.
  static let readOnlyCommands: Set<String> = ["ls", "pwd", "cat", "head", "tail", "wc", "rg", "grep", "file", "stat", "which", "echo"]
  /// The hooks file an organisation installs for every account on the Mac.
  public static let systemHooks = "/Library/Application Support/Cursor/hooks.json"

  /// Where Cursor keeps cli-config.json and permissions.json. Its hooks.json and mcp.json stay in
  /// ~/.cursor whatever this says, so `problem` reads both folders.
  public static func configDirectory(home: String, environment: [String: String]) -> String {
    func env(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
    return env("CURSOR_CONFIG_DIR") ?? env("XDG_CONFIG_HOME").map { $0 + "/cursor" } ?? home + "/.cursor"
  }

  /// Why Cursor must not run, or nil. `project` is the folder a turn runs in; its own files and
  /// those of the repository around it count too. A file that is there but cannot be read as JSON
  /// refuses, because Cursor may still follow it.
  /// Paths the wrapped Cursor process cannot read or modify. Administrator hooks stay effective.
  public static func isolatedPaths(home: String, environment: [String: String], project: String?) -> [String] {
    let configs = Set([home + "/.cursor", configDirectory(home: home, environment: environment)])
    let projects = project.map(projectFolders) ?? []
    var paths = configs.flatMap { [$0 + "/mcp.json", $0 + "/hooks.json", $0 + "/plugins"] }
    paths += [home + "/.claude/settings.json", home + "/.claude/plugins"]
    for folder in projects {
      paths += ["/.cursor/mcp.json", "/.cursor/hooks.json", "/.cursor/plugins", "/.claude/settings.json",
                "/.claude/settings.local.json", "/.claude/plugins"].map { folder + $0 }
    }
    return Array(Set(paths.flatMap { [$0, AgentFileGuard.physicalPath($0)] })).sorted()
  }

  public static func problem(
    home: String, environment: [String: String] = [:], project: String? = nil, systemHooks: String = systemHooks, isolated: Bool = false
  ) -> String? {
    let config = configDirectory(home: home, environment: environment)
    let cursor = config == home + "/.cursor" ? [config] : [home + "/.cursor", config]
    let projects = project.map { projectFolders($0) } ?? []
    let closed = isolated ? Set(isolatedPaths(home: home, environment: environment, project: project)) : []
    func visible(_ path: String) -> Bool { !closed.contains { path == $0 || path.hasPrefix($0 + "/") } }
    let claude = [home + "/.claude/settings.json"] + projects.flatMap { [$0 + "/.claude/settings.json", $0 + "/.claude/settings.local.json"] }
    func shown(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }
    do {
      let hooks = [systemHooks, home + "/.cursor/managed/active-team-hooks/hooks.json"]
        + cursor.map { $0 + "/hooks.json" } + projects.map { $0 + "/.cursor/hooks.json" } + claude
      for path in hooks where visible(path) {
        let found = try object(path)?["hooks"] as? [String: Any] ?? [:]
        if found.values.contains(where: { ($0 as? [Any]).map { !$0.isEmpty } ?? true }) {
          return "Cursor would run the hooks in \(shown(path)) inside Serein's tasks, so Serein will not use Cursor until they are removed."
        }
      }
      // A plugin brings hooks and MCP servers of its own. A switch on Cursor's side decides
      // whether plugins load, and Serein cannot read it, so any plugin Cursor could load refuses.
      // shortcut: a plugin with no hooks or servers refuses as well; read each plugin's own
      // manifest if people hit that.
      let local = home + "/.cursor/plugins/local", fm = FileManager.default
      var isFolder: ObjCBool = false
      if visible(local), ((try? fm.contentsOfDirectory(atPath: local)) ?? []).contains(where: {
        fm.fileExists(atPath: local + "/" + $0, isDirectory: &isFolder) && isFolder.boolValue
      }) {
        return "Cursor could load the plugins in \(shown(local)), which can run hooks and tools inside Serein's tasks, so Serein will not use Cursor until they are removed."
      }
      let installed = visible(home + "/.claude/plugins") ? (try object(home + "/.claude/plugins/installed_plugins.json")?["plugins"] as? [String: Any] ?? [:]) : [:]
      if !installed.isEmpty,
        let path = try claude.first(where: { path in
          (try object(path)?["enabledPlugins"] as? [String: Any] ?? [:]).values.contains { $0 as? Bool == true }
        })
      {
        return "Cursor could load the Claude Code plugins turned on in \(shown(path)), which can run hooks and tools inside Serein's tasks, so Serein will not use Cursor until they are turned off."
      }
      for path in cursor.map({ $0 + "/mcp.json" }) + projects.map({ $0 + "/.cursor/mcp.json" }) where visible(path) {
        if let servers = try object(path)?["mcpServers"] as? [String: Any], !servers.isEmpty {
          return "Cursor has MCP servers configured in \(shown(path)) (\(servers.keys.sorted().prefix(3).joined(separator: ", "))). Serein cannot keep them out of its tasks, so it will not use Cursor until they are removed."
        }
      }
      var allow: [(entry: String, path: String)] = []
      if let json = try object(config + "/cli-config.json") {
        // Cursor's own default is "allowlist"; anything else it may add later is refused too.
        if let mode = json["approvalMode"], (mode as? String)?.lowercased() != "allowlist" {
          return "Cursor is set to run commands without asking (approvalMode in \(shown(config + "/cli-config.json"))). Serein will not use it until that is set back to allowlist."
        }
        allow += allowEntries(json).map { ($0, config + "/cli-config.json") }
      }
      // Any entry here makes Cursor report itself unrestricted, so none is treated as harmless.
      if let json = try object(config + "/permissions.json") {
        let lists = json.filter { ["mcpallowlist", "terminalallowlist"].contains($0.key.lowercased()) }
        if lists.values.contains(where: { ($0 as? [Any]).map { !$0.isEmpty } ?? true }) {
          return "Cursor's \(shown(config + "/permissions.json")) lets commands or tools run without asking. Serein will not use Cursor until its lists are emptied."
        }
      }
      // Cursor also follows the allow rules Claude Code keeps.
      for path in claude where visible(path) { allow += allowEntries(try object(path) ?? [:]).map { ($0, path) } }
      for (entry, path) in allow where !safeAllowEntry(entry) {
        return "The allow list in \(shown(path)) includes \(entry.prefix(40)), which Cursor could use to change files or reach the network without asking. Serein will not use Cursor until it is removed."
      }
    } catch {
      let path = (error as? Unreadable).map { shown($0.path) } ?? "one of Cursor's settings files"
      return "Serein could not read \(path), so it cannot tell whether Cursor would act without asking. Serein will not use Cursor until that file is valid JSON."
    }
    return nil
  }

  struct Unreadable: Error { let path: String }
  /// A config file's top-level object; nil when the file is absent or empty.
  static func object(_ path: String) throws -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    // shortcut: only whole-line // comments are stripped, so a file with inline comments or
    // trailing commas is refused as unreadable; parse full JSONC if people hit that.
    guard let json = try? JSONSerialization.jsonObject(with: Data(HarnessCatalog.stripLineComments(text).utf8)) as? [String: Any]
    else { throw Unreadable(path: path) }
    return json
  }
  static func allowEntries(_ json: [String: Any]) -> [String] {
    guard let allow = (json["permissions"] as? [String: Any])?["allow"] else { return [] }
    // A list that is not plain strings cannot be judged, so it counts as one unsafe entry.
    return allow as? [String] ?? ["permissions.allow"]
  }
  /// `folder` and the repository root above it (the nearest parent holding `.git`).
  static func projectFolders(_ folder: String) -> [String] {
    var url = URL(fileURLWithPath: folder).standardizedFileURL
    let start = url.path
    while url.path != "/" {
      if FileManager.default.fileExists(atPath: url.path + "/.git") { return url.path == start ? [start] : [start, url.path] }
      url.deleteLastPathComponent()
    }
    return [start]
  }
  /// `Read(...)`, or a read-only command with nothing that could chain or expand into another.
  /// Claude Code writes the same rule as `Bash(...)`.
  static func safeAllowEntry(_ entry: String) -> Bool {
    if entry.hasPrefix("Read(") { return true }
    guard let open = ["Shell(", "Bash("].first(where: entry.hasPrefix), entry.hasSuffix(")") else { return false }
    let inner = entry.dropFirst(open.count).dropLast()
    let command = inner.split(separator: " ").first.map(String.init) ?? ""
    return readOnlyCommands.contains(command) && !inner.contains(where: { "*;|>&$`".contains($0) })
  }
}

/// The OpenCode generation Serein talks to, from the probed `--version`; an unknown version is 1.x.
/// OpenCode 2 dropped `--pure` and `models --verbose`, and signs in with `auth login`.
public enum OpenCodeAPI: Sendable, Equatable {
  case v1, v2

  public init(version: String?) {
    self = version.map { !HarnessParse.isOlder($0, than: "2") } == true ? .v2 : .v1
  }
  /// 2.x has no `--pure`; a private, empty config folder keeps the user's plugins out instead
  /// (OPENCODE_CONFIG_DIR).
  public var serveArguments: [String] {
    ["serve"] + (self == .v1 ? ["--pure"] : []) + ["--hostname=127.0.0.1", "--port=0"]
  }
  /// `--standalone` keeps 2.x's probes off its shared background service.
  public var modelArguments: [String] { self == .v1 ? ["models", "--verbose", "--pure"] : ["models", "--standalone"] }
  /// 1.x has no `--format` (it prints its help for it), so it lists accounts as plain text.
  public var accountArguments: [String] { self == .v2 ? ["auth", "list", "--format", "json", "--standalone"] : ["auth", "list"] }
  /// 1.x's console account, which its Sign in connects; 2.x dropped `console`.
  public var consoleArguments: [String]? { self == .v1 ? ["console", "orgs"] : nil }
  public func models(_ text: String) -> [HarnessModel] {
    self == .v1 ? HarnessParse.openCodeVerboseModels(text) : HarnessParse.openCodeModelLines(text)
  }
  /// OpenCode 2's own route that stores a new key for a model's provider (the part of the model
  /// before "/", which is its integration's id): POST with `{"key": …}` in the body, 204 when
  /// stored. The newest key becomes the active one. nil for a model with no provider part.
  public static func keyRoute(model: String) -> String? {
    let parts = model.split(separator: "/", maxSplits: 1)
    guard parts.count == 2, !parts[0].isEmpty else { return nil }
    return "api/integration/\(parts[0])/connect/key"
  }
}

/// CLIs that ship inside Mac apps: Codex in the ChatGPT app (`codex-cli/bin`, its launcher) and in
/// the older Codex app. Someone with one of those apps can connect Codex without installing
/// anything; the app keeps its copy current, so Serein never offers that copy an update of its own.
public enum BundledCLI {
  /// In /Applications and ~/Applications, after every folder a person installs into.
  public static func folders(home: String) -> [String] {
    ["/Applications", home + "/Applications"].flatMap { apps in
      [apps + "/ChatGPT.app/Contents/Resources/codex-cli/bin", apps + "/Codex.app/Contents/Resources"]
    }
  }
  /// The app a CLI at `path` ships in (“ChatGPT”), or nil for one installed on its own.
  public static func app(_ path: String?) -> String? {
    guard let path, let end = path.range(of: ".app/Contents/") else { return nil }
    return path[..<end.lowerBound].split(separator: "/").last.map(String.init)
  }
}
