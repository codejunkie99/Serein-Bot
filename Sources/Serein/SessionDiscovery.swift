import CoreServices
import SereinCore
import SwiftUI

/// Finds folders the user already works in from Claude Code and Codex history.
/// Automatic by default: every folder found is saved, and the classifier puts it under projects
/// or "Other folders". It reads only the start of each local session log and nothing leaves this
/// Mac. Turning it off (Settings or the Projects ⋯ menu) stops reading; saved folders stay.
@MainActor final class SessionDiscoveryModel: ObservableObject {
  static let shared = SessionDiscoveryModel()
  enum Phase { case asking, scanning, found, empty }

  @Published var presenting = false
  @Published var phase = Phase.asking
  @Published var found: [DiscoveredProject] = []
  @Published var selected = Set<String>()
  @Published var offered: [DiscoveredProject] = []  // only used when automatic saving is off
  /// True while a pass over history runs; the empty state waits for it.
  @Published var scanning = false
  weak var browser: BrowserModel?
  private var stream: FSEventStreamRef?
  private var rescanTask: Task<Void, Never>?
  private var manualScanTask: Task<Void, Never>?
  private var rescanRequested = false
  private var rescanAnnounce = false
  /// What the last pass listed and read; nil until a full pass ends and after discovery stops.
  private var lastScan: SessionIndex.Scan?
  /// History paths FSEvents named since the last pass began; nil asks for a full pass.
  private var changedPaths: Set<String>? = []
  private static let autoKey = "serein.sessionDiscovery.automatic"
  private let dismissedKey = "serein.sessionDiscovery.dismissed"

