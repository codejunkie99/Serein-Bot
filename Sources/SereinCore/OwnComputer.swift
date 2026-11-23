import CryptoKit
import Foundation

/// The person's own computer or VM as an assistant's computer (Settings › Serein's computer ›
/// Connect your own…), reached only through the system's own `ssh` with the person's own keys and
/// agent. Two kinds: "A desktop for Serein" (`ComputerPlace.ownDesktop`, Serein's hardened
/// container started over SSH on a Linux machine with Docker) and "Use this machine as it is"
/// (`ComputerPlace.ownMachine`, a small helper in the person's home there, treated like their own
/// Mac: every act asks). Everything here is pure, so SereinChecks can check it: the SSH
/// destination, the aliases read from ~/.ssh/config (Host names only), host keys and their
/// fingerprints, the ssh arguments, the helper's install manifest and the access rules.

// MARK: where the machine is

/// The machine as the person named it: an alias from ~/.ssh/config, or `user@host` with an optional
/// `:port`. Kept only in the computer's own record (`OwnSettings`); ssh reads the alias's own lines.
public struct SSHTarget: Codable, Hashable, Sendable {
  /// As the person picked or typed it.
  public let text: String
  /// What ssh is given after `--`: the alias, or user@host.
  public let destination: String
  public let port: Int?
  public var isAlias: Bool { !destination.contains("@") }

  private init(text: String, destination: String, port: Int?) {
    self.text = text
    self.destination = destination
    self.port = port
  }

  /// An alias or user@host[:port], or nil. Nothing that could reach ssh as an option (a leading
  /// dash) or the shell (spaces, quotes) passes.
  public static func parse(_ raw: String) -> SSHTarget? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 255, !text.hasPrefix("-") else { return nil }
    guard let at = text.firstIndex(of: "@") else {
      return isAliasName(text) ? SSHTarget(text: text, destination: text, port: nil) : nil
    }
    let user = String(text[..<at])
    let rest = text[text.index(after: at)...]
    guard user.count <= 32, word(user) else { return nil }
    let host: String
    var portText: Substring?
    if rest.hasPrefix("[") {
      guard let close = rest.firstIndex(of: "]") else { return nil }
      host = String(rest[rest.index(after: rest.startIndex)..<close]).lowercased()
      let tail = rest[rest.index(after: close)...]
      if !tail.isEmpty {
        guard tail.hasPrefix(":") else { return nil }
        portText = tail.dropFirst()
      }
      guard ComputerNetworkPolicy.ipv6Groups(host) != nil else { return nil }
    } else {
      let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count <= 2 else { return nil }
      host = String(parts[0]).lowercased()
      if parts.count == 2 { portText = parts[1] }
      guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"), !host.hasPrefix("."), !host.contains(":"),
        ComputerNetworkPolicy.plainHost(host)
      else { return nil }
    }
    var port: Int?
    if let portText {
      guard !portText.isEmpty, portText.count <= 5, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
        let value = Int(portText), (1...65535).contains(value)
      else { return nil }
      port = value
    }
    return SSHTarget(text: text, destination: user + "@" + host, port: port)
  }

  /// A name ssh_config can hold that Serein passes on: letters, digits, `.`, `_` and `-`, not
  /// starting with a dash or a dot, at most 64 characters.
  public static func isAliasName(_ name: String) -> Bool {
    name.count <= 64 && word(name) && !name.hasPrefix(".")
  }
  private static func word(_ text: String) -> Bool {
    !text.isEmpty && !text.hasPrefix("-")
      && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
  }

  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let parsed = SSHTarget.parse(raw) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an SSH destination."))
    }
    self = parsed
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(text)
  }
}

/// The Host names in the text of ~/.ssh/config, for the alias picker. Only `Host` lines are read:
/// every other line (HostName, User, IdentityFile, Match, Include…) is skipped unread past its
/// keyword, and nothing of the file is kept but the names. Patterns (`*`, `?`, `!`) are not
/// machines, so they are skipped too.
public enum SSHConfigHosts {
  public static let limit = 200

  public static func aliases(_ config: String) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for raw in config.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      // `Host a b` or `Host=a b`: the keyword ends at a space, a tab or `=`.
      guard !line.hasPrefix("#"), let end = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }),
        line[..<end].lowercased() == "host"
      else { continue }
      var rest = line[end...].drop { $0 == " " || $0 == "\t" }
      if rest.first == "=" { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
      for token in rest.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
        if token.hasPrefix("#") { break }
        var name = String(token)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
        guard !name.contains(where: { "*?!".contains($0) }), SSHTarget.isAliasName(name), seen.insert(name).inserted
        else { continue }
        out.append(name)
        if out.count == limit { return out }
      }
    }
    return out
  }
}

// MARK: host keys

/// One SSH host key: its type and its public blob, from a known_hosts line.
public struct SSHHostKey: Equatable, Sendable {
  public let type: String
  public let blob: Data
  public static let types: Set<String> = [
    "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa",
    "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
  ]

