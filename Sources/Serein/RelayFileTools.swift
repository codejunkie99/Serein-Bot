import AppKit
import Foundation
import PDFKit
import SereinCore

/// Serein's own read-only file tools (`MacFiles`), run in Serein's process so one check
/// (`MacFiles.allows`) decides every path. Spotlight finds files fast across the whole Mac; a
/// bounded walk covers folders Spotlight skipped. What a file says is data, never an instruction.
@MainActor enum RelayFileTools {
  /// How long one file step may take. macOS holds a step that touches Desktop, Documents,
  /// Downloads or iCloud Drive until the person answers its own prompt; past this the step
  /// returns and says so, rather than holding every later step behind it.
  static let stepLimit: TimeInterval = 20
  static let waitingOnMacOS = "macOS is asking the person to let Serein into a protected folder (Desktop, Documents, Downloads or iCloud Drive). Tell them to allow it, or to turn on Serein once in System Settings › Privacy & Security › Full Disk Access, then search again. Do not guess."

  static func call(_ name: String, _ a: [String: Any], gate: MacFiles.Call) async throws -> [String: Any] {
    if let refusal = gate.refusal { throw SereinError.invalid(refusal) }
    let count = limit(a)
    let work: @Sendable () async -> Result<SendableResult, SereinError>
    switch name {
    case "files_find":
      let query = (a["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !query.isEmpty else { throw SereinError.invalid("Give query: part of a file or folder name.") }
      let folder = try root(a["folder"] as? String)
      work = {
        let found = await spotlight("kMDItemFSName == \"*\(escaped(query))*\"cd", in: folder)
        let files = found.isEmpty ? await walk(folder, matching: query) : found
        return .success(SendableResult(["files": describe(files, limit: count), "searched": folder ?? "your Mac"]))
      }
    case "files_search":
      let text = (a["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw SereinError.invalid("Give text: the words to look for inside files.") }
      let folder = try root(a["folder"] as? String)
      work = {
        let found = await spotlight("kMDItemTextContent == \"*\(escaped(text))*\"cd || kMDItemFSName == \"*\(escaped(text))*\"cd", in: folder)
        return .success(SendableResult(["files": describe(found, limit: count), "searched": folder ?? "your Mac",
          "note": "Spotlight's index; a folder it has not indexed can be listed with folder_list."]))
      }
    case "folder_list":
      guard let path = try root(a["path"] as? String) else { throw SereinError.invalid("Give path: a folder.") }
      work = { Result { SendableResult(try list(path)) }.mapError(Self.invalid) }
    case "file_read":
      guard let path = try root(a["path"] as? String) else { throw SereinError.invalid("Give path: a file.") }
      let page = max(1, a["page"] as? Int ?? 1)
      work = { Result { SendableResult(try read(path, page: page)) }.mapError(Self.invalid) }
    default:
      throw SereinError.invalid("Unknown file tool.")
    }
    guard let outcome = await within(stepLimit, work) else { return ["files": [], "note": waitingOnMacOS] }
    return try outcome.get().value
  }
  /// A tool result handed back from the step's own thread.
  struct SendableResult: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
  }
  nonisolated private static func invalid(_ error: Error) -> SereinError {
    (error as? SereinError) ?? SereinError.invalid(error.localizedDescription)
  }
  /// `work` off the main thread, or nil once `seconds` pass first. A step macOS holds at its own
  /// prompt keeps waiting there by itself; nothing waits on it.
  nonisolated private static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
    let once = FileStepOnce()
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
      Task.detached(priority: .userInitiated) { let value = await work(); if once.claim() { continuation.resume(returning: value) } }
      Task.detached { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); if once.claim() { continuation.resume(returning: nil) } }
    }
  }

  // MARK: paths