  /// Automatic discovery; on unless the user turned it off. Never on in checks or previews.
  @Published var automatic: Bool =
    (UserDefaults.standard.object(forKey: SessionDiscoveryModel.autoKey) as? Bool ?? true)
    && !RunMode.automated && !RunMode.stress
  {
    didSet {
      guard automatic != oldValue else { return }
      UserDefaults.standard.set(automatic, forKey: Self.autoKey)
      if automatic {
        startWatching()
        rescan()
      } else {
        stopWatching()
        rescanTask?.cancel()
        // Changes while off go unseen, so the next pass reads everything.
        lastScan = nil
        rescanRequested = false
        rescanAnnounce = false
        if !offered.isEmpty { offered = [] }
      }
    }
  }
  var consented: Bool { automatic }
  var dismissed: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: dismissedKey) }
  }
  /// A folder the user removed from Serein; automatic discovery leaves it out from now on.
  func remember(removed path: String) { dismissed.insert(ProjectAutoDiscovery.key(path)) }

  /// Called at launch and when Projects opens. Starts the watch and a first pass.
  func attach(_ browser: BrowserModel) {
    self.browser = browser
    if automatic, stream == nil { startWatching(); rescan(initial: true) }
  }

  /// "Find from Claude Code and Codex…": with automatic discovery on, look again now; otherwise
  /// show the sheet so the user picks folders by hand.
  func present() {
    if automatic {
      rescan(announce: true)
      return
    }
    found = []
    selected = []
    phase = .scanning
    presenting = true
    scan()
  }
  func agree() { automatic = true }
  func decline() { manualScanTask?.cancel(); presenting = false }

  private func knownKeys() -> Set<String> {
    Set((browser?.projects ?? []).map { ProjectInsights.key($0.path) })
  }
  /// History folders that are not projects (chat folders, temp, home…) this scan left out.
  @Published var skipped = 0
  private func runScan() async -> [DiscoveredProject] {
    let worker = Task.detached(priority: .utility) {
      SessionIndex.discover(
        claudeRoot: SessionIndex.defaultClaudeRoot(), codexRoot: SessionIndex.defaultCodexRoot())
    }
    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: { worker.cancel() }
  }
  /// Only folders that look like projects are offered by hand; one-off chat folders are not.
  private func candidates(_ all: [DiscoveredProject]) async -> [DiscoveredProject] {
    let context = browser?.projectCandidateContext ?? .current()
    let worker = Task.detached(priority: .utility) {
      all.filter { !Task.isCancelled && ProjectCandidate.classify(path: $0.path, context: context).isProject }
    }
    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: { worker.cancel() }
  }
  private func scan() {
    manualScanTask?.cancel()
    manualScanTask = Task {
      let all = await runScan()
      guard !Task.isCancelled else { return }
      let known = knownKeys()
      let usable = await candidates(all)
      guard !Task.isCancelled else { return }
      skipped = all.filter { !known.contains($0.path) }.count - usable.filter { !known.contains($0.path) }.count
      found = usable.filter { !known.contains($0.path) }
      selected = Set(found.prefix(20).map(\.path))
      phase = found.isEmpty ? .empty : .found
      refreshKnown(all)
    }
  }
  /// Keeps session titles current for folders that are already saved.
  private func refreshKnown(_ all: [DiscoveredProject]) {
    guard let browser else { return }
    let known = knownKeys()
    var titles: [String: [String]] = [:]
    for project in all where known.contains(project.path) {
      titles[project.path] = project.sessions.map(\.title)
    }
    ProjectInsights.shared.setTitles(titles, library: browser.library)
  }

  func add() {
    guard let browser else { return }
    let chosen = found.filter { selected.contains($0.path) }
    var skipped = dismissed
    for item in found where !selected.contains(item.path) { skipped.insert(item.path) }
    dismissed = skipped
    for item in chosen where !browser.projects.contains(where: { ProjectInsights.key($0.path) == item.path }) {
      browser.projects.append(Project(name: item.name, path: item.path, source: .history))
    }
    ProjectInsights.shared.setTitles(
      Dictionary(uniqueKeysWithValues: chosen.map { ($0.path, $0.sessions.map(\.title)) }),
      library: browser.library)
    browser.saveProjects()
    browser.warnIfHoldsSereinData(chosen.map(\.path))
    browser.notice = "Added \(chosen.count) project\(chosen.count == 1 ? "" : "s") from your history."
    offered.removeAll { item in chosen.contains { $0.path == item.path } }
    presenting = false
  }
  func review() {
    found = offered
    selected = Set(offered.map(\.path))
    phase = .found
    presenting = true
  }
  func dismissOffers() {
    dismissed.formUnion(offered.map(\.path))
    offered = []
  }

  /// Saves a finished pass: new folders join the projects or "Other folders" with their
  /// verdicts. It says nothing by itself; `announce` answers the person who asked for this pass.
  func apply(_ result: ProjectDiscoveryResult, announce: Bool = false) {
    guard let browser else { return }
    browser.addDiscovered(result)
    // One title-cache commit covers previously known and newly accepted folders. A folder
    // removed while the pass ran stays absent from both the project list and its evidence.
    refreshKnown(result.discovered)
    if announce {
      browser.notice =
        result.added.isEmpty
        ? "No new folders in your agent history."
        : "Added \(result.added.count) folder\(result.added.count == 1 ? "" : "s") from your agent history."
    }
  }

  // MARK: Watching

  /// One pass over history, off the main thread, then saved on it. Runs at launch and whenever
  /// the history folders change (FSEvents, coalesced over ten seconds). With the event `paths`,
  /// only the folders they touch are listed again; without them (launch, "look again"), all are.
  func rescan(initial: Bool = false, announce: Bool = false, paths: [String]? = nil) {
    guard automatic, let browser else { return }
    if let paths { changedPaths?.formUnion(paths) } else { changedPaths = nil }
    rescanRequested = true
    rescanAnnounce = rescanAnnounce || announce
    // File-system bursts request one follow-up pass instead of starting overlapping walkers.
    guard rescanTask == nil else { return }
    if !scanning { scanning = true }
    rescanTask = Task {
      defer {
        rescanTask = nil
        if scanning { scanning = false }
        // Off then on during a cancelled pass must still start the newly requested pass.
        if automatic, rescanRequested { rescan() }
      }
      while rescanRequested, automatic, !Task.isCancelled {
        rescanRequested = false
        let announce = rescanAnnounce
        rescanAnnounce = false
        let existing = browser.projects
        let removed = dismissed
        let context = browser.projectCandidateContext
        let claudeRoot = SessionIndex.defaultClaudeRoot()
        let codexRoot = SessionIndex.defaultCodexRoot()
        let touched = lastScan == nil ? nil
          : changedPaths.flatMap { SessionIndex.touched(Array($0), claudeRoot: claudeRoot, codexRoot: codexRoot) }
        changedPaths = []
        let last = lastScan ?? SessionIndex.Scan()
        let worker = Task.detached(priority: .utility) {
          // ProjectAutoDiscovery.run, over the sessions this pass found.
          var state = last
          let discovered = SessionIndex.group(
            SessionIndex.sessions(claudeRoot: claudeRoot, codexRoot: codexRoot, touched: touched, scan: &state))
          let added = ProjectAutoDiscovery.newProjects(discovered, existing: existing, removed: removed)
          return (
            ProjectDiscoveryResult(
              added: added, kinds: ProjectAutoDiscovery.kinds(added, context: context), discovered: discovered),
            state
          )
        }
        let (result, next) = await withTaskCancellationHandler {
          await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled, automatic else { return }
        lastScan = next
        apply(result, announce: announce)
      }
    }
  }
  func startWatching() {
    guard stream == nil else { return }
    let roots = [SessionIndex.defaultClaudeRoot(), SessionIndex.defaultCodexRoot()].map(\.path)
      .filter { FileManager.default.fileExists(atPath: $0) }
    guard !roots.isEmpty else { return }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
      guard let info else { return }
      let model = Unmanaged<SessionDiscoveryModel>.fromOpaque(info).takeUnretainedValue()
      let list = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
      let changed = (0..<count).map { String(cString: list[$0]) }
      Task { @MainActor in model.rescan(paths: changed) }
    }
    guard
      let created = FSEventStreamCreate(
        nil, callback, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        10, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
    else { return }
    FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
    FSEventStreamStart(created)
    stream = created
  }
  func stopWatching() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }
}

