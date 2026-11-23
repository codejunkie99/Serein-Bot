import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
// Claude uses this immutable per-run copy as its shell, including its pre-sandbox startup
// snapshot. Do not call setsid here: command descendants must stay in the CLI's owned group.
if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "zsh" {
  launchClaudeShell(arguments)
}
guard let executable = arguments.first, executable.hasPrefix("/") else { exit(126) }
if setsid() < 0 && getpgrp() != getpid() { exit(126) }
writeRunRecord()
closeInheritedDescriptors()
var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
execv(executable, &argv)
perror("Serein process host")
exit(127)

/// Only stdin, stdout and stderr go on to the program. Serein starts processes from more than one
/// thread, so a pipe end it held for another process at the moment this one was spawned can be
/// inherited here; kept open by a long-lived program (a pooled helper), it hides the end of that
/// other process's output and its run never completes.
func closeInheritedDescriptors() {
  guard let directory = opendir("/dev/fd") else { return }
  let own = dirfd(directory)
  var open: [Int32] = []
  while let entry = readdir(directory) {
    let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
    if let fd = Int32(name), fd > 2, fd != own { open.append(fd) }
  }
  closedir(directory)
  for fd in open { close(fd) }
}

/// An engine run (SereinEngines.RunRecords) is recorded before exec, so no group that could run
/// is ever unrecorded. A run that cannot be recorded does not start.
func writeRunRecord() {
  let environment = ProcessInfo.processInfo.environment
  guard let directory = environment["SEREIN_RUN_DIR"], environment["SEREIN_RUN_TAG"] != nil else { return }
  let pid = getpid()
  let fd = open("\(directory)/\(pid)", O_CREAT | O_EXCL | O_WRONLY, 0o600)
  guard fd >= 0 else { exit(126) }
  let line = Array("\(pid)\n".utf8)
  guard write(fd, line, line.count) == line.count, fsync(fd) == 0 else { exit(126) }
  close(fd)
}