  /// nil unless the type is a host key type and the blob names that same type first (a 4-byte
  /// length, then the name), as every SSH public key blob does.
  public init?(type: String, base64: String) {
    guard Self.types.contains(type), base64.count <= 16_384, let blob = Data(base64Encoded: base64), blob.count > 4
    else { return nil }
    let bytes = [UInt8](blob)
    let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
    let name = Array(type.utf8)
    guard length == name.count, bytes.count > 4 + length, Array(bytes[4..<4 + length]) == name else { return nil }
    self.type = type
    self.blob = blob
  }
  public var base64: String { blob.base64EncodedString() }
  /// As `ssh-keygen -l` and a machine's own sshd print it: `SHA256:` and the unpadded base64 of
  /// the blob's SHA-256.
  public var fingerprint: String {
    "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
  }
  /// The kind in the words ssh-keygen uses (ED25519, ECDSA, RSA).
  public var kind: String {
    if type.contains("ed25519") { return "ED25519" }
    if type.contains("ecdsa") { return "ECDSA" }
    return "RSA"
  }
  public func line(host: String) -> String { host + " " + type + " " + base64 }
}

/// Serein's own known_hosts file (one per Library, 0600), keyed by each computer's own name
/// (`SSHInvocation.hostAlias`). The person's ~/.ssh/known_hosts is never read or written.
public enum SSHHostKeys {
  /// The keys `text` holds for exactly `host`. Marker lines (`@revoked`, `@cert-authority`) and
  /// hashed names are never read as a key for it.
  public static func keys(in text: String, host: String) -> [SSHHostKey] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard fields.count >= 3, !fields[0].hasPrefix("@"), !fields[0].hasPrefix("#"),
        fields[0].split(separator: ",").contains(where: { $0 == host })
      else { return nil }
      return SSHHostKey(type: String(fields[1]), base64: String(fields[2]))
    }
  }
  /// `text` with every line for `host` taken out, and `key`'s line added when there is one. Only
  /// the person's Accept on the fingerprint card writes a key; nothing replaces one silently.
  public static func replacing(_ text: String, host: String, with key: SSHHostKey?) -> String {
    var lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { line in
      let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
      return !first.split(separator: ",").contains(where: { $0 == host })
    }
    if let key { lines.append(key.line(host: host)) }
    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
  }

  public enum Check: Equatable, Sendable {
    /// No key is stored: the first connection, which shows the fingerprint card.
    case unknown
    case same
    /// The machine shows another key than the one the person trusted (`was` is its fingerprint).
    case changed(was: String)
  }
  public static func compare(stored: [SSHHostKey], offered: SSHHostKey) -> Check {
    guard let first = stored.first else { return .unknown }
    return stored.contains(offered) ? .same : .changed(was: first.fingerprint)
  }
}

/// Why an ssh run failed, from its exit code (255 is ssh's own failure; any other code is the
/// remote command's) and the lines it wrote to stderr.
public enum SSHFailure: Equatable, Sendable {
  case keyChanged
  case keyUnknown
  /// The machine answered but took no key from the person's ssh-agent or their own setup.
  case notAccepted
  case unreachable(String)

  /// `hasStoredKey`: a key is trusted for this machine, so "no key is known" means it now offers
  /// only another key type, which is a changed key.
  public static func classify(code: Int, stderr: String, hasStoredKey: Bool) -> SSHFailure? {
    guard code == 255 else { return nil }
    if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .keyChanged }
    if stderr.contains("host key is known for") { return hasStoredKey ? .keyChanged : .keyUnknown }
    // A key is stored (the caller checks first) and this one does not match it.
    if stderr.contains("Host key verification failed") { return .keyChanged }
    if stderr.contains("Permission denied") { return .notAccepted }
    let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    let shown = String(last.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(200).map(Character.init))
    return .unreachable(shown.trimmingCharacters(in: .whitespaces).isEmpty ? "ssh gave no reason" : shown)
  }
}

// MARK: the ssh command

/// The system's own `ssh`, run the same way every time.
public enum SSHInvocation {
  public static let ssh = "/usr/bin/ssh"

  /// The name a computer's host key is kept under in Serein's known_hosts file (ssh's
  /// HostKeyAlias), so the key belongs to this computer whatever the alias resolves to. nil for an
  /// id with other characters than letters, digits and dashes.
  public static func hostAlias(assistantID: String) -> String? {
    OwnComputerNames.safe(assistantID) ? "serein-" + assistantID.lowercased() : nil
  }

