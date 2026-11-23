import AppKit
import Combine
import CoreServices
import SereinCore
import SwiftUI
import WebKit

/// Files a task downloads, while Settings › Assistants › Task downloads is on. They go to a
/// private folder per task under the Library's `task-downloads` (folders 0700, files 0600), never
/// to the person's Downloads folder. The type is checked before any card (TaskDownloadPolicy);
/// the first file from each site asks once per run; unattended runs are refused. Nothing here
/// opens or runs a file. The agent gets a file's extracted text inside the page fence and never
/// its path. Keep moves a file to Downloads; the rest go when the task's last run leaves the hub
/// (Dismiss, Delete Chat, the hub's own trim), at quit, and at the next launch after a crash.
@MainActor final class TaskShelf: NSObject, ObservableObject, WKDownloadDelegate {
  static let shared = TaskShelf()
  static let folder = "task-downloads"
  struct File: Identifiable, Equatable {
    enum State: Equatable { case downloading, ready }
    let id: String
    let thread: String
    let name: String
    /// The host of the task's page that started the download.
    let site: String
    /// The size the site announced, then the finished size.
    var size: Int64
    var received: Int64 = 0
    var state: State = .downloading
    /// In the private folder; never given to an agent.
    let url: URL
    /// When the download started, for the inspector's Library (newest first).
    var at = Date()
    var detail: String {
      switch state {
      case .ready: return Bytes.file(size) + " · " + site
      case .downloading:
        return "Downloading · " + Bytes.file(received) + (size > 0 ? " of " + Bytes.file(size) : "") + " · " + site
      }
    }
  }
  @Published private(set) var files: [File] = []
  /// Refusals per thread, newest last, for the downloads tool and nowhere else.
  private var refusals: [String: [String]] = [:]
  /// Refusals, stops and deletions the agent has not been told yet, by browser task id. Its next
  /// tool call carries them (BrowserModel.handle), fenced.
  private var unseen: [String: [String]] = [:]
  /// Sites allowed, by run record id. A new run, even of the same chat, asks again.
  private var allowed: [String: Set<String>] = [:]
  /// Sites the person declined, by run record id: no second card for them in that run.
  private var declined: [String: Set<String>] = [:]
  /// One card per run and site while it waits; later files from that site wait on its answer.
  private var asks: [String: Task<ApprovalGate.HumanAnswer, Never>] = [:]
  /// Cards waiting, by run record id and site (an Ask every step file has its own), for the tool's "waiting".
  private var waitingCards: [String: Int] = [:]
  private var folders: [String: URL] = [:]
  private struct Flight {
    let download: WKDownload
    let task: String
    var fileID: String?
    var observation: NSKeyValueObservation?
  }
  /// Downloads in progress. The download holds its web view weakly, so no page is kept alive.
  private var flights: [ObjectIdentifier: Flight] = [:]
  private weak var browser: BrowserModel?
  private weak var hub: AgentHub?
  private var watch: AnyCancellable?

  private var root: URL? { browser?.library.root.appendingPathComponent(Self.folder, isDirectory: true) }

  /// Whether an agent tab hands its downloads here (BrowserTab's policy). Personal and private
  /// tabs never do; with the switch off the download is cancelled as before.
  static func takes(_ tab: BrowserTab) -> Bool {
    tab.owner != nil && !tab.privateMode && !tab.hiddenFromAgents && TaskDownloadPolicy.isEnabled()
  }

  /// At launch: whatever is left belongs to a launch that ended without quitting, so nobody kept
  /// it. The shelf then follows the hub's runs.
  func attach(_ browser: BrowserModel, hub: AgentHub) {
    self.browser = browser
    self.hub = hub
    if let root { try? FileManager.default.removeItem(at: root) }
    watch = hub.$runs.sink { [weak self] runs in self?.prune(runs) }
  }

