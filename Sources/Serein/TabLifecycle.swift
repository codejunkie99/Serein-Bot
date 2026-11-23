import SereinCore
import SwiftUI
import WebKit

extension BrowserTab {
  /// Notes each field that gets text by hand, in every frame, so `suspend` can tell an unsent
  /// draft from a hidden token or a field the page filled in itself. PageKit calls the same
  /// function when an agent types: that text is work the user has not seen yet.
  static let draftWatch = """
    (() => {
      if (globalThis.__sereinDrafts) return;
      const drafts = globalThis.__sereinDrafts = new Set(), seen = new WeakMap();
      const note = globalThis.__sereinDraft = field => {
        if (!(field instanceof Element) || seen.has(field)) return;
        const ref = new WeakRef(field);
        // The address when the typing began: `busyScript` uses it to see a search that ran.
        ref.began = location.href;
        seen.set(field, ref);
        drafts.add(ref);
      };
      addEventListener('input', e => { if (e.isTrusted) note(e.composedPath()[0]); }, true);
    })();
    """
  /// True while the page holds something sleeping would lose: text that was typed and not sent,
  /// a file picked for upload, sound that plays, or a picture-in-picture window. An emptied
  /// field is no draft, a ticked box or a chosen option is not text, and a muted clip is not
  /// being listened to. One-line text is not lost either when the address took it over after it
  /// was typed (a search that ran): the page comes back with it. The address must have changed
  /// since the typing began and must now carry exactly that text, as it did not before.
  static let busyScript = """
    (() => {
      const carried = address => {
        const found = [];
        try {
          const url = new URL(address);
          for (const value of url.searchParams.values()) found.push(value);
          if (url.hash.includes('=')) for (const value of new URLSearchParams(url.hash.slice(1)).values()) found.push(value);
          for (const part of url.pathname.split('/')) { try { found.push(decodeURIComponent(part)); } catch (_) {} }
        } catch (_) {}
        return found;
      };
      // Exact text: "ABC" is not kept by an address that holds "abc".
      const tookOver = (text, began) => !!began && began !== location.href
        && carried(location.href).includes(text) && !carried(began).includes(text);
      for (const ref of globalThis.__sereinDrafts || []) {
        const field = ref.deref();
        if (!field || !field.isConnected) continue;
        if (field instanceof HTMLInputElement) {
          if (['checkbox', 'radio', 'range', 'color'].includes(field.type)) continue;
          const text = field.value.trim();
          if (field.type === 'file' ? field.files.length : text !== '' && !tookOver(field.value, ref.began)) return true;
        } else if (field instanceof HTMLTextAreaElement) {
          if (field.value.trim() !== '') return true;
        } else if (field.isContentEditable) {
          if ((field.textContent || '').trim() !== '') return true;
        } else if (!(field instanceof HTMLSelectElement)) {
          // The typing went into something this script cannot read (a closed component).
          return true;
        }
      }
      // Long text that is not what the page first put there counts with no note too: Back
      // restores it without an event, and a script can put it there.
      for (const area of document.querySelectorAll('textarea')) {
        if (area.value !== area.defaultValue && area.value.trim() !== '') return true;
      }
      // An editor in an inline frame (about:blank or srcdoc): no script of ours runs in there.
      for (const frame of document.querySelectorAll('iframe')) {
        let inner = null;
        try { inner = frame.contentDocument; } catch (_) {}
        const body = inner && inner.body;
        if (body && (inner.designMode === 'on' || body.isContentEditable) && (body.textContent || '').trim() !== '') return true;
      }
      if (document.pictureInPictureElement) return true;
      return Array.from(document.querySelectorAll('audio,video')).some(e =>
        e.webkitPresentationMode === 'picture-in-picture' || (!e.paused && !e.ended && !e.muted && e.volume > 0));
    })()
    """
  /// Asks the page what a close would ask it. A page with unsaved work cancels the event; one
  /// that does not is unloaded straight after, as a close would do.
  static let closeProbe = """
    (() => {
      let event;
      try {
        event = document.createEvent('BeforeUnloadEvent');
        event.initEvent('beforeunload', false, true);
      } catch (_) { event = new Event('beforeunload', { cancelable: true }); }
      dispatchEvent(event);
      return event.defaultPrevented || (typeof event.returnValue === 'string' && event.returnValue !== '');
    })()
    """
  /// One frame's sessionStorage and, for the top frame, `window.name`: [origin, entries, name].
  static let storageProbe = """
    (() => {
      try {
        const entries = Object.entries(sessionStorage), name = window === top ? window.name : '';
        return entries.length || name ? [location.origin, JSON.stringify(Object.fromEntries(entries)), name] : null;
      } catch (_) { return null; }
    })()
    """
  /// The most sessionStorage a sleeping tab keeps, in UTF-16 units. Past this the page starts
  /// with empty storage, as it would in a new tab.
  static let storageLimit = 2_000_000