  /// One ssh run: never a prompt (BatchMode), the host key checked strictly against Serein's own
  /// file and nothing else (no global file, no DNS, no key updates), nothing forwarded (agent,
  /// X11, ports, tunnels), no shared connection socket and no terminal, so nothing listens on
  /// either side. `scan` is the first connection's fetch of the host key: ssh writes the key the
  /// machine shows into the scratch file `knownHosts` and stops before signing in (no key, agent or
  /// password is offered), so the person sees its fingerprint before anything is trusted. nil when
  /// the file's path cannot be given to ssh as one quoted value.
  public static func arguments(target: SSHTarget, hostAlias: String, knownHosts: String, scan: Bool, remote: String)
    -> [String]?
  {
    // ssh expands `%` tokens and `${…}` variables in the file's path, and reads quotes and backslashes.
    guard !knownHosts.isEmpty, !knownHosts.contains(where: { "\"\\%$\n\r\0".contains($0) }),
      hostAlias.hasPrefix("serein-"), OwnComputerNames.safe(String(hostAlias.dropFirst(7)))
    else { return nil }
    var options = [
      "BatchMode=yes", "StrictHostKeyChecking=" + (scan ? "accept-new" : "yes"),
      "UserKnownHostsFile=\"" + knownHosts + "\"", "GlobalKnownHostsFile=/dev/null", "HostKeyAlias=" + hostAlias,
      "UpdateHostKeys=no", "HashKnownHosts=no", "CheckHostIP=no", "VerifyHostKeyDNS=no",
      "ClearAllForwardings=yes", "ForwardAgent=no", "ForwardX11=no", "ControlMaster=no", "ControlPath=none",
      "PermitLocalCommand=no", "Tunnel=no", "RequestTTY=no", "ConnectTimeout=15", "ServerAliveInterval=15",
      "ServerAliveCountMax=3", "LogLevel=ERROR",
      // Nothing from the person's own config replaces the command, supplies a key the card never
      // showed, or changes how the session runs.
      "RemoteCommand=none", "KnownHostsCommand=none", "SessionType=default", "StdinNull=no",
      "ForkAfterAuthentication=no", "EscapeChar=none",
    ]
    if scan {
      options += [
        "PreferredAuthentications=none", "PubkeyAuthentication=no", "PasswordAuthentication=no",
        "KbdInteractiveAuthentication=no", "GSSAPIAuthentication=no", "HostbasedAuthentication=no",
        "IdentitiesOnly=yes", "IdentityAgent=none",
      ]
    }
    var out = ["-T", "-x", "-a"]
    for option in options { out += ["-o", option] }
    if let port = target.port { out += ["-p", String(port)] }
    return out + ["--", target.destination, remote]
  }

  /// One command line for the machine's shell: every word single-quoted, so nothing in a word is
  /// read by the shell. nil for a word with a backslash or NUL, which a shell other than sh (fish)
  /// reads differently inside quotes.
  public static func remote(_ words: [String]) -> String? {
    guard !words.isEmpty, !words.contains(where: { $0.contains("\\") || $0.contains("\0") }) else { return nil }
    let quoted: [String] = words.map { word in
      let escaped: String = word.replacingOccurrences(of: "'", with: "'\\''")
      return "'\(escaped)'"
    }
    return quoted.joined(separator: " ")
  }
}

/// Names Serein makes from an assistant's id (container, volume, host key alias): only ids of
/// letters, digits and dashes are used, so no name can carry anything else into a command.
public enum OwnComputerNames {
  public static func safe(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64 && !id.hasPrefix("-")
      && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
  }
}

// MARK: "A desktop for Serein"