struct SessionDiscoverySheet: View {
  @ObservedObject var model: SessionDiscoveryModel
  @Environment(\.palette) var p

  func relative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
  }
  func short(_ path: String) -> String { HomePath.short(path) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      switch model.phase {
      case .asking:
        Text("Look through your agents’ chat history?").font(UIStyle.title)
        Text(
          "Serein can read the chats that your agent apps keep on this Mac, to find folders you already work in and to let you open and continue a chat here. Its index keeps the folder, the first message and the time of each chat; a chat is read in full only when you open it. Serein does not change these files. When Serein chooses where a request goes, titles of recent chats go to your agent with it. You choose which folders to add."
        ).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(
          horizontal: false, vertical: true)
        Text("Reads the chats of Claude Code, Codex, Cursor Agent, OpenCode, Pi, Oh My Pi and Grok in their own folders. You can stop this in Settings.")
          .font(UIStyle.micro).foregroundStyle(p.secondary)
        Spacer(minLength: 0)
        HStack {
          Spacer()
          Button("Not now") { model.decline() }.buttonStyle(QuietButton())
          Button("Look for projects") { model.agree() }.buttonStyle(PrimaryButton())
        }
      case .scanning:
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Looking through your history…").font(UIStyle.body)
        }
        Spacer(minLength: 0)
      case .empty:
        Text("No new projects found").font(UIStyle.title)
        Text(
          model.skipped > 0
            ? "Every project in your history is already here. \(model.skipped) one-off chat or temporary folder\(model.skipped == 1 ? " was" : "s were") left out."
            : "Every folder in your Claude Code and Codex history is already here, or no longer exists."
        ).font(UIStyle.meta).foregroundStyle(p.secondary)
        Spacer(minLength: 0)
        HStack {
          Spacer()
          Button("Done") { model.decline() }.buttonStyle(PrimaryButton())
        }
      case .found:
        Text(
          "Found \(model.found.count) project\(model.found.count == 1 ? "" : "s") in your Claude Code and Codex history"
        ).font(UIStyle.title)
        HStack {
          Button("Select all") { model.selected = Set(model.found.map(\.path)) }
          Button("Select none") { model.selected = [] }
          Spacer()
          if model.skipped > 0 {
            Text("\(model.skipped) chat or temporary folder\(model.skipped == 1 ? "" : "s") left out")
              .foregroundStyle(p.faint)
          }
        }.buttonStyle(QuietButton()).font(UIStyle.micro)
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(model.found) { item in
              Toggle(
                isOn: Binding(
                  get: { model.selected.contains(item.path) },
                  set: { on in
                    if on { model.selected.insert(item.path) } else { model.selected.remove(item.path) }
                  })
              ) {
                VStack(alignment: .leading, spacing: 2) {
                  HStack {
                    Text(item.name).font(UIStyle.meta).lineLimit(1)
                    Spacer()
                    Text("\(item.sessions.count) recent · " + relative(item.lastActive)).font(UIStyle.micro).foregroundStyle(p.secondary)
                  }
                  Text(short(item.path)).font(UIStyle.micro).foregroundStyle(p.secondary)
                    .lineLimit(1).truncationMode(.middle)
                }
              }.toggleStyle(.checkbox).padding(.vertical, 3)
            }
          }
        }
        HStack {
          Spacer()
          Button("Cancel") { model.decline() }.buttonStyle(QuietButton())
          Button("Add \(model.selected.count)") { model.add() }.buttonStyle(PrimaryButton())
            .disabled(model.selected.isEmpty)
        }
      }
    }.padding(22).frame(width: 520, height: 440).background(p.panel)
  }
}

