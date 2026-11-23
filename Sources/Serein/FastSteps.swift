import Foundation
import Security
import SereinCore
import SwiftUI

/// Fast steps (the `do` tool): a switch, a key in the Keychain, and the client for TypeSafe's Jev
/// decision model. A key that starts with `sk-or-` goes through OpenRouter's decisions endpoint.
enum FastSteps {
  static let switchKey = "serein.fastSteps"
  static var enabled: Bool { UserDefaults.standard.bool(forKey: switchKey) }
  static var available: Bool {
    #if DEBUG
    if scripted != nil { return true }
    #endif
    // The switch stands for the key: it goes on only after the key answered, and off when the
    // key is removed. So no launch, turn or check reads the Keychain.
    return enabled
  }
  private static let item = KeychainItem(service: "serein.jev", account: "api-key")
  /// The key is read once, at the first fast step, and off the main thread: the Keychain can show
  /// a dialog, and nothing may wait on one at launch, in a turn or in a check without a window.
  /// A failed read (a locked Keychain, or Deny in the dialog) is kept too, so one task does not ask
  /// at every step; Settings › Fast steps forgets it. Save replaces the copy.
  private static let keyLock = NSLock()
  private static var cachedKey: String??
  /// The key once it was read (or saved), else nil. Never reads the Keychain.
  private static var knownKey: String? {
    #if DEBUG
    if let key = ProcessInfo.processInfo.environment["SEREIN_JEV_KEY"], !key.isEmpty { return key }
    #endif
    keyLock.lock()
    defer { keyLock.unlock() }
    return cachedKey ?? nil
  }
  static func key() async -> String? {
    #if DEBUG
    if let key = ProcessInfo.processInfo.environment["SEREIN_JEV_KEY"], !key.isEmpty { return key }
    #endif
    if let cached = keyLock.withLock({ cachedKey }) { return cached }
    return await withCheckedContinuation { done in
      DispatchQueue.global(qos: .userInitiated).async {
        let key = item.read()
        if key != nil { item.restrictToThisDevice() }
        keyLock.lock()
        // A key saved during the read wins.
        if cachedKey == nil { cachedKey = .some(key) }
        let result = cachedKey ?? nil
        keyLock.unlock()
        done.resume(returning: result)
      }
    }
  }
  /// Whether a key is saved, without reading it: the Keychain shows no dialog for this.
  static var saved: Bool {
    if knownKey != nil { return true }
    return item.exists
  }
  /// Settings › Fast steps opened: the next step reads the Keychain again after a failed read.
  static func forgetFailedRead() {
    keyLock.lock()
    defer { keyLock.unlock() }
    if case .some(nil) = cachedKey { cachedKey = nil }
  }
  /// Where Jev answers. Chosen when the key is saved; an older key without a choice is read by its form.
  static let routeKey = "serein.jevProvider"
  enum Route: String, CaseIterable {
    case openRouter = "openrouter", typeSafe = "typesafe"
    var name: String { self == .openRouter ? "OpenRouter" : "TypeSafe" }
    var keysPage: URL { URL(string: self == .openRouter ? "https://openrouter.ai/keys" : "https://typesafe.ai")! }
    var endpoint: URL {
      URL(string: self == .openRouter ? "https://openrouter.ai/api/alpha/decisions" : "https://api.typesafe.ai/v1/systemone")!
    }
    var model: String { self == .openRouter ? "~typesafe/jev-latest" : "jev-latest" }
  }
  static var route: Route {
    UserDefaults.standard.string(forKey: routeKey).flatMap(Route.init(rawValue:))
      ?? (knownKey?.hasPrefix("sk-or-") == true ? .openRouter : .typeSafe)
  }
  /// Saves a key for one route and turns fast steps on. Throws on a key that cannot be right.
  static func connect(key raw: String, route: Route) throws {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
      throw SereinError.invalid("Paste the whole key, without spaces.")
    }
    if route == .openRouter, !key.hasPrefix("sk-or-") {
      throw SereinError.invalid("An OpenRouter key starts with sk-or-.")
    }
    guard save(key: key) else { throw SereinError.invalid("The key could not be saved in the Keychain.") }
    UserDefaults.standard.set(route.rawValue, forKey: routeKey)
  }
  /// Turns fast steps on; the form calls this only after the key answered.
  static func enable() { UserDefaults.standard.set(true, forKey: switchKey) }
  static func disconnect() {
    save(key: "")
    UserDefaults.standard.set(false, forKey: switchKey)
  }
  /// One tiny decision, to show that the key works. Returns how long it took in milliseconds.
  static func check() async throws -> Int {
    let started = Date()
    let (answers, _) = try await ask(
      state: ["goal": "Search for Ada Lovelace", "page": ["elements": [["1", "textbox", "Search"]]]],
      questions: [
        "operation": [
          "type": "choice",
          "criteria": ["TYPE_TEXT": "Type into the search field.", "CLICK": "Click a control."],
          "instructions": ["rules": "Choose the next operation."],
        ]
      ])
    guard (answers["operation"] as? [String: Any])?["choice"] is String else {
      throw SereinError.invalid("Jev answered without a choice.")
    }
    return Int(Date().timeIntervalSince(started) * 1000)
  }
  /// Replaces the saved key; an empty key removes it.
  @discardableResult static func save(key: String) -> Bool {
    keyLock.lock()
    defer { keyLock.unlock() }
    let added = item.replace(with: key)
    cachedKey = .some(added && !key.isEmpty ? key : nil)
    return added
  }

  /// One line per job and per step in ~/Library/Logs/Serein/fast-steps.log, to watch the speed live.
  /// Input values are never written, only their names.
  static func log(_ line: String) {
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Serein")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("fast-steps.log")
    let data = Data("\(stamp.string(from: Date()))  \(line)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: file) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: file)
    }
  }
  private static let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  #if DEBUG
  /// Checks answer here instead of the network.
  static var scripted: (([String: Any], [String: Any]) async throws -> [String: Any])?
  #endif
  /// Decisions replayed within this launch when the page and question are unchanged.
  static let cache = ActionCache()
  /// One request of choice questions. Returns the answers, and whether they carry probabilities.
  static func ask(state: [String: Any], questions: [String: Any]) async throws -> ([String: Any], Bool) {
    #if DEBUG
    if let scripted { return (try await scripted(state, questions), true) }
    #endif
    guard let key = await key() else { throw SereinError.invalid("Fast steps have no key; no action executed.") }
    let route = route
    let openRouter = route == .openRouter
    // An action cache: the same question over an unchanged page replays the last
    // decision without a model call. A changed page makes a new key by construction.
    let cacheKey = ActionCache.key(state: state, questions: questions, model: route.model)
    if let hit = cache.get(cacheKey),
      let answers = try? JSONSerialization.jsonObject(with: hit.answers) as? [String: Any]
    {
      Self.log("cache hit \(cacheKey.prefix(8))")
      return (answers, hit.distribution)
    }
    var request = URLRequest(url: route.endpoint, timeoutInterval: 25)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": route.model, "state": state, "questions": questions,
    ])
    for attempt in 0..<3 {
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if [429, 503, 529].contains(status) && attempt < 2 {
        try await Task.sleep(nanoseconds: 500_000_000 << UInt64(attempt))
        continue
      }
      guard (200..<300).contains(status),
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { throw SereinError.invalid("Jev returned HTTP \(status); no action executed.") }
      // OpenRouter reports each choice and its confidence, without the full distribution.
      let answers = body["answers"] as? [String: Any] ?? [:]
      if let answersJSON = try? JSONSerialization.data(withJSONObject: answers) {
        cache.put(key: cacheKey, answers: answersJSON, distribution: !openRouter)
      }
      return (answers, !openRouter)
    }
    throw SereinError.invalid("Jev is busy; no action executed.")
  }
}

