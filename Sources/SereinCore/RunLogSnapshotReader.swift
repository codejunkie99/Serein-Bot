import Darwin
import Foundation

/// A serial-use reader for the append-only run log. It retains the latest record per run,
/// reads new bytes in bounded chunks, and returns its cached snapshot when the file has not
/// changed. The writer and the durability of the log are independent of this display cache.
public struct RunLogSnapshotReader {
  private struct Stamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ value: stat) {
      device = value.st_dev
      inode = value.st_ino
      size = value.st_size
      modifiedSeconds = value.st_mtimespec.tv_sec
      modifiedNanos = value.st_mtimespec.tv_nsec
      changedSeconds = value.st_ctimespec.tv_sec
      changedNanos = value.st_ctimespec.tv_nsec
    }
  }
  private var stamp: Stamp?
  private var completeOffset: UInt64 = 0
  private var header = Data()
  private var boundary = Data()
  private var latest: [String: RunRecord] = [:]
  private var cached: [RunRecord] = []
  private let url: URL
  /// Diagnostic counters let synthetic checks verify that an unchanged poll reads no bytes.
  public private(set) var bytesRead: UInt64 = 0
  public private(set) var decodedRecords: UInt64 = 0
  public private(set) var revision: UInt64 = 0

  public init(library: Library) {
    url = library.root.appendingPathComponent(Library.runLogPath)
  }

  /// Latest record per id, newest first, with the same malformed-line behavior as `runs()`.
  /// Truncation, replacement and a same-size rewrite rebuild the snapshot. A valid final line
  /// without a newline is visible, but reread on append so a partial record never becomes a
  /// permanent winner. Transient read errors keep the last successfully read snapshot.
  public mutating func snapshot() -> [RunRecord] {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      if !FileManager.default.fileExists(atPath: url.path) { reset() }
      return cached
    }
    defer { try? handle.close() }
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0 else { return cached }
    let current = Stamp(info)
    guard current != stamp else { return cached }
    var appending = stamp.map {
      $0.device == current.device && $0.inode == current.inode && current.size > $0.size
    } ?? false
    // A log can be truncated and regrown between polls. Check small prefix/boundary samples
    // before trusting an increased size as an append; normal appends keep both samples.
    if appending {
      do {
        appending = try Self.sample(handle, at: 0, count: header.count) == header
          && Self.sample(handle, at: completeOffset - UInt64(boundary.count), count: boundary.count) == boundary
      } catch { return cached }
    }
    var updated = appending ? latest : [:]
    var offset: UInt64 = appending ? completeOffset : 0
    var buffer = Data()
    var searchOffset = 0
    var remaining = UInt64(max(0, current.size)) - offset
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var readBytes: UInt64 = 0
    var records: UInt64 = 0
    var newHeader = Data()
    var newBoundary = Data()
    do {
      try handle.seek(toOffset: offset)
      while remaining > 0 {
        guard !Task.isCancelled else { return cached }
        let chunk = try handle.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
        guard !chunk.isEmpty else { return cached }  // file truncated while being read
        remaining -= UInt64(chunk.count)
        readBytes += UInt64(chunk.count)
        buffer.append(chunk)
        var consumed = buffer.startIndex
        while let newline = buffer[searchOffset...].firstIndex(of: 10) {
          if let record = try? decoder.decode(RunRecord.self, from: buffer[consumed..<newline]) {
            updated[record.id] = record
            records += 1
          }
          let end = buffer.index(after: newline)
          offset += UInt64(end - consumed)
          consumed = end
          searchOffset = end
        }
        if consumed != buffer.startIndex { buffer = Data(buffer[consumed...]) }
        // Bytes already searched contain no newline; a long record scans each byte once.
        searchOffset = buffer.count
      }
      newHeader = try Self.sample(handle, at: 0, count: Int(min(current.size, 256)))
      let boundaryCount = Int(min(offset, 256))
      newBoundary = try Self.sample(handle, at: offset - UInt64(boundaryCount), count: boundaryCount)
    } catch { return cached }
    var visible = updated
    if !buffer.isEmpty, let record = try? decoder.decode(RunRecord.self, from: buffer) {
      visible[record.id] = record
      records += 1
    }
    latest = updated
    completeOffset = offset
    header = newHeader
    boundary = newBoundary
    cached = visible.values.sorted { $0.startedAt > $1.startedAt }
    stamp = current
    bytesRead += readBytes
    decodedRecords += records
    revision &+= 1
    return cached
  }

  private mutating func reset() {
    if stamp != nil || !cached.isEmpty { revision &+= 1 }
    stamp = nil
    completeOffset = 0
    header.removeAll()
    boundary.removeAll()
    latest.removeAll()
    cached.removeAll()
  }

  private static func sample(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
    guard count > 0 else { return Data() }
    try handle.seek(toOffset: offset)
    return try handle.read(upToCount: count) ?? Data()
  }
}