/// Serein's hardened container (33a's, `DockerComputer.containerConfig`) started on the person's
/// Linux machine with that machine's own `docker` command over SSH. The Docker socket is never
/// forwarded: Serein only runs these commands there. No published ports, no host mounts, no
/// network of its own, every capability dropped.
public enum OwnDesktop {
  public static func names(_ assistantID: String) -> (container: String, volume: String)? {
    guard OwnComputerNames.safe(assistantID) else { return nil }
    return (ComputerPolicy.containerPrefix + assistantID, ComputerPolicy.volumePrefix + assistantID)
  }
  /// Exits 0 when the image is there and was built from this Serein's pinned files (its label,
  /// ComputerPins), 1 when it needs building, 125 when Docker does not answer, 127 when there is no
  /// `docker` command.
  public static let probeScript =
    "command -v docker >/dev/null 2>&1 || exit 127; if docker image inspect \(ComputerPolicy.imageTag) >/dev/null 2>&1; then "
    + "[ \"$(docker image inspect -f '{{index .Config.Labels \"\(ComputerPins.labelKey)\"}}' \(ComputerPolicy.imageTag))\" = "
    + "'\(ComputerPins.labelValue)' ] && exit 0; exit 1; fi; docker info >/dev/null 2>&1 || exit 125; exit 1"
  /// A container made from another image than the one there now (built again for new pins) goes,
  /// its home volume kept, so the next lines make it again from the new image. Always exits 0.
  public static func staleScript(container: String) -> String {
    "i=$(docker inspect -f '{{.Image}}' \(container) 2>/dev/null) || exit 0; "
      + "[ \"$i\" = \"$(docker image inspect -f '{{.Id}}' \(ComputerPolicy.imageTag) 2>/dev/null)\" ] || docker rm -f \(container) >/dev/null 2>&1; exit 0"
  }
  /// The build, with Serein's own recipe as a tar context on stdin (the same files as on this Mac).
  public static let buildCommand = ["docker", "build", "--force-rm", "-t", ComputerPolicy.imageTag, "-"]
  /// The container's state word (running, paused, exited, created…), or nothing when it is not there.
  public static func stateCommand(container: String) -> [String] {
    ["docker", "ps", "-a", "--filter", "name=^/?\(container)$", "--filter", "label=\(ComputerPolicy.label)", "--format", "{{.State}}"]
  }
  public static func volumeCommand(assistantID: String, volume: String) -> [String] {
    ["docker", "volume", "create", "--label", "\(ComputerPolicy.label)=\(assistantID)", volume]
  }
  /// The same hardening as on this Mac: no network, every capability dropped, no new privileges,
  /// a read-only root with small tmpfs mounts, its own home volume, the person's memory and CPU
  /// caps, a pids limit, never privileged, no ports and no host mounts.
  public static func createCommand(assistantID: String, memoryMB: Int, cpus: Int) -> [String]? {
    guard let names = names(assistantID), memoryMB > 0, cpus > 0 else { return nil }
    return [
      "docker", "create", "--name", names.container, "--hostname", "serein-computer", "--user", "1000:1000",
      "--label", "\(ComputerPolicy.label)=\(assistantID)", "--network", "none", "--cap-drop", "ALL",
      "--security-opt", "no-new-privileges:true", "--read-only", "--memory", "\(memoryMB)m", "--memory-swap", "\(memoryMB)m",
      "--cpus", "\(cpus)", "--pids-limit", "1024", "--shm-size", "268435456", "--init", "--restart", "no",
      "--tmpfs", "/tmp:rw,nosuid,size=512m", "--tmpfs", "/run:rw,nosuid,noexec,size=16m",
      "--tmpfs", "/var/tmp:rw,nosuid,noexec,size=64m",
      "--mount", "type=volume,source=\(names.volume),target=/home/serein", ComputerPolicy.imageTag,
    ]
  }
  /// The machine's processors and memory, for the caps the container is made with.
  public static let sizeScript = "getconf _NPROCESSORS_ONLN; grep MemTotal /proc/meminfo"
  /// `sizeScript`'s answer: the processor count and the memory in bytes, or nil.
  public static func size(_ text: String) -> (cores: Int, bytes: UInt64)? {
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    guard lines.count >= 2, let cores = Int(lines[0]), cores > 0 else { return nil }
    let words = lines[1].split(separator: " ")
    guard words.count >= 2, words[0] == "MemTotal:", let kilobytes = UInt64(words[1]), kilobytes > 0 else { return nil }
    return (cores, kilobytes * 1024)
  }
  /// The caps a container was made with (`docker inspect` of `capsFormat`): memory in MB and processors.
  public static let capsFormat = "{{.HostConfig.Memory}}/{{.HostConfig.NanoCpus}}"
  public static func caps(_ text: String) -> (memoryMB: Int, cpus: Int)? {
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
    guard parts.count == 2, let memory = Int64(parts[0]), let nano = Int64(parts[1]), memory > 0, nano > 0 else { return nil }
    return (Int(memory / 1_048_576), max(1, Int(nano / 1_000_000_000)))
  }
  public static func capsLine(memoryMB: Int, cpus: Int, target: String) -> String {
    let gigabytes = memoryMB % 1024 == 0 ? "\(memoryMB / 1024) GB" : String(format: "%.1f GB", Double(memoryMB) / 1024)
    return "Up to \(gigabytes) and \(cpus) CPU\(cpus == 1 ? "" : "s") on \(target)"
  }
  /// A command inside the container as its unprivileged user, its stdin kept open when asked.
  public static func execCommand(container: String, stdin: Bool, command: [String], asShell: Bool = false) -> [String] {
    var words: [String] = ["docker", "exec"]
    if stdin { words.append("-i") }
    words += ["-u", asShell ? "1001:1000" : "1000:1000", "-w", asShell ? "/home/serein/work" : "/home/serein", container]
    return words + command
  }
  /// Paused, or already paused.
  public static func pauseScript(container: String) -> String {
    "docker pause \(container) >/dev/null 2>&1 || [ \"$(docker inspect -f {{.State.Paused}} \(container))\" = true ]"
  }
  /// Remove: the container and its home volume, and Serein's image once no other Serein container
  /// is left on the machine. Exits 0 only when Docker answered and both are gone.
  public static func removeScript(container: String, volume: String) -> String {
    "docker info >/dev/null 2>&1 || exit 125; docker rm -f -v \(container) >/dev/null 2>&1; docker volume rm -f \(volume) >/dev/null 2>&1; "
      + "if docker container inspect \(container) >/dev/null 2>&1 || docker volume inspect \(volume) >/dev/null 2>&1; then exit 1; fi; "
      + "docker ps -aq --filter label=\(ComputerPolicy.label) | grep -q . || docker image rm \(ComputerPolicy.imageTag) >/dev/null 2>&1; exit 0"
  }
  /// What Remove deletes, for its confirmation.
  public static func removeList(container: String, volume: String, target: String) -> String {
    "the container \(container) and its home volume \(volume) on \(target) (every file, sign-in and app inside it), Serein's image \(ComputerPolicy.imageTag) there once no other assistant's computer uses it"
  }
}

