import CryptoKit
import Foundation
import SereinCore

/// The speech model's download, begun only by the person on its card (SereinSetupCard): from the
/// pinned Hugging Face address into `Application Support/Serein/Models`, where SpeechModel looks
/// first. The file is kept only when its length and SHA-256 are the pinned ones. Cancel, or any
/// failure, removes what was fetched.
// shortcut: a download that stops starts again from nothing; keep URLSession's resume data if
// people on slow connections report failed downloads.
@MainActor final class SpeechModelDownload: ObservableObject {
  static let shared = SpeechModelDownload(.pinned) { await SpeechEngine.shared.warm() }
  static let declinedKey = "serein.speech.model.declined"
  static var declined: Bool { UserDefaults.standard.bool(forKey: declinedKey) }

  struct File: Sendable {
    var source: URL
    var bytes: Int64
    var sha256: String
    /// Nil when this Mac gives no Application Support folder.
    var target: URL?

    static var pinned: File {
      var source = SpeechModel.source
      #if DEBUG
      // For trying the card against a copy served on this Mac; the length and checksum stay pinned.
      if let other = ProcessInfo.processInfo.environment["SEREIN_SPEECH_MODEL_URL"].flatMap(URL.init(string:)) {
        source = other
      }
      #endif
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      return File(
        source: source, bytes: SpeechModel.bytes, sha256: SpeechModel.sha256,
        target: support.map { SpeechModel.candidates(applicationSupport: $0)[0] })
    }
  }
  enum State: Equatable {
    case idle, checking, done
    /// The share fetched so far.
    case downloading(Double)
    case failed(String)
  }
  @Published private(set) var state = State.idle
  var working: Bool {
    if case .downloading = state { return true }
    return state == .checking
  }
  private let file: File
  private let after: @MainActor () async -> Void
  private var flag: CancelFlag?
  private var fetch: FileFetch?

  /// `after` runs once the checked file is in place.
  init(_ file: File, after: @escaping @MainActor () async -> Void) {
    self.file = file
    self.after = after
  }

  @discardableResult func start() -> Task<Void, Never>? {
    guard !working, state != .done else { return nil }
    guard let target = file.target else {
      state = .failed("This Mac gave Serein no folder to keep the speech model in.")
      return nil
    }
    let flag = CancelFlag()
    self.flag = flag
    state = .downloading(0)
    return Task {
      let part = target.appendingPathExtension("download")
      do {
        try await get(to: part, flag)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: part, to: target)
        state = .done
        await after()
      } catch {
        try? FileManager.default.removeItem(at: part)
        state = flag.isSet ? .idle : .failed(AgentPrivacy.redact(error.localizedDescription))
      }
      self.flag = nil
      fetch = nil
    }
  }

  func cancel() {
    flag?.set()
    fetch?.cancel()
  }

  private func get(to part: URL, _ flag: CancelFlag) async throws {
    let folder = part.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage
    if let free, free < file.bytes + (200 << 20) {
      throw SereinError.invalid("This Mac's disk has too little room for the speech model.")
    }
    let fetch = FileFetch(
      target: part, limit: file.bytes, what: "speech model", from: "Hugging Face", host: file.source.host ?? "The server",
      follow: SpeechModel.mayFollow
    ) { [weak self] share in
      Task { @MainActor in
        if case .downloading = self?.state { self?.state = .downloading(share) }
      }
    }
    self.fetch = fetch
    try await fetch.run(file.source)
    if flag.isSet { throw SereinError.invalid("Cancelled.") }
    state = .checking
    let size = (try? part.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    let sum = try await Task.detached { try fileDigest(part, SHA256.self, flag) }.value
    guard size == file.bytes, sum == file.sha256 else {
      throw SereinError.invalid("The download is not the file Serein expects.")
    }
  }
}
