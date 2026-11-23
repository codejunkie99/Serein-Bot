import AppKit
import Combine
import SereinCore
import SwiftUI
import WebKit

/// Hold a key while Serein is frontmost, speak, release: the words land where the cursor is.
/// (Holding the Ask Serein key from any app is `RelayController.summonPressed`, which sends the
/// words to an assistant instead.)
/// Recognition is Apple Speech with on-device recognition required (see Dictation). No model download.
@MainActor final class PushToTalk: ObservableObject {
  static let shared = PushToTalk()
  private weak var browser: BrowserModel?
  private weak var agent: AgentModel?
  private var monitor: Any?
  private var machine = TalkKeyMachine(key: .fn)
  private let dictation = Dictation()
  private let hud = TalkHUD()
  private var heldSince = Date()
  private var recordingURL: URL?
  private var busy = false
  /// Click-to-talk from the composer: the words go to this closure instead of the focused field.
  private var clickInsert: ((String) -> Void)?
  @Published private(set) var clickListening = false
  @Published private(set) var clickWorking = false
  private var errorWatch: AnyCancellable?
  private var micWatch: AnyCancellable?
  /// True from key-down (or the mic click) until release or cancel: the only time the mic may be on.
  private var listening = false
  /// Bumped by every begin, release and cancel; a delayed start checks it is still current.
  private var session = 0

  private init() {
    // The microphone is never live without the HUD: a start that lands after the user let go
    // or cancelled is stopped at once.
    micWatch = dictation.$recording.removeDuplicates().sink { [weak self] on in
      guard on, let self else { return }
      DispatchQueue.main.async {
        if !self.listening, self.dictation.recording { self.dictation.stop() }
      }
    }
  }