/// New folders the watch noticed, as a banner under the Projects header. The opt-in entry
/// point ("Find from Claude Code and Codex…") is in the Projects organize menu.
struct SessionDiscoveryRow: View {
  @ObservedObject var model = SessionDiscoveryModel.shared
  @Environment(\.palette) var p
  var body: some View {
    if !model.offered.isEmpty {
      HStack(spacing: 8) {
        InterfaceIcon(systemName: "folder.badge.plus", size: 14).foregroundStyle(p.accent)
        Text("\(model.offered.count) new project folder\(model.offered.count == 1 ? "" : "s") in your agents’ chat history")
          .font(UIStyle.body).lineLimit(1)
        Spacer()
        Button("Review") { model.review() }.buttonStyle(PrimaryButton())
        Button("Not these") { model.dismissOffers() }.buttonStyle(QuietButton())
      }.padding(.horizontal, 12).padding(.vertical, 8).card(p).padding(.top, 16)
    }
  }
}

private struct SessionDiscoveryHost: ViewModifier {
  var browser: BrowserModel
  @ObservedObject var model = SessionDiscoveryModel.shared

  func body(content: Content) -> some View {
    content.sheet(isPresented: $model.presenting) { SessionDiscoverySheet(model: model) }
      .onAppear {
        model.attach(browser)
        ProjectInsights.shared.refreshGit(for: browser.projects, library: browser.library)
      }
  }
}
extension View {
  /// Presents the consent and selection sheet and starts the watch after earlier consent.
  func sessionDiscovery(browser: BrowserModel) -> some View {
    modifier(SessionDiscoveryHost(browser: browser))
  }
}

/// Settings control: automatic discovery from Claude Code and Codex history, on or off.
struct SessionDiscoverySettings: View {
  @ObservedObject var model = SessionDiscoveryModel.shared
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("Show chats from Claude Code and Codex on this Mac", isOn: $model.automatic)
      Text(
        model.automatic
          ? "Serein reads the start of your local session logs and lists the folders you work in. Folders without project files go under Other folders. Nothing leaves this Mac."
          : "Serein is not reading your Claude Code or Codex history. Folders already listed stay."
      ).font(UIStyle.micro).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      ExternalSessionSettings()
    }
  }
}

private struct ExternalSessionSettings: View {
  @ObservedObject private var store = ExternalSessionStore.shared
  @Environment(\.palette) private var p
  var body: some View {
    Toggle("Show sessions running in other apps", isOn: $store.enabled)
    Text("Checks which agent apps are running on this Mac and reads their open chats when those change and when you come back to Serein. Session open means turn status is unavailable. This stays on this Mac and grants no access.")
      .font(UIStyle.micro).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
  }
}