  /// At quit: downloads stop and every file not kept is deleted.
  func quit() {
    watch = nil
    for key in Array(flights.keys) { stop(key, reason: nil) }
    files.removeAll()
    folders.removeAll()
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  /// The browser task ended (BrowserModel.endTask): its capability is gone, so its downloads in
  /// progress stop. Finished files stay for the person until the task leaves the hub.
  func taskEnded(_ task: String) {
    for (key, flight) in flights where flight.task == task {
      stop(key, reason: "The task ended before a download finished, so it was deleted.")
    }
    unseen[task] = nil
  }

  /// What the agent has not been told yet about this task's downloads; cleared once taken.
  func takeNotices(task: String) -> [String] { unseen.removeValue(forKey: task) ?? [] }

  func accept(_ download: WKDownload, task: String) {
    guard TaskDownloadPolicy.isEnabled(), browser?.tasks[task] != nil else {
      download.cancel { _ in }
      return
    }
    flights[ObjectIdentifier(download)] = Flight(download: download, task: task)
    download.delegate = self
  }

  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
    completionHandler: @escaping (URL?) -> Void
  ) {
    let key = ObjectIdentifier(download)
    let page = download.webView?.url ?? download.originalRequest?.url
    Task { @MainActor in
      let destination = await self.admit(key, response: response, suggested: suggestedFilename, page: page)
      if destination == nil { self.flights[key] = nil }
      completionHandler(destination)
    }
  }

  /// Every check before a byte is written: the switch, a live run with a chat, the type, the
  /// caps, unattended runs, then the card for a site this run has not allowed. nil cancels.
  private func admit(_ key: ObjectIdentifier, response: URLResponse, suggested: String, page: URL?) async -> URL? {
    guard TaskDownloadPolicy.isEnabled(), let browser, let task = flights[key]?.task,
      let live = browser.tasks[task], !live.finished, live.allows == nil,
      let run = hub?.runs.first(where: { $0.taskID == task && $0.isActive })
    else { return nil }
    let thread = run.spec.threadID
    let name = SafeFileName.clean(suggested, fallback: "Download")
    let site = TaskPass.host(page?.absoluteString ?? "")
    let expected = response.expectedContentLength
    func refused(_ reason: String) -> URL? {
      note(reason, thread: thread, task: task)
      return nil
    }
    if let reason = TaskDownloadPolicy.refusal(name: name, mimeType: response.mimeType) { return refused(reason) }
    // Runs nobody watches and an assistant speaking first (`isUnattended`), and hand-offs between
    // assistants (the lower trust class), stand as nobody there: their card is deferred.
    let unattended = browser.isUnattended(task: task) || run.spec.initiator == .handoff
    guard !site.isEmpty else { return refused("\(name) did not come from a site, so it was refused.") }
    // The person's site rule, read now and again after the card: Never refuses, Ask every step
    // asks for every file and keeps no yes.
    let address = page?.absoluteString
    let rule = SiteRules.rule(for: address)
    if rule == .never { return refused(SiteRules.refusal(address ?? site)) }
    // A file served from another host is asked for, and allowed, under both names.
    let source = TaskPass.host(response.url?.absoluteString ?? "")
    let origin = !source.isEmpty && !SitePolicy.matches(host: source, site: site) ? "\(site) (served by \(source))" : site
    // The serving host's rule counts too: Ask every step there asks for every file from it.
    let sourceRule = source.isEmpty ? SiteRule.normal : SiteRules.rule(for: response.url?.absoluteString)
    let everyFile = rule == .ask || sourceRule == .ask
    if sourceRule == .never { return refused(SiteRules.refusal(response.url?.absoluteString ?? source)) }
    // The task's level: Allow all and Auto keep the file with no card; Manual and a site set to
    // Ask every step show one.
    let door = ApprovalDoor.answer(
      .init(.downloads, browser.standing(task: task, else: RelayOrchestrator.standing(
        browser.relayTask(task, live), present: !unattended)), site: everyFile ? .ask : .normal, taskID: task),
      facts: .init(
        secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
        runsAnything: false, ref: ""))
    if let said = door.said { return refused(said) }
    // Serein's own chat shows no shelf: a download belongs in a task it starts.
    guard !run.spec.relay else {
      return refused("Serein’s own chat cannot download files; start a task for it, so \(name) was refused.")
    }
    if let reason = capRefusal(thread: thread, name: name, expected: expected) { return refused(reason) }
    if !door.runs, everyFile || allowed[run.record.id]?.contains(origin) != true {
      if declined[run.record.id]?.contains(origin) == true {
        return refused("The user declined downloads from \(origin) for this task, so \(name) was not downloaded.")
      }
      guard let relay = browser.relayTask(task, live) ?? RelayOrchestrator.shared else {
        return refused("No one can answer for downloads from \(site), so \(name) was refused.")
      }
      let askKey = run.record.id + "\n" + origin
      let size = expected > 0 ? " (" + Bytes.file(expected) + ")" : ""
      let ask: Task<ApprovalGate.HumanAnswer, Never>
      // Under Ask every step each file has its own card.
      if !everyFile, let waiting = asks[askKey] {
        ask = waiting
      } else {
        ask = Task {
          await relay.confirmAnswer(
            "Download files from \(origin)?",
            everyFile
              ? "This file is \(name)\(size). It waits unopened on this task’s shelf until you keep or delete it. A yes covers only this file."
              : "The first file is \(name)\(size). Files wait unopened on this task’s shelf until you keep or delete them. A yes covers only this task.",
            button: "Allow for this task", decline: "Decline", thread: thread)
        }
        if !everyFile { asks[askKey] = ask }
      }
      waitingCards[askKey, default: 0] += 1
      let human = await ask.value
      waitingCards[askKey, default: 1] -= 1
      if waitingCards[askKey] == 0 { waitingCards[askKey] = nil }
      if !everyFile { asks[askKey] = nil }
      guard human == .yes else {
        if human == .no { declined[run.record.id, default: []].insert(origin) }
        return refused(human == .no
          ? "The user declined downloads from \(origin), so \(name) was not downloaded."
          : "No one allowed downloads from \(origin), so \(name) was not downloaded.")
      }
      if !everyFile { allowed[run.record.id, default: []].insert(origin) }
      // The rules, the switch, the task, its run or the download may have changed while the card waited.
      if SiteRules.rule(for: address) == .never { return refused(SiteRules.refusal(address ?? site)) }
      guard TaskDownloadPolicy.isEnabled(), SiteRules.rule(for: response.url?.absoluteString) != .never, run.isActive,
        browser.tasks[task]?.finished == false, flights[key] != nil
      else { return refused("The task ended or downloads were turned off before \(name) could start, so it was not downloaded.") }
      if let reason = capRefusal(thread: thread, name: name, expected: expected) { return refused(reason) }
    }
    guard let folder = folder(for: thread) else {
      return refused("Serein could not make this task’s private folder, so \(name) was refused.")
    }
    let id = UUID().uuidString
    let url = folder.appendingPathComponent(id + "." + TaskDownloadPolicy.fileExtension(name))
    files.append(File(id: id, thread: thread, name: name, site: site, size: max(expected, 0), url: url))
    flights[key]?.fileID = id
    // Read, then written: one statement doing both is an exclusivity violation on `flights`.
    let observation = flights[key]?.download.progress.observe(\.completedUnitCount, options: [.new]) {
      [weak self] progress, _ in
      let done = progress.completedUnitCount
      Task { @MainActor in self?.progressed(key, bytes: done) }
    }
    flights[key]?.observation = observation
    return url
  }