  static var enabled: Bool { UserDefaults.standard.bool(forKey: TalkKey.enabledKey) }
  static var key: TalkKey {
    TalkKey(rawValue: UserDefaults.standard.string(forKey: TalkKey.defaultsKey) ?? "") ?? .fn
  }
  /// Fn dictates here right now, so it does not also call Serein. Matches what `begin` accepts.
  static var ownsFn: Bool {
    guard enabled, key == .fn, NSApp.isActive, let window = NSApp.keyWindow else { return false }
    return !(window is NSPanel)
  }
  static var recordingsDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Serein/Recordings")
  }
  static var recordings: TalkRecordingStore { TalkRecordingStore(directory: recordingsDirectory) }

  func install(browser: BrowserModel, agent: AgentModel) {
    self.browser = browser
    self.agent = agent
    Self.purgeOldRecordings()
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      self?.handle(event)
      return event
    }
  }

  /// Composer mic: click, speak, click again. Shares the push-to-talk pipeline (recognition, proofreading,
  /// private-tab rules, the HUD, optional recording); only delivery differs. Works without the hold-key setting.
  func toggleClickToTalk(insert: @escaping (String) -> Void) {
    if clickListening {
      release(minimumHold: 0)
      return
    }
    guard !busy, clickInsert == nil else { return }
    clickInsert = insert
    if !begin(clickMode: true) { clickInsert = nil }
  }

  private func handle(_ event: NSEvent) {
    // Changing focus during a hold forfeits recording retention for the whole utterance.
    if listening && !clickListening && [.keyDown, .leftMouseDown, .rightMouseDown].contains(event.type) {
      discardRecording()
    }
    guard event.type == .flagsChanged || event.type == .keyDown else { return }
    guard Self.enabled, NSApp.isActive, !busy, !clickListening else { return }
    if machine.key != Self.key { machine = TalkKeyMachine(key: Self.key) }
    let result: TalkKeyEvent?
    if event.type == .flagsChanged {
      result = machine.flagsChanged(
        keyCode: event.keyCode,
        flags: event.modifierFlags.rawValue)
    } else {
      result = machine.keyDown(keyCode: event.keyCode)
    }
    switch result {
    case .down: begin()
    case .up: release()
    case .cancelled: cancel()
    case nil: break
    }
  }

  @discardableResult
  private func begin(clickMode: Bool = false) -> Bool {

    guard let window = NSApp.keyWindow, !(window is NSPanel) else {
      machine = TalkKeyMachine(key: Self.key)
      return false
    }
    // A session left over from before never carries into this one (start would toggle it off).
    if dictation.recording { dictation.stop() }
    session += 1
    let current = session
    heldSince = Date()
    recordingURL = nil
    dictation.recordTo = nil
    // A failure from an earlier attempt must not end this one.
    dictation.error = nil
    hud.show(over: window, dictation: dictation, clickMode: clickMode)
    // Proofreading's helper starts while the user speaks.
    if FeaturePolicy.isEnabled(.proofreading) { agent?.prewarmHelper() }
    listening = true
    clickListening = clickMode
    errorWatch = clickMode
      ? dictation.$error.dropFirst().compactMap { $0 }.sink { [weak self] message in
        // Permission or recognizer failure: stop listening and say why.
        guard let self, self.clickListening else { return }
        self.cancel()
        self.hud.notice(message)
      } : nil
    guard listening, current == session else { return false }
    let keep = UserDefaults.standard.bool(forKey: TalkKey.keepKey) && !isPrivate(window)
    guard keep, !clickMode else {
      // The composer is never a sensitive field.
      if keep { prepareRecording() }
      dictation.start { _ in }
      return true
    }
    // Keeping recordings: find the target first, so speech for a password or code field is
    // never written to disk.
    Task {
      let target = await resolveTarget(window)
      guard listening, current == session else { return }
      if !target.isSensitive { prepareRecording() }
      dictation.start { _ in }
    }
    return true
  }

  private func prepareRecording() {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    recordingURL = Self.recordingsDirectory.appendingPathComponent(stamp + "-" + UUID().uuidString + ".caf")
    dictation.recordTo = recordingURL
  }

  /// Stops click-to-talk without inserting anything (sending the message, leaving the composer).
  func stopClickToTalk() {
    guard clickListening else { return }
    cancel()
  }

  private func cancel() {
    listening = false
    session += 1
    dictation.stop()
    hud.hide()
    discardRecording()
    clickListening = false
    clickInsert = nil
    errorWatch = nil
  }

  private func release(minimumHold: TimeInterval = 0.25) {
    // Only a press still listening has words to deliver (cancelled or stopped ones do not).
    guard listening else { return }
    // A quick tap is not a request to talk.
    guard Date().timeIntervalSince(heldSince) > minimumHold else { return cancel() }
    busy = true
    listening = false
    session += 1
    let current = session
    let insert = clickInsert
    clickInsert = nil
    clickListening = false
    errorWatch = nil
    clickWorking = insert != nil
    let window = NSApp.keyWindow
    let privateFocus = isPrivate(window)
    Task {
      defer {
        busy = false
        clickWorking = false
      }
      hud.setPhase(.working("Writing it down…"))
      var text = await dictation.finish().trimmingCharacters(in: .whitespacesAndNewlines)
      // Discard a recording from a superseded session.
      guard current == session else { hud.hide(); return discardRecording() }
      let segments = dictation.segments
      // Where the words go is decided before anything else: speech for a password, card or
      // code field is never kept, never proofread and never shown in the recordings list.
      let target: TalkTarget? = insert == nil ? await resolveTarget(window) : nil
      guard current == session else { hud.hide(); return discardRecording() }
      let sensitive = target?.isSensitive == true
      if sensitive || privateFocus { discardRecording() }
      guard !text.isEmpty else {
        discardRecording()
        hud.notice(
          dictation.error
            ?? (insert == nil ? "Nothing was heard. Hold the key while you talk." : "Nothing was heard. Try again."))
        return
      }
      if !sensitive {
        text = await proofread(text, segments: segments, privateFocus: privateFocus)
        guard current == session else { hud.hide(); return discardRecording() }
      }
      if let insert {
        insert(text)
        finishDelivery("Added to your message.", text: text)
      } else if let target {
        await deliver(text, to: target, window: window)
      }
    }
  }

  private func discardRecording() {
    dictation.audio.discard()
    dictation.recordTo = nil
    if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
    recordingURL = nil
  }

  // MARK: Proofreading

  private func proofread(_ text: String, segments: [TalkSegment], privateFocus: Bool) async -> String {
    guard let agent else { return text }
    // Dictation waits at most eight seconds; the helper started when the user began to speak.
    // A slower answer keeps the dictated text.
    let executable = agent.helperExecutable
    guard
      TalkProofread.shouldProofread(
        segments: segments, text: text, featureEnabled: FeaturePolicy.isEnabled(.proofreading),
        privateTab: privateFocus, hasAgent: executable != nil),
      let executable
    else { return text }
    hud.setPhase(.working("Tidying…"))
    let prompt = TalkProofread.prompt(
      text: text, low: TalkProofread.lowSegments(segments), language: dictation.language)
    let provider = agent.helperProvider
    let model = agent.helperModel
    let runner = StructuredAgent()
    let reply: String? = await withTaskGroup(of: String?.self) { group in
      group.addTask {
        try? await runner.run(
          executable: executable, provider: provider, model: model, prompt: prompt)
      }
      group.addTask {
        // Cancelled when the reply wins: then nothing is stopped.
        do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return nil }
        runner.cancel()
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    // On timeout, failure or a reply that drifted from what was said, keep the raw text.
    guard let reply, let fixed = TalkProofread.validate(reply: reply, original: text) else {
      return text
    }
    return fixed
  }

  // MARK: Delivery

  private struct Environment: TalkEnvironment {
    var native: TalkNativeFocus
    var page: @Sendable () async -> TalkPageElement?
    func nativeFocus() -> TalkNativeFocus { native }
    func pageElement() async -> TalkPageElement? { await page() }
  }

  /// The tab on screen in `window`: a secondary window's own active tab, else the main window's.
  private func tab(in window: NSWindow?) -> BrowserTab? {
    browser?.active
  }
  /// A private window counts as private even when it has no tab yet.
  private func isPrivate(_ window: NSWindow?) -> Bool {
    tab(in: window)?.privateMode == true
  }

  private func nativeFocus(in window: NSWindow?) -> TalkNativeFocus {
    guard let responder = window?.firstResponder else { return .none }
    if let text = responder as? NSTextView {
      if text.isFieldEditor {
        // A secure field's editor has the field itself as its delegate.
        return .textField(secure: text.delegate is NSSecureTextField)
      }
      return text.isEditable ? .textField(secure: false) : .none
    }
    if let view = responder as? NSView, let web = tab(in: window)?.web,
      view === web || view.isDescendant(of: web)
    {
      return .webView
    }
    return .none
  }

  private func resolveTarget(_ window: NSWindow?) async -> TalkTarget {
    let native = nativeFocus(in: window)
    let target = tab(in: window)
    let env = Environment(native: native) { [weak target] in
      guard let tab = target else { return nil }
      return await Self.probe(tab)
    }
    return await TalkTargetResolver.resolve(env)
  }

  private func deliver(_ text: String, to resolved: TalkTarget, window: NSWindow?) async {
    let target = tab(in: window)
    switch resolved {
    case .nativeField:
      if let editor = window?.firstResponder as? NSTextView {
        editor.insertText(text, replacementRange: editor.selectedRange())
        finishDelivery("Inserted.", text: text)
      } else {
        copy(text, "Copied. Paste it with ⌘V.")
      }
    case .pageElement:
      if let tab = target, await Self.insert(text, into: tab) {
        finishDelivery("Inserted.", text: text)
      } else {
        copy(text, "The page moved on, so I copied it. Paste it with ⌘V.")
      }
    case .clipboard(.sensitiveField):
      copy(text, "That field is private, so I copied it instead. Paste it with ⌘V.", keep: false)
    case .clipboard(.noField):
      copy(text, "No field is focused. Copied what you said. Paste it with ⌘V.")
    }
  }

  private func finishDelivery(_ message: String, text: String, keep: Bool = true) {
    // The transcript is not kept unless the user opted into keeping recordings.
    if !keep || !UserDefaults.standard.bool(forKey: TalkKey.keepKey) {
      discardRecording()
    } else if let url = recordingURL, dictation.audio.save(to: url) {
      Self.recordings.add(
        TalkRecording(
          id: url.deletingPathExtension().lastPathComponent, date: heldSince,
          duration: Date().timeIntervalSince(heldSince), text: text))
      NotificationCenter.default.post(name: .sereinRecordingsChanged, object: nil)
    }
    dictation.audio.discard()
    recordingURL = nil
    hud.notice(message)
  }

  private func copy(_ text: String, _ message: String, keep: Bool = true) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    finishDelivery(message, text: text, keep: keep)
  }

  // MARK: Page access

  /// Shared by both scripts: the focused element, through shadow roots and same-origin frames.
  private static let focusedJS = """
    const deep = () => {
      let a = document.activeElement;
      for (let i = 0; i < 10 && a; i++) {
        if (a.shadowRoot && a.shadowRoot.activeElement) { a = a.shadowRoot.activeElement; continue; }
        if (a.tagName === 'IFRAME' || a.tagName === 'FRAME') {
          try { const d = a.contentDocument; if (d && d.activeElement) { a = d.activeElement; continue; } } catch (_) {}
        }
        break;
      }
      return a;
    };
    """

  private static func probe(_ tab: BrowserTab) async -> TalkPageElement? {
    guard tab.owner == nil else { return nil }
    let source = """
      (() => {
        \(focusedJS)
        const e = deep();
        if (!e || e === document.body || e === document.documentElement) return null;
        const tag = (e.tagName || '').toLowerCase();
        const type = (e.getAttribute('type') || (tag === 'input' ? 'text' : '')).toLowerCase();
        const textual = ['text','search','url','email','tel','number','password','',
          'date','datetime-local','month','week','time'].includes(type);
        const editable = !e.disabled && !e.readOnly &&
          ((tag === 'input' && textual) || tag === 'textarea' || e.isContentEditable === true);
        let label = [e.getAttribute('aria-label'), e.getAttribute('placeholder'), e.getAttribute('title')].join(' ');
        try { if (e.labels) label += ' ' + Array.from(e.labels).map(l => l.textContent).join(' '); } catch (_) {}
        globalThis.__sereinTalkEl = e;
        return JSON.stringify({ editable, tag, type, autocomplete: e.getAttribute('autocomplete') || '',
          name: e.getAttribute('name') || '', id: e.id || '', label: label.slice(0, 300) });
      })()
      """
    guard let raw = try? await tab.script(source) as? String,
      let data = raw.data(using: .utf8)
    else { return nil }
    return try? JSONDecoder().decode(TalkPageElement.self, from: data)
  }

  private static func insert(_ text: String, into tab: BrowserTab) async -> Bool {
    let source = """
      (() => {
        \(focusedJS)
        const e = globalThis.__sereinTalkEl;
        globalThis.__sereinTalkEl = null;
        if (!e || e !== deep()) return false;
        const text = \(jsonString(text));
        e.focus();
        let ok = false;
        try { ok = e.ownerDocument.execCommand('insertText', false, text); } catch (_) {}
        if (!ok && 'value' in e) {
          const start = e.selectionStart ?? e.value.length, end = e.selectionEnd ?? start;
          const proto = Object.getPrototypeOf(e);
          const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
          const next = e.value.slice(0, start) + text + e.value.slice(end);
          if (setter) setter.call(e, next); else e.value = next;
          e.setSelectionRange?.(start + text.length, start + text.length);
          e.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
          e.dispatchEvent(new Event('change', { bubbles: true }));
          ok = true;
        }
        return ok;
      })()
      """
    return (try? await tab.script(source)) as? Bool ?? false
  }

  // MARK: Recordings

  static func purgeOldRecordings(days: Int = TalkRecordingStore.retentionDays) {
    recordings.purge(days: days)
  }
  static func deleteAllRecordings() {
    recordings.removeAll()
    NotificationCenter.default.post(name: .sereinRecordingsChanged, object: nil)
  }
}

