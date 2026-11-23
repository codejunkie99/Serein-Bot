import Foundation
import SereinCore

/// Cua Driver's MCP over one raw link connection into the built-in computer: the helper's
/// `--vsock` link runs `CuaDriverRelease.mcpCommand` as `serein` with the connection as its stdin
/// and stdout (VirtualMachineComputer.openStream), so there is no new port and no listener on
/// this Mac. Serein is the driver's only client and no agent sees its tools. The pure parts
/// (framing, the line cap, the closed tool set, the pinned schemas, Serein's words) are DriverWire.
/// Like HelperChannel: each request carries an id, each answer comes back under it, a request
/// with no answer in time fails on its own (a late answer is dropped), and the stream's end fails
/// every request still waiting. A line longer than `DriverWire.lineLimit` ends the stream.
final class DriverChannel {
  private var stream: ComputerStream?
  private let lock = NSLock()
  private var nextID = 1
  private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var lines = DriverWire.Lines()
  private var didEnd = false
  private var endHandler: (() -> Void)?

  func setEndHandler(_ handler: (() -> Void)?) {
    lock.lock()
    if didEnd {
      lock.unlock()
      handler?()
    } else {
      endHandler = handler
      lock.unlock()
    }
  }

  /// The callbacks a backend's stream is opened with (ComputerBackend.openStream).
  var sink: (Data) -> Void { { [weak self] data in self?.received(data) } }
  var ender: () -> Void { { [weak self] in self?.finish(closeStream: false) } }
  func attach(_ stream: ComputerStream) {
    lock.lock()
    if didEnd {
      lock.unlock()
      stream.close()
      return
    }
    self.stream = stream
    lock.unlock()
  }
  var isOpen: Bool {
    lock.lock(); defer { lock.unlock() }
    return stream.map { !$0.isClosed } ?? false
  }

  /// Opens the link and makes the handshake: `initialize` at Serein's revision, answered by the
  /// pinned driver; `notifications/initialized`; then `tools/list`, which must offer every tool
  /// Serein calls with every argument it sends. Any failure closes the link.
  @MainActor static func open(_ machine: ComputerBackend, command: [String]) async throws -> DriverChannel {
    let channel = DriverChannel()
    let stream = try await machine.openStream(command, stdin: true, onStdout: channel.sink, onEnd: channel.ender)
    channel.attach(stream)
    do {
      let hello = try await channel.send(timeout: 30) { DriverWire.initialize(id: $0) }
      if let refusal = DriverWire.handshakeRefusal(hello) { throw SereinError.invalid(refusal) }
      guard let initialized = DriverWire.initialized, channel.post(initialized) else { throw Self.closed }
      let tools = try await channel.send(timeout: 30) { DriverWire.request(id: $0, method: "tools/list", params: [:]) }
      if let refusal = DriverWire.inventoryRefusal(tools) { throw SereinError.invalid(refusal) }
    } catch {
      channel.setEndHandler(nil)
      channel.close()
      throw error
    }
    return channel
  }

  /// One tool of the closed set, and its answer read into typed parts (untrusted).
  func call(_ tool: DriverWire.Tool, _ arguments: [String: Any], timeout seconds: Int) async throws -> DriverWire.ToolAnswer {
    let result = try await send(timeout: seconds) { DriverWire.call(id: $0, tool, arguments) }
    guard let answer = DriverWire.toolAnswer(result) else { throw SereinError.invalid(DriverWire.unreadable(tool)) }
    return answer
  }

  static let closed = SereinError.invalid("The link to Cua Driver in Serein's computer closed.")

  private func received(_ data: Data) {
    lock.lock()
    let taken: [Data]
    do {
      taken = try lines.take(data)
    } catch {
      // Out of step: nothing sensible can follow, so the stream ends and every waiter fails.
      lock.unlock()
      close()
      return
    }
    lock.unlock()
    for line in taken { handle(DriverWire.message(line)) }
  }
  private func handle(_ message: DriverWire.Message) {
    switch message {
    case .result(let id, let result):
      resume(id, .success(result))
    case .failure(let id, let code):
      resume(id, .failure(SereinError.invalid("Cua Driver in Serein's computer refused Serein's request (code \(code)).")))
    case .request(let id):
      if let answer = DriverWire.refusal(toRequest: id) { _ = post(answer) }
    case .notification, .malformed:
      break
    }
  }
  private func resume(_ id: Int, _ result: Result<[String: Any], Error>) {
    lock.lock()
    let waiter = waiting.removeValue(forKey: id)
    lock.unlock()
    waiter?.resume(with: result)
  }
  private func finish(closeStream: Bool) {
    lock.lock()
    guard !didEnd else { lock.unlock(); return }
    didEnd = true
    let stream = self.stream
    self.stream = nil
    let handler = endHandler
    endHandler = nil
    let gone = waiting
    waiting.removeAll()
    lock.unlock()
    for (_, waiter) in gone { waiter.resume(throwing: Self.closed) }
    if closeStream { stream?.close() }
    handler?()
  }