  private func capRefusal(thread: String, name: String, expected: Int64) -> String? {
    let shelf = files.filter { $0.thread == thread }
    if shelf.count >= TaskDownloadPolicy.maxFiles {
      return "This task already holds \(TaskDownloadPolicy.maxFiles) files, so \(name) was refused."
    }
    if expected > TaskDownloadPolicy.maxFileBytes { return Self.tooLarge(name) }
    if shelf.reduce(0, { $0 + max($1.size, $1.received) }) + max(expected, 0) > TaskDownloadPolicy.maxTotalBytes {
      return "This task’s files would pass \(Bytes.file(TaskDownloadPolicy.maxTotalBytes)), so \(name) was refused."
    }
    return nil
  }

  private static func tooLarge(_ name: String) -> String {
    "\(name) is larger than \(Bytes.file(TaskDownloadPolicy.maxFileBytes)), the most one task file may be, so it was refused."
  }

  /// A site can announce less than it sends: the caps hold on the bytes received.
  private func progressed(_ key: ObjectIdentifier, bytes: Int64) {
    guard let id = flights[key]?.fileID, let index = files.firstIndex(where: { $0.id == id }) else { return }
    files[index].received = bytes
    let thread = files[index].thread
    let total = files.filter { $0.thread == thread }.reduce(0) { $0 + max($1.size, $1.received) }
    if bytes > TaskDownloadPolicy.maxFileBytes || total > TaskDownloadPolicy.maxTotalBytes {
      stop(key, reason: Self.tooLarge(files[index].name))
    }
  }