// MARK: "Use this machine as it is"

/// The helper Serein installs in the person's home on their own machine: exactly these items, as
/// their user, with no root and nothing that starts by itself. The install card lists them, and
/// Remove deletes exactly them.
public enum OwnHelperManifest {
  public struct Item: Equatable, Sendable {
    /// From the home folder, as the card shows it (`~/…`).
    public let path: String
    public let folder: Bool
    public let what: String
  }
  /// The folder and the helper, relative to the home folder.
  public static let folder = ".serein-helper"
  public static let helper = folder + "/helper.py"
  public static let items: [Item] = [
    Item(path: "~/" + folder, folder: true, what: "a folder only you can open, for Serein's helper"),
    Item(path: "~/" + helper, folder: false, what: "Serein's helper, one Python file: it runs as you only while Serein is connected"),
  ]
  /// Writes the helper from stdin. Exits 3 without python3 there, 4 when a folder of that name
  /// holds anything else or is a link (nothing of the person's is overwritten).
  public static let installScript =
    "umask 077; command -v python3 >/dev/null 2>&1 || exit 3; D=\"$HOME/\(folder)\"; "
    + "if [ -L \"$D\" ] || [ -L \"$D/helper.py\" ] || { [ -e \"$D\" ] && [ ! -d \"$D\" ]; }; then exit 4; fi; "
    + "if [ -d \"$D\" ] && [ -n \"$(ls -A \"$D\" | grep -vxF helper.py)\" ]; then exit 4; fi; "
    + "mkdir -p \"$D\" && chmod 700 \"$D\" && cat > \"$D/helper.py\" && chmod 700 \"$D/helper.py\""
  /// Deletes exactly the items: exits 0 when both are gone, 5 when the folder stays because
  /// something else was put in it since.
  public static let removeScript =
    "D=\"$HOME/\(folder)\"; rm -f \"$D/helper.py\"; rmdir \"$D\" 2>/dev/null; if [ -e \"$D\" ]; then exit 5; fi; exit 0"
  /// The helper's link, over the SSH session's stdin and stdout only.
  public static let helperCommand = ["sh", "-c", "exec python3 -I \"$HOME/\(helper)\" --own"]

  public static func cardTitle(target: String) -> String { "Install Serein's helper on \(target)?" }
  /// Every item with its path, what the helper may do, and what Serein cannot limit there.
  public static func cardDetail(target: String) -> String {
    let list = items.map { "\($0.path): \($0.what)." }.joined(separator: " ")
    return "Serein puts exactly these in your home folder on \(target), as your user, with no administrator rights and nothing that starts by itself: \(list) It needs python3 there, and is written again each time Serein connects so it is always Serein's own. Remove deletes exactly these. "
      + "Assistants start at Watch only there (screenshots and reading the screen); you can let one act, and every act still asks you. On a Mac, macOS must allow Screen Recording and Accessibility for its SSH service before the helper can see the screen or click. "
      + OwnCard.network
  }
  public static func removeList(target: String) -> String {
    items.reversed().map(\.path).joined(separator: " and ") + " on \(target)"
  }
}

/// What an assistant may do on the person's own machine used as it is (Settings, per computer).
/// Watch only, the default, is screenshots and reading the screen; Can act adds input, commands,
/// files and opening sites, each judged as `mac_act` judges a step on this Mac.
public enum OwnMachineAccess: String, Codable, Sendable, CaseIterable {
  case watchOnly, canAct
  public var label: String { self == .watchOnly ? "Watch only" : "Can act" }
}

/// The access rules for the person's own machine. It may hold their accounts and files, and Serein
/// learns nothing there that the Mac's own gates use (the app, the field's role), so every act asks:
/// the gate judges it with Autopilot off. Nobody is there in an unattended run, so it only watches.
public enum OwnMachinePolicy {
  /// The tools that only look.
  public static let watchTools: Set<String> = ["computer_screenshot", "computer_tree"]
  /// Tools whose own person-only card asks (the Outbox, the clipboard): no step card before it.
  public static let ownCardTools: Set<String> = ["computer_send_file", "computer_send_text"]
  /// Tools whose answer carries what the machine shows or holds: each marks the chat as having
  /// read the person's data before it runs.
  public static let readsMachine: Set<String> = ["computer_screenshot", "computer_tree", "computer_read_file", "computer_run"]

