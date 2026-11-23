import Darwin
import Foundation

/// The app's managed local server.
/// not run on a real Mac.
/// The lock is an advisory flock, taken only when singleInstance is true.
/// The kernel releases it when the process dies, so a crash does not block the next start.
/// The socket listens on 127.0.0.1 and on no other address.
enum ManagedLocalServer {
  private static var lockFD: Int32 = -1
  private static var listener: Int32 = -1
  private static var lockURL: URL?

  static func start(directory: URL, singleInstance: Bool) -> Bool {
    if singleInstance {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("instance.lock")
      let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      if fd < 0 { return false }
      if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        Darwin.close(fd)
        return false
      }
      lockFD = fd
      lockURL = url
    }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return false }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if bound != 0 || listen(fd, 16) != 0 {
      Darwin.close(fd)
      return false
    }
    listener = fd
    return true
  }

  static func close() {
    if listener >= 0 {
      Darwin.close(listener)
      listener = -1
    }
    if lockFD >= 0 {
      flock(lockFD, LOCK_UN)
      Darwin.close(lockFD)
      lockFD = -1
    }
    lockURL = nil
  }
}
