import AppKit
import Darwin
import Foundation
import SereinCore
import Virtualization

/// Apple's framework selects a compatible IPSW. Only Apple's HTTPS download hosts are used;
/// VZMacOSRestoreImage and VZMacOSInstaller validate the downloaded restore image before use.
@MainActor final class MacRestoreImage {
  static let shared = MacRestoreImage()
  private var downloading: Task<URL, Error>?

  var root: URL? {
    GateSettings.shared.string(forKey: MacComputerPolicy.storageKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
  }
  var tools: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MacGuest", isDirectory: true) }
  var helper: URL { tools.appendingPathComponent(MacComputerPolicy.guestAppName, isDirectory: true) }

  /// Storage is chosen before download. A full virtual Mac needs considerably more space than
  /// the Linux desktop; never silently fill the user's system disk or place runtime files in Git.
  /// `asks: false` never opens the folder picker: with too little room at `defaultFolder` it answers false.
  func chooseStorage(defaultFolder: URL? = nil, asks: Bool = true) -> Bool {
    if root != nil { return true }
    if let defaultFolder, Self.freeBytes(at: defaultFolder.deletingLastPathComponent()) >= MacComputerPolicy.minimumFreeBytes {
      return GateSettings.shared.update(defaultFolder.path, forKey: MacComputerPolicy.storageKey)
    }
    guard asks else { return false }
    let panel = NSOpenPanel()
    panel.title = "Where should Serein keep its virtual Mac?"
    panel.message = "Choose a folder with at least 60 GB free. Serein keeps the Mac and its installer here. This folder is not shared with the guest."
    panel.prompt = "Use This Folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    let directory = url.resolvingSymlinksInPath().appendingPathComponent("Serein Macs", isDirectory: true)
    return GateSettings.shared.update(directory.path, forKey: MacComputerPolicy.storageKey)
  }

  static func freeBytes(at folder: URL) -> Int64 {
    let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
  }

  func image(progress: @escaping (String?) -> Void) async throws -> URL {
    if let downloading { return try await downloading.value }
    let operation = Task { @MainActor () throws -> URL in
      guard let root else { throw SereinError.invalid("Choose where to keep the virtual Mac first.") }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let cache = root.appendingPathComponent("cache", isDirectory: true)
      try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      progress("Finding a compatible macOS installer…")
      let selected = try await VZMacOSRestoreImage.latestSupported
      guard selected.mostFeaturefulSupportedConfiguration != nil,
        selected.buildVersion.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
        MacComputerPolicy.appleDownload(selected.url)
      else { throw SereinError.invalid("Apple did not return a compatible macOS restore image.") }
      let destination = cache.appendingPathComponent("macOS-\(selected.buildVersion).ipsw")
      if FileManager.default.fileExists(atPath: destination.path) {
        if let cached = try? await VZMacOSRestoreImage.image(from: destination),
          cached.buildVersion == selected.buildVersion, cached.mostFeaturefulSupportedConfiguration != nil {
          return destination
        }
        try FileManager.default.moveItem(at: destination, to: cache.appendingPathComponent("invalid-\(UUID().uuidString).ipsw"))
      }
      guard Self.freeBytes(at: root) >= MacComputerPolicy.minimumFreeBytes else {
        throw SereinError.invalid("The virtual Mac needs at least 60 GB free for its installer and disk. Choose storage with more free space.")
      }
      let download = MacImageDownload(destination: destination) { share in
        Task { @MainActor in progress("Downloading macOS from Apple · \(share)%") }
      }
      let downloaded = try await download.run(from: selected.url)
      let verified = try await VZMacOSRestoreImage.image(from: downloaded)
      guard verified.buildVersion == selected.buildVersion, verified.mostFeaturefulSupportedConfiguration != nil else {
        throw SereinError.invalid("The downloaded macOS installer is not compatible with this Mac.")
      }
      return downloaded
    }
    downloading = operation
    defer { downloading = nil }
    return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
  }
}

/// Stream directly to the chosen volume. URLSession's download temporary directory would put
/// the entire IPSW on the system disk first, defeating external storage on a nearly full Mac.
private final class MacImageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let destination: URL
  private let progress: (Int) -> Void
  private let lock = NSLock()
  private var cancelled = false
  private var task: URLSessionDataTask?
  private var continuation: CheckedContinuation<URL, Error>?
  private var handle: FileHandle?
  private var received: Int64 = 0
  private var expected: Int64 = 0
  private var failure: Error?
  private var lastPercent = -1
  private var partial: URL { destination.appendingPathExtension("download") }
  private static let sizeLimit: Int64 = 40 * 1_073_741_824

  init(destination: URL, progress: @escaping (Int) -> Void) {
    self.destination = destination; self.progress = progress
  }
  func run(from url: URL) async throws -> URL {
    let fd = open(partial.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SereinError.invalid("The macOS download file cannot be opened.") }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
      info.st_size >= 0, info.st_size <= Self.sizeLimit else {
      close(fd); throw SereinError.invalid("The partial macOS download is not a regular file.")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    self.handle = handle
    received = info.st_size
    try handle.seek(toOffset: UInt64(received))
    var request = URLRequest(url: url)
    if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 86_400
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let cancelled = lock.withLock {
          self.continuation = continuation; self.task = task
          return self.cancelled
        }
        task.resume()
        if cancelled { task.cancel() }
      }
    } onCancel: {
      let task = self.lock.withLock { self.cancelled = true; return self.task }
      task?.cancel()
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(request.url.map(MacComputerPolicy.appleDownload) == true ? request : nil)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    do {
      guard let response = response as? HTTPURLResponse, response.url.map(MacComputerPolicy.appleDownload) == true,
        response.statusCode == 200 || response.statusCode == 206 else {
        throw SereinError.invalid("Apple's macOS download did not return an installer.")
      }
      if response.statusCode == 206 {
        guard received > 0, let range = response.value(forHTTPHeaderField: "Content-Range"),
          range.hasPrefix("bytes \(received)-"), let total = range.split(separator: "/").last.flatMap({ Int64($0) }),
          total > received, total <= Self.sizeLimit else { throw SereinError.invalid("Apple's download could not be resumed safely.") }
        expected = total
      } else {
        try handle?.truncate(atOffset: 0); try handle?.seek(toOffset: 0)
        received = 0
        expected = response.expectedContentLength
      }
      guard expected <= Self.sizeLimit else { throw SereinError.invalid("The macOS installer download is unexpectedly large.") }
      completionHandler(.allow)
    } catch { failure = error; completionHandler(.cancel) }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    do {
      guard received + Int64(data.count) <= Self.sizeLimit else { throw SereinError.invalid("The macOS installer download exceeded its size limit.") }
      try handle?.write(contentsOf: data)
      received += Int64(data.count)
      if expected > 0 {
        let percent = min(100, Int(Double(received) / Double(expected) * 100))
        if percent != lastPercent { lastPercent = percent; progress(percent) }
      }
    } catch { failure = error; dataTask.cancel() }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let result: Result<URL, Error>
    do {
      if let failure = failure ?? error { throw failure }
      guard received > 0, expected <= 0 || received == expected else { throw SereinError.invalid("The macOS download is incomplete; it can be resumed.") }
      try handle?.synchronize(); try handle?.close(); handle = nil
      try FileManager.default.moveItem(at: partial, to: destination)
      result = .success(destination)
    } catch {
      try? handle?.close(); handle = nil
      result = .failure(error)
    }
    continuation?.resume(with: result)
    continuation = nil
    lock.withLock { self.task = nil }
    session.finishTasksAndInvalidate()
  }
}