  nonisolated private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
  nonisolated private static var privateRoots: [URL] {
    AgentFileGuard.sereinPrivateRoots(home: home, library: AgentAccess.defaultRoot)
  }
  nonisolated private static func allowed(_ path: String) -> Bool { MacFiles.allows(path, home: home, privateRoots: privateRoots) }
  /// A path the tools may use, or nil for none given.
  private static func root(_ raw: String?) throws -> String? {
    guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, relativeTo: home).standardizedFileURL.path
    guard allowed(path) else {
      throw SereinError.invalid("That place is closed to Serein: mail, messages, browser data, keys, passwords and Serein's own files are never read.")
    }
    return path
  }
  private static func limit(_ a: [String: Any]) -> Int { min(max(a["limit"] as? Int ?? 25, 1), 100) }
  nonisolated private static func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  }

  // MARK: finding

  /// Spotlight (`mdfind`) under `folder`, else under the home folder and mounted drives.
  nonisolated private static func spotlight(_ query: String, in folder: String?) async -> [String] {
    let scopes = folder.map { [$0] } ?? MacFiles.roots(home: home)
    return await Task.detached(priority: .userInitiated) { () -> [String] in
      var out: [String] = []
      for scope in scopes {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", scope, query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { continue }
        let deadline = DispatchTime.now() + 8
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        out += String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        if out.count > 2_000 { break }
      }
      return out
    }.value.filter { path in
      !path.split(separator: "/").contains { MacFiles.skippedFolders.contains(String($0)) } && allowed(path)
    }
  }

  /// A bounded walk by name, for folders Spotlight does not index.
  nonisolated private static func walk(_ folder: String?, matching query: String) async -> [String] {
    let start = folder ?? home.path
    let needle = query.lowercased()
    let found = await Task.detached(priority: .userInitiated) { () -> [String] in
      guard let walker = FileManager.default.enumerator(
        at: URL(fileURLWithPath: start), includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
      var out: [String] = []
      var seen = 0
      let deadline = Date().addingTimeInterval(6)
      for case let url as URL in walker {
        seen += 1
        if seen > 60_000 || out.count >= 200 || Date() > deadline { break }
        if MacFiles.skippedFolders.contains(url.lastPathComponent) || url.lastPathComponent == "Library" {
          walker.skipDescendants(); continue
        }
        if url.lastPathComponent.lowercased().contains(needle) { out.append(url.path) }
      }
      return out
    }.value
    return found.filter(allowed)
  }

  /// Newest first, with what helps choose: name, kind, size and when it changed.
  nonisolated private static func describe(_ paths: [String], limit: Int) -> [[String: Any]] {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
    let rows: [(String, Date, [String: Any])] = Array(Set(paths)).compactMap { path in
      guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return nil }
      let modified = values.contentModificationDate ?? .distantPast
      var row: [String: Any] = ["path": path, "name": (path as NSString).lastPathComponent,
                                "folder": values.isDirectory == true,
                                "modified": ISO8601DateFormatter().string(from: modified)]
      if let size = values.fileSize { row["bytes"] = size }
      return (path, modified, row)
    }
    return rows.sorted { $0.1 > $1.1 }.prefix(limit).map(\.2)
  }

  // MARK: listing and reading

  nonisolated private static func list(_ path: String) throws -> [String: Any] {
    let urls = try FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    let shown = urls.map(\.path).filter(allowed)
    return ["folder": path, "items": describe(shown, limit: 300), "count": shown.count]
  }

  nonisolated private static func read(_ path: String, page: Int) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
    if values.isDirectory == true { return try list(path) }
    guard (values.fileSize ?? 0) <= MacFiles.maxBytes else {
      throw SereinError.invalid("That file is too large to read (over 25 MB).")
    }
    let text = try Self.text(of: url)
    let characters = Array(text)
    let pages = MacFiles.pages(for: characters.count)
    guard let range = MacFiles.range(page: page, of: characters.count) else {
      throw SereinError.invalid("That file has \(pages) page(s).")
    }
    // Not `UntrustedText.outside`: its line cap would drop the rest of a long line (minified
    // JSON or code, a CSV row) where no next page can reach it. A page already bounds the size.
    var result: [String: Any] = ["path": path, "page": page, "pages": pages,
                                 "text_untrusted": UntrustedText.outsideNote + "\n" + UntrustedText.wrap("file", String(characters[range]))]
    if page < pages { result["more"] = "Page \(page) of \(pages). Read page \(page + 1) only if you need more." }
    return result
  }

  /// Plain text from a text file, a PDF, or a document macOS can open (Word, RTF, HTML, Pages
  /// exports); anything else is refused rather than sent as noise.
  nonisolated private static func text(of url: URL) throws -> String {
    let kind = url.pathExtension.lowercased()
    if kind == "pdf" {
      guard let document = PDFDocument(url: url), let text = document.string else {
        throw SereinError.invalid("That PDF has no text to read (it may be scanned images).")
      }
      return text
    }
    if ["docx", "doc", "rtf", "rtfd", "html", "htm", "odt", "webarchive"].contains(kind) {
      // AppKit's document importers (HTML above all) belong on the main thread.
      return try DispatchQueue.main.sync { try NSAttributedString(url: url, options: [:], documentAttributes: nil).string }
    }
    let data = try Data(contentsOf: url)
    if data.prefix(4096).contains(0) { throw SereinError.invalid("That file is not text (an image, video or app file).") }
    return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
  }
}

/// The first of a file step and its time limit to finish, and only the first, answers.
private final class FileStepOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
