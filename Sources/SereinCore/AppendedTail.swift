import Foundation

/// The newest part of a file that another app only appends to (a chat transcript), kept between
/// reads so that each read after the first takes only the bytes written since. The file is read
/// whole again when it shrank, was replaced (another file number) or was rewritten in place (the
/// byte before the kept end is no longer a newline). Throwaway: it holds nothing the file does not.
public final class AppendedTail: @unchecked Sendable {
  public struct Read: Sendable {
    /// The kept whole lines, newest `limit` bytes at most, then a last line with no newline
    /// yet only when it is already a whole JSON value (a writer that ends without one).
    public var data: Data
    /// The whole lines this read added; all of `data` when `whole`.
    public var added: Data
    /// Earlier lines were left out to keep `limit`.
    public var omitsEarlier: Bool
    /// The file was read from its start (or its newest `limit` bytes), not from the kept end.
    public var whole: Bool
  }
  public let limit: Int
  private let lock = NSLock()
  private var path: String?
  private var device: dev_t = 0
  private var inode: ino_t = 0
  /// Just after the last newline taken: where the next read starts.
  private var offset: UInt64 = 0
  private var kept = Data()
  private var cut = false

  public init(limit: Int = 24 << 20) { self.limit = limit }

  public func read(_ path: String) throws -> Read {
    lock.lock()
    defer { lock.unlock() }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
    let size = UInt64(info.st_size)
    var whole = path != self.path || info.st_dev != device || info.st_ino != inode || size < offset
    var data = Data()
    if !whole, offset > 0 {
      try handle.seek(toOffset: offset - 1)
      data = try handle.readToEnd() ?? Data()
      // The kept end always follows a newline; anything else means the file was rewritten.
      if data.first == 10 { data = Data(data.dropFirst()) } else { whole = true }
    } else if !whole {
      data = try handle.readToEnd() ?? Data()
    }
    if whole {
      kept = Data()
      offset = size > UInt64(limit) ? size - UInt64(limit) : 0
      cut = offset > 0
      try handle.seek(toOffset: offset)
      data = try handle.readToEnd() ?? Data()
      // A cut start falls inside a line; the next whole line starts after its newline.
      if cut {
        let skip = data.firstIndex(of: 10).map { data.index(after: $0) } ?? data.endIndex
        offset += UInt64(skip - data.startIndex)
        data = Data(data[skip...])
      }
    }
    self.path = path
    device = info.st_dev
    inode = info.st_ino
    // Only whole lines are taken; a line still being written waits for its newline.
    let end = data.lastIndex(of: 10).map { data.index(after: $0) } ?? data.startIndex
    let added = Data(data[..<end])
    let pending = Data(data[end...])
    offset += UInt64(added.count)
    kept.append(added)
    if kept.count > limit {
      let from = kept.index(kept.startIndex, offsetBy: kept.count - limit)
      kept = kept[from...].firstIndex(of: 10).map { Data(kept[kept.index(after: $0)...]) } ?? Data()
      cut = true
    }
    var shown = kept
    if !pending.isEmpty, (try? JSONSerialization.jsonObject(with: pending)) != nil { shown.append(pending) }
    return Read(data: shown, added: added, omitsEarlier: cut, whole: whole)
  }
}
