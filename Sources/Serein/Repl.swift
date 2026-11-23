import Foundation
import JavaScriptCore
import SereinCore

/// The `repl` tool (docs/AGENT-REPL-SPEC.md): the agent's JavaScript runs in a JSContext kept for
/// its task, inside Serein and never in a page. Its only reach is the task's own browser tools, each
/// run through `handle` as if the agent had called it, so every check of a single call holds: the
/// actions switch, the agent's sites, the user's fields, the step list and the agent history. One
/// call does many steps, and only what the program logs or returns goes back to the model.
@MainActor final class Repl {
  typealias Call = (String, [String: Any]) async throws -> [String: Any]
  /// On by default. `defaults write local.serein.browser serein.repl -bool false` turns it off;
  /// in debug builds SEREIN_BENCH_REPL=0 or 1 decides (bench arms).
  static var available: Bool {
    #if DEBUG
    if let bench = ProcessInfo.processInfo.environment["SEREIN_BENCH_REPL"] { return bench == "1" }
    #endif
    return UserDefaults.standard.object(forKey: "serein.repl") as? Bool ?? true
  }
  /// The tools a program may call: no do, finish, screenshot, Mac or settings tools.
  static let tools: Set<String> = [
    "list_tabs", "open_tab", "navigate", "read", "click", "fill", "select", "key", "scroll", "back",
    "wait", "close_tab", "fetch",
  ]
  /// Codex stops waiting for a browser tool after 25 s and the helper's socket after 30 s, so no
  /// step starts after `soft` seconds and the call returns at `hard` whatever the program does.
  static let soft = 18.0, hard = 23.0, maxSteps = 60, maxLog = 8000