  /// A yes-or-no question to the page. The outer nil means no answer in five seconds; the inner
  /// nil means the script failed (for a frame: the frame is gone).
  private func ask(_ source: String, frame: WKFrameInfo? = nil) async -> Bool?? {
    await withTimeout(5) { [weak self] in (try? await self?.script(source, frame: frame)) as? Bool }
  }
  /// The script that gives each origin of this page its sessionStorage back in a new web view.
  private func storageScript() async -> String? {
    var byOrigin: [String: String] = [:]
    var top: (origin: String, name: String)?
    let frames: [WKFrameInfo?] = [nil] + self.frames.values.filter { !$0.isMainFrame }
    for frame in frames {
      let answer = await withTimeout(5) { [weak self] in
        (try? await self?.script(Self.storageProbe, frame: frame)) as? [String]
      }
      guard let found = answer ?? nil, found.count == 3 else { continue }
      if byOrigin[found[0]] == nil { byOrigin[found[0]] = found[1] }
      if frame == nil, !found[2].isEmpty { top = (found[0], found[2]) }
    }
    guard !byOrigin.isEmpty || top != nil,
      byOrigin.values.reduce(0, { $0 + $1.utf16.count }) + (top?.name.utf16.count ?? 0)
        <= Self.storageLimit,
      let saved = try? JSONSerialization.data(withJSONObject: byOrigin),
      let name = try? JSONSerialization.data(
        withJSONObject: [top?.origin ?? "", top?.name ?? ""])
    else { return nil }
    // Each origin gets back only what it had, and only into storage that is still empty.
    return """
      (() => {
        try {
          const saved = \(String(decoding: saved, as: UTF8.self)), [origin, name] = \(String(decoding: name, as: UTF8.self));
          const mine = saved[location.origin];
          if (mine && sessionStorage.length === 0) for (const [key, value] of Object.entries(JSON.parse(mine))) sessionStorage.setItem(key, value);
          if (window === top && name && location.origin === origin && !window.name) window.name = name;
        } catch (_) {}
      })();
      """
  }
  /// Sleeps the tab unless it is working for the user. `inUse` is asked again after the page
  /// answers, because the tab can come into view in the meantime.
  func suspend(unless inUse: () -> Bool = { false }) async {
    guard owner == nil, !privateMode, !loading, !sleeping, !address.isEmpty, !keepsAwake,
      !formResult
    else { return }
    guard web.cameraCaptureState == .none, web.microphoneCaptureState == .none else { return }
    // The page must say no: one that fails or does not answer counts as busy.
    guard (await ask(Self.busyScript) ?? nil) == false else { return }
    for frame in frames.values where !frame.isMainFrame {
      // A frame that is gone has nothing to lose. One that is slow to answer may have.
      guard let answer = await ask(Self.busyScript, frame: frame), answer != true else { return }
    }
    guard !loading, !sleeping, !inUse() else { return }
    // Asked once, of the page and then of each frame, as a close does. One that refuses keeps
    // the tab awake until the user next opens it.
    let refused = await ask(Self.closeProbe) ?? nil
    if refused == true { keepsAwake = true }
    guard refused == false else { return }
    for frame in frames.values where !frame.isMainFrame {
      // No answer in time: busy for this pass. A failed script: the frame is gone.
      guard let answer = await ask(Self.closeProbe, frame: frame) else { return }
      if answer == true {
        keepsAwake = true
        return
      }
    }
    guard !loading, !sleeping, !inUse() else { return }
    let storage = await storageScript()
    guard !loading, !sleeping, !inUse() else { return }
    unload(storage: storage)
  }
  /// Lets go of the page and its WebKit process; `wake` loads the page again where it was.
  func unload(storage: String? = nil) {
    guard !sleeping, !address.isEmpty else { return }
    sleepingAddress = address
    sleepingTitle = title
    sleepingStorage = storage
    // The answer to a sent form is not kept: to show it again WebKit would send the form again.
    sleepingState = formResult ? nil : web.interactionState
    sleeping = true
    discardPage()
  }
  /// A tab from the last session: it shows its title and loads when it is first opened.
  func rest(at address: String, title: String) {
    self.address = address
    self.title = title
    sleepingAddress = address
    sleepingTitle = title
    sleeping = true
  }
  func wake() {
    lastActive = Date()
    keepsAwake = false
    guard sleeping, let address = sleepingAddress else { return }
    sleeping = false
    sleepingAddress = nil
    error = nil
    endWake()
    if let script = sleepingStorage {
      web.configuration.userContentController.addUserScript(
        WKUserScript(
          source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false,
          in: Self.world))
      wakeScript = script
    }
    sleepingStorage = nil
    if let state = sleepingState {
      wakingAddress = address
      web.interactionState = state
    }
    sleepingState = nil
    // No saved state, or WebKit did not take it: load the address.
    if web.backForwardList.currentItem == nil {
      wakingAddress = nil
      try? navigate(address)
    }
  }
  /// The woken page has loaded, or failed: later pages get no saved storage and no form check.
  func endWake() {
    wakingAddress = nil
    guard let script = wakeScript else { return }
    wakeScript = nil
    let controller = web.configuration.userContentController
    let kept = controller.userScripts.filter { $0.source != script }
    controller.removeAllUserScripts()
    for other in kept { controller.addUserScript(other) }
  }
}
extension BrowserModel {
  /// True for a tab the user or a task is using now; such a tab never sleeps. The selected tab
  /// counts only while the browser shows it.
  func inUse(_ tab: BrowserTab) -> Bool {
    (tab.id == selected && section == ShellSection.browser)
      || tasks.values.contains { $0.tabs.contains { $0.id == tab.id } }
      // A popup and its opener talk through window.opener; sleep would cut the link.
      || tabs.contains { $0.opener === tab }
      || tab.opener.map { opener in tabs.contains { $0 === opener } } == true
  }
  /// Sleeps every background tab that has been idle for `idle` seconds and holds no unsent work.
  func sleepIdleTabs(idle: TimeInterval) async {
    if sleepPassRunning {
      sleepPassWaiting = min(sleepPassWaiting ?? idle, idle)
      return
    }
    sleepPassRunning = true
    defer { sleepPassRunning = false }
    var limit = idle
    while true {
      for tab in tabs where !inUse(tab) && Date().timeIntervalSince(tab.lastActive) >= limit {
        await tab.suspend(unless: { [weak self] in
          // Opened, handed to a task or closed while the page answered.
          guard let self else { return true }
          return self.inUse(tab) || !self.tabs.contains { $0 === tab }
        })
      }
      guard let next = sleepPassWaiting else { return }
      sleepPassWaiting = nil
      limit = next
    }
  }
  func startLifecycle() {
    lifecycle = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        guard !Task.isCancelled else { return }
        agentTabs.unloadIdle()
        let minutes = UserDefaults.standard.integer(forKey: "serein.sleepMinutes")
        if minutes > 0 { await sleepIdleTabs(idle: Double(minutes * 60)) }
      }
    }
    // Checks keep their background tabs whatever the Mac's memory does.
    guard !RunMode.checking else { return }
    // When macOS runs short of memory, background tabs sleep ahead of their timer: those idle
    // for five minutes at a warning, all of them when it is critical. "Never" in Settings still
    // means never.
    let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    pressure.setEventHandler { [weak self, weak pressure] in
      MainActor.assumeIsolated {
        let minutes = UserDefaults.standard.integer(forKey: "serein.sleepMinutes")
        guard minutes > 0, let level = pressure?.data else { return }
        let idle = level.contains(.critical) ? 0 : min(300, Double(minutes * 60))
        Task { await self?.sleepIdleTabs(idle: idle) }
      }
    }
    pressure.resume()
    memoryPressure = pressure
  }
  func applyRetention() {
    let days = UserDefaults.standard.integer(forKey: "serein.retentionDays")
    guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
    else { return }
    do {
      let files = try FileManager.default.contentsOfDirectory(
        at: library.root.appendingPathComponent("history"), includingPropertiesForKeys: nil)
      let key = Self.dayKey(cutoff)
      for file in files
      where file.pathExtension == "jsonl" && file.deletingPathExtension().lastPathComponent < key {
        try FileManager.default.removeItem(at: file)
      }
      historyClears += 1
      visits.removeAll { Self.dayKey($0.date) < key }
      pruneSemanticIndex()
      for day in Array(timelines.keys) where day < key { timelines.removeValue(forKey: day) }
      // From the folder, not `timelines`: an old day's description is read only when it shows.
      for file
        in (try? FileManager.default.contentsOfDirectory(
          at: library.root.appendingPathComponent("index/days"), includingPropertiesForKeys: nil)) ?? []
      where file.pathExtension == "json" && file.deletingPathExtension().lastPathComponent < key {
        try? FileManager.default.removeItem(at: file)
      }
    } catch { notice = error.localizedDescription }
  }
}
struct SitePermissionSettings: View {
  @ObservedObject var browser: BrowserModel
  @State private var permission = "deny"
  @Environment(\.palette) var p
  var origin: String {
    guard let url = URL(string: browser.active?.address ?? ""), let host = url.host else {
      return ""
    }
    return "\(url.scheme ?? "https")://\(host)" + (url.port.map { ":\($0)" } ?? "")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !origin.isEmpty {
        Text(origin).font(UIStyle.mono(12)).foregroundStyle(p.faint)
        SettingsPopUp("Camera and microphone", selection: $permission, choices: [
          SettingsChoice(value: "deny", label: "Deny"), SettingsChoice(value: "ask", label: "Ask"),
        ]).onAppear {
          permission = UserDefaults.standard.string(forKey: "serein.media." + origin) ?? "deny"
        }.onChange(of: permission) { _, v in
          UserDefaults.standard.set(v, forKey: "serein.media." + origin)
        }
      } else {
        Text("Open a page to manage its camera and microphone permission.").font(UIStyle.font(12))
          .foregroundStyle(p.secondary)
      }
      Text(
        "Agent-owned pages are always denied media access. Notifications and screen capture stay blocked."
      ).font(UIStyle.font(12)).foregroundStyle(p.secondary)
    }.font(UIStyle.font(13)).foregroundStyle(p.ink).controlSize(.small)
  }
}