extension BrowserModel {
  /// Runs a `do` job in one of the task's own tabs. Each step reads the page, asks Jev once, acts
  /// through the same PageKit path as the agent's own tools, and waits for the page. It stops on
  /// any final answer, low confidence, a page with the user's steps, a failed request, a repeated
  /// step that changed nothing, two failed actions in a row, or the action limit.
  func fastSteps(_ tab: BrowserTab, task id: String, arguments a: [String: Any]) async throws
    -> [String: Any]
  {
    let job = try JevPolicy.Job(arguments: a)
    var history: [String] = []
    var steps: [[String: Any]] = []
    var previous: (step: String, revision: Int?)?
    var used = Set<String>()
    var failures = 0
    let begun = Date()
    var jevTimes: [Int] = []
    FastSteps.log("job   \(job.goal.prefix(80))  inputs: \(job.inputs.map(\.key).joined(separator: ", "))  max \(job.maxActions)")
    func done(_ status: String, _ reason: String? = nil) async throws -> [String: Any] {
      let average = jevTimes.isEmpty ? 0 : jevTimes.reduce(0, +) / jevTimes.count
      FastSteps.log(String(format: "end   %@  %d steps  %.1f s  jev avg %d ms", status, steps.count, Date().timeIntervalSince(begun), average)
        + (reason.map { "  (\($0.prefix(120)))" } ?? ""))
      guard tasks[id] != nil else { throw SereinError.invalid("The task ended during this operation") }
      var r: [String: Any] = ["status": status, "steps": steps]
      if let reason { r["reason"] = reason }
      r["page"] =
        (try? await pageOutline(tab, task: id, start: 0, frame: nil, answerOverlay: steps.isEmpty))
        ?? ["tab": tab.id, "note": "The page is not readable yet. Use wait."]
      return r
    }
    while steps.count < job.maxActions {
      guard tasks[id] != nil else { throw SereinError.invalid("The task ended during this operation") }
      // Click & type can be switched off while the job runs; it applies at once.
      guard tasks[id]?.allowActions == true else {
        return try await done("NEEDS_AGENT", "Click & type was switched off; no action executed.")
      }
      // Never sent: a page with password, card or code fields, or a frame Serein could not check.
      if await tab.hasUserSteps() { return try await done("NEEDS_USER", HandBack.message) }
      let page = try await pageOutline(tab, task: id, start: 0, frame: nil, answerOverlay: steps.isEmpty)
      // The page can gain a password, card or code field after the probe above; this read decides.
      if page["sensitive"] as? Bool == true { return try await done("NEEDS_USER", HandBack.message) }
      // A verification check (PageKit challenge, without a CAPTCHA field): the person finishes it.
      if page["needs_user"] as? Bool == true { return try await done("NEEDS_USER", page["message"] as? String ?? HandBack.message) }
      let revision = page["revision"] as? Int
      var changed = true
      if let previous {
        changed = previous.revision != revision
        history[history.count - 1] += changed ? ": page changed" : ": no visible change"
      }
      let prompt = JevPolicy.prompt(
        job, title: page["title"] as? String ?? "", url: page["url"] as? String ?? "",
        text: page["text"] as? String ?? "", elements: JevPolicy.Element.list(page["elements"] as? [[String: Any]] ?? []), history: history,
        used: used)
      let started = Date()
      let decision: JevPolicy.Decision
      do { decision = try await decide(prompt, job) } catch {
        return try await done("NEEDS_AGENT", error.localizedDescription)
      }
      let ms = Int(Date().timeIntervalSince(started) * 1000)
      jevTimes.append(ms)
      if let terminal = decision.terminal { return try await done(terminal.rawValue, decision.reason) }
      guard let op = decision.operation, decision.confidence >= JevPolicy.minConfidence else {
        return try await done(
          "NEEDS_AGENT", String(format: "Low confidence (%.2f); no action executed.", decision.confidence))
      }
      let target = decision.target
      let label = target.map { String($0.label.prefix(60)) } ?? ""
      let step = "\(op.rawValue) \(target?.id ?? "") \(decision.inputKey ?? "")"
      if op.act != nil, previous?.step == step, !changed {
        return try await done("NEEDS_AGENT", "The same step changed nothing twice; no action executed.")
      }
      // Risky controls were not offered; refuse one anyway if it comes back.
      if op == .click, let target, !JevPolicy.risks(target.label).isSubset(of: job.allowedRisks) {
        return try await done("NEEDS_AGENT", "Jev chose a risky control the job does not allow; not pressed.")
      }
      var tool = op.act ?? "scroll"
      var args: [String: Any] = ["tab": tab.id]
      if let target { args["ref"] = target.ref }
      switch op {
      case .type:
        let value = decision.inputKey.flatMap(job.value) ?? ""
        if HandBack.containsCardNumber(value) { return try await done("NEEDS_USER", HandBack.message) }
        args["text"] = value
        args["press_enter"] = decision.enter
      case .select: args["value"] = decision.option ?? ""
      case .scrollUp, .scrollDown: args["direction"] = op == .scrollUp ? "up" : "down"
      case .wait: tool = "wait"
      case .click: break
      }
      agentTabs.step(task: id, tool: tool == "type" ? "fill" : tool, arguments: args)
      var failure: String?
      let acting = Date()
      if op == .wait {
        await tab.settle(limit: 3)
      } else {
        let actedHost = tab.verificationHost
        do {
          _ = try await runWebAction(name: tool, arguments: args, tab: tab, taskID: id, allowed: { [weak self] in
            self?.tasks[id]?.allowActions == true
          })
          // As for the agent's own steps (perform): a later read must not close a dialog the job opened.
          if ["click", "type", "select", "key"].contains(tool) { tasks[id]?.consentHosts.insert(actedHost) }
          failures = 0
        } catch {
          // A verification check that appeared after the probe above: the person's.
          if let check = error as? VerificationCheck { return try await done("NEEDS_USER", check.message) }
          let reason = error.localizedDescription
          if reason == ActionAdmission.needsPerson || reason == ActionAdmission.declined
            || reason == ActionAdmission.pageChanged || reason == ActionAdmission.effectChanged
          {
            return try await done("NEEDS_USER", reason)
          }
          failure = reason
          failures += 1
          if failures >= 2 { return try await done("NEEDS_AGENT", "Two steps failed in a row: \(reason)") }
        }
        await tab.settleAfterAction()
      }
      FastSteps.log(
        String(format: "step %-2d %-11@ jev %4d ms  act %4d ms  conf %.2f  ", steps.count + 1, op.rawValue, ms,
          Int(Date().timeIntervalSince(acting) * 1000), decision.confidence)
          + (target.map { "\"\($0.label.prefix(50))\"" } ?? "") + (decision.inputKey.map { " <- \($0)" } ?? "")
          + (decision.enter ? " +Enter" : "") + (failure.map { "  FAILED: \($0)" } ?? ""))
      history.append(
        "\(steps.count + 1). \(op.rawValue)" + (target.map { " element \($0.id) (\(label))" } ?? "")
          + (decision.inputKey.map { " with input \($0)" } ?? "") + (decision.enter ? " then ENTER" : "")
          + (failure.map { " failed (\($0))" } ?? ""))
      var record: [String: Any] = [
        "op": op.rawValue, "target": label, "confidence": (decision.confidence * 100).rounded() / 100, "ms": ms,
      ]
      if let failure { record["error"] = failure }
      steps.append(record)
      previous = (step, revision)
      if op == .type, failure == nil, let key = decision.inputKey { used.insert(key) }
    }
    return try await done("NEEDS_AGENT", "Reached the action limit (\(job.maxActions)).")
  }
  /// An answer that fails validation runs nothing; the same question is asked once more.
  private func decide(_ prompt: JevPolicy.Prompt, _ job: JevPolicy.Job) async throws -> JevPolicy.Decision {
    var tries = 0
    while true {
      let (answers, full) = try await FastSteps.ask(state: prompt.state, questions: prompt.questions)
      do { return try JevPolicy.decide(answers, prompt, job, fullDistribution: full) } catch {
        tries += 1
        if tries > 1 { throw error }
      }
    }
  }
}