  private typealias Terminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
  private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, Terminate?, UnsafeMutableRawPointer?) -> Void
  /// JavaScriptCore's CPU limit for one entry into a context (exported; JSContextRefPrivate.h): a
  /// `while (true) {}` stops with "JavaScript execution terminated." and the context stays usable.
  private static let limitCPU: SetLimit? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit")
    .map { unsafeBitCast($0, to: SetLimit.self) }

  private var context: JSContext!
  private var pending: CheckedContinuation<[String: Any], Never>?
  private var call: Call?
  private var run = 0, steps = 0, inflight = 0
  private var started = Date.distantPast
  private var log: [String] = [], logSize = 0
  /// The tab the program used last: agents pass it to finish as result_tab.
  private var tab: String?

  init() { context = makeContext() }

  /// `tab` is the tab the agent used last, which `page` starts from.
  /// `pages` holds the last page each tab returned, so refs the model saw outside a program resolve.
  func run(_ code: String, tab: String?, tabs: [[String: Any]], pages: [String: [String: Any]], call: @escaping Call)
    async -> [String: Any]
  {
    guard pending == nil else { return ["error": "Another repl call is still running in this task."] }
    self.call = call
    run += 1
    (started, steps, log, logSize, self.tab) = (Date(), 0, [], 0, nil)
    let (context, run) = (self.context!, self.run)
    return await withCheckedContinuation { continuation in
      pending = continuation
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(Self.hard * 1_000_000_000))
        guard let self, self.run == run else { return }
        self.finish(nil, "Time is up after \(Int(Self.hard)) s.", nil)
      }
      context.evaluateScript("__tabID = \(jsonString(tab ?? NSNull())); __tabList = \(jsonString(tabs)); __seed(\(jsonString(pages)))")
      context.evaluateScript("__finish((async () => {\n" + code + "\n})())")
    }
  }

  private func makeContext() -> JSContext {
    let context = JSContext()!
    Self.limitCPU?(JSContextGetGroup(context.jsGlobalContextRef), 2, nil, nil)
    // Syntax errors and stopped loops; errors inside the program arrive through __done.
    context.exceptionHandler = { [weak self] context, error in
      guard let self, context === self.context, let error else { return }
      let line = error.objectForKeyedSubscript("line").toInt32()
      self.finish(nil, error.toString() + (line > 1 ? " (line \(line - 1))" : ""), nil)
    }
    let host: @convention(block) (String, String) -> JSValue = { [weak self] name, json in
      let context = JSContext.current()!
      guard let self, context === self.context else { return Self.rejected("This program has ended.", context) }
      return self.host(name, json, context)
    }
    let done: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> Void = { [weak self] value, error, page, tab in
      guard let self, JSContext.current() === self.context else { return }
      self.tab = tab.isString ? tab.toString() : nil
      self.finish(value.isString ? value.toString() : nil, error.isString ? error.toString() : nil,
        page.isString ? page.toString() : nil)
    }
    let print: @convention(block) (String) -> Void = { [weak self] line in
      guard let self, JSContext.current() === self.context, self.pending != nil, self.logSize < Self.maxLog else { return }
      let kept = String(line.prefix(Self.maxLog - self.logSize))
      self.logSize += kept.count
      self.log.append(kept + (self.logSize >= Self.maxLog ? "\n[log cut at \(Self.maxLog) characters]" : ""))
    }
    // URL is not part of JavaScriptCore; programs that resolve links use it, so Foundation parses.
    let parse: @convention(block) (String, String) -> String = { input, base in
      guard let u = URL(string: input, relativeTo: base.isEmpty ? nil : URL(string: base))?.absoluteURL,
        let scheme = u.scheme, let c = URLComponents(url: u, resolvingAgainstBaseURL: false)
      else { return "" }
      let host = c.host ?? "", port = c.port.map { ":\($0)" } ?? ""
      return jsonString([
        "href": u.absoluteString, "protocol": scheme + ":", "hostname": host, "host": host + port,
        "port": String(port.dropFirst()), "pathname": c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath,
        "search": c.percentEncodedQuery.map { "?" + $0 } ?? "", "hash": c.percentEncodedFragment.map { "#" + $0 } ?? "",
        "origin": scheme + "://" + host + port,
      ])
    }
    context.setObject(parse, forKeyedSubscript: "__url" as NSString)
    context.setObject(host, forKeyedSubscript: "__call" as NSString)
    context.setObject(done, forKeyedSubscript: "__done" as NSString)
    context.setObject(print, forKeyedSubscript: "__log" as NSString)
    context.evaluateScript(Self.prelude)
    return context
  }

  private static func rejected(_ message: String, _ context: JSContext) -> JSValue {
    JSValue(newPromiseRejectedWithReason: JSValue(newErrorFromMessage: message, in: context), in: context)
  }

  private func host(_ name: String, _ json: String, _ context: JSContext) -> JSValue {
    guard let call, pending != nil else { return Self.rejected("This program has ended.", context) }
    guard Date().timeIntervalSince(started) < Self.soft else {
      return Self.rejected(
        "Time is up: no step starts after \(Int(Self.soft)) s. Values on globalThis are kept; call repl again to go on.", context)
    }
    let operation: () async throws -> String
    if name == "choose" {
      operation = { try await Self.choose(json) }
    } else if name == "sleep" {
      let ms = min(max(Double(json) ?? 0, 0), 5000)
      operation = { try await Task.sleep(nanoseconds: UInt64(ms * 1_000_000)); return "null" }
    } else {
      guard Self.tools.contains(name) else { return Self.rejected("\(name) is not available in repl.", context) }
      guard steps < Self.maxSteps else {
        return Self.rejected("Step limit: at most \(Self.maxSteps) steps per call. Call repl again to go on.", context)
      }
      steps += 1
      let arguments = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
      operation = { jsonString(try await call(name, arguments)) }
    }
    inflight += 1
    return JSValue(newPromiseIn: context) { resolve, reject in
      Task { @MainActor [weak self] in
        let outcome: Result<String, Error>
        do { outcome = .success(try await operation()) } catch { outcome = .failure(error) }
        // A program that ended with this step still running got a new context (finish).
        guard let self, context === self.context else { return }
        self.inflight -= 1
        switch outcome {
        case .success(let text): resolve?.call(withArguments: [text])
        case .failure(let error):
          reject?.call(withArguments: [JSValue(newErrorFromMessage: error.localizedDescription, in: context) as Any])
        }
      }
    }
  }

  /// `choose(question, options)`: one Jev decision (fast steps) inside a program, in place of a
  /// model turn. Needs fast steps on; the program sends only what it passes in, redacted.
  private static func choose(_ json: String) async throws -> String {
    guard FastSteps.available else {
      throw SereinError.invalid("choose needs fast steps (Jev), which are off. Decide in the program or return what you found.")
    }
    let input = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    let question = input["question"] as? String ?? "", options = Array((input["options"] as? [String] ?? []).prefix(40))
    guard !question.isEmpty, options.count >= 2 else { throw SereinError.invalid("choose needs a question and at least 2 options.") }
    var criteria: [String: String] = [:]
    for (i, option) in options.enumerated() { criteria["o\(i)"] = String(option.prefix(300)) }
    let state = AgentPrivacy.sanitize(["question": question, "context": input["context"] ?? NSNull()])
    let (answers, _) = try await FastSteps.ask(
      state: state as? [String: Any] ?? [:],
      questions: ["pick": ["type": "choice", "criteria": criteria, "instructions": ["rules": question]]])
    guard let pick = answers["pick"] as? [String: Any], let id = pick["choice"] as? String, let i = Int(id.dropFirst()),
      options.indices.contains(i)
    else { throw SereinError.invalid("Jev gave no usable choice.") }
    return jsonString(["choice": options[i], "index": i, "confidence": pick["confidence"] ?? NSNull()])
  }

  private func finish(_ value: String?, _ error: String?, _ page: String?) {
    guard let pending else { return }
    self.pending = nil
    call = nil
    var out: [String: Any] = ["steps": steps, "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10]
    if let tab { out["tab"] = tab }
    if !log.isEmpty { out["log"] = log.joined(separator: "\n") }
    // Aside caps a call's output at 16 KB: log 8,000, result 6,000, an error's page about 2,000.
    if let value {
      out["result"] = value.count > 6000 ? String(value.prefix(6000)) + " [cut]"
        : (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) ?? value
    }
    if let error {
      out["error"] = error
      if let page, let object = try? JSONSerialization.jsonObject(with: Data(page.utf8)) { out["page"] = object }
    }
    if inflight > 0 {
      // A step still running would land in the next program, so that one gets a fresh context.
      context = makeContext()
      inflight = 0
      out["note"] = "A step was still running when this call ended, so globalThis starts empty on the next call."
    }
    pending.resume(returning: out)
  }

  /// The program's globals. Pages stay here: an action returns the page after it, which the next
  /// target lookup uses, so a program never pays a read it does not need.
  private static let prelude = #"""
    const __last = {}, __snaps = {}, __byRef = {};
    let __tabID = null, __tabList = [];
    const __show = v => { if (typeof v === 'string') return v; try { return JSON.stringify(v); } catch { return String(v); } };
    globalThis.console = { log: (...a) => __log(a.map(__show).join(' ')) };
    console.info = console.warn = console.error = console.debug = console.log;
    const log = console.log;
    // Refs change after every action. Each ref seen is kept with its role, words and place among
    // equal elements, so an older ref still finds its element on the newer page (Tab.ref).
    function __remember(p) {
      const seen = {};
      for (const e of p.elements ?? []) {
        if (!e.ref) continue;
        const k = e.role + '\u0000' + (e.label ?? '');
        __byRef[e.ref] = [e.role, e.label ?? '', seen[k] = (seen[k] ?? -1) + 1];
      }
    }
    function __seed(pages) { for (const [id, p] of Object.entries(pages)) { __last[id] = p; __remember(p); } }
    async function __tool(name, args) {
      const r = JSON.parse(await __call(name, JSON.stringify(args)));
      const p = r && (r.page || (r.elements ? r : null));
      if (p && p.tab) { __last[p.tab] = p; __tabID = p.tab; __remember(p); }
      if (name === 'open_tab' && r.tab) __tabList.push({ tab: r.tab, url: args.url });
      if (name === 'close_tab') __tabList = __tabList.filter(t => t.tab !== args.tab);
      return r;
    }
    const __norm = s => String(s ?? '').replace(/\s+/g, ' ').trim().toLowerCase();
    const __isRef = s => typeof s === 'string' && /^[ex][A-Za-z0-9-]*(_\d+)+$/.test(s);
    // Rows name tags (input, a, select); programs often ask for ARIA roles.
    const __roles = { textbox: ['input', 'textarea', 'textbox'], searchbox: ['input', 'textbox'], spinbutton: ['input'],
      combobox: ['select', 'input', 'combobox'], listbox: ['select', 'listbox'], button: ['button', 'input', 'clickable'],
      link: ['a', 'link'], checkbox: ['input', 'checkbox'], radio: ['input', 'radio'], switch: ['input', 'switch'], option: ['option'] };
    const __roleOK = (e, want) => { const r = __norm(e.role); return r.includes(want) || (__roles[want] ?? []).includes(r); };
    const __line = e => `${e.role} "${e.label ?? ''}"${e.value != null ? ` value="${e.value}"` : ''}${e.checked ? ' [checked]' : ''} ref=${e.ref}`;
    class Tab {
      constructor(id) { this.id = id; }
      get page() { return __last[this.id]; }
      get url() { return this.page?.url; }
      get title() { return this.page?.title; }
      get text() { return this.page?.text ?? ''; }
      get elements() { return (this.page?.elements ?? []).filter(e => e.ref); }
      find(target, options = {}) {
        if (__isRef(target)) return this.elements.find(e => e.ref === target) ?? null;
        const want = target && typeof target === 'object' ? target : { name: target, ...options };
        const name = __norm(want.name ?? want.label ?? want.text);
        const role = want.role ? __norm(want.role) : null;
        const pool = this.elements.filter(e => e.ref && (!role || __roleOK(e, role)));
        const tiers = [e => __norm(e.label) === name, e => __norm(e.label).startsWith(name), e => __norm(e.label).includes(name)];
        for (const tier of tiers) {
          const hits = name ? pool.filter(tier) : pool;
          if (hits.length) return hits[want.nth ?? 0] ?? null;
        }
        return null;
      }
      async ref(target) {
        if (!this.page) await this.read();
        if (__isRef(target)) {
          const old = __byRef[target];
          if (this.elements.some(e => e.ref === target) || !old) return target;
          return this.elements.filter(e => e.role === old[0] && (e.label ?? '') === old[1])[old[2]]?.ref ?? target;
        }
        const hit = this.find(target);
        if (hit) return hit.ref;
        const seen = this.elements.slice(0, 40).map(e => `${e.role} "${e.label}"`).join(', ');
        throw new Error(`No element matches ${JSON.stringify(target)} on ${this.url}. Elements: ${seen}`);
      }
      // Every method returns the page after it; an action adds its result.
      async __page(name, args) { const r = await __tool(name, { tab: this.id, ...args }); return r.page ? { ...r.page, result: r.result } : r; }
      read(o = {}) { return this.__page('read', o); }
      go(url) { return this.__page('navigate', { url: String(url) }); }
      async click(t) { return this.__page('click', { ref: await this.ref(t) }); }
      async fill(t, text, o = {}) { return this.__page('fill', { ref: await this.ref(t), text: String(text), ...o }); }
      async select(t, value) {
        // A list is labelled by its options' text, so when the words miss, the one list that has
        // the value is meant.
        if (!__isRef(t) && !this.find(t)) {
          if (!this.page) await this.read();
          const v = __norm(value), lists = this.elements.filter(e => (e.options ?? []).some(o => __norm(o.label) === v || __norm(o.value) === v));
          if (lists.length === 1) t = lists[0].ref;
        }
        return this.__page('select', { ref: await this.ref(t), value: String(value) });
      }
      async press(t, key) { return this.__page('key', { ref: await this.ref(t), key }); }
      scroll(direction = 'down') { return this.__page('scroll', { direction }); }
      back() { return this.__page('back', {}); }
      wait() { return this.__page('wait', {}); }
      close() { return __tool('close_tab', { tab: this.id }); }
      async snapshot({ fresh = false } = {}) {
        if (fresh || !this.page) await this.read();
        const tree = this.elements.map(__line), key = l => l.replace(/ ref=\S+$/, '');
        const old = new Map();
        for (const l of __snaps[this.id] ?? []) old.set(l, (old.get(l) ?? 0) + 1);
        __snaps[this.id] = tree.map(key);
        const diff = [];
        for (const l of tree) { const k = key(l), n = old.get(k) ?? 0; if (n) old.set(k, n - 1); else diff.push('+ ' + l); }
        for (const [l, n] of old) for (let i = 0; i < n; i++) diff.push('- ' + l);
        return { url: this.url, title: this.title, tree: tree.join('\n'), diff: diff.join('\n') };
      }
    }
    const tab = t => new Tab(t && typeof t === 'object' ? (t.id ?? t.tab) : t);
    Object.defineProperty(globalThis, 'page', { get: () => (__tabID ? new Tab(__tabID) : null), configurable: true });
    async function openTab(url) { return new Tab((await __tool('open_tab', { url: String(url) })).tab); }
    // Synchronous: programs write tabs()[0]. Serein passes the task's tabs in at each call.
    function tabs() { return __tabList.map(t => Object.assign(new Tab(t.tab), { info: t })); }
    // ponytail: regex HTML to text (scripts, styles and tags out, blocks to lines, common entities);
    // a page that needs its scripts to show content needs a tab.
    const __plain = html => String(html)
      .replace(/<(script|style|noscript|template)[\s\S]*?<\/\1>/gi, ' ').replace(/<!--[\s\S]*?-->/g, ' ')
      .replace(/<(br|\/title|\/p|\/div|\/li|\/tr|\/h[1-6]|\/td|\/th|\/article|\/section|\/header|\/footer)[^>]*>/gi, '\n')
      .replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&#0?39;|&apos;/g, "'").replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n))
      .replace(/&pound;/g, '£').replace(/&amp;/g, '&').replace(/[ \t]+/g, ' ').replace(/\s*\n\s*/g, '\n').trim();
    async function fetch(url) {
      const r = await __tool('fetch', { url: String(url) });
      return { ...r, ok: r.status >= 200 && r.status < 300, text: async () => r.body, json: async () => JSON.parse(r.body),
        pageText: () => __plain(r.body) };
    }
    const sleep = ms => __call('sleep', String(ms)).then(() => undefined);
    async function choose(question, options, context) {
      return JSON.parse(await __call('choose', JSON.stringify({ question: String(question), options: options.map(String), context })));
    }
    globalThis.setTimeout = (fn, ms = 0, ...a) => { sleep(ms).then(() => fn(...a)); return 0; };
    globalThis.clearTimeout = () => {};
    class URLSearchParams {
      constructor(init = '') {
        this._p = [];
        for (const part of String(init).replace(/^\?/, '').split('&').filter(Boolean)) {
          const i = part.indexOf('='), d = s => decodeURIComponent(s.replace(/\+/g, ' '));
          this._p.push(i < 0 ? [d(part), ''] : [d(part.slice(0, i)), d(part.slice(i + 1))]);
        }
      }
      get(k) { return this._p.find(p => p[0] === k)?.[1] ?? null; }
      getAll(k) { return this._p.filter(p => p[0] === k).map(p => p[1]); }
      has(k) { return this._p.some(p => p[0] === k); }
      append(k, v) { this._p.push([String(k), String(v)]); }
      delete(k) { this._p = this._p.filter(p => p[0] !== k); }
      set(k, v) { this.delete(k); this.append(k, v); }
      entries() { return this._p[Symbol.iterator](); }
      [Symbol.iterator]() { return this.entries(); }
      toString() { return this._p.map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&'); }
    }
    class URL {
      constructor(input, base) {
        const parts = __url(String(input), base === undefined ? '' : String(base));
        if (!parts) throw new TypeError('Invalid URL: ' + input);
        Object.assign(this, JSON.parse(parts));
        this.searchParams = new URLSearchParams(this.search);
      }
      toString() { return this.href; }
      toJSON() { return this.href; }
    }
    const __short = p => JSON.stringify({ url: p.url, title: p.title, tab: p.tab, text: String(p.text ?? '').slice(0, 1000), elements: (p.elements ?? []).slice(0, 30).map(__line) });
    function __finish(p) {
      p.then(v => __done(v === undefined ? null : __show(v), null, null, __tabID),
        e => __done(null, String(e && e.message ? e.message : e), __tabID && __last[__tabID] ? __short(__last[__tabID]) : null, __tabID));
    }
    """#
}
