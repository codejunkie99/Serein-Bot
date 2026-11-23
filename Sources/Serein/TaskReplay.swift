import AppKit
import AVFoundation
import AVKit
import os
import SereinCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// One recorded run of a task: an MP4 of Serein's own tabs on this Mac, the run's steps, and which
/// tab each stretch of the video shows. Video time is wall time since `startedAt`, so a step's
/// time is its place in the video.
struct TaskRecording: Codable, Identifiable {
  struct Segment: Codable {
    var tab: String
    /// “Tab 2 · example.com”: tabs are numbered in the order the recording first showed them,
    /// with the site the segment began on.
    var label: String
    var start: Double
    var end: Double
  }
  var id: String
  var thread: String
  var startedAt: Date
  /// nil while it records, and in a recording an earlier launch never finished.
  var endedAt: Date?
  var steps: [AgentStep] = []
  var segments: [Segment] = []
  /// Step id -> seconds since `startedAt`, at full precision: the saved dates keep whole seconds.
  var offsets: [String: Double] = [:]
  /// The assistant its task worked for when it began (`assistantOwning`), for that assistant's
  /// Library after a relaunch; nil for the person's own tasks and in an index an earlier build wrote.
  var owner: String? = nil
  /// Under the Record this task switch, in every Options that shows it.
  static let switchNote = "A video of the pages this task opens, kept on this Mac to watch after the run. Pages with password, card or code fields are blacked out."

  func offset(of step: AgentStep) -> Double { offsets[step.id] ?? max(0, step.time.timeIntervalSince(startedAt)) }
  /// The tab the step named (“Not recorded” when the video never showed it), else the tab the
  /// video showed when it ran.
  func tabLabel(for step: AgentStep) -> String? {
    if let tab = step.tab { return segments.first(where: { $0.tab == tab })?.label ?? "Not recorded" }
    let at = offset(of: step)
    return (segments.last { $0.start <= at } ?? segments.first)?.label
  }
}

extension TaskRecording {
  /// `offsets` may be missing from an index an earlier build wrote; such steps fall back to their dates.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    thread = try container.decode(String.self, forKey: .thread)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
    steps = try container.decode([AgentStep].self, forKey: .steps)
    segments = try container.decode([Segment].self, forKey: .segments)
    offsets = try container.decodeIfPresent([String: Double].self, forKey: .offsets) ?? [:]
    owner = try container.decodeIfPresent(String.self, forKey: .owner)
  }
}

/// Record this task: per thread, off unless the person turns it on in the task's Options. While
/// on, each run of that thread records the agent-owned tab it works in, through the same viewport
/// writer as Record This Page (`ViewportMovieWriter`). Frames of a page with a password, card or
/// code field (`pageIsSensitive`, which fails closed) are black. Only tabs the task owns are
/// recorded: the person's tabs and private windows never belong to a task. Nothing here is a tool,
/// in a prompt or in a folder an agent may read; files live under the Library's private
/// `task-recordings` folder and unsaved ones are deleted on schedule (hourly, launch and quit).
@MainActor final class TaskRecordings: ObservableObject {
  static let shared = TaskRecordings()
  /// Settings › Privacy: days to keep unsaved recordings; 0 deletes them at quit.
  static let keepKey = "serein.taskRecordingDays"
  static let folder = "task-recordings"
  private static let log = Logger(subsystem: "app.serein", category: "task-recordings")
  @Published private(set) var recordings: [TaskRecording] = []
  /// Threads with Record this task on.
  @Published private(set) var threads: Set<String> = []
  /// Browser tasks recording now (the agent tab rows' dot).
  @Published private(set) var recordingTasks: Set<String> = []
  private weak var browser: BrowserModel?
  private var active: [String: Recorder] = [:]
  /// Hourly retention while Serein stays open, so “1 day” and “7 days” hold on a Mac that never quits it.
  private var sweep: Task<Void, Never>?
  /// The recording whose Save panel is open, kept from the hourly sweep until the copy is made.
  private var saving: String?

  /// One run's capture. It holds its tab and page weakly: the recorder never keeps a page alive,
  /// and a page that is closed or discarded (`BrowserTab.discardPage` swaps the web view) ends
  /// its segment at the next frame.
  @MainActor private final class Recorder {
    let task: String
    let movie: ViewportMovieWriter
    var recording: TaskRecording
    var loop: Task<Void, Never>?
    weak var tab: BrowserTab?
    weak var web: WKWebView?
    var numbers: [String: Int] = [:]
    /// A gap with no tab to show has had its one black frame.
    var blackShown = false
    init(task: String, movie: ViewportMovieWriter, recording: TaskRecording) {
      self.task = task
      self.movie = movie
      self.recording = recording
    }
  }