  /// The most distinct apps a tree on the person's machine lists; a walk that reaches more stops
  /// and says so (`apps_cut`).
  public static let maxWalkedApps = 50
  /// Whether a helper's tree answer stopped at more apps than it lists, or lists more than the
  /// cap: then an unlisted app could hold secrets, and Serein does not look.
  public static func appsCut(_ answer: [String: Any]) -> Bool {
    answer["apps_cut"] as? Bool == true || (answer["apps"] as? [Any])?.count ?? 0 > maxWalkedApps
  }
  /// Why `tool` may not run on the machine now, or nil.
  public static func refusal(tool: String, access: OwnMachineAccess, unattended: Bool, assistant: String, machine: String)
    -> String?
  {
    if watchTools.contains(tool) { return nil }
    if access == .watchOnly {
      return "\(assistant) may only watch \(machine): screenshots and reading the screen. The user can let \(assistant) act there in Settings › Serein's computer; every act then asks them."
    }
    if unattended {
      return "Nobody is here to allow a step on \(machine), so a scheduled run, an alert or a webhook only watches it."
    }
    return nil
  }
}

/// One assistant's own-computer record (`computers/state.json`): only what is needed to reach the
/// machine and how far the assistant may go there. Keys and passphrases stay with ssh and the
/// macOS ssh-agent; the host key is in Serein's own known_hosts file. A key this record does not
/// name (an older `level`) is ignored.
public struct OwnSettings: Codable, Equatable, Sendable {
  public var target: SSHTarget
  public var access: OwnMachineAccess
  /// The install card the person accepted; other words ask again.
  public var acceptedInstall: String?

  public init(target: SSHTarget) {
    self.target = target
    access = .watchOnly
    acceptedInstall = nil
  }
  enum CodingKeys: String, CodingKey { case target, access, acceptedInstall }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    target = try c.decode(SSHTarget.self, forKey: .target)
    access = try c.decodeIfPresent(OwnMachineAccess.self, forKey: .access) ?? .watchOnly
    acceptedInstall = try c.decodeIfPresent(String.self, forKey: .acceptedInstall)
  }
}

/// This Mac's own sshd host keys (world-readable files): a machine that shows one of them is this
/// Mac, which Serein never takes as the person's own machine, so `computer_read_file` and
/// `computer_run` never reach the files every agent on this Mac is kept from.
public enum ThisMacHostKeys {
  public static let refusal =
    "That machine is this Mac. Serein already works on this Mac with its own Mac tools, where your private files stay protected. Connect another computer."
  /// The system sshd's folder and Homebrew's, on Apple silicon and Intel: a second sshd on this
  /// Mac answers with its own keys.
  public static let folders = ["/etc/ssh", "/opt/homebrew/etc/ssh", "/usr/local/etc/ssh"]
  public static func keys() -> [SSHHostKey] { folders.flatMap { keys(folder: $0) } }
  public static func keys(folder: String) -> [SSHHostKey] {
    ["ed25519", "ecdsa", "rsa"].compactMap { kind -> SSHHostKey? in
      guard let text = try? String(contentsOfFile: folder + "/ssh_host_\(kind)_key.pub", encoding: .utf8) else { return nil }
      let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
      return fields.count >= 2 ? SSHHostKey(type: String(fields[0]), base64: String(fields[1])) : nil
    }
  }
}

/// The words of the own-computer cards and refusals.
public enum OwnCard {
  public static let network =
    "Serein can't limit this machine's internet. Your site rules apply only to what the assistant opens through Serein's tools."
  public static let desktopNetwork =
    "Serein can't limit this machine's internet. The desktop Serein starts on it has no network of its own: its sites go through this Mac, so your site rules apply there."

  /// One line for each kind, on the connect sheet.
  public static func kindLine(_ place: ComputerPlace) -> String {
    switch place {
    case .ownDesktop:
      return "A desktop for Serein: on a Linux machine with Docker, Serein starts its own hardened desktop, apart from your files there. Steps inside need no card; anything leaving it asks."
    case .ownMachine:
      return "Use this machine as it is: on a Linux desktop or a Mac, Serein installs a small helper in your home folder. It is your machine, so assistants start at Watch only and every act asks."
    case .docker, .builtIn, .macOS, .e2b, .daytona, .unavailable:
      return place.label
    }
  }

