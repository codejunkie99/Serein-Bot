#if DEBUG
import AppKit
import WebKit
import SereinCore

extension SmokeTest {
  /// Relay's hologram in its real web view: it starts with WebGL, gives every state its own
  /// shape, follows a new look and the jobs, plays a tour, draws frames, takes a tap without
  /// taking the keyboard, and its page reaches neither the network nor another page.
  @MainActor static func avatar() async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
    }
    func waitFor(_ seconds: Double, _ condition: () async -> Bool) async throws {
      let deadline = Date().addingTimeInterval(seconds)
      while !(await condition()) && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
    }
    let engine = RelayAvatarEngine()
    // Relay's own kind of window: a panel that takes clicks and keys without activating Serein.
    let window = RelayWindow(
      contentRect: NSRect(x: 60, y: 60, width: 480, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // On top of every app and Space, as Relay's panel is: a covered page draws nothing.
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.backgroundColor = .black
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
    engine.web.frame = container.bounds
    engine.web.autoresizingMask = [.width, .height]
    container.addSubview(engine.web)
    // The composer stands in: it holds the keyboard while the hologram is tapped.
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
    container.addSubview(field)
    window.contentView = container
    window.orderFrontRegardless()
    window.makeKey()
    defer { window.orderOut(nil) }
    let serein = RelayLook.serein
    engine.update(state: .idle, look: serein, jobs: [])
    try await waitFor(20) { engine.ready || engine.failed }
    try check(engine.ready && !engine.failed, "The hologram starts in its web view with WebGL")
    try check(engine.transparent, "The hologram's web view draws no background, so the light floats over the panel")
    func info() async -> [String: Any] { await engine.info() }
    var now = await info()
    try check(now["formation"] as? String == "logo" && now["core"] as? String == "orb" && now["rings"] as? Int == 5,
              "Ready wears the Serein logo: five rings around an orb")

    var shapes: [String] = []
    for state in RelayLook.State.allCases where state != .done {
      engine.update(state: state, look: serein, jobs: [])
      try await waitFor(3) { await info()["state"] as? String == state.rawValue }
      now = await info()
      let style = serein.states[state.rawValue]!
      let core = style.core ?? serein.core.shape
      try check(now["state"] as? String == state.rawValue && now["formation"] as? String == style.formation && now["core"] as? String == core,
                "\(state.title) takes its own shape (\(style.formation!) + \(core))")
      shapes.append("\(style.formation!)+\(core)")
    }
    try check(Set(shapes).count == shapes.count, "No two states share a shape")

    let aurora = RelayLook.preset("Aurora")!
    engine.update(state: .idle, look: aurora, jobs: [])
    try await waitFor(3) { await info()["look"] as? String == "Aurora" }
    now = await info()
    try check(now["look"] as? String == "Aurora" && now["rings"] as? Int == 7 && now["formation"] as? String == "crown",
              "A new look re-forms the hologram (Aurora: seven rings in a crown)")

    let running = ["a", "b", "c"].map { RelayAvatarJob(id: $0, state: "running") }
    engine.update(state: .working, look: aurora, jobs: running)
    try await waitFor(3) { await info()["jobs"] as? Int == 3 }
    try check(await info()["jobs"] as? Int == 3, "Each delegated run rides the rings as a satellite")
    engine.update(state: .working, look: aurora, jobs: [RelayAvatarJob(id: "a", state: "done"), running[1], RelayAvatarJob(id: "c", state: "failed")])
    try await waitFor(8) { await info()["jobs"] as? Int == 1 }
    try check(await info()["jobs"] as? Int == 1, "Finished and failed runs flash, then leave")
    // The host keeps listing the finished ones; they do not come back.
    engine.update(state: .working, look: aurora, jobs: [RelayAvatarJob(id: "a", state: "done"), RelayAvatarJob(id: "b", state: "running"), RelayAvatarJob(id: "c", state: "failed"), RelayAvatarJob(id: "x", state: "running")])
    try await Task.sleep(nanoseconds: 600_000_000)
    try check(await info()["jobs"] as? Int == 2, "A run that already left does not return")

    engine.update(state: .idle, look: aurora, jobs: [])
    engine.send(.preview("tour", 8))
    var seen = Set<String>()
    let tourEnd = Date().addingTimeInterval(10)
    while Date() < tourEnd {
      if let state = await info()["state"] as? String { seen.insert(state) }
      try await Task.sleep(nanoseconds: 150_000_000)
    }
    try check(seen.count >= 7, "look_show tour plays every state (\(seen.sorted().joined(separator: ", ")))")
    try check(await info()["state"] as? String == "idle", "After the tour the real state comes back")

    let png = await engine.snapshot()
    let bitmap = png.flatMap { NSBitmapImageRep(data: $0) }
    // Light in the middle; the edges stay clear, so the panel shows through around it.
    var lit = 0, shaded = 0, edge = 0, edgeClear = 0
    if let bitmap {
      let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
      for y in stride(from: 0, to: h, by: 6) {
        for x in stride(from: 0, to: w, by: 6) {
          guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.2 else { continue }
          lit += 1
          // Light alone has a full brightest channel once its alpha is divided out. A dimmer one
          // means the pixel covers more than it lights, which is what darkens a bright page.
          if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.85 { shaded += 1 }
        }
      }
      // The outermost pixels: light fades to nothing there, so the view has no visible border.
      let ring = stride(from: 0, to: w, by: 4).flatMap { [($0, 0), ($0, h - 1)] } + stride(from: 0, to: h, by: 4).flatMap { [(0, $0), (w - 1, $0)] }
      for (x, y) in ring {
        edge += 1
        if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.02 { edgeClear += 1 }
      }
    }
    try check(bitmap != nil && lit > 50 && edge > 0 && edgeClear == edge,
              "The hologram draws light, and its edges stay transparent (\(lit) lit; \(edgeClear) of \(edge) edge samples clear)")

    try check(shaded > 20, "The glow keeps coverage of its own, so it shows over a bright page (\(shaded) of \(lit) lit samples)")

    let fetched = try await engine.web.callAsyncJavaScript(
      "try { await fetch('https://example.com/'); return 'reached' } catch (e) { return 'blocked' }",
      arguments: [:], in: nil, contentWorld: .page) as? String
    try check(fetched == "blocked", "The hologram's page cannot reach the network")
    _ = try? await engine.web.callAsyncJavaScript("location.href = 'https://example.com/'; return true", arguments: [:], in: nil, contentWorld: .page)
    try await Task.sleep(nanoseconds: 800_000_000)
    let stayed = await info()["look"] as? String == "Aurora"
    try check(engine.web.url?.absoluteString == "about:blank" && stayed, "The hologram's page cannot navigate anywhere")

    // A tap: pointer down and up on the stage inside the page, as WebKit delivers a click, so the
    // check does not depend on which app macOS keeps in front.
    var tapped = false
    engine.onTap = { tapped = true }
    _ = try? await engine.web.callAsyncJavaScript("""
      const stage = document.getElementById('stage'), r = stage.getBoundingClientRect();
      const at = { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, pointerId: 1, bubbles: true, isPrimary: true };
      stage.dispatchEvent(new PointerEvent('pointerdown', at));
      stage.dispatchEvent(new PointerEvent('pointerup', at));
      return true
      """, arguments: [:], in: nil, contentWorld: .page)
    try await waitFor(3) { tapped }
    try check(tapped, "A tap on the hologram reaches Serein (it talks to Relay)")
    // The keyboard stays with the composer: a click or Tab never moves it to the hologram, which
    // does not accept it. A real click is also tried when macOS lets the check's window be key.
    try check(!engine.web.acceptsFirstResponder, "The hologram never asks for the keyboard, so clicks and Tab leave it with the composer")
    window.makeKey()
    window.makeFirstResponder(field)
    if window.isKeyWindow {
      let holder = window.firstResponder
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(
          with: type, location: NSPoint(x: 240, y: 150), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        { window.sendEvent(event) }
      }
      try await Task.sleep(nanoseconds: 300_000_000)
      try check(window.firstResponder === holder, "A real click on the hologram leaves the keyboard with the composer")
    } else {
      results.append("NOTE: another app kept the front, so the real click was not tried")
    }
    return results
  }
}
#endif