  /// The next request id and the open stream, or nil once it is gone.
  private func reserve() -> (Int, ComputerStream)? {
    lock.lock(); defer { lock.unlock() }
    guard let stream, !stream.isClosed else { return nil }
    let id = nextID
    nextID += 1
    return (id, stream)
  }

  /// Writes one whole line (a notification or an answer); false once the stream is gone.
  private func post(_ line: Data) -> Bool {
    lock.lock()
    let stream = self.stream
    lock.unlock()
    return stream?.write(line) ?? false
  }

  /// One request line built for its id, and the result under that id. Throws the driver's refusal
  /// in Serein's words, a timeout, or a closed link.
  private func send(timeout seconds: Int, _ build: (Int) -> Data?) async throws -> [String: Any] {
    guard let reserved = reserve() else { throw Self.closed }
    let id: Int = reserved.0
    let stream: ComputerStream = reserved.1
    guard let line = build(id) else { throw SereinError.invalid("Serein could not write that request for Cua Driver.") }
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
      lock.lock()
      guard !didEnd else {
        lock.unlock()
        continuation.resume(throwing: Self.closed)
        return
      }
      waiting[id] = continuation
      lock.unlock()
      guard stream.write(line) else {
        resume(id, .failure(Self.closed))
        return
      }
      Task.detached { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        self?.resume(id, .failure(SereinError.invalid("Cua Driver in Serein's computer did not answer within \(seconds) seconds.")))
      }
    }
  }

  func close() {
    finish(closeStream: true)
  }
}

/// Cua Driver as the built-in computer's screen, input and tree (NativeScreen): ComputerHost.screenCall
/// sends it the helper's ops of the same names (`screenshot`, `click`, `type`, `key`, `scroll`,
/// `windows`, `tree`, `zoom`) while `CuaDriverPolicy.isOn()` and the computer carries the pinned
/// driver (VirtualMachineComputer.carriesDriver), with the same answers as the helper's. The lease,
/// Take over and the personal-read refusal stay in ComputerHost.call, before any op reaches here.
/// Every answer is untrusted.
///
/// The box's floor lives here and in BoxFloor, and nowhere else: each model step the floor can
/// stop (`step`, `click`, `fill`) reads its window whole inside its own slot (`serially`), judges
/// that read, and only then sends the input. No earlier read, no remembered focus, is ever judged.
@MainActor final class DriverScreen: NativeScreen {
  private let channel: DriverChannel
  let connectionID = UUID()
  let openObserver: @MainActor () async throws -> DriverChannel
  /// The one-use binding of the last desktop picture the agent saw: its next pixel click carries
  /// it, so the driver refuses a click on a picture that is gone, used or older than a minute.
  /// Serein never takes a hidden picture to pass that check.
  private var capture: String?
  /// Desktop pixels per pixel of that picture (DriverCalls.Shot.scale), for the floor's point.
  private var scale = 1.0
  /// The model's latest tree: refs resolve here only, to a target the floor reads again.
  private(set) var table = ElementTable.empty
  /// Reads made by every link of this run: never reset, so a ref from before a hand-back, a new
  /// lease or a reopened link never names an element of a later read.
  private static var reads = 0
  /// The step running now, its read included: the next waits for it, so no input lands between a
  /// read and the input judged on it, and no read shows a value half typed.
  private var gate: Task<Void, Never>?
  /// Every uncut read as it is taken (ComputerHost forgets the CAPTCHAs it no longer shows).
  var saw: (@MainActor (FreshRead) -> Void)?
  /// Whether a picture may show a value Serein filled in this computer (FilledValues.shows): set
  /// by ComputerHost; until then every picture is judged as if one may.
  var values: @MainActor () -> Bool = { true }
  /// Popups open over the screen (a context menu: an override-redirect window `list_windows`
  /// never lists), by id: from every read's `popups` and every click's answer, with the processes
  /// that may own each, until a read finds it gone (`openPopups`).
  private var popups: [Int: (pids: Set<Int>, bounds: DriverCalls.Row.Frame?)] = [:]
  /// A key that opens a menu no answer reports (shift+F10, F10, an alt letter: BoxFloor.opensMenu)
  /// went since the last Escape, or the person held the screen: the next key or text that reaches
  /// an element sends Escape first.
  private var menuKeyed = false

  init(channel: DriverChannel, openObserver: @escaping @MainActor () async throws -> DriverChannel) {
    self.channel = channel
    self.openObserver = openObserver
  }
  var isOpen: Bool { channel.isOpen }
  func close() {
    channel.setEndHandler(nil)
    channel.close()
  }
  /// Take over and Hand back: the screen changed under the person's hands, so no click is aimed
  /// at the old picture and no ref names an old element.
  func forgetPicture() {
    capture = nil
    table = .empty
    popups = [:]
    menuKeyed = true
  }