  func downloadDidFinish(_ download: WKDownload) {
    guard let flight = flights.removeValue(forKey: ObjectIdentifier(download)), let id = flight.fileID,
      let index = files.firstIndex(where: { $0.id == id })
    else { return }
    let file = files[index]
    switch Self.verify(file) {
    case .failure(let refusal):
      try? FileManager.default.removeItem(at: file.url)
      files.removeAll { $0.id == id }
      note(refusal.reason, thread: file.thread, task: flight.task)
    case .success(let size):
      // The shelf total on the finished size, as progress may not have reported the last bytes.
      let others = files.filter { $0.thread == file.thread && $0.id != id }.reduce(0) { $0 + max($1.size, $1.received) }
      if others + size > TaskDownloadPolicy.maxTotalBytes {
        try? FileManager.default.removeItem(at: file.url)
        files.removeAll { $0.id == id }
        note("This task’s files would pass \(Bytes.file(TaskDownloadPolicy.maxTotalBytes)), so \(file.name) was deleted.",
             thread: file.thread, task: flight.task)
        return
      }
      files[index].size = size
      files[index].received = size
      files[index].state = .ready
      // One notification for the shelf, not one per file.
      if files.filter({ $0.thread == file.thread && $0.state == .ready }).count == 1 {
        TaskNotifications.shared.post(
          threadID: file.thread, title: "Files are waiting",
          body: "Files are on the task’s shelf. Keep them to move them to Downloads.")
      }
    }
  }

  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    stop(ObjectIdentifier(download), reason: "The download of a file stopped before it finished, so it was deleted.")
  }

  private struct Refusal: Error { let reason: String }

  /// The finished file: a regular file within the cap, not executable, whose first bytes are its
  /// type; then private to this user and carrying macOS's downloaded-file mark.
  private static func verify(_ file: File) -> Result<Int64, Refusal> {
    let fm = FileManager.default
    guard let attributes = try? fm.attributesOfItem(atPath: file.url.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let size = (attributes[.size] as? NSNumber)?.int64Value
    else { return .failure(Refusal(reason: "\(file.name) could not be checked, so it was deleted.")) }
    if size > TaskDownloadPolicy.maxFileBytes { return .failure(Refusal(reason: tooLarge(file.name))) }
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
    // The same file the type check saw: never through a link, never blocking on a pipe.
    guard let head = SafeFileRead.regularFile(file.url.path, limit: 4096) else {
      return .failure(Refusal(reason: "\(file.name) could not be checked, so it was deleted."))
    }
    if let reason = TaskDownloadPolicy.contentRefusal(name: file.name, head: head, executable: mode & 0o111 != 0) {
      return .failure(Refusal(reason: reason))
    }
    do {
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
      try quarantine(file.url)
    } catch {
      return .failure(Refusal(reason: "\(file.name) could not be marked as downloaded, so it was deleted."))
    }
    return .success(size)
  }

  /// macOS's downloaded-file mark, so Gatekeeper checks the file if the person ever opens it.
  /// WebKit may have set it already; a missing one is added.
  static func quarantine(_ url: URL) throws {
    var url = url
    if try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil { return }
    var values = URLResourceValues()
    values.quarantineProperties = [
      kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
      kLSQuarantineAgentNameKey as String: "Serein",
    ]
    try url.setResourceValues(values)
  }

  /// Stops a download in progress and deletes what it wrote, now and once WebKit has let go of it.
  private func stop(_ key: ObjectIdentifier, reason: String?) {
    guard let flight = flights.removeValue(forKey: key) else { return }
    let file = flight.fileID.flatMap { id in files.first { $0.id == id } }
    let part = file?.url
    flight.download.cancel { _ in if let part { try? FileManager.default.removeItem(at: part) } }
    guard let file else { return }
    try? FileManager.default.removeItem(at: file.url)
    files.removeAll { $0.id == file.id }
    if let reason { note(reason, thread: file.thread, task: flight.task) }
  }

  private func note(_ reason: String, thread: String, task: String) {
    refusals[thread] = Array(((refusals[thread] ?? []) + [reason]).suffix(10))
    // An ended task's notices would never be taken.
    if browser?.tasks[task] != nil { unseen[task] = Array(((unseen[task] ?? []) + [reason]).suffix(10)) }
    browser?.notice = reason
  }

  private func folder(for thread: String) -> URL? {
    if let known = folders[thread] { return known }
    guard let root else { return nil }
    let fm = FileManager.default
    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
      try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    } catch { return nil }
    folders[thread] = folder
    return folder
  }

  /// A thread none of whose runs is in the hub any more has ended for the shelf: its files and
  /// folder go, as its result tab does. A run that ended takes its allowed sites with it.
  private func prune(_ runs: [AgentRun]) {
    let threads = Set(runs.map(\.spec.threadID))
    let active = Set(runs.filter(\.isActive).map(\.record.id))
    allowed = allowed.filter { active.contains($0.key) }
    declined = declined.filter { active.contains($0.key) }
    for file in files where !threads.contains(file.thread) { delete(file.id) }
    for (thread, folder) in folders where !threads.contains(thread) {
      try? FileManager.default.removeItem(at: folder)
      folders[thread] = nil
    }
    refusals = refusals.filter { threads.contains($0.key) }
  }

  // MARK: The person's choices

  /// Keep: the person's move of a finished file into their Downloads folder, under a free name.
  /// The downloaded-file mark goes with it, and the file joins the Downloads list.
  func keep(_ id: String) {
    guard let file = files.first(where: { $0.id == id && $0.state == .ready }),
      let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    else { return }
    let fm = FileManager.default
    let placed: URL?
    do {
      placed = try Self.intoDownloads(file.name, in: downloads) { try fm.moveItem(at: file.url, to: $0) }
    } catch {
      browser?.notice = "\(file.name) could not be moved to Downloads: \(error.localizedDescription)"
      return
    }
    guard let target = placed else {
      browser?.notice = "\(file.name) could not be moved to Downloads: too many files share its name."
      return
    }
    try? Self.quarantine(target)
    files.removeAll { $0.id == id }
    DownloadCenter.shared.kept(target)
    // The assistant whose task downloaded it lists it in its Library; the person's own tasks have none.
    if let owner = RelayOrchestrator.shared?.assistantOwning(thread: file.thread) {
      AssistantLibrary.shared.kept(target, owners: [owner])
    }
    browser?.notice = "Kept \(target.lastPathComponent) in Downloads."
  }

  /// The first free name for `name` in `downloads` ("cv.pdf", "cv 2.pdf", …), with `place`
  /// moving or copying the file there. nil when a hundred names are taken; any other failure
  /// of `place` is thrown. Shared with the Outbox of Serein's computer (ComputerHost.keep).
  static func intoDownloads(_ name: String, in downloads: URL, _ place: (URL) throws -> Void) throws -> URL? {
    let fm = FileManager.default
    for attempt in 0..<100 {
      let target = downloads.appendingPathComponent(SafeFileName.numbered(name, attempt + 1))
      if fm.fileExists(atPath: target.path) { continue }
      do {
        try place(target)
      } catch {
        if fm.fileExists(atPath: target.path) { continue }
        throw error
      }
      return target
    }
    return nil
  }

  func keepAll(thread: String) {
    for file in files where file.thread == thread && file.state == .ready { keep(file.id) }
  }

  /// Delete: the file now, or a download in progress stopped and its part deleted.
  func delete(_ id: String) {
    if let key = flights.first(where: { $0.value.fileID == id })?.key {
      stop(key, reason: nil)
      return
    }
    guard let file = files.first(where: { $0.id == id }) else { return }
    try? FileManager.default.removeItem(at: file.url)
    files.removeAll { $0.id == id }
  }

  // MARK: The agent's tool

  /// `downloads`: the shelf of the task's chat, or one file's extracted text inside the page
  /// fence. Ids only; never a path, and no way to open, run, move or keep a file.
  func call(task: String, arguments: [String: Any]) async throws -> [String: Any] {
    guard TaskDownloadPolicy.isEnabled() else {
      throw SereinError.invalid("Downloads are off. The user can turn on Let tasks download files from a card Serein offers in its chat (setup_offer, topic downloads) or in Settings › Assistants › Task downloads.")
    }
    guard let run = hub?.runs.last(where: { $0.taskID == task }) else {
      return ["files": [[String: Any]](), "refused": [String]()]
    }
    let thread = run.spec.threadID
    let shelf = files.filter { $0.thread == thread }
    guard let id = arguments["file"] as? String, !id.isEmpty else {
      // A download waiting on the card is not on the shelf yet; say so, so the agent does not finish.
      let prefix = run.record.id + "\n"
      let waiting = waitingCards.keys.filter { $0.hasPrefix(prefix) }.map {
        "A download from \($0.dropFirst(prefix.count)) waits for the user's yes; check downloads again before you finish."
      }
      return [
        "files": shelf.map { file -> [String: Any] in
          [
            "file": file.id, "name": PageFence.fence(file.name), "site": file.site, "size": Bytes.file(file.size),
            "state": file.state == .ready ? "ready" : "downloading", "readable": TaskDownloadPolicy.readable(file.name),
          ]
        },
        // Reasons can quote the site's file name: fenced, never instructions.
        "refused": (refusals[thread] ?? []).map(PageFence.fence),
        "notices": takeNotices(task: task).map(PageFence.fence),
        "waiting": waiting.map(PageFence.fence),
      ]
    }
    guard let file = shelf.first(where: { $0.id == id }) else {
      throw SereinError.invalid("No file with that id is on this task’s shelf.")
    }
    guard file.state == .ready else { throw SereinError.invalid("That file is still downloading.") }
    guard TaskDownloadPolicy.readable(file.name) else {
      throw SereinError.invalid("Only PDF and text files can be read; that file has no text to give.")
    }
    let url = file.url
    let pdf = TaskDownloadPolicy.fileExtension(file.name) == "pdf"
    // Redacted whole, then cut: a key that straddles a page edge is never sent as a fragment the
    // recognizer no longer matches. Offsets count in the redacted text, which is all the agent sees.
    let text = await Task.detached(priority: .utility) {
      // The 2 MB of a text file, or a PDF's text, whole: the agent pages through it with start.
      AgentPrivacy.redact((try? DocumentText.read(url, kind: pdf ? .pdf : .plain, limit: 2_000_000, keep: .max).text) ?? "")
    }.value
    let start = max(0, arguments["start"] as? Int ?? 0)
    let slice = AgentPrivacy.clipped(String(text.dropFirst(start)), limit: TaskDownloadPolicy.textPage)
    var result: [String: Any] = [
      // Escaped, not line-capped: a cut line (a downloaded JSON or CSV) could never be paged back.
      "file": file.id, "name": PageFence.fence(file.name), "site": file.site, "untrusted": true,
      "text": PageFence.fence(UntrustedText.escape(slice)),
    ]
    if start + slice.count < text.count { result["next_start"] = start + slice.count }
    if text.isEmpty { result["note"] = "No text could be read from this file." }
    return result
  }
}

