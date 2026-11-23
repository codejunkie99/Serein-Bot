import Foundation

/// Parser for Safari's `Cookies.binarycookies` file: a big-endian page index followed by pages of
/// little-endian cookie records. Pure bytes in, cookies out; reading the file (which the user
/// picks in an open panel) is separate so the parser is testable with synthetic data.
public enum SafariCookies {
  public static let fileName = "Cookies.binarycookies"
  /// The folder the open panel starts in.
  public static var folderURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Containers/com.apple.Safari/Data/Library/Cookies", isDirectory: true)
  }
  public static var fileURL: URL { folderURL.appendingPathComponent(fileName) }

  public enum Failure: Error, Equatable, LocalizedError {
    case blocked
    case notFound
    case invalid

    public var errorDescription: String? {
      switch self {
      case .blocked:
        return
          "macOS blocked Serein from opening that file. Export your sign-ins from Safari, or sign in to those sites in Serein instead."
      case .notFound: return "Safari has no sign-in file on this Mac."
      case .invalid: return "That is not a Safari cookie file."
      }
    }
  }

  /// True for the errors macOS gives when privacy protection blocks a read.
  public static func isPermissionError(_ error: Error) -> Bool {
    let e = error as NSError
    if e.domain == NSCocoaErrorDomain, e.code == NSFileReadNoPermissionError { return true }
    if e.domain == NSPOSIXErrorDomain, e.code == Int(EPERM) || e.code == Int(EACCES) { return true }
    if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== e {
      return isPermissionError(underlying)
    }
    return false
  }

  /// Reads and parses the file once. Throws `.blocked` when macOS refuses the read.
  public static func read(url: URL, now: Date = Date()) throws -> CookieReadResult {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      if isPermissionError(error) { throw Failure.blocked }
      if (error as NSError).code == NSFileReadNoSuchFileError { throw Failure.notFound }
      throw error
    }
    return try parse(data, now: now)
  }

  /// Seconds between 1970-01-01 and Safari's reference date, 2001-01-01.
  static let macEpochOffset: Double = 978_307_200

  public static func parse(
    _ data: Data, now: Date = Date(), limit: Int = 50_000, isCancelled: () -> Bool = { false }
  ) throws -> CookieReadResult {
    let bytes = [UInt8](data)
    guard bytes.count >= 8, bytes[0..<4].elementsEqual("cook".utf8) else { throw Failure.invalid }
    func be32(_ at: Int) -> Int? {
      guard at >= 0, at + 4 <= bytes.count else { return nil }
      return bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
    }
    func le32(_ at: Int) -> Int? {
      guard at >= 0, at + 4 <= bytes.count else { return nil }
      return bytes[at..<at + 4].reversed().reduce(0) { $0 << 8 | Int($1) }
    }
    func leDouble(_ at: Int) -> Double? {
      guard at >= 0, at + 8 <= bytes.count else { return nil }
      var bits: UInt64 = 0
      for i in (0..<8).reversed() { bits = bits << 8 | UInt64(bytes[at + i]) }
      return Double(bitPattern: bits)
    }
    func cString(_ at: Int, end: Int) -> String? {
      guard at >= 0, at < end, end <= bytes.count else { return nil }
      guard let stop = bytes[at..<end].firstIndex(of: 0) else { return nil }
      return String(decoding: bytes[at..<stop], as: UTF8.self)
    }

    guard let pageCount = be32(4), pageCount <= 100_000 else { throw Failure.invalid }
    var sizes: [Int] = []
    for i in 0..<pageCount {
      guard let size = be32(8 + i * 4), size > 0 else { throw Failure.invalid }
      sizes.append(size)
    }
    var pageStart = 8 + pageCount * 4
    var cookies: [ImportedCookie] = []
    var skipped = 0
    for size in sizes {
      if isCancelled() { throw CancellationError() }
      let page = pageStart
      let pageEnd = pageStart + size
      pageStart = pageEnd
      guard pageEnd <= bytes.count, page + 8 <= pageEnd,
        bytes[page..<page + 4].elementsEqual([0, 0, 1, 0]),
        let declared = le32(page + 4)
      else {
        skipped += 1
        continue
      }
      // A page cannot hold more offsets than fit in it; a larger count is a damaged file.
      let count = min(declared, max(0, (pageEnd - page - 8) / 4))
      skipped += declared - count
      for i in 0..<count {
        guard cookies.count < limit else {
          skipped += count - i
          break
        }
        guard let offset = le32(page + 8 + i * 4), offset >= 8, offset < size else {
          // The rest of this page's offsets cannot be trusted either.
          skipped += count - i
          break
        }
        let start = page + offset
        guard let recordSize = le32(start), recordSize >= 56, start + recordSize <= pageEnd,
          let flags = le32(start + 8), let urlOffset = le32(start + 16),
          let nameOffset = le32(start + 20), let pathOffset = le32(start + 24),
          let valueOffset = le32(start + 28), let expiry = leDouble(start + 40),
          let domain = cString(start + urlOffset, end: start + recordSize),
          let name = cString(start + nameOffset, end: start + recordSize),
          let path = cString(start + pathOffset, end: start + recordSize),
          let value = cString(start + valueOffset, end: start + recordSize)
        else {
          skipped += 1
          continue
        }
        var expires: Date?
        if expiry.isFinite, expiry > 0 {
          let date = Date(timeIntervalSince1970: expiry + macEpochOffset)
          if date <= now {
            skipped += 1
            continue
          }
          expires = date
        }
        guard !domain.isEmpty, !name.isEmpty || !value.isEmpty else {
          skipped += 1
          continue
        }
        cookies.append(
          ImportedCookie(
            domain: domain, name: name, value: value, path: path.isEmpty ? "/" : path,
            expires: expires, secure: flags & 0x1 != 0, httpOnly: flags & 0x4 != 0, sameSite: nil))
      }
    }
    return CookieReadResult(cookies: cookies, skipped: skipped)
  }
}
