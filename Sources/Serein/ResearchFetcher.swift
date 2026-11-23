import Darwin
import Foundation
import SereinCore

/// A source that cannot be used by this reader, rather than a temporary connection failure.
enum ResearchReadFailure: LocalizedError {
  case unavailable(String)
  var errorDescription: String? { switch self { case .unavailable(let words): return words } }
}

/// Public HTTPS GET only. curl ignores user configuration, cookies, credentials and proxies;
/// DNS is resolved once and its checked address is pinned, including for TLS host verification.
/// Redirects are not followed. This reader never touches a personal tab or a signed-in session.
enum ResearchFetcher {
  static let byteLimit = 2_000_000

  private final class Request: @unchecked Sendable {
    let lock = NSLock()
    var process: Process?
    var cancelled = false
    func cancel() {
      lock.lock()
      cancelled = true
      let child = process
      lock.unlock()
      if let child, child.isRunning { child.terminate() }
    }
    func start(_ child: Process) throws {
      lock.lock()
      defer { lock.unlock() }
      guard !cancelled else { throw CancellationError() }
      try child.run()
      process = child
    }
  }

  static func read(_ address: String) async throws -> String {
    let url = try ResearchJob.publicURL(address)
    let (body, type) = try await fetch(url)
    let text = type == "text/plain" ? String(body.prefix(ResearchJob.textLimit))
      : RelayWatches.visibleText(body, limit: ResearchJob.textLimit)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ResearchReadFailure.unavailable("The source contained no readable text.")
    }
    return text
  }

  static func search(_ query: String) async throws -> [ResearchFollowUp.Candidate] {
    // This sole query-bearing endpoint is constructed locally. Page URLs still use publicURL.
    let url = try ResearchFollowUp.searchURL(query)
    let (body, _) = try await fetch(url)
    return try ResearchFollowUp.candidates(in: body)
  }

  private static func fetch(_ url: URL) async throws -> (String, String) {
    let request = Request()
    return try await withTaskCancellationHandler(operation: {
      try await Task.detached(priority: .utility) {
        let host = SitePolicy.host(url.host ?? "")
        let ip = try resolve(host)
        let pinned = ip.contains(":") ? "[" + ip + "]" : ip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-q", "--silent", "--globoff", "--noproxy", "*", "--proto", "=https",
          "--connect-timeout", "10", "--max-time", "25", "--max-filesize", String(byteLimit),
          "--resolve", host + ":443:" + pinned, "--header", "Accept: text/html, text/plain",
          "--user-agent", "SereinResearch/1.0", "--write-out", "\n%{http_code}\n%{content_type}", "--url", url.absoluteString]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try request.start(process)
        var data = Data()
        while true {
          let chunk = output.fileHandleForReading.readData(ofLength: 32_768)
          if chunk.isEmpty { break }
          data.append(chunk)
          if data.count > byteLimit + 1_024 {
            request.cancel()
            break
          }
        }
        process.waitUntilExit()
        if process.terminationStatus == 63 || data.count > byteLimit + 1_024 {
          throw ResearchReadFailure.unavailable("The source exceeds the research reader's size limit.")
        }
        guard process.terminationStatus == 0 else {
          throw SereinError.invalid("The source could not be read within the size and time limits.")
        }
        let raw = String(decoding: data, as: UTF8.self)
        guard let typeLine = raw.range(of: "\n", options: .backwards),
          let statusLine = raw[..<typeLine.lowerBound].range(of: "\n", options: .backwards),
          let code = Int(raw[statusLine.upperBound..<typeLine.lowerBound])
        else { throw ResearchReadFailure.unavailable("The source did not return a readable response.") }
        if code >= 500 || code == 408 || code == 429 { throw SereinError.invalid("The source is temporarily unavailable. Continue to try again.") }
        guard (200..<300).contains(code) else {
          throw ResearchReadFailure.unavailable("The source returned an error or redirect. Use its direct public page.")
        }
        let type = raw[typeLine.upperBound...].lowercased().split(separator: ";").first.map(String.init) ?? ""
        guard ["text/html", "text/plain", "application/xhtml+xml"].contains(type) else {
          throw ResearchReadFailure.unavailable("This research reader supports HTML and plain-text pages only.")
        }
        return (String(raw[..<statusLine.lowerBound]), type)
      }.value
    }, onCancel: { request.cancel() })
  }

  private static func resolve(_ host: String) throws -> String {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, "443", &hints, &list) == 0, let first = list else {
      throw SereinError.invalid("The source's address could not be found.")
    }
    defer { freeaddrinfo(first) }
    var addresses: [String] = []
    var next: UnsafeMutablePointer<addrinfo>? = first
    while let current = next {
      let item = current.pointee
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(item.ai_addr, item.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
        addresses.append(String(cString: buffer))
      }
      next = item.ai_next
    }
    guard let address = addresses.first, addresses.allSatisfy({ !ComputerNetworkPolicy.blockedAddress($0) }) else {
      throw SereinError.invalid("Research cannot read this Mac or a private network address.")
    }
    return address
  }
}
