import Foundation

/// Reads small regular files without following links or blocking on pipes and devices.
public enum SafeFileRead {
  public static func regularFile(_ path: String, limit: Int) -> Data? {
    let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while data.count < limit {
      let n = read(fd, &buffer, min(buffer.count, limit - data.count))
      if n <= 0 { break }
      data.append(buffer, count: n)
    }
    return data
  }
}
