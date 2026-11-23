import AppKit
import Darwin
import SereinCore
import SwiftUI

/// Watches the localhost ports where registered projects' dev servers are likely to listen.
///
/// What it learns stays in the app: it feeds the project card and popover only. Process names,
/// working folders and ports are never put in a prompt. It polls only while a view that shows
/// dev servers is on screen. A server counts for a project when the process listening has its
/// working folder inside the project, or when exactly one project's files claim the port.
@MainActor final class DevServerMonitor: ObservableObject {
  static let shared = DevServerMonitor()
  @Published private(set) var tracker = DevServerTracker()
  private weak var browser: BrowserModel?
  private var viewers = 0
  private var loop: Task<Void, Never>?

  func status(_ projectID: String) -> DevServerStatus? { tracker.status[projectID] }

  /// A view that shows dev servers appeared. Polling runs while at least one is visible.
  func retain(browser: BrowserModel) {
    self.browser = browser
    viewers += 1
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.probe()
        try? await Task.sleep(nanoseconds: 5_000_000_000)
      }
    }
  }
  func release() {
    viewers = max(0, viewers - 1)
    if viewers == 0 {
      loop?.cancel()
      loop = nil
    }
  }

  func probe() async {
    guard let browser else { return }
    let projects = browser.projects.map { ($0.id, $0.name, $0.path) }
    let found = await Task.detached(priority: .utility) { Self.scan(projects) }.value
    var next = tracker
    var changed = false
    for (id, _, _) in projects { changed = next.update(project: id, listening: found[id] ?? []) || changed }
    let before = next.status.count
    next.prune(keeping: Set(projects.map(\.0)))
    if next.status.count != before { changed = true }
    if changed { tracker = next }
  }

  /// Opens the server in a tab, reusing a tab that already shows it.
  func open(_ status: DevServerStatus, browser: BrowserModel) {
    if let tab = browser.tabs.first(where: {
      !$0.privateMode && DevServer.localPort($0.address) == status.port
    }) {
      browser.selected = tab.id
    } else {
      browser.openInDefaultBrowser(status.url)
    }
  }

  // MARK: Scanning (off the main thread)

  /// Project id to the ports serving it, configured ports first.
  nonisolated static func scan(_ projects: [(String, String, String)]) -> [String: [Int]] {
    let candidates = projects.map { id, name, path in
      DevServer.Candidate(id: id, name: name, path: path, ports: configuredPorts(path))
    }
    let listeners = listeningPorts()
    var found: [String: Set<Int>] = [:]
    for (port, folder) in listeners {
      if let owner = DevServer.match(port: port, listenerFolder: folder, projects: candidates) {
        found[owner.id, default: []].insert(port)
      }
    }
    // A configured port that lsof could not attribute still counts when it answers and only
    // one project claims it.
    for candidate in candidates {
      for port in candidate.ports where !listeners.contains(where: { $0.0 == port }) {
        guard tcpOpen(port),
          DevServer.match(port: port, listenerFolder: nil, projects: candidates)?.id == candidate.id
        else { continue }
        found[candidate.id, default: []].insert(port)
      }
    }
    return Dictionary(
      uniqueKeysWithValues: candidates.map { candidate in
        let ports = found[candidate.id] ?? []
        let ordered =
          candidate.ports.filter(ports.contains) + ports.subtracting(candidate.ports).sorted()
        return (candidate.id, ordered)
      })
  }

  nonisolated static func configuredPorts(_ path: String) -> [Int] {
    let root = URL(fileURLWithPath: path)
    // Regular files only, opened without blocking: a FIFO or device named package.json must
    // never stall the polling loop.
    func read(_ name: String) -> Data? {
      SafeFileRead.regularFile(root.appendingPathComponent(name).path, limit: 200_000)
    }
    return DevServerPorts.candidates(
      packageJSON: read("package.json"),
      config: DevServerPorts.configNames.compactMap {
        read($0).map { String(decoding: $0, as: UTF8.self) }
      },
      procfile: read("Procfile").map { String(decoding: $0, as: UTF8.self) })
  }

  /// Loopback or wildcard TCP listeners with the working folder of the owning process, from `lsof`.
  nonisolated static func listeningPorts() -> [(Int, String?)] {
    guard let out = ComposerContext.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
    else { return [] }
    var pid = ""
    var ports: [(Int, String)] = []
    for line in out.split(whereSeparator: \.isNewline) {
      if line.hasPrefix("p") { pid = String(line.dropFirst()) }
      guard line.hasPrefix("n"), let colon = line.lastIndex(of: ":"),
        let port = Int(line[line.index(after: colon)...])
      else { continue }
      let host = line[line.index(after: line.startIndex)..<colon]
      guard ["*", "127.0.0.1", "[::1]", "localhost", "[::]"].contains(String(host)),
        (1024...65535).contains(port)
      else { continue }
      ports.append((port, pid))
    }
    let pids = Set(ports.map(\.1))
    var folders: [String: String] = [:]
    if !pids.isEmpty,
      let cwd = ComposerContext.run(
        "/usr/sbin/lsof", ["-a", "-p", pids.sorted().joined(separator: ","), "-d", "cwd", "-Fpn"])
    {
      var current = ""
      for line in cwd.split(whereSeparator: \.isNewline) {
        if line.hasPrefix("p") { current = String(line.dropFirst()) }
        if line.hasPrefix("n/") { folders[current] = String(line.dropFirst()) }
      }
    }
    var seen = Set<Int>()
    return ports.filter { seen.insert($0.0).inserted }.map { ($0.0, folders[$0.1]) }
  }

  /// True when something accepts a connection on this loopback port.
  nonisolated static func tcpOpen(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
    var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }
}

/// A small ":port" marker on a project row while its dev server is running; click to open it.
struct DevServerBadge: View {
  let projectID: String
  let browser: BrowserModel
  @ObservedObject private var monitor = DevServerMonitor.shared
  @Environment(\.palette) var p
  var body: some View {
    Group {
      if case .running(let port)? = monitor.status(projectID), let status = monitor.status(projectID) {
        Button {
          monitor.open(status, browser: browser)
        } label: {
          HStack(spacing: 4) {
            Circle().fill(p.success).frame(width: 5, height: 5)
            Text(":\(port)").font(UIStyle.microMono).foregroundStyle(p.secondary)
          }.contentShape(Rectangle())
        }.buttonStyle(.pressable).help("Open the dev server on localhost:\(port)")
          .accessibilityLabel("Open dev server on port \(port)")
      }
    }.onAppear { monitor.retain(browser: browser) }.onDisappear { monitor.release() }
  }
}