  private var directory: URL? { browser?.library.root.appendingPathComponent(Self.folder, isDirectory: true) }
  func file(_ recording: TaskRecording) -> URL? { directory?.appendingPathComponent(recording.id + ".mp4") }
  func isRecording(task: String) -> Bool { recordingTasks.contains(task) }
  /// The thread's newest finished recording.
  func latest(thread: String) -> TaskRecording? { recordings.last { $0.thread == thread && $0.endedAt != nil } }

  /// At launch: loads the switches and the index, then deletes what is due.
  func attach(_ browser: BrowserModel) {
    self.browser = browser
    guard let directory else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    threads = Set(browser.library.load([String].self, from: Self.folder + "/threads.json") ?? [])
    if let loaded = browser.library.load([TaskRecording].self, from: Self.folder + "/index.json") {
      recordings = loaded
    } else {
      recordings = []
      if FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path) {
        Self.log.error("task-recordings/index.json could not be read; unlisted videos are kept until they are past the chosen time")
      }
    }
    cleanup()
    sweep?.cancel()
    sweep = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        guard let self, !Task.isCancelled else { return }
        self.sweepDue()
      }
    }
  }

  /// At quit: a recording still running is dropped unfinished, then what is due is deleted.
  func quit() {
    sweep?.cancel()
    sweep = nil
    for recorder in active.values {
      recorder.loop?.cancel()
      remove(recorder.recording.id)
    }
    active.removeAll()
    recordingTasks.removeAll()
    cleanup()
  }

  /// At launch and quit: what is due, every recording under “Until quit”, then any file in the
  /// folder the index does not list. An unlisted video (an index that could not be read) goes
  /// once it is past the chosen time, or under “Until quit”.
  private func cleanup(now: Date = Date()) {
    sweepDue(now: now, untilQuit: true)
    guard let directory else { return }
    let listed = Set(recordings.map { $0.id + ".mp4" } + ["index.json", "threads.json"])
    let days = UserDefaults.standard.integer(forKey: Self.keepKey)
    for item in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    where !listed.contains(item.lastPathComponent) {
      if item.pathExtension == "mp4", days > 0,
        let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
        now.timeIntervalSince(modified) < Double(days) * 86_400 { continue }
      try? FileManager.default.removeItem(at: item)
    }
  }

  /// Deletes finished recordings older than the chosen days, never one recording now or being
  /// saved; unfinished ones and, under “Until quit”, finished ones go only at launch and quit.
  private func sweepDue(now: Date = Date(), untilQuit: Bool = false) {
    let days = UserDefaults.standard.integer(forKey: Self.keepKey)
    for recording in recordings where active.values.allSatisfy({ $0.recording.id != recording.id })
      && recording.id != saving
    {
      guard let ended = recording.endedAt else {
        // Recording or finishing now; an earlier launch's goes at launch, a running one at quit.
        if untilQuit { remove(recording.id) }
        continue
      }
      let kept = days > 0 ? now.timeIntervalSince(ended) < Double(days) * 86_400 : !untilQuit
      if !kept { remove(recording.id) }
    }
  }

  /// The Options switch. On during a run starts recording it now; off finishes what was recorded.
  func set(_ on: Bool, thread: String) {
    if on { threads.insert(thread) } else { threads.remove(thread) }
    try? browser?.library.save(threads.sorted(), to: Self.folder + "/threads.json")
    guard let browser else { return }
    if on {
      for (task, info) in browser.agentTabs.runs where info.threadID == thread && !info.ended {
        begin(task: task, thread: thread)
      }
    } else {
      for recorder in active.values where recorder.recording.thread == thread { recorder.loop?.cancel() }
    }
  }

  /// A run started (AgentTabBoard.register): recorded only when its thread has the switch on.
  func runStarted(task: String, thread: String) {
    if threads.contains(thread) { begin(task: task, thread: thread) }
  }

  private func begin(task: String, thread: String) {
    guard active[task] == nil, let browser, browser.tasks[task] != nil, let directory else { return }
    var recording = TaskRecording(id: UUID().uuidString, thread: thread, startedAt: Date())
    recording.owner = RelayOrchestrator.shared?.assistantOwning(thread: thread)
    // 4:3, the size of an agent tab's page; other sizes are letterboxed by the writer.
    guard let movie = try? ViewportMovieWriter(url: directory.appendingPathComponent(recording.id + ".mp4"), width: 1000, height: 750) else {
      browser.notice = "This task could not be recorded."
      return
    }
    let recorder = Recorder(task: task, movie: movie, recording: recording)
    active[task] = recorder
    recordingTasks = Set(active.keys)
    // Listed while it records, so a recording a crash cut short is deleted at the next launch.
    recordings.append(recording)
    persist()
    recorder.loop = Task { [weak self] in
      await self?.capture(recorder)
      await self?.finish(recorder)
    }
  }

  private static let black: CGImage = {
    let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    return context.makeImage()!
  }()

  /// Two frames a second until the run's browser task ends, its run ends, or the switch goes off.
  private func capture(_ recorder: Recorder) async {
    while !Task.isCancelled {
      let tick = ProcessInfo.processInfo.systemUptime
      guard let browser, browser.tasks[recorder.task] != nil,
        browser.agentTabs.run(for: recorder.task)?.isActive == true
      else { return }
      let info = browser.agentTabs.runs[recorder.task]
      let at = Date().timeIntervalSince(recorder.recording.startedAt)
      // Only the chosen tab is kept across the awaits below, not a copy of the task's tab list.
      let wanted = info?.steps.last { $0.tab != nil }?.tab
      let shown = browser.tasks[recorder.task].flatMap { Self.source($0, taskID: recorder.task, wanted: wanted) }
      follow(recorder, shown, at: at)
      // The page is checked before and after its picture; a page that has, or cannot rule out, a
      // password, card or code field gives a black frame. With no tab to show, one black frame
      // marks the gap and nothing is probed or encoded until a tab is back.
      var frame: CGImage?
      var gap = false
      if let tab = recorder.tab, let web = recorder.web {
        var image: CGImage?
        if tab.web === web, !(await tab.pageIsSensitive()), let shot = try? await PageViewportRecorder.snapshot(web),
          tab.web === web, tab.owner == recorder.task, !(await tab.pageIsSensitive())
        {
          image = shot
        }
        frame = image ?? Self.black
        recorder.blackShown = false
      } else if !recorder.blackShown {
        frame = Self.black
        gap = true
      }
      guard !Task.isCancelled else { return }
      if let frame {
        do {
          let appended = try await recorder.movie.append(frame, seconds: at)
          if gap { recorder.blackShown = appended }
        } catch {
          browser.notice = "Task recording stopped: " + error.localizedDescription
          return
        }
      }
      if let steps = info?.steps { copySteps(steps, to: recorder) }
      let spent = ProcessInfo.processInfo.systemUptime - tick
      try? await Task.sleep(nanoseconds: UInt64(max(0.001, 0.5 - spent) * 1_000_000_000))
    }
  }

  /// The run's steps since the recording began, each with its place in the video at full precision.
  private func copySteps(_ steps: [AgentStep], to recorder: Recorder) {
    let start = recorder.recording.startedAt
    recorder.recording.steps = steps.filter { $0.time >= start }
    for step in recorder.recording.steps where recorder.recording.offsets[step.id] == nil {
      recorder.recording.offsets[step.id] = step.time.timeIntervalSince(start)
    }
  }

  /// The tab to show: one the task owns, awake and with a page, preferring the tab of its latest
  /// step that named one, then the tab of its latest call, then its newest tab.
  private static func source(_ task: BrowserTask, taskID: String, wanted: String?) -> BrowserTab? {
    let own = task.tabs.filter { $0.owner == taskID && !$0.hiddenFromAgents && !$0.sleeping && $0.web.url != nil }
    return own.first { $0.id == wanted } ?? own.first { $0.id == task.lastTab } ?? own.last
  }

  /// Extends the current segment, or closes it and starts one for another tab or a new page.
  private func follow(_ recorder: Recorder, _ tab: BrowserTab?, at: Double) {
    if let tab, tab === recorder.tab, tab.web === recorder.web, !recorder.recording.segments.isEmpty {
      recorder.recording.segments[recorder.recording.segments.count - 1].end = at
      return
    }
    recorder.tab = tab
    recorder.web = tab?.web
    guard let tab else { return }
    let number = recorder.numbers[tab.id] ?? recorder.numbers.count + 1
    recorder.numbers[tab.id] = number
    recorder.recording.segments.append(.init(tab: tab.id, label: "Tab \(number) · " + (tab.web.url?.host ?? "page"),
      start: at, end: at))
  }

  private func finish(_ recorder: Recorder) async {
    guard active[recorder.task] === recorder else { return }
    active[recorder.task] = nil
    recordingTasks = Set(active.keys)
    recorder.tab = nil
    recorder.web = nil
    // The last steps (often the final action and finish) came after the last frame's copy.
    if let steps = browser?.agentTabs.runs[recorder.task]?.steps { copySteps(steps, to: recorder) }
    var recording = recorder.recording
    // A task Serein started is adopted once its run is under way: its owner is known by now.
    if recording.owner == nil { recording.owner = RelayOrchestrator.shared?.assistantOwning(thread: recording.thread) }
    let ended = Date()
    do {
      // A run that never showed a tab has nothing to watch.
      guard !recording.segments.isEmpty, let url = file(recording) else { throw CancellationError() }
      try await recorder.movie.finish(seconds: ended.timeIntervalSince(recording.startedAt))
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      recording.endedAt = ended
      guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { throw CancellationError() }
      recordings[index] = recording
      persist()
    } catch {
      await recorder.movie.cancel()
      remove(recording.id)
    }
  }

  /// Save…: copies the video to the place chosen in the save panel and nowhere else. The copy is
  /// made in the private folder first, so a failed save leaves an existing file as it was.
  func save(_ recording: TaskRecording) {
    guard !RunMode.automated, let source = file(recording), let directory else { return }
    saving = recording.id
    defer { saving = nil }
    let panel = ChatExport.savePanel(
      named: ChatExport.movieName("task", at: recording.startedAt), title: "Save Task Recording", types: [.mpeg4Movie])
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    let copy = directory.appendingPathComponent(recording.id + ".saving")
    do {
      try? FileManager.default.removeItem(at: copy)
      try FileManager.default.copyItem(at: source, to: copy)
      try ChatExport.place(copy, at: destination)
      browser?.notice = "Saved task recording to " + destination.lastPathComponent
    } catch {
      try? FileManager.default.removeItem(at: copy)
      NSAlert(error: error).runModal()
    }
  }

  /// Delete: the video and its entry, now.
  func delete(_ recording: TaskRecording) { remove(recording.id) }

  private func remove(_ id: String) {
    if let file = directory?.appendingPathComponent(id + ".mp4") { try? FileManager.default.removeItem(at: file) }
    recordings.removeAll { $0.id == id }
    persist()
  }

  private func persist() { try? browser?.library.save(recordings, to: Self.folder + "/index.json") }
}