  public static func hostKeyTitle(target: String) -> String { "Trust \(target)'s host key?" }
  /// The fingerprint to compare with the one the machine shows; with `was`, the key it replaces.
  public static func hostKeyDetail(target: String, key: SSHHostKey, was: String?) -> String {
    let compare = "Compare it with the machine's own (ssh-keygen -lf on its /etc/ssh/ssh_host_\(key.kind.lowercased())_key.pub, or what your VM or cloud provider shows) and trust it only if they match."
    if let was {
      return "\(target) shows a new \(key.kind) host key, \(key.fingerprint). The key you trusted was \(was). A machine that was reinstalled gets a new key; someone pretending to be it does too. \(compare) Serein then connects only while the machine shows this key."
    }
    return "Serein is connecting to \(target) for the first time. Its \(key.kind) host key fingerprint is \(key.fingerprint). \(compare) Serein then connects only while the machine shows this key, and asks you again if it ever changes."
  }
  public static func keyChanged(target: String) -> String {
    "\(target) did not show the host key you trusted, so Serein did not connect. That happens when the machine was reinstalled, and also when someone is pretending to be it. Serein never replaces the key on its own: the user checks the machine, then uses Check the New Key in Settings › Serein's computer."
  }
  public static func notAccepted(target: String) -> String {
    "\(target) did not accept a key from ssh. Serein uses only your own SSH setup and never asks for a password: add your key to the macOS ssh-agent (ssh-add --apple-use-keychain), or check the alias in ~/.ssh/config, then try again."
  }
  /// A machine that cannot be reached. Nothing falls back to this Mac: the step fails.
  public static func unreachable(target: String, reason: String) -> String {
    "\(target) could not be reached over SSH (\(reason)). Serein does not use this Mac instead, so this step failed; try again once the machine is on."
  }
  public static func noPython(target: String) -> String {
    "\(target) has no python3, which Serein's helper needs. Install Python 3 there, then connect again."
  }
  public static func folderTaken(target: String) -> String {
    "\(target) already has ~/\(OwnHelperManifest.folder) with other files in it (or it is a link), so Serein did not install anything there. Move it, then connect again."
  }
  public static func noDocker(target: String) -> String {
    "\(target) has no docker command, which A desktop for Serein needs. Install Docker there, or connect it as it is."
  }
  public static func dockerNotAnswering(target: String) -> String {
    "Docker on \(target) did not answer for your user there. Start it, and make sure your user may run docker without sudo."
  }
  /// The keys a key step may name: letters, digits, `_`, `+` and spaces between chords.
  public static let keyCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+ ")
  /// The most chords one key step presses.
  public static let maxChords = 8
  /// xdotool's own command names. `xdotool key` stops at the first word that names one, in any
  /// case, and runs the rest as a chained command (`exec` runs any program), so no key step may
  /// hold one. The helper refuses the same list and presses each chord in its own call.
  public static let xdotoolCommands: Set<String> = [
    "behave", "behave_screen_edge", "click", "exec", "get_desktop", "get_desktop_for_window", "get_desktop_viewport",
    "get_num_desktops", "getactivewindow", "getdisplaygeometry", "getmouselocation", "getwindowclassname",
    "getwindowfocus", "getwindowgeometry", "getwindowname", "getwindowpid", "help", "key", "keydown", "keyup",
    "mousedown", "mousemove", "mousemove_relative", "mouseup", "search", "selectwindow", "set_desktop",
    "set_desktop_for_window", "set_desktop_viewport", "set_num_desktops", "set_window", "sleep", "type", "version",
    "windowactivate", "windowclose", "windowfocus", "windowkill", "windowlower", "windowmap", "windowminimize",
    "windowmove", "windowquit", "windowraise", "windowreparent", "windowsize", "windowstate", "windowunmap",
  ]

  /// The one reading of a tool's arguments on the person's own machine: exact typed values, or nil
  /// for anything that does not fit. Its answer is both what the card shows and what the helper
  /// is sent, so the card can never name another act than the one performed. Numbers are
  /// numbers (never true or false, a string or below 0), names are one of their words, and text
  /// is a String a card can show; nothing that reaches a command line can begin with `-`.
  public static func arguments(tool: String, _ raw: [String: Any]) -> [String: Any]? {
    func number(_ key: String, _ range: ClosedRange<Double>) -> Int?? {
      guard let value = raw[key] else { return .some(nil) }
      guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
        range.contains(n.doubleValue)
      else { return nil }
      return .some(Int(n.doubleValue))
    }
    func flag(_ key: String) -> Bool?? {
      guard let value = raw[key] else { return .some(nil) }
      guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
      return .some(n.boolValue)
    }
    func word(_ key: String, _ allowed: [String]) -> String?? {
      guard let value = raw[key] else { return .some(nil) }
      guard let text = value as? String, allowed.contains(text) else { return nil }
      return .some(text)
    }
    func words(_ key: String, limit: Int) -> String? {
      guard let text = raw[key] as? String, !text.isEmpty, text.count <= limit, ComputerPolicy.clipboardShowable(text) else { return nil }
      return text
    }
    switch tool {
    case "computer_screenshot":
      return [:]
    case "computer_tree":
      var out: [String: Any] = [:]
      if let value = raw["window"] {
        guard let window = value as? String, window.count <= 200, window.isEmpty || ComputerPolicy.clipboardShowable(window) else { return nil }
        if !window.isEmpty { out["window"] = window }
      }
      guard let depth = number("depth", 1...12) else { return nil }
      if let depth { out["depth"] = depth }
      return out
    case "computer_click":
      guard let xValue = number("x", 0...1280), let x = xValue, let yValue = number("y", 0...1280), let y = yValue,
        let button = word("button", ["left", "right", "middle"]), let double = flag("double")
      else { return nil }
      return ["x": x, "y": y, "button": button ?? "left", "double": double ?? false]
    case "computer_scroll":
      guard let xValue = number("x", 0...1280), let x = xValue, let yValue = number("y", 0...1280), let y = yValue,
        let direction = word("direction", ["up", "down"]), let amount = number("amount", 0...1_000_000)
      else { return nil }
      return ["x": x, "y": y, "direction": direction ?? "down", "amount": max(1, min(30, amount ?? 3))]
    case "computer_type":
      // A tab moves the focus where the card's box shows only blank space: Tab is a key step.
      guard let text = words("text", limit: 8_000), !text.contains("\t") else { return nil }
      return ["text": text]
    case "computer_key":
      guard let key = words("key", limit: 40), key.allSatisfy(keyCharacters.contains), !key.hasPrefix("-") else { return nil }
      let chords = key.split(separator: " ")
      guard chords.count <= maxChords, !chords.contains(where: { xdotoolCommands.contains($0.lowercased()) }) else { return nil }
      return ["key": key]
    case "computer_open_url":
      guard let url = words("url", limit: 2_000), url.hasPrefix("https://") || url.hasPrefix("http://"),
        !url.contains(where: \.isWhitespace)
      else { return nil }
      return ["url": url]
    case "computer_run":
      return words("command", limit: 8_000).map { ["command": $0] }
    case "computer_read_file":
      guard let path = words("path", limit: 1_000), let start = number("start", 0...2_000_000_000) else { return nil }
      return ["path": path, "start": start ?? 0]
    case "computer_send_file":
      return words("path", limit: 1_000).map { ["path": $0] }
    case "computer_send_text":
      guard let text = raw["text"] as? String, !text.isEmpty, text.utf8.count <= 64_000 else { return nil }
      return ["text": text]
    default:
      return nil
    }
  }

