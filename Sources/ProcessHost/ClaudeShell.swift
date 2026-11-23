import Darwin
import Foundation

/// Decode only a quoted simple command, never shell syntax. SRT quotes its argv with
/// shell-quote; interpreting expansions or operators here could execute outside its sandbox.
private func simpleArguments(_ text: String) -> [String]? {
  var result: [String] = [], word = ""
  var quote: Character?, escaped = false, started = false
  for character in text {
    if escaped {
      guard character != "\n" else { return nil }
      if quote == "\"" && !"$`\"\\".contains(character) { word.append("\\") }
      word.append(character); escaped = false; continue
    }
    if quote == "'" {
      if character == "'" { quote = nil } else { word.append(character) }
    } else if quote == "\"" {
      if character == "\"" { quote = nil }
      else if character == "\\" { escaped = true }
      else if character == "$" || character == "`" { return nil }
      else { word.append(character) }
    } else if character == "'" || character == "\"" {
      quote = character; started = true
    } else if character == "\\" {
      escaped = true; started = true
    } else if character == " " || character == "\t" {
      if started { result.append(word); word = ""; started = false }
    } else {
      guard !"\n\r;|&<>$`*?[](){}~#".contains(character) else { return nil }
      word.append(character); started = true
    }
  }
  guard quote == nil && !escaped else { return nil }
  if started { result.append(word) }
  return result
}

private func identifier(_ text: String) -> Bool {
  guard let first = text.utf8.first,
    first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
  return text.utf8.allSatisfy { $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
}

/// The only unsandboxed command dispatch accepted is SRT's complete argv envelope. Execute
/// it directly so no host shell can evaluate model text, PATH aliases, operators or expansions.
private func sandboxEnvelope(_ arguments: [String], executable: String) -> [String]? {
  let script: String
  if arguments.count == 2 && arguments[0] == "-c" { script = arguments[1] }
  else if arguments.count == 3 && arguments[0] == "-l" && arguments[1] == "-c" { script = arguments[2] }
  else if arguments.count == 3 && arguments[0] == "-c" && arguments[1] == "-l" { script = arguments[2] }
  else { return nil }
  guard var words = simpleArguments(script), words.first == "env" || words.first == "/usr/bin/env" else { return nil }
  words[0] = "/usr/bin/env"
  var index = 1
  while index < words.count {
    if words[index] == "-u" {
      guard index + 1 < words.count, identifier(words[index + 1]) else { return nil }
      index += 2
    } else if let equal = words[index].firstIndex(of: "="), identifier(String(words[index][..<equal])) {
      index += 1
    } else { break }
  }
  if index < words.count && words[index] == "--" { index += 1 }
  guard words.count == index + 6,
    words[index] == "/usr/bin/sandbox-exec", words[index + 1] == "-p",
    !words[index + 2].isEmpty, words[index + 3] == executable, words[index + 4] == "-c" else { return nil }
  return words
}

private func execute(_ arguments: [String]) -> Never {
  var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
  execv(arguments[0], &argv)
  perror("Serein Claude shell")
  exit(127)
}

private func physicalPath(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
}

private func snapshotInitializer(_ arguments: [String]) -> Bool {
  guard arguments.count == 3, arguments[0] == "-c", arguments[1] == "-l",
    arguments[2].hasPrefix("SNAPSHOT_FILE="), let newline = arguments[2].firstIndex(of: "\n"),
    let words = simpleArguments(String(arguments[2][..<newline].dropFirst("SNAPSHOT_FILE=".count))),
    words.count == 1, words[0].hasPrefix("/"),
    arguments[2].contains("# First, create/clear the snapshot file\n"),
    arguments[2].contains("echo \"# Snapshot file\" >| \"$SNAPSHOT_FILE\"") else { return false }
  let target = URL(fileURLWithPath: words[0])
  let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
  return target.lastPathComponent.hasPrefix("snapshot-zsh-") && target.pathExtension == "sh"
    && physicalPath(target.deletingLastPathComponent().path) == physicalPath(config + "/shell-snapshots")
}

func launchClaudeShell(_ arguments: [String]) -> Never {
  typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
  guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { exit(126) }
  let check = unsafeBitCast(symbol, to: SandboxCheck.self)
  let sandboxed = check(getpid(), nil, 0)
  guard sandboxed == 0 || sandboxed == 1 else { exit(126) }
  for key in ProcessInfo.processInfo.environment.keys {
    let name = key.lowercased()
    if name.contains("token") || name.contains("secret") || name.contains("password")
      || name.contains("credential") || name.contains("api_key") || name.contains("private_key")
      || name == "aws_access_key_id" || ["bash_env", "env", "claude_code_shell_prefix"].contains(name) {
      unsetenv(key)
    }
  }
  let executable = CommandLine.arguments[0]
  let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
  setenv("ZDOTDIR", directory, 1)
  if sandboxed == 1 { execute(["/bin/zsh", "-f"] + arguments) }
  if let envelope = sandboxEnvelope(arguments, executable: executable) { execute(envelope) }
  if arguments == ["--version"] { execute(["/bin/zsh", "-f", "--version"]) }
  // Verified Claude 2.1.296 uses these initialization forms. The snapshot markers identify
  // the form; the startup read/write/network profile still supplies its security boundary.
  if arguments == ["-c", "env"] || snapshotInitializer(arguments) {
    execute(["/usr/bin/sandbox-exec", "-f", directory + "/startup.sb", "/bin/zsh", "-f"] + arguments)
  }
  fputs("Serein refused an unsupported Claude shell launch. Run the local security verifier after updating Claude.\n", stderr)
  exit(126)
}