  private func serially<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
    let prior = gate
    let run = Task { @MainActor in
      await prior?.value
      return try await body()
    }
    gate = Task { _ = await run.result }
    return try await run.value
  }

  /// The looks, and input with no element: the person's own while they hold control
  /// (ComputerHost.personInput), and the model's steps the floor never stops (a scroll, keys that
  /// only move). The model's clicks, typing and reaching keys go through `step` and `click`.
  func screen(_ op: String, _ a: [String: Any]) async throws -> [String: Any] {
    switch op {
    case "click", "type", "key", "scroll":
      try await serially { try await self.input(op, a) }
      return [:]
    case "screenshot":
      do {
        let (png, width, height) = try await look()
        return ["png": png.base64EncodedString(), "width": width, "height": height]
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw SereinError.invalid(Self.noPicture)
      }
    case "windows":
      let windows = try await windowList()
      return ["windows": DriverCalls.windowsAnswer(windows)]
    case "tree":
      return try await tree(window: a["window"] as? String, depth: DriverCalls.depth(a["depth"]))
    case "zoom":
      guard let call = DriverCalls.zoom(a) else { throw SereinError.invalid("window_id and a region x1 < x2, y1 < y2 are required.") }
      let answer = try await channel.call(call.tool, call.arguments, timeout: 30)
      guard let picture = DriverCalls.zoomPicture(answer) else { throw SereinError.invalid(Self.failure(call.tool, answer)) }
      return ["jpeg": picture.jpeg, "width": picture.width, "height": picture.height]
    default:
      throw SereinError.invalid("unknown op")
    }
  }
  private func input(_ op: String, _ a: [String: Any]) async throws {
    switch op {
    case "click":
      guard let call = DriverCalls.click(a, capture: capture) else {
        throw SereinError.invalid("x and y must be on the screen, and button is left, middle or right.")
      }
      // One use: the binding goes with this click, whatever its answer.
      capture = nil
      try await act(call, timeout: 30)
    case "type":
      guard let text = a["text"] as? String, let call = DriverCalls.type(text) else {
        throw SereinError.invalid("text is required, up to 8000 characters.")
      }
      // Key events run at about 45 characters a second.
      try await act(call, timeout: 30 + text.count / 30)
    case "key":
      guard let calls = DriverCalls.keys(String(describing: a["key"] ?? "")) else { throw SereinError.invalid(Self.keyWords) }
      if DriverCalls.keyPresses(String(describing: a["key"] ?? ""))?.contains(where: BoxFloor.opensMenu) == true { menuKeyed = true }
      for call in calls { try await act(call, timeout: 30) }
    default:
      guard let call = DriverCalls.scroll(a) else { throw SereinError.invalid("x and y must be on the screen.") }
      try await act(call, timeout: 30)
    }
  }

  /// Serein's words for an answer that is not the one asked for: the driver's refusal, or a shape
  /// this copy does not read.
  private static func failure(_ tool: DriverWire.Tool, _ answer: DriverWire.ToolAnswer) -> String {
    answer.isError ? DriverWire.refusal(tool, code: DriverWire.failureCode(answer)) : DriverWire.unreadable(tool)
  }
  /// One input call; its failure or refusal in Serein's words.
  @discardableResult
  private func act(_ call: DriverCalls.Call, timeout: Int) async throws -> DriverWire.ToolAnswer {
    let answer = try await channel.call(call.tool, call.arguments, timeout: timeout)
    if let refusal = DriverCalls.inputRefusal(call.tool, answer) { throw SereinError.invalid(refusal) }
    return answer
  }
  private var apps: [Int: String] = [:]
  private func windowList() async throws -> [DriverCalls.Window] {
    let call = DriverCalls.windows()
    let answer = try await channel.call(call.tool, call.arguments, timeout: 30)
    guard let windows = DriverCalls.windowList(answer) else { throw SereinError.invalid(Self.failure(call.tool, answer)) }
    for window in windows { if let pid = window.pid { apps[pid] = window.app } }
    return windows
  }
  /// One window read whole (DriverCalls.windowState), with its place on the desktop.
  private func read(pid: Int, window: Int, picture: Bool = false, observer: DriverChannel? = nil) async throws -> (read: FreshRead, bounds: DriverCalls.Row.Frame?) {
    let call = DriverCalls.windowState(pid: pid, window: window, picture: picture)
    let answer = try await (observer ?? channel).call(call.tool, call.arguments, timeout: 40)
    guard DriverWire.integer(answer.structured?["window_id"]) == window, let menus = DriverCalls.completePopups(answer), let rows = DriverCalls.treeRows(answer) else { throw SereinError.invalid(Self.failure(call.tool, answer)) }
    let read = FreshRead(pid: pid, window: window, rows: rows.rows, cut: rows.cut, degraded: rows.degraded, app: answer.structured?["app_name"] as? String ?? apps[pid] ?? "")
    for menu in menus { popups[menu.id] = ((popups[menu.id]?.pids ?? []).union([menu.pid ?? pid]), menu.bounds) }
    saw?(read)
    return (read, DriverCalls.windowBounds(answer))
  }
  private typealias Reads = (reads: [(window: DriverCalls.Window, read: FreshRead)], whole: Bool, pidless: Bool, windows: [DriverCalls.Window])
  /// Each window named by `wanted` (or every one, and every popup still open), at most
  /// DriverCalls.treeWindows, each read whole: `whole` when those are every window with a process
  /// and none is cut (the desktop's bare read aside), `pidless` when a window has no process to read.
  private func readAll(_ wanted: String?) async throws -> Reads {
    let windows = try await windowList()
    let targets = DriverCalls.treeTargets(windows, wanted: wanted)
    var reads: [(window: DriverCalls.Window, read: FreshRead)] = []
    for window in targets {
      guard let pid = window.pid else { continue }
      reads.append((window, try await read(pid: pid, window: window.id).read))
    }
    if wanted == nil { reads += try await openPopups() }
    let whole = targets.count == windows.filter { $0.pid != nil }.count && !reads.contains { $0.read.cut && !BoxFloor.bare($0.window, $0.read) }
    return (reads, whole, windows.contains { $0.pid == nil }, windows)
  }
  /// The helper's `tree` answer: each window named by `window` (or every one), each read whole
  /// and shown down to `depth`.
  private func tree(window wanted: String?, depth: Int) async throws -> [String: Any] {
    let (table, checks, whole, windows, hiddenNumberLabels) = try await serially {
      self.table = .empty
      let all = try await self.readAll(wanted)
      let selected = all.reads.filter { !BoxFloor.bare($0.window, $0.read) }
      guard (wanted != nil || all.whole && !all.pidless), !selected.contains(where: { $0.read.cut }) else {
        throw SereinError.invalid("Serein could not read the selected window trees completely, so it sends no tree. Select a smaller window or ask the person to take over with computer_ask_person.")
      }
      let labels = selected.flatMap { [$0.window.title, $0.window.app] + $0.read.rows.flatMap { [$0.role, $0.label] } }
      let selectedIDs = Set(selected.map { $0.window.id })
      // Other windows remain discoverable by name. Omit their numeric title content
      // before screening this view so background panels cannot obscure its figures.
      let hiddenTitles = Set(all.windows.filter { !selectedIDs.contains($0.id) }.map(\.title))
      let hiddenNumberLabels = HandBack.cardFragmentLabels(labels)
      Self.reads += 1
      self.table = ElementTable(read: Self.reads, depth: depth, windows: selected, hiddenNumberLabels: hiddenNumberLabels)
      return (self.table, selected.reduce(into: Set<String>()) { $0.formUnion($1.read.botChecks) }, all.whole, all.windows, hiddenNumberLabels.union(hiddenTitles))
    }
    return ["tree": table.text, "cut": table.cut, "botChecks": Array(checks), "whole": whole,
            "windows": DriverCalls.windowsAnswer(windows, hiddenNumberLabels: hiddenNumberLabels)]
  }

  // MARK: pictures

  /// A look at the screen: the driver's picture with every place a value of the person's may show
  /// blacked out (`between`). A failed privacy check returns guidance, never a fallback payload.
  private func look() async throws -> (Data, Int, Int) {
    try await serially {
      let call = DriverCalls.screenshot()
      self.capture = nil
      let seen = try await self.between { () -> (DriverCalls.Shot, Data) in
        let answer = try await self.channel.call(call.tool, call.arguments, timeout: 20)
        guard let shot = DriverCalls.shot(answer), let png = Data(base64Encoded: shot.png) else {
          throw SereinError.invalid(Self.failure(call.tool, answer))
        }
        return (shot, png)
      }
      let (shot, png) = seen.shot
      guard let places = seen.places else {
        throw SereinError.invalid(seen.moving ? Self.moving : Self.noPicture)
      }
      guard let masked = await Self.cleared(png, places, scale: shot.scale) else {
        throw SereinError.invalid(Self.shown)
      }
      self.capture = shot.capture
      self.scale = shot.scale
      return (masked, shot.width, shot.height)
    }
  }
  /// A step's picture for its record (`shoot`: the helper's, which binds no click), masked as a
  /// look's is; nil when Serein cannot tell where a value may show.
  func stepPicture(_ shoot: @escaping @MainActor () async throws -> Data) async throws -> Data? {
    try await serially {
      let seen = try await self.between(shoot)
      guard let places = seen.places, let size = ScreenPicture.pngSize(seen.shot) else { return nil }
      return await Self.cleared(
        seen.shot, places, scale: Double(ComputerPolicy.screenWidth) / Double(size.width))
    }
  }
  /// A picture (`shoot`) between two reads of every window, in the caller's slot, and where to
  /// black it out: both reads' secret places (`secrets`), so the picture is masked where a value
  /// was just before and just after it. A smooth scroll or a transition moves a field while the
  /// picture is taken: when a place moved by more than 2 pixels, or the places differ,
  /// it tries once more after a short settle, then gives `moving` and no places. nil places too
  /// when Serein cannot tell them. Each read of the box's windows takes about 1.6 s (live).
  private func between<Shot>(_ shoot: @MainActor () async throws -> Shot) async throws -> (shot: Shot, places: [DriverCalls.Row.Frame]?, moving: Bool) {
    var settled = false
    while true {
      let before = try await readAll(nil)
      let shot = try await shoot()
      let after = try await readAll(nil)
      guard let a = secrets(before), let b = secrets(after) else { return (shot, nil, false) }
      if Self.steady(a, b) { return (shot, (a + b).flatMap(\.places), false) }
      if settled { return (shot, nil, true) }
      settled = true
      try await Task.sleep(nanoseconds: 500_000_000)
    }
  }
  /// Where a picture may show a value of the person's, window by window (FreshRead.secretPlaces),
  /// nil if any window could not be read whole or a private place could not be located.
  private func secrets(_ all: Reads) -> [(window: Int, places: [DriverCalls.Row.Frame])]? {
    guard all.whole, !all.pidless else { return nil }
    let shown = values(), reads = all.reads.filter { !BoxFloor.bare($0.window, $0.read) }.map(\.read)
    var out: [(window: Int, places: [DriverCalls.Row.Frame])] = []
    for read in reads {
      guard let found = read.secretPlaces(values: shown) else { return nil }
      out.append((read.window, found))
    }
    return out
  }
  /// The same windows, each with as many secret places, each within 2 pixels: the mask's margin beyond
  /// the frames' own offset (BoxPictureMask.margin).
  private static func steady(_ a: [(window: Int, places: [DriverCalls.Row.Frame])], _ b: [(window: Int, places: [DriverCalls.Row.Frame])]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { one, two in
      one.window == two.window && one.places.count == two.places.count && zip(one.places, two.places).allSatisfy { p, q in
        [p.x - q.x, p.y - q.y, p.width - q.width, p.height - q.height].allSatisfy { abs($0) <= 2 }
      }
    }
  }
  /// Decoding and encoding run off the main thread, as StepPictures' do; the slot stays held.
  private static func cleared(_ png: Data, _ places: [DriverCalls.Row.Frame], scale: Double) async -> Data? {
    guard let out = await Task.detached(priority: .userInitiated, operation: { BoxPictureMask.blackOut(png, places, scale: scale) }).value else { return nil }
    return await BoxPictureMask.screenedPNG(out)
  }

  // MARK: the floor's steps (ComputerHost+Box)

  /// Keys sent to no element (Cua Driver reports no keyboard focus) that move inside an element
  /// (BoxFloor.movesInside): in one slot, every window read whole, the floor on those reads
  /// (BoxFloor.judge(bare:)), then the keys.
  func keys(_ a: [String: Any], _ facts: BoxFloor.Facts) async throws -> BoxFloor.Stopped? {
    guard let presses = DriverCalls.keyPresses(String(describing: a["key"] ?? "")) else { throw SereinError.invalid(Self.keyWords) }
    return try await serially {
      let all = try await self.readAll(nil)
      let reads = all.reads.filter { !BoxFloor.bare($0.window, $0.read) }.map(\.read)
      if let stopped = BoxFloor.judge(bare: presses, in: reads, whole: all.whole && !all.pidless, facts) { return stopped }
      try await self.input("key", a)
      return nil
    }
  }

  /// The element a model step names in its latest tree, or Serein's words for why there is none.
  func element(_ raw: Any?) throws -> ElementTable.Element {
    guard let ref = ElementRef(raw) else { throw SereinError.invalid("element is a ref from computer_tree, like \"e3.12\".") }
    switch table.resolve(ref) {
    case .success(let element): return element
    case .failure(let miss): throw SereinError.invalid(miss.line)
    }
  }

  /// A model step on an element: click (button, double), type (text), key (key), scroll
  /// (direction, amount) or set_value (value). In one slot, for each part (a key sequence goes a
  /// press at a time), the window read whole again, the element found in that read, the floor on
  /// that row, then the input by that read's token; the stop that ends it, or nil when it all ran.
  /// A click, and a set_value that falls back to one, presses a real pointer at the element's
  /// centre, so it is judged where it lands (`landing`). Typing and keys that type or press go
  /// into a field only, with no pointer and no popup holding the keyboard, and go on only while
  /// the driver says the focus is on it; Return or space on a press is a click (BoxFloor.delivered).
  /// Values never leave this call but in their one request line.
  func step(_ step: String, on target: BoxTarget, _ a: [String: Any], _ facts: BoxFloor.Facts) async throws -> BoxFloor.Stopped? {
    let parts = try Self.parts(step, a)
    return try await serially {
      for var part in parts {
        let keyed = part.tool == .typeText || part.tool == .pressKey && Self.reaches(part.act)
        var (read, bounds) = try await self.read(pid: target.pid, window: target.window)
        // A menu holds the keyboard, known from an answer, from this fresh read or from a key that
        // opens one: Escape (a key that only moves) closes it first, and no key or text goes while
        // one stays, so none reaches a menu's item (a Paste among them).
        if keyed, try await self.menuMayHoldKeys() {
          self.menuKeyed = false
          try await self.input("key", ["key": "Escape"])
          (read, bounds) = try await self.read(pid: target.pid, window: target.window)
          if try await !self.openPopups().isEmpty { throw SereinError.invalid(Self.popupOpen) }
        }
        if read.degraded { throw SereinError.invalid(Self.degraded) }
        guard let i = read.find(target), let token = read.rows[i].token else { throw SereinError.invalid(ElementMiss.changed.line) }
        if let stopped = BoxFloor.judge(part.act, at: i, in: read, facts) { return stopped }
        let act = BoxFloor.delivered(part.act, on: read.rows[i])
        if case .click = act, part.tool == .pressKey { part = (act, .click, ["button": "left", "count": 1], 30) }
        var background = false
        if part.tool == .click, read.rows[i].acts, part.fields["button"] as? String == "left", part.fields["count"] as? Int == 1 {
          // The element's own action, no pointer: it reaches the row and what holds it only.
          if let stopped = BoxFloor.judge(press: i, in: read, facts) { return stopped }
          background = true
        } else if [.click, .setValue].contains(part.tool), let stopped = try await self.pointer(on: i, read, bounds, facts) {
          return stopped
        }
        var call = DriverCalls.onElement(part.tool, pid: target.pid, token: token, part.fields, background: background)
        if case .key(let key) = part.act, BoxFloor.opensMenu(key) { self.menuKeyed = true }
        let answer: DriverWire.ToolAnswer
        do {
          var tried = try await self.channel.call(call.tool, call.arguments, timeout: part.timeout)
          // The driver's own way on when it cannot work an action in the background (a field): a
          // real pointer at the centre, judged where it lands.
          if background, DriverWire.failureCode(tried) == "background_unavailable" {
            if let stopped = try await self.pointer(on: i, read, bounds, facts) { return stopped }
            call = DriverCalls.onElement(part.tool, pid: target.pid, token: token, part.fields)
            tried = try await self.channel.call(call.tool, call.arguments, timeout: part.timeout)
          }
          if let refusal = DriverCalls.inputRefusal(call.tool, tried) { throw SereinError.invalid(refusal) }
          answer = tried
        } catch where keyed && !BoxFloor.takesText(read.rows[i]) {
          throw SereinError.invalid(Self.noFocus)
        }
        self.notePopup(answer, pids: [target.pid])
        let focus = DriverCalls.focusAfter(answer)
        if keyed, focus != "target" { throw SereinError.invalid(Self.focusMissed(focus ?? "nowhere")) }
      }
      return nil
    }
  }
  private static func reaches(_ act: BoxFloor.Act) -> Bool {
    if case .key(let key) = act { return BoxFloor.reach(key) != nil }
    return false
  }
  private typealias Part = (act: BoxFloor.Act, tool: DriverWire.Tool, fields: [String: Any], timeout: Int)
  private static func parts(_ step: String, _ a: [String: Any]) throws -> [Part] {
    switch step {
    case "click":
      let button = a["button"] as? String ?? "left"
      guard ["left", "right", "middle"].contains(button) else { throw SereinError.invalid("button is left, middle or right.") }
      return [(.click, .click, ["button": button, "count": a["double"] as? Bool == true ? 2 : 1], 30)]
    case "type", "set_value":
      let key = step == "type" ? "text" : "value"
      guard let text = a[key] as? String, text.count <= 8_000, step == "set_value" || !text.isEmpty else {
        throw SereinError.invalid("\(key) is required, up to 8000 characters.")
      }
      // A tab would move the rest into an element nobody judged.
      if step == "type", text.contains("\t") {
        throw SereinError.invalid("A tab in the text would move the rest into another field. Type each field on its own: computer_type with element, a ref from computer_tree.")
      }
      return [(step == "type" ? .type(text) : .setValue(text), step == "type" ? .typeText : .setValue, [key: text], 30 + text.count / 30)]
    case "key":
      guard let presses = DriverCalls.keyPresses(String(describing: a["key"] ?? "")) else { throw SereinError.invalid(keyWords) }
      return presses.map { (.key($0), .pressKey, $0.fields, 30) }
    case "scroll":
      let direction = a["direction"] as? String ?? "down"
      guard ["up", "down"].contains(direction) else { throw SereinError.invalid("direction is up or down.") }
      return [(.scroll, .scroll, ["direction": direction, "amount": max(1, min(50, DriverCalls.coordinate(a["amount"], below: 51) ?? 3))], 30)]
    default:
      throw SereinError.invalid("unknown op")
    }
  }

  /// A model click at x, y of the latest picture: in one slot, judged where it lands
  /// (`landing`), then the click. The picture's scale applies only to a click bound to it: one
  /// with no capture is in desktop points already.
  func click(_ a: [String: Any], _ facts: BoxFloor.Facts) async throws -> BoxFloor.Stopped? {
    guard let call = DriverCalls.click(a, capture: capture), let px = call.arguments["x"] as? Int, let py = call.arguments["y"] as? Int else {
      throw SereinError.invalid("x and y must be on the screen, and button is left, middle or right.")
    }
    let factor = call.arguments["capture_id"] == nil ? 1 : scale
    capture = nil
    let x = Int(Double(px) * factor), y = Int(Double(py) * factor)
    return try await serially {
      let (stopped, pids) = try await self.landing(x, y, known: nil, facts)
      if let stopped { return stopped }
      self.notePopup(try await self.act(call, timeout: 30), pids: pids)
      return nil
    }
  }

  /// An input landing at desktop point x, y, by element or by x, y: every window `list_windows`
  /// puts there and an open popup, read whole (`known`, the element's own read, is not read
  /// again), and the floor on every row there in every one of them; with the processes read. A
  /// point Serein cannot read all of is refused.
  private func landing(_ x: Int, _ y: Int, known: FreshRead?, _ facts: BoxFloor.Facts) async throws
    -> (stopped: BoxFloor.Stopped?, pids: [Int])
  {
    let there = try await windowList().filter { $0.bounds?.holds(x, y) ?? true }
    guard (1...DriverCalls.treeWindows).contains(there.count) else { throw SereinError.invalid(Self.unread) }
    if let known, !there.contains(where: { $0.id == known.window }) { throw SereinError.invalid(Self.outOfView) }
    var reads: [FreshRead] = []
    for window in there {
      var read = known
      if read?.window != window.id {
        guard let pid = window.pid else { throw SereinError.invalid(Self.unread) }
        read = try await self.read(pid: pid, window: window.id).read
      }
      if let read, BoxFloor.bare(window, read) { continue }
      guard let read, !read.cut else { throw SereinError.invalid(read?.degraded == true ? Self.degraded : Self.unread) }
      reads.append(read)
    }
    for menu in try await openPopups() where menu.window.bounds?.holds(x, y) ?? true {
      guard !menu.read.cut else { throw SereinError.invalid(Self.unread) }
      reads.insert(menu.read, at: 0)
    }
    return (BoxFloor.judge(clickAt: x, y, in: reads, facts), reads.map(\.pid))
  }

  /// The popups a click's answer says appeared (`popup window <id>`, with or without a title),
  /// the driver's own pointer overlay aside, kept with the processes that may own one.
  private func notePopup(_ answer: DriverWire.ToolAnswer, pids: [Int]) {
    let text = answer.texts.joined(separator: " ")
    guard let found = text.range(of: "popup window [0-9]+ (?!\"Cua\\.)", options: .regularExpression),
      let window = Int(text[found].split(separator: " ")[2])
    else { return }
    popups[window] = ((popups[window]?.pids ?? []).union(pids), popups[window]?.bounds)
  }
  /// A click or set_value the driver sends at row i's frame centre, judged where it lands; nil to send.
  private func pointer(on i: Int, _ read: FreshRead, _ bounds: DriverCalls.Row.Frame?, _ facts: BoxFloor.Facts) async throws -> BoxFloor.Stopped? {
    switch BoxFloor.landing(of: i, in: read, window: bounds) {
    case .hidden: throw SereinError.invalid(Self.outOfView)
    // No pointer: the driver works the element itself (a double, right or middle click, a row
    // with no action of its own, set_value), which reaches it and what holds it.
    case .none: return BoxFloor.judge(press: i, in: read, facts)
    case .at(let x, let y): return try await landing(x, y, known: read, facts).stopped
    }
  }
  private func menuMayHoldKeys() async throws -> Bool {
    if menuKeyed { return true }
    return try await !openPopups().isEmpty
  }
  /// Every popup still open, each read whole as a window of its own (the model's tree shows it, a
  /// click judges it); one no process shows any more is forgotten.
  private func openPopups(observer: DriverChannel? = nil) async throws -> [(window: DriverCalls.Window, read: FreshRead)] {
    var open: [(window: DriverCalls.Window, read: FreshRead)] = []
    for (id, menu) in popups.sorted(by: { $0.key < $1.key }) {
      var found = false
      for pid in menu.pids.sorted() {
        let call = DriverCalls.windowState(pid: pid, window: id)
        let answer = try await (observer ?? channel).call(call.tool, call.arguments, timeout: 40)
        if DriverCalls.staleWindow(answer, pid: pid, id: id) { continue }
        guard !answer.isError, DriverCalls.completePopups(answer)?.isEmpty == true,
          DriverWire.integer(answer.structured?["window_id"]) == id, let rows = DriverCalls.treeRows(answer)
        else { throw SereinError.invalid(Self.failure(call.tool, answer)) }
        let bounds = DriverCalls.windowBounds(answer) ?? menu.bounds
        open.append((DriverCalls.Window(id: id, pid: pid, title: "menu", app: "popup", bounds: bounds),
                     FreshRead(pid: pid, window: id, rows: rows.rows, cut: rows.cut, app: answer.structured?["app_name"] as? String ?? apps[pid] ?? "")))
        found = true
        break
      }
      if !found { popups[id] = nil }
    }
    return open
  }

  /// The person's value into a secure card's field: in one slot, its window read whole again, the
  /// same element with the same floor stop, then the value typed by that read's token. False when
  /// the field is gone or changed.
  func fill(_ target: BoxTarget, stop: BoxFloor.Stop, _ value: String) async throws -> Bool {
    try await serially {
      // A fresh walk on the input connection would retire the card's token. Observe on
      // a separate driver connection and deliver only on the connection that issued it.
      let observer = try await self.openObserver()
      defer { observer.close() }
      let read = try await self.read(pid: target.pid, window: target.window, observer: observer).read
      guard try await self.openPopups(observer: observer).isEmpty else { return false }
      guard !read.cut, let token = target.row.token, let i = read.find(target),
        read.rows[i].index == target.row.index, read.rows[i].frame == target.row.frame, BoxFloor.judge(.type(""), at: i, in: read)?.stop == stop else {
        return false
      }
      let answer = try await self.act(DriverCalls.onElement(.typeText, pid: target.pid, token: token, ["text": value]), timeout: 30 + value.count / 30)
      return DriverCalls.focusAfter(answer) == "target"
    }
  }

  /// A close-up of one element: in one slot, its window read again with its picture, then the
  /// element's frame in that picture (the driver's zoom is window-local), between two more reads
  /// of the window, as a look's picture is (`between`).
  func zoom(_ target: BoxTarget) async throws -> [String: Any] {
    let shot = try await serially { () -> (jpeg: String, width: Int, height: Int) in
      let before = try await self.read(pid: target.pid, window: target.window).read
      let now = try await self.read(pid: target.pid, window: target.window, picture: true)
      guard let i = now.read.find(target) else { throw SereinError.invalid(ElementMiss.changed.line) }
      guard let frame = now.read.rows[i].frame, let window = now.bounds else {
        throw SereinError.invalid("That element has no place on the screen to zoom into.")
      }
      // A picture of a filled field, or of a place a value of the person's may show in
      // (FreshRead.secretPlaces), would carry it.
      let pad = Int(BoxPictureMask.margin.rounded(.up))
      let near = { (f: DriverCalls.Row.Frame) in
        f.x - pad < frame.x + frame.width && frame.x < f.x + f.width + pad && f.y - pad < frame.y + frame.height && frame.y < f.y + f.height + pad
      }
      guard !before.cut, !now.read.cut, let secrets = now.read.secretPlaces(values: self.values()), !secrets.contains(where: near),
        !now.read.rows.contains(where: { $0.filled && $0.frame.map(near) == true })
      else {
        throw SereinError.invalid("That field holds the person's value, or the element holds such a field, or Serein cannot tell where one shows in its window, so Serein sends no picture of it. Zoom into a smaller element, or go on from computer_tree.")
      }
      let x1 = max(0, frame.x - window.x), y1 = max(0, frame.y - window.y)
      let x2 = min(window.width, frame.x + frame.width - window.x), y2 = min(window.height, frame.y + frame.height - window.y)
      guard let call = DriverCalls.zoom(["window_id": target.window, "x1": x1, "y1": y1, "x2": x2, "y2": y2]) else {
        throw SereinError.invalid("That element is outside its window's picture.")
      }
      let answer = try await self.channel.call(call.tool, call.arguments, timeout: 30)
      guard let picture = DriverCalls.zoomPicture(answer) else { throw SereinError.invalid(Self.failure(call.tool, answer)) }
      let after = try await self.read(pid: target.pid, window: target.window).read
      let clear = await !BoxPictureMask.shows(Data(base64Encoded: picture.jpeg) ?? Data())
      guard clear, !after.cut, let first = before.secretPlaces(values: self.values()), let last = after.secretPlaces(values: self.values()), !(first + last).contains(where: near),
        Self.steady([(target.window, first)], [(target.window, last)])
      else {
        throw SereinError.invalid("The window was still moving (a scroll or an animation), or showed a value of the person's away from its field, while Serein took the close-up, so it sends none. Call computer_zoom again once the page has settled, or go on from computer_tree.")
      }
      return picture
    }
    return ["jpeg": shot.jpeg, "width": shot.width, "height": shot.height]
  }

  static let keyWords = "key is a key name or chord like Return, Tab, ctrl+l"
  static let noPicture =
    "Serein could not locate all private values and withheld the picture. Use computer_tree to read the available labels and controls. If the hidden content is needed, use computer_ask_person."
  static let moving =
    "Private areas moved between reads. No picture or tree was sent. Retry computer_screenshot after the screen settles."
  static let shown =
    "Serein could not clear the picture for sharing. No picture or tree was sent. Use computer_tree for the available labels and controls, or computer_ask_person for the private step."
  static let outOfView =
    "That element is only partly in view in its window, so a click at its middle would land on something else. Scroll it into view (computer_scroll with element), then computer_tree and click its new ref."
  static func focusMissed(_ focus: String) -> String {
    "Cua Driver could not keep the keyboard focus on that element (it reports focus \(focus)), so what it sent may have reached another element, and Serein sends no more. Look with computer_tree, click the field (computer_click with element), then type into it again."
  }
  static let unread =
    "Serein could not read all of what is at that point (a window too big to read whole, or one Serein cannot read), so it sends no pointer there. Click it by its ref from computer_tree instead (computer_click with element presses it by its own action, with no pointer), or scroll so less of the window shows and try again. If computer_tree shows it with no ref, call computer_ask_person: the person clicks it."
  static let noFocus =
    "That element takes no keyboard focus, so Cua Driver sent nothing. Send the text or key to the field it is meant for (its ref in computer_tree); a button or check box takes computer_click with element."
  static let popupOpen =
    "A menu is open over the screen and holds the keyboard, and Escape did not close it, so a key or text would go to the menu and Serein does not send it. Click one of its items by its ref (computer_tree shows it as window \"menu\"), or click outside it, then try again."
  static let degraded =
    "That app shows Serein no accessibility tree, so Serein cannot tell what a step in it does and does not take it. Close the app and open it again (Serein turns accessibility on for apps opened after it starts), then act by element ref from computer_tree."
}
