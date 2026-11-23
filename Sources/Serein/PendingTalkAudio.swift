import AVFoundation
import SereinCore

/// Audio awaiting the release-time privacy check. Never opens a file while listening.
/// The tap owns its buffers, so copy them under a lock and bound retention to 64 MiB.
final class PendingTalkAudio: @unchecked Sendable {
  private let lock = NSLock()
  private var buffers: [AVAudioPCMBuffer] = []
  private var bytes = 0
  private var discarded = false
  func append(_ source: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard !discarded else { return }
    let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let size = input.reduce(0) { $0 + Int($1.mDataByteSize) }
    guard bytes + size <= 64 * 1024 * 1024,
      let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
    else { discarded = true; buffers.removeAll(); return }
    copy.frameLength = source.frameLength
    let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for i in input.indices {
      guard let from = input[i].mData, let to = output[i].mData else { continue }
      memcpy(to, from, Int(input[i].mDataByteSize))
    }
    buffers.append(copy)
    bytes += size
  }
  func discard() {
    lock.lock()
    defer { lock.unlock() }
    discarded = true
    buffers.removeAll()
    bytes = 0
  }
  func save(to url: URL) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !discarded, let first = buffers.first else { return false }
    defer { buffers.removeAll(); bytes = 0; discarded = true }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let file = try AVAudioFile(forWriting: url, settings: first.format.settings)
      TalkRecordingStore.protect(url)
      for buffer in buffers { try file.write(from: buffer) }
      return true
    } catch {
      try? FileManager.default.removeItem(at: url)
      return false
    }
  }
}