extension Notification.Name {
  static let sereinRecordingsChanged = Notification.Name("serein.talk.recordingsChanged")
}

// MARK: HUD

@MainActor final class TalkHUDModel: ObservableObject {
  enum Phase: Equatable { case listening, working(String), notice(String) }
  @Published var phase = Phase.listening
  @Published var levels = [Float](repeating: 0, count: 14)
  @Published var clickMode = false
  func push(_ level: Float) {
    levels.removeFirst()
    levels.append(level)
  }
}

@MainActor final class TalkHUD {
  private let model = TalkHUDModel()
  private var panel: NSPanel?
  private var hideTask: Task<Void, Never>?
  private var feed: Any?
  func show(over window: NSWindow, dictation: Dictation, clickMode: Bool = false) {
    hideTask?.cancel()
    model.phase = .listening
    model.clickMode = clickMode
    model.levels = [Float](repeating: 0, count: 14)
    if panel == nil {
      let p = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 52),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      p.isFloatingPanel = true
      p.level = .floating
      p.backgroundColor = .clear
      p.isOpaque = false
      p.hasShadow = true
      p.ignoresMouseEvents = true
      p.collectionBehavior = [.transient, .ignoresCycle]
      p.contentView = NSHostingView(rootView: TalkHUDView(model: model))
      panel = p
    }
    let frame = window.frame
    panel?.setFrameOrigin(NSPoint(x: frame.midX - 160, y: frame.minY + 56))
    panel?.orderFront(nil)
    feed = dictation.meter.$level.sink { [weak self] in self?.model.push($0) }
  }
  func setPhase(_ phase: TalkHUDModel.Phase) {
    model.phase = phase
    feed = nil
  }
  func notice(_ message: String) {
    feed = nil
    model.phase = .notice(message)
    hideTask?.cancel()
    hideTask = Task {
      try? await Task.sleep(nanoseconds: 3_200_000_000)
      if !Task.isCancelled { hide() }
    }
  }
  func hide() {
    feed = nil
    panel?.orderOut(nil)
  }
}