/// The task view's Replay, after the run: the video, which tab each stretch shows, and the steps
/// with their tabs. A step or a tab jumps the video to it. Save… and Delete act on the file only.
struct TaskReplaySection: View {
  let thread: String
  @ObservedObject private var recordings = TaskRecordings.shared
  @State private var player: AVPlayer?
  @State private var playerFor: String?
  @State private var stepsHeight: CGFloat = 0
  static let stepsMaxHeight: CGFloat = 220
  @Environment(\.palette) var p
  var body: some View {
    if let recording = recordings.latest(thread: thread) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text("Replay").font(UIStyle.bodyStrong).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
          Spacer(minLength: 4)
          Button("Save…") { recordings.save(recording) }.buttonStyle(QuietButton())
            .help("Save this video to a place you choose")
          Button("Delete") {
            player?.replaceCurrentItem(with: nil)
            recordings.delete(recording)
          }.buttonStyle(QuietButton()).help("Delete this video from this Mac")
        }
        if let player {
          ReplayPlayer(player: player).aspectRatio(4.0 / 3.0, contentMode: .fit).frame(maxHeight: 320)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: UIStyle.panelRadius))
            .accessibilityLabel("Recording of this task")
        }
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(Array(recording.segments.enumerated()), id: \.offset) { _, segment in
              Button { seek(segment.start) } label: {
                Text("\(segment.label) · \(TaskClock.short(segment.start))–\(TaskClock.short(segment.end))")
                  .font(UIStyle.micro).monospacedDigit().foregroundStyle(p.secondary)
                  .padding(.horizontal, 8).frame(height: 22).background(p.track, in: Capsule())
              }.buttonStyle(.pressable).help("Play from where \(segment.label) starts")
            }
          }
        }
        // As tall as its steps up to a fixed cap, then it scrolls: a nested scroll view with only a
        // max height can collapse inside the task view's own scroll view.
        ScrollView {
          AgentStepList(steps: recording.steps, tab: { recording.tabLabel(for: $0) },
                        seek: { seek(recording.offset(of: $0)) })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stepsHeight = $0 }
        }.frame(height: min(max(stepsHeight, 1), Self.stepsMaxHeight))
        Text("Kept only on this Mac and never shown to the AI. Pages with password, card or code fields are blacked out.")
          .font(UIStyle.micro).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }
      .padding(12)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .onAppear { load(recording) }
      .onChange(of: recording.id) { _, _ in load(recording) }
      .accessibilityElement(children: .contain).accessibilityLabel("Replay")
    }
  }
  private func load(_ recording: TaskRecording) {
    guard playerFor != recording.id, let url = recordings.file(recording) else { return }
    player = AVPlayer(url: url)
    playerFor = recording.id
  }
  private func seek(_ seconds: Double) {
    player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  }
}

/// The system player with its inline controls.
private struct ReplayPlayer: NSViewRepresentable {
  let player: AVPlayer
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .inline
    view.showsFullScreenToggleButton = false
    view.player = player
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
  }
}
