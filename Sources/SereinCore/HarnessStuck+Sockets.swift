import Darwin
import Foundation

extension HarnessStuck {
  /// How many of these remote addresses are model I/O: every one that is not loopback.
  public static func modelConnections(remotes: [String]) -> Int {
    remotes.filter { !isLoopbackAddress($0) }.count
  }

  /// Established TCP connections of `pids` to a remote that is not loopback, read through libproc.
  /// A process that exited since it was listed is skipped. nil when no process could be read, or
  /// one that still runs refuses the read: unknown is never reported as zero.
  public static func modelConnections(pids: [pid_t]) -> Int? {
    var remotes: [String] = []
    var read = false
    for pid in pids {
      if let found = establishedRemotes(pid) {
        remotes += found
        read = true
      } else if errno != ESRCH {
        return nil
      }
    }
    return read ? modelConnections(remotes: remotes) : nil
  }

  private static func establishedRemotes(_ pid: pid_t) -> [String]? {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0, bytes < 4 * 1024 * 1024 else { return nil }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 32)
    let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    guard filled > 0 else { return nil }
    var remotes: [String] = []
    for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
      var info = socket_fdinfo()
      // A socket closed since the listing is simply gone.
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
        info.psi.soi_kind == SOCKINFO_TCP
      else { continue }
      let tcp = info.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == TSI_S_ESTABLISHED else { continue }
      var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      var foreign = tcp.tcpsi_ini.insi_faddr
      let family = tcp.tcpsi_ini.insi_vflag & UInt8(INI_IPV6) != 0 ? AF_INET6 : AF_INET
      let ok = family == AF_INET6
        ? withUnsafePointer(to: &foreign.ina_6) { inet_ntop(AF_INET6, $0, &text, socklen_t(text.count)) }
        : withUnsafePointer(to: &foreign.ina_46.i46a_addr4) { inet_ntop(AF_INET, $0, &text, socklen_t(text.count)) }
      if ok != nil { remotes.append(String(cString: text)) }
    }
    return remotes
  }
}