private struct TalkHUDView: View {
  @ObservedObject var model: TalkHUDModel
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.accessibilityReduceTransparency) var reduceTransparency
  var body: some View {
    HStack(spacing: 10) {
      switch model.phase {
      case .listening:
        HStack(spacing: 3) {
          ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
            Capsule().fill(p.accent).frame(width: 3, height: 5 + CGFloat(level) * 20)
          }
        }.frame(height: 26).animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: model.levels)
        Text(model.clickMode ? "Listening. Click the mic to finish." : "Listening. Let go to insert.")
          .font(UIStyle.meta)
      case .working(let text), .notice(let text):
        Image(systemName: "waveform").foregroundStyle(p.accent)
        Text(text).font(UIStyle.meta).lineLimit(2)
      }
    }
    .foregroundStyle(p.ink).padding(.horizontal, 14).padding(.vertical, 9)
    .frame(width: 320, height: 52, alignment: .leading)
    .background(
      reduceTransparency ? AnyShapeStyle(p.panel) : AnyShapeStyle(p.panel.opacity(0.94)),
      in: RoundedRectangle(cornerRadius: UIStyle.panelRadius)
    )
    .overlay(RoundedRectangle(cornerRadius: UIStyle.panelRadius).stroke(p.line))
    .accessibilityElement(children: .combine)
  }
}
