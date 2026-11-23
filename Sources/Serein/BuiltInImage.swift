import CryptoKit
import Foundation
import SereinCore

/// The system image of Serein's built-in computer, downloaded once on this Mac when the person
/// sets it up (Settings › Serein's computer shows the size line first) or, on a new install, the
/// first time an assistant needs it (BuiltInSetup). Debian's checksum list is
/// fetched over HTTPS from Debian's own host, then the image from the same folder on its fixed HTTPS mirror
/// (no redirect is followed, no cookie or cache kept, EphemeralHTTP), checked against the list's
/// SHA-512 before anything uses it, and unpacked by macOS's own `tar` into `computers/vm-image/`
/// (0700, the disk 0600). Each computer's disk is a clone of it (VirtualMachineComputer). Cancel,
/// or any failure, removes everything downloaded so far.
@MainActor final class BuiltInImage: ObservableObject {
  static let shared = BuiltInImage()
  @Published private(set) var ready = false
  @Published private(set) var working = false
  @Published private(set) var lines: [String] = []
  /// The download's share done, while it runs.
  @Published private(set) var fraction: Double?
  /// This download began from an assistant's need, not from Settings, so the chat shows it.
  @Published private(set) var automatic = false
  /// A download begun that way failed: it isn't tried again by itself until the next launch.
  private(set) var automaticFailed = false
  private var folder: URL?
  private var flag: CancelFlag?
  private var fetch: FileFetch?
  /// The checksum list's session, so Cancel ends that request at once.
  private var listSession: URLSession?
  private var unpacker: Process?
  private var setupTask: Task<Void, Never>?
  private let fm = FileManager.default

  /// The verified disk every new built-in computer is cloned from.
  var base: URL? { folder?.appendingPathComponent("base.raw") }
  private var record: URL? { folder?.appendingPathComponent("image.json") }
  private static let listLimit = 1_000_000
  private struct Record: Codable {
    var file: String
    var sha512: String
    var at: Date
  }

  func attach(folder: URL) {
    self.folder = folder
    ready = isThere
    // A download a quit cut short leaves nothing behind for the next launch.
    if !ready { try? fm.removeItem(at: folder) }
  }
  /// The image is there and is the build this Serein pins (an image of another build, from an
  /// earlier Serein, is downloaded again for new computers; computers already made keep their disks).
  private var isThere: Bool {
    guard let base, let record, fm.fileExists(atPath: base.path), let data = try? Data(contentsOf: record) else { return false }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let kept = try? decoder.decode(Record.self, from: data) else { return false }
    return ChecksumList.matches(kept.sha512, published: VirtualMachinePolicy.imageSHA512)
  }