  /// The card for one act on the person's machine as it is: exactly what it does there, read from
  /// the normalized arguments (`arguments(tool:_:)`). `more` is the text typed or the command run,
  /// shown whole in the card's open box. nil for a tool that has no step card.
  public static func step(tool: String, machine: String, arguments a: [String: Any]) -> (title: String, detail: String, more: String?)? {
    func number(_ key: String) -> Int { a[key] as? Int ?? 0 }
    func words(_ key: String) -> String? { a[key] as? String }
    switch tool {
    case "computer_click":
      let x = number("x"), y = number("y")
      let button = (a["button"] as? String).flatMap { ["right", "middle"].contains($0) ? " with the \($0) button" : nil } ?? ""
      let what = (a["double"] as? Bool == true ? "Double-click" : "Click") + button
      return ("\(what) at \(x), \(y) on \(machine)?",
              "That is \(x) pixels from the left and \(y) from the top of the latest screenshot of \(machine), shown here. Serein clicks only there. Check what is there before you allow it.", nil)
    case "computer_type":
      guard let text = words("text") else { return nil }
      return ("Type \(text.count) character\(text.count == 1 ? "" : "s") on \(machine)?",
              "Serein types the text below where the keyboard focus is on \(machine)." + (text.contains(where: \.isNewline) ? " Its line breaks may send or confirm something." : " Nothing else is pressed."), text)
    case "computer_key":
      guard let key = words("key") else { return nil }
      return ("Press \(key) on \(machine)?", "Serein presses only this, once, in the window in front on \(machine).", nil)
    case "computer_scroll":
      let direction = (a["direction"] as? String) == "up" ? "up" : "down"
      return ("Scroll \(direction) on \(machine)?", "At \(number("x")), \(number("y")) in the latest screenshot of \(machine), \(number("amount")) notches.", nil)
    case "computer_open_url":
      guard let url = words("url") else { return nil }
      return ("Open a site on \(machine)?", "Serein opens \(url) in \(machine)'s default browser, with whatever sign-ins it holds there.", nil)
    case "computer_run":
      guard let command = words("command") else { return nil }
      return ("Run a command on \(machine)?",
              "Serein runs the command below on \(machine) as your user there, for at most \(ComputerPolicy.commandTimeout) seconds, and the task reads its output. Check it before you allow it.", command)
    case "computer_read_file":
      guard let path = words("path") else { return nil }
      let start = number("start")
      return ("Read a file on \(machine)?", "The task reads the text of \(path) on \(machine)" + (start > 0 ? " from byte \(start)." : "."), nil)
    default:
      return nil
    }
  }
  public static let unshowable =
    "That step's arguments do not fit: numbers must be numbers of 0 or more within the screenshot, button left, right or middle, direction up or down, double true or false, a key step of at most \(OwnCard.maxChords) keys or chords and no xdotool command, and text without tabs (use computer_key Tab), control characters or invisible formatting. Serein did not ask the user and did nothing."
  public static let declinedStep = "The user declined that step. Nothing was done on their machine."
  public static let declinedKey = "The user did not trust the machine's host key, so Serein did not connect."
  public static let declinedInstall = "The user did not install Serein's helper, so Serein did not connect."
  public static let needsPerson =
    "Connecting to this machine the first time needs the user's answer on a card, and nobody is here to give it."
}
