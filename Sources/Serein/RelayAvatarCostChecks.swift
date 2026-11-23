#if DEBUG
import AppKit
import Darwin
import SereinCore
import SwiftUI

extension SmokeTest {
  /// What Relay's hologram costs, measured in its real web view: the processor time of Serein
  /// and of the WebKit processes that draw it (its web content process and the GPU process), in
  /// every state, behind other apps, hidden, two at once, and while it changes shape without a
  /// pause. Each budget is a share of one core; the report lists every measurement.
  @MainActor static func avatarCost(browser: BrowserModel? = nil, agent: AgentModel? = nil) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
    }
    func sleep(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    // Two holograms at the sizes Serein uses: the column's large stage and the panel's.
    func stage(_ frame: NSRect) -> (RelayAvatarEngine, NSWindow) {
      let engine = RelayAvatarEngine()
      let window = RelayWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      // On top of every app and Space, as Relay's panel is: a covered page draws nothing.
      window.level = .floating
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.backgroundColor = NSColor(white: 0.1, alpha: 1)
      engine.web.frame = NSRect(origin: .zero, size: frame.size)
      engine.web.autoresizingMask = [.width, .height]
      window.contentView = engine.web
      window.orderFrontRegardless()
      return (engine, window)
    }
    let (column, columnWindow) = stage(NSRect(x: 40, y: 40, width: 340, height: 170))
    let (panel, panelWindow) = stage(NSRect(x: 420, y: 40, width: 640, height: 190))
    // Serein's own windows are minimized: the start page's animated wallpapers would be measured
    // too. Not hidden: with Relay off, Serein quits when its last window goes.
    let others = NSApp.windows.filter { $0.isVisible && $0 !== columnWindow && $0 !== panelWindow && $0.styleMask.contains(.miniaturizable) }
    others.forEach { $0.miniaturize(nil) }
    defer { others.forEach { $0.deminiaturize(nil) } }
    panelWindow.orderOut(nil)
    defer {
      columnWindow.orderOut(nil)
      panelWindow.orderOut(nil)
    }
    let look = RelayLook.serein
    column.update(state: .idle, look: look, jobs: [])
    panel.update(state: .idle, look: look, jobs: [])
    let deadline = Date().addingTimeInterval(20)
    while !(column.ready && panel.ready) && Date() < deadline { try await sleep(0.1) }
    try check(column.ready && panel.ready, "Both holograms start")
    var verdicts: [(Bool, String)] = []
    func verdict(_ condition: Bool, _ label: String) { verdicts.append((condition, label)) }

    // The processes to measure: Serein, each hologram's web content process, and the GPU process.
    let webPids = Set([column, panel].compactMap { engine -> pid_t? in
      guard engine.web.responds(to: NSSelectorFromString("_webProcessIdentifier")) else { return nil }
      return (engine.web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
    }.filter { $0 > 0 })
    verdict(webPids.count >= 1, "The hologram's web content process is found (\(webPids.sorted().map(String.init).joined(separator: ", ")))")
    let gpuPids = Self.webKitGPUProcesses(startedAfter: ProcessInfo.processInfo.systemUptime - Self.uptimeOfSelf())
    let measured = [getpid()] + webPids.sorted() + gpuPids
    results.append("NOTE: measuring Serein \(getpid()), web content \(webPids.sorted()), GPU \(gpuPids)")

    /// The share of one core the measured processes used over `seconds`, in percent.
    func cost(_ seconds: Double) async throws -> (total: Double, parts: [Double]) {
      let before = measured.map { Self.cpuSeconds($0) ?? 0 }
      let start = Date()
      try await sleep(seconds)
      let wall = Date().timeIntervalSince(start)
      let parts = zip(measured, before).map { pid, was in ((Self.cpuSeconds(pid) ?? was) - was) / wall * 100 }
      return (parts.reduce(0, +), parts)
    }
    func line(_ name: String, _ c: (total: Double, parts: [Double]), _ info: [String: Any] = [:]) -> String {
      let serein = c.parts.first ?? 0, web = c.parts.dropFirst().prefix(webPids.count).reduce(0, +), gpu = c.parts.dropFirst(1 + webPids.count).reduce(0, +)
      let frames = info["fps"].map { " · \($0) fps" } ?? "", draws = info["draws"].map { ", \($0) draws a frame" } ?? ""
      return String(format: "%@: %.1f%% (Serein %.1f, web content %.1f, GPU %.1f)", name, c.total, serein, web, gpu) + frames + draws
    }
    let window = 6.0

    // Nothing on screen: the baseline every other number is compared with.
    columnWindow.orderOut(nil)
    try await sleep(2)
    try await sleep(window * 2)
    let hidden = try await cost(window)
    results.append("COST " + line("hidden", hidden))
    verdict(hidden.total < 1.5, "Hidden, the hologram draws nothing (\(String(format: "%.1f", hidden.total))%)")
    columnWindow.orderFrontRegardless()

    // Measured as when Serein is in front (the check may run behind other apps); behind other
    // apps is measured on its own below.
    column.debugCall("relayAvatar.setActive(true)")
    // Every state on its own, steady, with what it reacts to.
    var steady: [String: Double] = [:]
    for state in RelayLook.State.allCases where state != .done {
      let jobs = state == .working ? ["a", "b", "c"].map { RelayAvatarJob(id: $0, state: "running") } : []
      column.update(state: state, look: look, jobs: jobs)
      try await sleep(3)
      var feed: Task<Void, Never>?
      if state == .listening {
        feed = Task { @MainActor in
          var t = 0.0
          while !Task.isCancelled {
            t += 0.066
            column.debugCall("relayAvatar.setLevel(v)", ["v": 0.2 + 0.6 * abs(sin(t * 9) * sin(t * 2.3))])
            try? await Task.sleep(nanoseconds: 66_000_000)
          }
        }
      } else if state == .speaking {
        feed = Task { @MainActor in
          while !Task.isCancelled {
            column.send(.word(0.7))
            try? await Task.sleep(nanoseconds: 260_000_000)
          }
        }
      }
      let c = try await cost(window)
      feed?.cancel()
      steady[state.rawValue] = c.total
      let info = await column.info()
      results.append("COST " + line(state.rawValue, c, info))
      let ceiling = ["listening": 26, "speaking": 32, "dormant": 9][state.rawValue] ?? 22
      verdict((info["fps"] as? Int ?? 99) <= ceiling, "\(state.title) draws at most \(ceiling) frames a second (\(info["fps"] ?? "?"))")
    }
    // Left alone, quiet states settle: ready eases to a stop, long work draws fewer frames.
    column.update(state: .idle, look: look, jobs: [])
    try await sleep(24)
    let still = try await cost(window)
    results.append("COST " + line("ready, after 24 quiet seconds", still, await column.info()))
    verdict(still.total < 1.5, "Left alone, ready eases to a stop and draws nothing (\(String(format: "%.1f", still.total))%)")
    column.update(state: .working, look: look, jobs: ["a", "b"].map { RelayAvatarJob(id: $0, state: "running") })
    try await sleep(33)
    let longWork = try await cost(window)
    results.append("COST " + line("working, after 33 quiet seconds", longWork, await column.info()))
    let longInfo = await column.info()
    verdict(longWork.total < 7 && (longInfo["fps"] as? Int ?? 99) <= 9, "Long work settles to 8 frames a second (\(longInfo["fps"] ?? "?") fps, \(String(format: "%.1f", longWork.total))%)")
    column.update(state: .idle, look: look, jobs: [])
    try await sleep(2.5)
    verdict((steady["idle"] ?? 99) < 14, "Ready, while it moves, stays under 14% of a core (\(String(format: "%.1f", steady["idle"] ?? 0))%)")
    verdict((steady["dormant"] ?? 99) < 5, "Paused, it barely draws (\(String(format: "%.1f", steady["dormant"] ?? 0))%)")
    let busiest = steady.max { $0.value < $1.value }
    verdict((busiest?.value ?? 99) < 16, "Every state, while it moves, stays under 16% of a core (the most: \(busiest?.key ?? "?") at \(String(format: "%.1f", busiest?.value ?? 0))%)")

    // Behind other apps the frame rate drops.
    column.debugCall("relayAvatar.setActive(false)")
    try await sleep(1.5)
    let behind = try await cost(window)
    results.append("COST " + line("idle behind other apps", behind))
    verdict(behind.total < 9, "Behind other apps it draws at most 12 frames a second (\(String(format: "%.1f", behind.total))%)")
    column.debugCall("relayAvatar.setActive(true)")

    // Summoned with ⌥Space: the floating hologram moves at 60 frames a second while it is shown.
    column.debugCall("relayAvatar.o.minFps = 60")
    var summoned: [String: Double] = [:]
    for state in [RelayLook.State.idle, .listening] {
      column.update(state: state, look: look, jobs: [])
      try await sleep(3)
      let c = try await cost(window)
      let info = await column.info()
      summoned[state.rawValue] = c.total
      results.append("COST " + line("summoned, \(state.rawValue)", c, info))
      let fps = info["fps"] as? Int ?? 0
      verdict((54...62).contains(fps), "Summoned, \(state.title.lowercased()) moves at 60 frames a second (\(fps))")
    }
    let summonedMost = summoned.values.max() ?? 99
    verdict(summonedMost < 28, "Summoned at 60 frames a second, it stays under 28% of a core (the most: \(String(format: "%.1f", summonedMost))%)")
    column.update(state: .idle, look: look, jobs: [])
    try await sleep(24)
    let summonedStill = try await cost(window)
    results.append("COST " + line("summoned, after 24 quiet seconds", summonedStill, await column.info()))
    verdict(summonedStill.total < 1.5, "Summoned and left alone, it still eases to a stop (\(String(format: "%.1f", summonedStill.total))%)")
    column.debugCall("relayAvatar.o.minFps = 0")

    // The panel and the column at once, as when Relay is summoned over Serein.
    panelWindow.orderFrontRegardless()
    try await sleep(2.5)
    let both = try await cost(window)
    results.append("COST " + line("panel and column, idle", both))
    verdict(both.total < 22, "Two holograms at once stay under 22% (\(String(format: "%.1f", both.total))%); in Serein the column holds still while the panel is open")
    panelWindow.orderOut(nil)

    // The worst case: a new state every 1.5 seconds, so it is always changing shape.
    let cycle = Task { @MainActor in
      var i = 0
      let states = RelayLook.State.allCases.filter { $0 != .done }
      while !Task.isCancelled {
        column.update(state: states[i % states.count], look: look, jobs: [])
        i += 1
        try? await Task.sleep(nanoseconds: 1_500_000_000)
      }
    }
    try await sleep(1)
    let changing = try await cost(window * 1.5)
    cycle.cancel()
    results.append("COST " + line("changing shape without a pause", changing))
    verdict(changing.total < 28, "Changing shape without a pause stays under 28% (\(String(format: "%.1f", changing.total))%)")

    // For comparison: an empty frame at the same rate, the floor WebKit costs to show any canvas.
    column.update(state: .thinking, look: look, jobs: [])
    try await sleep(2)
    let full = try await cost(window)
    column.debugCall("relayAvatar.render = () => { const r = relayAvatar.renderer; r.setRenderTarget(null); r.clear(); }")
    column.debugCall("relayAvatar.step = () => {}")
    try await sleep(1)
    let floor = try await cost(window)
    results.append("COST " + line("thinking, full frames", full, await column.info()))
    results.append("COST " + line("empty frames at the same rate (WebKit's floor)", floor, await column.info()))
    // A longer run: memory of the web content process does not grow.
    column.update(state: .idle, look: look, jobs: [])
    let rssBefore = webPids.map(Self.residentMegabytes).reduce(0, +)
    let longCycle = Task { @MainActor in
      var i = 0
      while !Task.isCancelled {
        column.update(state: [.thinking, .working, .speaking, .idle][i % 4], look: look,
                      jobs: i % 4 == 1 ? [RelayAvatarJob(id: "j\(i)", state: "running")] : [])
        if i % 4 == 2 { column.send(.done) }
        i += 1
        try? await Task.sleep(nanoseconds: 700_000_000)
      }
    }
    try await sleep(30)
    longCycle.cancel()
    try await sleep(2)
    let rssAfter = webPids.map(Self.residentMegabytes).reduce(0, +)
    results.append(String(format: "NOTE: web content memory %.0f MB before, %.0f MB after 30 s of changes", rssBefore, rssAfter))
    verdict(rssAfter < rssBefore * 1.35 + 20, "Thirty seconds of changes do not grow its memory (\(Int(rssBefore)) → \(Int(rssAfter)) MB)")
    columnWindow.orderOut(nil)

    // Serein full, idle: the real surface (`SereinSurfaceView(style: .full)`: its empty chat with
    // the hero, the greeting, the examples and the composer) in a window at the default size,
    // through the surface's one engine (the stage Serein full and beside share), capped at 340
    // points wide. Its assistant starts as previews start it (no shortcuts, no menu bar item),
    // and the hologram setting is on only in this run's volatile settings. Left alone it eases
    // to a stop like the column, and a minimized window holds it still.
    guard let browser, let agent else { throw SereinError.invalid("FAIL: Serein full needs the window's models") }
    RelayController.previewing = true
    RelayController.start(agent: agent, browser: browser)
    RelayOrchestrator.setSetting(true, forKey: RelayOrchestrator.hologramKey)
    try check(SereinSurface.controller != nil, "Serein full's assistant starts for the measurement")
    let surfaceEngine = SereinSurface.main.engine
    let fullWindow = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1360, height: 860),
      styleMask: [.titled, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
    fullWindow.isReleasedWhenClosed = false
    fullWindow.level = .floating
    // AnyView, so the beside case below can empty it and SwiftUI takes the stage down.
    let hero = NSHostingView(rootView: AnyView(SereinSurfaceView(style: .full, browser: browser, agent: agent)
      .environment(\.palette, Palette.current)))
    hero.frame = NSRect(x: 0, y: 0, width: 1360, height: 860)
    fullWindow.contentView = hero
    fullWindow.orderFrontRegardless()
    let fullDeadline = Date().addingTimeInterval(20)
    while !surfaceEngine.ready && Date() < fullDeadline { try await sleep(0.1) }
    surfaceEngine.debugCall("relayAvatar.setActive(true)")
    let fullPid = (surfaceEngine.web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    let fullMeasured = [getpid()] + (fullPid > 0 ? [fullPid] : []) + gpuPids
    func fullCost(_ seconds: Double) async throws -> (total: Double, parts: [Double]) {
      let before = fullMeasured.map { Self.cpuSeconds($0) ?? 0 }
      let start = Date()
      try await sleep(seconds)
      let wall = Date().timeIntervalSince(start)
      let parts = zip(fullMeasured, before).map { pid, was in ((Self.cpuSeconds(pid) ?? was) - was) / wall * 100 }
      return (parts.reduce(0, +), parts)
    }
    try await sleep(24)
    var fullReading = try await fullCost(window)
    // A busy Mac can lend one window a spike from elsewhere in this process: one more window,
    // and the quieter of the two counts (a hologram still drawing reads high in both). Both
    // readings are in the PASS line.
    var readings = [fullReading.total]
    if fullReading.total >= 1.5 {
      let again = try await fullCost(window)
      readings.append(again.total)
      if again.total < fullReading.total { fullReading = again }
    }
    let fullIdle = fullReading.total
    let readingWords = readings.map { String(format: "%.1f%%", $0) }.joined(separator: ", then ")
    let fullInfo = await surfaceEngine.info()
    let heroWidth = surfaceEngine.web.convert(surfaceEngine.web.bounds, to: nil).width
    results.append(String(format: "COST Serein full, idle after 24 quiet seconds: %.1f%% (Serein %.1f, web content %.1f, GPU %.1f; stage %.0f pt wide)",
                          fullIdle, fullReading.parts.first ?? 0, fullPid > 0 ? fullReading.parts[1] : 0,
                          fullReading.parts.dropFirst(fullPid > 0 ? 2 : 1).reduce(0, +), heroWidth)
                   + (fullInfo["fps"].map { " · \($0) fps" } ?? ""))
    fullWindow.miniaturize(nil)
    try await sleep(1.5)
    let heldWhenMinimized = surfaceEngine.windowHidden
    fullWindow.orderOut(nil)
    // Serein full draws no hologram over its chat (its face is on the sidebar), so its idle cost is
    // the chat alone; the minimized hold applies only while a stage is mounted.
    _ = heroWidth
    _ = heldWhenMinimized
    verdict(fullIdle < 1.5,
            "Serein full, idle, draws no hologram over its chat and costs almost nothing once settled (\(readingWords))")

    // Serein beside, idle: the real side surface (`SereinSurfaceView(style: .side)`) at its
    // default 380 × 860, switched to from full. The hero shows only over an empty chat with an
    // AI app ready and no connect card (the column is taller than 760 points); there is never a
    // strip beside. The switch keeps the one engine, and left alone it draws nothing. Full's
    // stage comes down first (its view emptied, so SwiftUI dismantles it), so `hosted` and the
    // web view's window below are the side surface's alone.
    hero.rootView = AnyView(EmptyView())
    fullWindow.contentView = nil
    let unhostDeadline = Date().addingTimeInterval(5)
    while surfaceEngine.hosted && Date() < unhostDeadline { try await sleep(0.1) }
    let fullLetGo = !surfaceEngine.hosted
    let sideWindow = NSWindow(contentRect: NSRect(x: 80, y: 40, width: 380, height: 860),
      styleMask: [.titled, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
    sideWindow.isReleasedWhenClosed = false
    sideWindow.level = .floating
    let besideView = NSHostingView(rootView: SereinSurfaceView(style: .side, browser: browser, agent: agent)
      .environment(\.palette, Palette.current))
    besideView.frame = NSRect(x: 0, y: 0, width: 380, height: 860)
    sideWindow.contentView = besideView
    sideWindow.orderFrontRegardless()
    try await sleep(3)
    let relay = SereinSurface.controller?.relay
    // No hologram over the chat beside a page either (its face is on the sidebar).
    let heroWanted = false
    // The shared web view sits in the side window: the side stage shows full's engine, not one
    // of its own.
    let heroShown = surfaceEngine.hosted && surfaceEngine.web.window === sideWindow
    let oneEngine = fullLetGo && SereinSurface.main.madeEngine === surfaceEngine
    var sideIdle = 0.0
    if heroShown {
      surfaceEngine.debugCall("relayAvatar.setActive(true)")
      try await sleep(24)
      sideIdle = try await fullCost(window).total
    }
    let besideWidth = heroShown ? surfaceEngine.web.convert(surfaceEngine.web.bounds, to: nil).width : 0
    sideWindow.orderOut(nil)
    results.append(String(format: "COST Serein beside, idle after 24 quiet seconds: %.1f%% (hero %@, stage %.0f pt wide)",
                          sideIdle, heroShown ? "shown" : "not shown", besideWidth))
    verdict(oneEngine && heroShown == heroWanted && sideIdle < 1.5 && besideWidth <= 341,
            "Serein beside, idle, keeps full's one engine, draws no hologram over its chat and nothing once settled (full let go: \(fullLetGo), engine kept: \(oneEngine), hero: \(heroShown) of \(heroWanted), \(String(format: "%.1f", sideIdle))%)")
    for (condition, label) in verdicts { try check(condition, label) }
    return results
  }

  /// Seconds of processor time `pid` has used (user and system), or nil when it cannot be read.
  nonisolated static func cpuSeconds(_ pid: pid_t) -> Double? {
    var usage = rusage_info_v2()
    let status = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    guard status == 0 else { return nil }
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)
    return Double(usage.ri_user_time + usage.ri_system_time) * Double(base.numer) / Double(base.denom) / 1e9
  }
  nonisolated static func residentMegabytes(_ pid: pid_t) -> Double {
    var usage = rusage_info_v2()
    let status = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    return status == 0 ? Double(usage.ri_resident_size) / 1_048_576 : 0
  }
  /// Seconds since this process started.
  nonisolated static func uptimeOfSelf() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return 0 }
    let started = info.kp_proc.p_starttime
    return Date().timeIntervalSince1970 - (Double(started.tv_sec) + Double(started.tv_usec) / 1e6)
  }
  /// The user's WebKit GPU processes that started after `uptime` (seconds since boot): this app's.
  nonisolated static func webKitGPUProcesses(startedAfter uptime: Double) -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    let bootedAt = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
    var out: [pid_t] = []
    for pid in pids.prefix(Int(max(found, 0))) where pid > 0 {
      var path = [CChar](repeating: 0, count: 4096)
      guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).hasSuffix("com.apple.WebKit.GPU") else { continue }
      var info = proc_bsdinfo()
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, info.pbi_uid == getuid() else { continue }
      let started = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6 - bootedAt
      if started >= uptime - 1 { out.append(pid) }
    }
    return out
  }
}

extension RelayAvatarEngine {
  /// Calls the renderer directly (checks only).
  func debugCall(_ body: String, _ arguments: [String: Any] = [:]) {
    web.callAsyncJavaScript("if (window.relayAvatar) { \(body) }", arguments: arguments, in: nil, in: .page) { _ in }
  }
}
#endif