  /// What's free on the disk the image goes to; nil when it can't be measured.
  var freeBytes: Int64? {
    guard let parent = folder?.deletingLastPathComponent() else { return nil }
    return (try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage
  }

  /// Set up: the checksum list, the image, the check, the unpacking. One at a time. `automatic`:
  /// an assistant's need started it rather than the person (BuiltInSetup).
  @discardableResult func setUp(automatic: Bool = false) -> Task<Void, Never>? {
    if let setupTask { return setupTask }
    guard !working, !ready, let folder else { return nil }
    guard VirtualMachineComputer.supported else {
      lines = [VirtualMachinePolicy.unsupported]
      return nil
    }
    let flag = CancelFlag()
    self.flag = flag
    self.automatic = automatic
    automaticFailed = false
    working = true
    fraction = nil
    lines = [VirtualMachinePolicy.sizeLine + ". Getting Debian's checksum list from \(VirtualMachinePolicy.imageHost)."]
    let task = Task {
      do {
        try await download(into: folder, flag)
        ready = true
        lines.append("Done. Each assistant's built-in computer is set up from this image on its first start.")
      } catch {
        removeAll()
        automaticFailed = automatic && !flag.isSet
        lines.append(flag.isSet
          ? "Cancelled. Everything downloaded so far was removed."
          : "Failed: " + AgentPrivacy.redact(error.localizedDescription) + " Nothing was kept.")
      }
      working = false
      self.automatic = false
      fraction = nil
      fetch = nil
      listSession = nil
      unpacker = nil
      self.flag = nil
      setupTask = nil
    }
    setupTask = task
    return task
  }

  /// Stops the download, the check or the unpacking; `setUp` then removes what was there. Cancelling
  /// one an assistant's need started is a no: it isn't started by itself again.
  func cancel() {
    if automatic { GateSettings.shared.set(false, forKey: ComputerPolicy.autoSetUpKey) }
    flag?.set()
    listSession?.invalidateAndCancel()
    fetch?.cancel()
    if let unpacker, unpacker.isRunning { unpacker.terminate() }
  }

  /// Deletes the image (Cancel during a first setup removes everything). Computers already made
  /// keep their own disks. Deleted by the person, it isn't downloaded by itself again.
  func remove() {
    guard !working else { return }
    GateSettings.shared.set(false, forKey: ComputerPolicy.autoSetUpKey)
    removeAll()
    ready = false
    lines = []
  }
  private func removeAll() {
    guard let folder else { return }
    try? fm.removeItem(at: folder)
  }

  private func download(into folder: URL, _ flag: CancelFlag) async throws {
    removeAll()
    try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    let work = folder.appendingPathComponent("download", isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

    // The published digest first, over HTTPS from the image's own host.
    let session = EphemeralHTTP.session(resourceTimeout: 120)
    listSession = session
    defer { session.finishTasksAndInvalidate() }
    let refused = SereinError.invalid("Debian's checksum list could not be fetched from \(VirtualMachinePolicy.imageHost).")
    let (bytes, response) = try await session.bytes(from: VirtualMachinePolicy.sumsURL)
    guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= Self.listLimit else {
      bytes.task.cancel()
      throw refused
    }
    // Read only up to the limit: a longer answer is not a checksum list.
    var sums = Data()
    for try await byte in bytes {
      sums.append(byte)
      if sums.count > Self.listLimit {
        bytes.task.cancel()
        throw refused
      }
    }
    guard let published = ChecksumList.digest(
      for: VirtualMachinePolicy.imageFile, in: String(decoding: sums, as: UTF8.self), length: VirtualMachinePolicy.digestLength)
    else { throw SereinError.invalid("Debian's checksum list does not name \(VirtualMachinePolicy.imageFile) once with a SHA-512 digest.") }
    // The list and this Serein's pin must agree: the image is the one build its packages are pinned against.
    guard ChecksumList.matches(published, published: VirtualMachinePolicy.imageSHA512) else {
      throw SereinError.invalid("Debian's checksum list gives another digest for \(VirtualMachinePolicy.imageFile) than this Serein pins, so nothing was downloaded.")
    }
    try checkCancelled(flag)

    lines.append("Downloading \(VirtualMachinePolicy.imageFile) from \(VirtualMachinePolicy.imageDownloadHost).")
    let archive = work.appendingPathComponent(VirtualMachinePolicy.imageFile)
    let fetch = FileFetch(
      target: archive, limit: VirtualMachinePolicy.downloadLimit, what: "image", from: "Debian",
      host: VirtualMachinePolicy.imageDownloadHost
    ) { [weak self] share in
      Task { @MainActor in if self?.working == true { self?.fraction = share } }
    }
    self.fetch = fetch
    try await fetch.run(VirtualMachinePolicy.imageURL)
    fraction = nil
    try checkCancelled(flag)

    lines.append("Checking the download against Debian's \(VirtualMachinePolicy.sumsFile).")
    let computed = try await Task.detached { try fileDigest(archive, SHA512.self, flag) }.value
    guard ChecksumList.matches(computed, published: VirtualMachinePolicy.imageSHA512) else {
      throw SereinError.invalid("The download does not match Debian's published checksum, so Serein deleted it.")
    }

    lines.append("Checked. Unpacking the disk.")
    let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
    try fm.createDirectory(at: unpacked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try await unpack(archive, into: unpacked)
    try checkCancelled(flag)
    let disk = unpacked.appendingPathComponent(VirtualMachinePolicy.imageMember)
    // Only a regular file, never a link the archive made.
    guard let kind = try? fm.attributesOfItem(atPath: disk.path)[.type] as? FileAttributeType, kind == .typeRegular else {
      throw SereinError.invalid("The image held no disk where Debian puts it.")
    }
    guard let base, let record else { throw SereinError.invalid("Serein's Library is not ready.") }
    try fm.moveItem(at: disk, to: base)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: base.path)
    try fm.removeItem(at: work)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(Record(file: VirtualMachinePolicy.imageFile, sha512: computed, at: Date())).write(to: record, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
  }

  private func checkCancelled(_ flag: CancelFlag) throws {
    if flag.isSet { throw SereinError.invalid("Cancelled.") }
  }

  /// macOS's own `tar` unpacks the archive (checked before this) into an empty folder of its own;
  /// it refuses absolute paths and `..` by default.
  private func unpack(_ archive: URL, into folder: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-x", "--no-same-owner", "-f", archive.path, "-C", folder.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    unpacker = process
    let status: Int32 = try await withCheckedThrowingContinuation { (done: CheckedContinuation<Int32, Error>) in
      process.terminationHandler = { finished in done.resume(returning: finished.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        done.resume(throwing: error)
      }
    }
    guard status == 0 else { throw SereinError.invalid("The disk could not be unpacked (tar ended with \(status)).") }
  }

}

/// The file's digest in hex, read in 4 MB pieces; stops when cancelled.
func fileDigest<H: HashFunction>(_ file: URL, _: H.Type, _ flag: CancelFlag) throws -> String {
  let handle = try FileHandle(forReadingFrom: file)
  defer { try? handle.close() }
  var hasher = H()
  while let piece = try handle.read(upToCount: 4 << 20), !piece.isEmpty {
    if flag.isSet { throw SereinError.invalid("Cancelled.") }
    hasher.update(data: piece)
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// A cancel switch the download's own threads can read.
final class CancelFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var on = false
  func set() {
    lock.lock(); defer { lock.unlock() }
    on = true
  }
  var isSet: Bool {
    lock.lock(); defer { lock.unlock() }
    return on
  }
}

/// One large download (the computer's image, the speech model) in a session of its own
/// (EphemeralHTTP's settings): a redirect is followed only where `follow` allows its address,
/// only a 200 answer is kept, and a download larger than `limit` is stopped. The file is
/// moved to `target` as soon as it is complete; progress is reported in steps of half a percent.
final class FileFetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let target: URL
  private let limit: Int64
  /// For what the person reads when it fails: the "image" "Debian" publishes on `host`.
  private let what: String
  private let from: String
  private let host: String
  private let follow: @Sendable (URL) -> Bool
  private let progress: @Sendable (Double) -> Void
  private let lock = NSLock()
  private var finished: CheckedContinuation<Void, Error>?
  private var task: URLSessionDownloadTask?
  private var failure: String?
  /// Only on the session's own serial queue.
  private var reported = -1.0

  init(target: URL, limit: Int64, what: String, from: String, host: String,
       follow: @escaping @Sendable (URL) -> Bool = { _ in false }, progress: @escaping @Sendable (Double) -> Void) {
    self.target = target
    self.limit = limit
    self.what = what
    self.from = from
    self.host = host
    self.follow = follow
    self.progress = progress
  }

  func run(_ url: URL) async throws {
    let session = URLSession(configuration: EphemeralHTTP.configuration(), delegate: self, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
      let task = session.downloadTask(with: url)
      lock.lock()
      finished = done
      self.task = task
      lock.unlock()
      task.resume()
    }
  }
  func cancel() {
    lock.lock()
    let task = self.task
    lock.unlock()
    task?.cancel()
  }
  private func fail(_ reason: String) {
    lock.lock(); defer { lock.unlock() }
    if failure == nil { failure = reason }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(request.url.map(follow) == true ? request : nil)
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else {
      fail("The \(what) is larger than Serein expects from \(from), so the download was stopped.")
      downloadTask.cancel()
      return
    }
    guard totalBytesExpectedToWrite > 0 else { return }
    let share = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    if share - reported >= 0.005 {
      reported = share
      progress(share)
    }
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      fail("\(host) answered \(status) for the \(what).")
      return
    }
    do {
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.moveItem(at: location, to: target)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    } catch {
      fail("The download could not be kept: " + error.localizedDescription)
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let done = finished
    finished = nil
    let failure = self.failure
    lock.unlock()
    if let failure {
      done?.resume(throwing: SereinError.invalid(failure))
    } else if let error {
      done?.resume(throwing: error)
    } else {
      done?.resume()
    }
  }
}