/// Settings › AI apps › Fast steps (beta): page steps work the same without it; a Jev
/// key makes simple page steps faster.
struct FastStepsSettings: View {
  @AppStorage(FastSteps.switchKey) private var on = false
  var body: some View {
    SettingsGroup("Fast steps · Beta") {
      Text(
        "Page steps work the same without this. Connect Jev, a fast decision model, and agents finish simple page steps (searches, forms, filters) in about a second each."
      ).role(.meta).fixedSize(horizontal: false, vertical: true)
      JevKeyForm()
      Toggle("Use fast steps", isOn: $on).disabled(!FastSteps.saved)
      Text(
        "For each step Serein sends the job, the values to type, and the page's title, address, the first 4,000 characters of its visible text and its controls (names, values, options) to the service you chose. Never pictures, your own tabs, or pages with password, card or code fields. Each step is logged on this Mac."
      ).role(.meta).fixedSize(horizontal: false, vertical: true)
    }.onAppear { FastSteps.forgetFailedRead() }
  }
}

/// Connect Jev: choose where the key comes from, paste it into a masked field, and Serein checks it
/// with one tiny request. The key goes only to the Keychain and to the chosen service.
struct JevKeyForm: View {
  @Environment(\.palette) private var p
  @State private var route = FastSteps.route
  @State private var key = ""
  @State private var connected = FastSteps.saved
  @State private var status: String?
  @State private var busy = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if connected {
        HStack(spacing: 8) {
          InterfaceIcon(systemName: "checkmark.circle", size: 13).foregroundStyle(p.accent)
          Text("Connected through \(FastSteps.route.name)").font(UIStyle.body)
          Spacer(minLength: 8)
          Button("Test") { test(enable: false) }.disabled(busy)
          Button("Remove") {
            FastSteps.disconnect()
            connected = false
            status = nil
          }
        }
      } else {
        Picker("Key from", selection: $route) {
          ForEach(FastSteps.Route.allCases, id: \.self) { Text($0.name).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
        HStack(spacing: 8) {
          SecureField(route == .openRouter ? "Paste your OpenRouter key (sk-or-…)" : "Paste your TypeSafe key", text: $key)
            .textFieldStyle(.roundedBorder)
            .onSubmit { connect() }
          Button("Connect") { connect() }.disabled(key.isEmpty || busy)
        }
        Link("Get a \(route.name) key", destination: route.keysPage).font(UIStyle.font(12))
        // What leaves the Mac, said before the key is saved, not only in Settings.
        Text(
          "On each fast step Serein sends \(route.name) the task, the values to type, and the page's title, address, the start of its text and its controls, under your key. Never pictures, or pages with password, card or code fields."
        ).role(.meta).fixedSize(horizontal: false, vertical: true)
      }
      if let status { Text(status).role(.meta).fixedSize(horizontal: false, vertical: true) }
      Text("Your key stays in this Mac's Keychain and goes only to \(connected ? FastSteps.route.name : route.name).")
        .role(.micro).fixedSize(horizontal: false, vertical: true)
    }
  }
  private func connect() {
    do {
      try FastSteps.connect(key: key, route: route)
      key = ""
      connected = true
      test(enable: true)
    } catch { status = error.localizedDescription }
  }
  /// A key that does not answer is kept but stays off, so no task is offered a do tool that fails.
  private func test(enable: Bool = false) {
    busy = true
    status = "Checking the key…"
    Task { @MainActor in
      do {
        status = "Works. Jev answered in \(try await FastSteps.check()) ms."
        if enable {
          // A moment to read the result before the offer row (and its popover) goes away.
          try? await Task.sleep(nanoseconds: 1_200_000_000)
          FastSteps.enable()
        }
      } catch {
        status = "That key did not work: \(error.localizedDescription) Fast steps stay off."
      }
      busy = false
    }
  }
}