/// The task's Files: what it downloaded, each with its size and site, Keep (moves it to Downloads)
/// and Delete, and Keep all. Nothing here opens a file.
struct TaskShelfSection: View {
  let thread: String
  @ObservedObject private var shelf = TaskShelf.shared
  @Environment(\.palette) var p
  var body: some View {
    let files = shelf.files.filter { $0.thread == thread }
    if !files.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text("Files (\(files.count))").font(UIStyle.bodyStrong).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
          Spacer(minLength: 4)
          if files.contains(where: { $0.state == .ready }) {
            Button("Keep all") { shelf.keepAll(thread: thread) }.buttonStyle(QuietButton())
              .help("Move every finished file to your Downloads folder").accessibilityLabel("Keep all files")
          }
        }
        ForEach(files) { file in
          HStack(spacing: 10) {
            InterfaceIcon(systemName: "doc", size: 13).foregroundStyle(p.faint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(file.name).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
              Text(file.detail).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1)
            }.accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            if file.state == .ready {
              Button("Keep") { shelf.keep(file.id) }.buttonStyle(QuietButton())
                .help("Move to your Downloads folder").accessibilityLabel("Keep \(file.name)")
            }
            Button("Delete") { shelf.delete(file.id) }.buttonStyle(QuietButton())
              .help(file.state == .ready ? "Delete this file" : "Stop and delete this download")
              .accessibilityLabel("Delete \(file.name)")
          }
        }
        Text("Files wait here unopened until you keep them. The rest are deleted when this task is dismissed or leaves the task list, and when Serein quits.")
          .font(UIStyle.micro).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }
      .padding(12)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .accessibilityElement(children: .contain).accessibilityLabel("Files")
    }
  }
}