/// The quiet offer above the composer after a browser task: Serein stays free and complete; Jev is
/// the faster option. It goes away for good with Not now, or once fast steps are on.
struct JevOfferRow: View {
  static let dismissedKey = "serein.jevOfferDismissed"
  /// After a finished web task, while nothing runs.
  static func fits(_ agent: AgentModel) -> Bool {
    if CommandLine.arguments.contains("--ui-jev-offer") { return true }
    return [.research, .page].contains(agent.mode) && !agent.running
      && agent.messages.contains { $0.role == "assistant" }
  }
  /// Shown now: fits, fast steps off, and not put away with Not now.
  static func visible(_ agent: AgentModel) -> Bool {
    fits(agent) && !UserDefaults.standard.bool(forKey: FastSteps.switchKey)
      && !UserDefaults.standard.bool(forKey: dismissedKey)
  }
  @Environment(\.palette) private var p
  @AppStorage(FastSteps.switchKey) private var on = false
  @AppStorage(dismissedKey) private var dismissed = false
  @State private var connecting = false
  var body: some View {
    if !on && !dismissed {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 7) {
          InterfaceIcon(systemName: "bolt", size: 12).foregroundStyle(p.secondary)
          Text("Faster page steps").font(UIStyle.metaStrong).foregroundStyle(p.ink)
          Text("Beta").font(UIStyle.font(10, weight: .medium)).foregroundStyle(p.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1).overlay(Capsule().strokeBorder(p.line))
            .fixedSize()
          Spacer(minLength: 0)
        }
        Text("Connect Jev to speed up simple page steps.").role(.meta)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 8) {
          Button("Connect Jev") { connecting = true }.buttonStyle(PrimaryButton()).fixedSize()
            .popover(isPresented: $connecting, arrowEdge: .bottom) {
              VStack(alignment: .leading, spacing: 10) {
                Text("Connect Jev").font(UIStyle.bodyStrong)
                Text("Agents hand clear page steps to Jev and finish them in about a second each.").role(.meta)
                  .fixedSize(horizontal: false, vertical: true)
                JevKeyForm()
              }.padding(16).frame(width: 360).environment(\.palette, p)
            }
          Button("Not now") { dismissed = true }.buttonStyle(QuietButton()).fixedSize()
          Spacer(minLength: 0)
        }
      }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(p.panel, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
        .accessibilityElement(children: .contain)
    }
  }
}
