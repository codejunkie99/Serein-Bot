import Foundation

/// Serein's built-in computer (ComputerPlace.builtIn): a Linux virtual machine Serein runs itself
/// with Apple's Virtualization framework (VirtualMachineComputer), the default when no Docker
/// engine is found. It has no network card: its only link is a virtio socket, which carries the
/// helper and Serein's proxy. Its system is Debian's own cloud image, downloaded once on this Mac
/// from Debian's host and checked against the checksum list published beside it; nothing
/// pre-built is redistributed. Everything here is pure, so SereinChecks can check it: the image's
/// source, the checksum list, the memory cap, the setup proxy rule, the default place and the
/// first-boot seed.
public enum VirtualMachinePolicy {
  /// Debian's official cloud images (Debian 13), over HTTPS from Debian's own host: one dated build,
  /// pinned by its SHA-512 (`imageSHA512`, as Debian's list in that folder gives it), so every
  /// computer starts from the same system the packages below are pinned against. The checksum list
  /// comes from the same folder and must name the same digest.
  public static let imageHost = "cloud.debian.org"
  /// Debian's fixed HTTPS image mirror. The checksum list stays on Debian's own host;
  /// redirects are refused and the image's pinned SHA-512 is unchanged.
  public static let imageDownloadHost = "chuangtzu.ftp.acc.umu.se"
  public static let imageFolder = "/images/cloud/trixie/20261001-2618/"
  public static let imageFile = "debian-13-generic-arm64-20261001-2618.tar.xz"
  public static let imageSHA512 =
    "cb80554bf05aa9eb42d0b99a9a395fefad04edc8435514c5387e32f4da83b7827c34809f6249b365dedacd3f0688580f2957fd13b388639c987058bbe127fa8d"
  /// Debian's snapshot archive at one fixed moment, the day after the image: the setup installs
  /// every package, and every package those pull in, as the archive was then. The image, the
  /// snapshot and the package versions move with each Serein release; newer security fixes arrive
  /// only then.
  public static let snapshot = "20261002T000000Z"
  /// Debian publishes SHA-512 sums for its cloud images, with no signature beside them (no
  /// SHA512SUMS.sign under /images/cloud/), so the list is trusted for its HTTPS origin; the image
  /// itself is also pinned by `imageSHA512`.
  public static let sumsFile = "SHA512SUMS"
  public static let digestLength = 128
  /// The raw disk inside the archive.
  public static let imageMember = "disk.raw"
  public static var imageURL: URL { URL(string: "https://" + imageDownloadHost + imageFolder + imageFile)! }
  public static var sumsURL: URL { URL(string: "https://" + imageHost + imageFolder + sumsFile)! }
  /// Bytes the image download may take (the archive is a few hundred MB); more is refused.
  public static let downloadLimit: Int64 = 2 << 30
  /// The line shown before anything is downloaded.
  public static let sizeLine = "About 700 MB download, up to 10 GB on disk"

  /// Under the Library's `computers/`: the shared download, and each computer's own files.
  public static let imageFolderName = "vm-image"
  public static let diskName = "disk.img"
  /// The computer's disk: a sparse file of this size that grows only as the computer writes.
  public static let diskBytes: Int64 = 10 << 30
  /// The virtio socket port the helper's link listens on inside (`serein-helper.py --vsock`).
  public static let linkPort: UInt32 = 6100
  /// First-boot setup (packages through the proxy) that runs longer than this is stopped.
  public static let setupLimit: TimeInterval = 45 * 60

  /// Settings › Serein's computer › Built-in computer › Memory.
  public static let memoryKey = "serein.computer.builtIn.memoryMB"
  public static let defaultMemoryMB = 2048
  /// 2, 3 or 4 GB, never more than half of this Mac's memory; a Mac with less than 4 GB gets half.
  public static func memoryChoices(totalBytes: UInt64) -> [Int] {
    let half = Int(min(totalBytes / 2 / 1_048_576, 1 << 30))
    let choices = [2048, 3072, 4096].filter { $0 <= half }
    return choices.isEmpty ? [half] : choices
  }
  /// The saved choice, within this Mac's choices (a value saved on another Mac is clamped down).
  public static func memoryMB(defaults: any SettingsStore = GateSettings.shared, totalBytes: UInt64) -> Int {
    let choices = memoryChoices(totalBytes: totalBytes)
    let saved = defaults.object(forKey: memoryKey) as? Int ?? defaultMemoryMB
    return choices.contains(saved) ? saved : choices.last(where: { $0 <= saved }) ?? choices[0]
  }

  /// While the computer is set up, its proxy reaches Debian's package archive only (its snapshot
  /// host, where the pinned packages come from, and its mirrors).
  public static let setupHosts: Set<String> = ["snapshot.debian.org", "deb.debian.org", "security.debian.org"]
  /// Why a setup connection is refused before any lookup, or nil (the person's site rules and the
  /// private-range refusals still apply after this).
  public static func setupRefusal(_ host: String, port: Int) -> String? {
    let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard setupHosts.contains(name), port == 443 || port == 80 else {
      return "While it is being set up, Serein's computer may reach only Debian's package archive."
    }
    return nil
  }

  public static let notSetUp =
    "Serein's built-in computer is not set up yet. The user sets it up once in Settings › Serein's computer (\(sizeLine))."
  public static let unsupported =
    "This Mac cannot run Serein's built-in computer: it needs a Mac with Apple silicon. The user can install Docker instead."
  public static let setupCancelled = "Setting up Serein's built-in computer was cancelled."
  /// A build signed without scripts/Serein.entitlements (`swift run`, or a hand-signed copy).
  public static let unsigned =
    "This build of Serein isn't signed for the built-in computer; use a packaged build or Docker."
  /// Whether a Virtualization error is the missing-entitlement one, which `unsigned` explains.
  public static func missingEntitlement(_ message: String) -> Bool {
    message.contains("com.apple.security.virtualization")
  }
}

/// What an assistant's first need of an unset built-in computer does. A tool call can't wait out a
/// 700 MB download (tool calls time out at 120 seconds), so it starts the download and answers at
/// once. It starts only with the person here, on a connection that isn't metered, with room on the
/// disk, and never again by itself after a failure.
public enum BuiltInSetup: Equatable, Sendable {
  case start
  /// Nothing starts: the words the assistant gets, which it passes on.
  case answer(String)

  /// `VirtualMachinePolicy.sizeLine`'s 10 GB on disk, with room for the download beside it.
  public static let freeBytesNeeded: Int64 = 12 << 30

  public static func downloading(share: Double?) -> String {
    let done = share.map { ", \(Int(($0 * 100).rounded()))% so far" } ?? ""
    return "Serein's computer is being set up for the first time (about 700 MB\(done)). This takes a few minutes and the chat shows "
      + "its progress. Say so in a line, carry on with anything that doesn't need the computer, and try it again later rather than in a loop."
  }

  public static func decide(
    setsItselfUp: Bool, working: Bool, share: Double?, unattended: Bool, failed: Bool, online: Bool, metered: Bool, freeBytes: Int64?,
    requested: Bool = false
  ) -> BuiltInSetup {
    if working { return .answer(downloading(share: share)) }
    // Wake is the person's request to set it up now, even after an earlier automatic attempt
    // was cancelled or failed. Unattended tool calls never pass this flag.
    guard requested || setsItselfUp else { return .answer(VirtualMachinePolicy.notSetUp) }
    let later = "The user can set it up in Settings › Serein's computer."
    if !requested && unattended { return .answer("Serein's computer isn't set up yet, and its first download only starts while the user is here. \(later)") }
    if !requested && failed { return .answer("Serein's computer could not be set up: the download failed. \(later)") }
    if !online { return .answer("Serein's computer isn't set up yet, and this Mac is offline.") }
    if !requested && metered { return .answer("Serein's computer isn't set up yet, and its 700 MB download doesn't start on a metered connection. \(later)") }
    if let freeBytes, freeBytes < freeBytesNeeded {
      return .answer("Serein's computer isn't set up yet: it needs \(freeBytesNeeded >> 30) GB free on this Mac. \(later)")
    }
    return .start
  }
}

extension ComputerPlace {
  /// Where an assistant's computer runs before the person picks: Docker when an engine is found,
  /// otherwise Serein's built-in computer, and the built-in one whenever that assistant already has
  /// one (an engine installed later never hides it).
  public static func defaultPlace(dockerFound: Bool, builtInExists: Bool) -> ComputerPlace {
    builtInExists || !dockerFound ? .builtIn : .docker
  }
}

/// A published checksum list (SHA256SUMS, SHA512SUMS): one `<hex digest>  <file name>` per line,
/// with `*` before the name in binary mode.
public enum ChecksumList {
  /// The digest the list gives `file`, in lower case; nil when it names the file nowhere, with a
  /// digest that is not `length` hex characters, or with two different digests.
  public static func digest(for file: String, in text: String, length: Int) -> String? {
    var found: String?
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard let gap = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
      let hex = line[..<gap].lowercased()
      var name = line[gap...].trimmingCharacters(in: .whitespaces)
      if name.hasPrefix("*") { name.removeFirst() }
      guard name == file else { continue }
      guard hex.count == length, hex.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
      if let found, found != hex { return nil }
      found = hex
    }
    return found
  }
  /// Whether a computed digest is the published one (both hex, either case).
  public static func matches(_ computed: String, published: String) -> Bool {
    !published.isEmpty && computed.lowercased() == published.lowercased()
  }
}

/// The cloud-init seed Serein writes for a built-in computer's first boot (NoCloud: a small disk
/// labelled `cidata` with `user-data` and `meta-data`). Every value in it is Serein's own: these
/// constants, an instance id Serein makes, and the helper script shipped in the app, carried as
/// base64. Nothing from a page, a task, a file or an assistant goes into it.
public enum VirtualMachineSeed {
  /// Where the setup script writes how it went (`running`, `done` or `failed: …`).
  public static let setupState = "/var/lib/serein/setup"
  /// Inside the computer: the helper and its scripts.
  public static let helperPath = "/opt/serein/helper.py"
  /// The pinned helper on the seed disk beside `user-data`: the computer's boot installs it
  /// (`bootScript`), so a computer set up once runs this Serein's helper after every fresh boot.
  public static let helperFile = "helper.py"
  /// Cua Driver on the seed disk, only when this copy of Serein ships it (CuaDriverRelease), with
  /// its licence and notices: each start's seed carries the pinned binary, and the boot installs
  /// it as root's, 0755, at `CuaDriverRelease.guestPath`. Without it on the seed, the boot removes
  /// any older copy, so the computer holds only what this Serein pins.
  public static let driverFile = "cua-driver"
  public static let driverLicenseFile = "cua-driver-license.txt"
  public static let driverNoticesFile = "cua-driver-notices.md"
  /// Cua Driver's binary, licence and notices, each already checked against its pin.
  public typealias DriverFiles = (binary: Data, license: Data, notices: Data, crateNotices: Data)
  /// The seed files a start writes beside `user-data` and `meta-data`, by name: the helper, and
  /// the driver with its licence and notices when supplied.
  public static func extraFiles(helper: Data, driver: DriverFiles?) -> [(String, Data)] {
    var files: [(String, Data)] = [(helperFile, helper)]
    if let driver {
      files += [(driverFile, driver.binary), (driverLicenseFile, driver.license), (driverNoticesFile, driver.notices),
                (CuaDriverRelease.crateNoticesResource + ".md", driver.crateNotices)]
    }
    return files
  }

  /// An instance id Serein made: `serein-` and a lower-case UUID's characters only.
  public static func validInstanceID(_ id: String) -> Bool {
    let rest = id.dropFirst("serein-".count)
    return id.hasPrefix("serein-") && !rest.isEmpty && id.count <= 64
      && rest.allSatisfy { "0123456789abcdefghijklmnopqrstuvwxyz-".contains($0) }
  }
  public static func metaData(instanceID: String) -> String? {
    guard validInstanceID(instanceID) else { return nil }
    return "instance-id: \(instanceID)\nlocal-hostname: serein-computer\n"
  }

  public struct File: Equatable, Sendable {
    public var path: String
    public var mode: String
    public var data: Data
  }
  /// The files the first boot writes: the helper (from the app) and Serein's own constants.
  public static func files(helper: Data) -> [File] {
    [
      File(path: helperPath, mode: "0755", data: helper),
      File(path: "/opt/serein/setup.sh", mode: "0755", data: Data(setupScript.utf8)),
      File(path: "/opt/serein/session.sh", mode: "0755", data: Data(sessionScript.utf8)),
      File(path: "/opt/serein/boot.sh", mode: "0755", data: Data(bootScript.utf8)),
      File(path: "/etc/systemd/system/serein-boot.service", mode: "0644", data: Data(bootUnit.utf8)),
      File(path: "/etc/systemd/system/serein-link.service", mode: "0644", data: Data(linkUnit.utf8)),
      File(path: "/etc/xdg/autostart/serein-session.desktop", mode: "0644", data: Data(sessionAutostart.utf8)),
      File(path: "/etc/lightdm/lightdm.conf.d/50-serein.conf", mode: "0644", data: Data(autologin.utf8)),
      File(path: "/etc/X11/Xsession.d/95serein", mode: "0644", data: Data(sessionEnvironment.utf8)),
      File(path: "/etc/apt/apt.conf.d/90serein-proxy", mode: "0644", data: Data(aptProxy.utf8)),
    ]
  }

  /// The `user-data`: an unprivileged user with no password and no sudo, the files above (each as
  /// one quoted base64 line, so no byte of them can become YAML), the setup script once, and a
  /// power-off only after setup succeeded.
  public static func userData(helper: Data) -> String {
    var lines = [
      "#cloud-config",
      "# Serein's built-in computer, first boot. Written by Serein from its own constants and the",
      "# helper script shipped in the app; nothing here comes from a page, a task or an assistant.",
      "hostname: serein-computer",
      "disable_root: true",
      "ssh_pwauth: false",
      "users:",
      "  - name: serein",
      "    uid: 1000",
      "    shell: /bin/bash",
      "    lock_passwd: true",
      "    groups: [audio, video]",
      "write_files:",
    ]
    for file in files(helper: helper) {
      lines += [
        "  - path: \(file.path)",
        "    owner: root:root",
        "    permissions: \"\(file.mode)\"",
        "    encoding: b64",
        "    content: \"\(file.data.base64EncodedString())\"",
      ]
    }
    lines += [
      "runcmd:",
      "  - [/bin/sh, /opt/serein/setup.sh]",
      "power_state:",
      "  mode: poweroff",
      "  timeout: 120",
      "  condition: [grep, -qx, done, \(setupState)]",
    ]
    return lines.joined(separator: "\n") + "\n"
  }

  /// What the desktop, the browser and the helper need, as in the Docker recipe, plus a display
  /// server and an automatic sign-in for the computer's own screen; each at its version in
  /// `VirtualMachinePolicy.snapshot` for arm64 (what they pull in is held by the snapshot itself).
  public static let packages = [
    "xserver-xorg-core=2:21.1.16-1.3+deb13u4", "xserver-xorg-input-libinput=1.5.0-1", "x11-xserver-utils=7.7+11",
    "lightdm=1.32.0-6+b2", "lightdm-gtk-greeter=2.0.9-1+b2", "xfce4-session=4.20.2-2", "xfwm4=4.20.0-1",
    "xfce4-panel=4.20.4-1", "xfdesktop4=4.20.1-1", "xfce4-terminal=1.1.4-1", "xfce4-settings=4.20.1-1",
    "dbus-x11=1.16.2-2", "at-spi2-core=2.56.2-1+deb13u2", "chromium=154.0.8037.57-1~deb13u1", "fonts-dejavu=2.37-8",
    "ca-certificates=20250419", "python3-pyatspi=2.46.1-1", "xdotool=1:3.20160805.1-5.1", "scrot=1.12.1-1",
    "wmctrl=1.07+git20240228.1105759-1", "procps=2:4.0.4-9",
  ]

  static let proxyEnvironment =
    "http_proxy=http://127.0.0.1:3128 https_proxy=http://127.0.0.1:3128 HTTP_PROXY=http://127.0.0.1:3128 HTTPS_PROXY=http://127.0.0.1:3128 no_proxy=127.0.0.1,localhost"

  static let setupScript = #"""
    #!/bin/sh
    # Serein's built-in computer, first boot only (cloud-init runcmd, as root). The computer has no
    # network card: apt reaches Debian's archive through Serein's proxy, which the helper carries over
    # the virtio socket and which allows only the archive during setup. Serein reads the result from
    # the state file; on success cloud-init powers the computer off (power_state).
    set -u
    state=/var/lib/serein/setup
    mkdir -p /var/lib/serein
    fail() { echo "failed: $1" > "$state"; exit 1; }
    echo running > "$state"
    systemctl daemon-reload || fail "systemd did not reload"
    systemctl enable --now serein-link.service || fail "Serein's link did not start"
    i=0
    until python3 -I -c 'import socket; socket.create_connection(("127.0.0.1", 3128), 2).close()' 2>/dev/null; do
      i=$((i + 1))
      [ "$i" -lt 600 ] || fail "Serein's proxy did not come up"
      sleep 1
    done
    export DEBIAN_FRONTEND=noninteractive
    # Debian's archive as it was at one moment (VirtualMachinePolicy.snapshot), signed by Debian's
    # own keys as ever: each package below at its pinned version, and what they pull in from then.
    key=/usr/share/keyrings/debian-archive-keyring.pgp
    [ -f "$key" ] || key=/usr/share/keyrings/debian-archive-keyring.gpg
    cat > /etc/apt/sources.list.d/debian.sources <<SOURCES || fail "Debian's snapshot could not be set"
    Types: deb
    URIs: https://snapshot.debian.org/archive/debian/\#(VirtualMachinePolicy.snapshot)/
    Suites: trixie trixie-updates
    Components: main
    Signed-By: $key

    Types: deb
    URIs: https://snapshot.debian.org/archive/debian-security/\#(VirtualMachinePolicy.snapshot)/
    Suites: trixie-security
    Components: main
    Signed-By: $key
    SOURCES
    rm -f /etc/apt/sources.list
    apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Retries=5 update || fail "Debian's package lists could not be fetched"
    apt-get -o Acquire::Retries=5 install -y --no-install-recommends \#(packages.joined(separator: " ")) || fail "the desktop and browser could not be installed"
    apt-get clean
    systemctl enable serein-boot.service || fail "Serein's boot step could not be turned on"
    systemctl disable ssh.service ssh.socket 2>/dev/null || true
    systemctl set-default graphical.target || fail "the desktop could not be set to start"
    echo done > "$state"

    """#

  /// Every boot, as root, before the link: the pinned helper from the seed disk Serein wrote for
  /// this start (`helperFile`), Cua Driver with its notices when the seed carries it (else no
  /// driver), and the person's shared folder, read-only, when this Mac shares one (its virtio-fs
  /// tag is there only then). Its own constants only. The driver stays root's: `serein` may run
  /// it but not change it, and gets no other right for it (no `/dev/uinput`, no new group).
  static let bootScript = #"""
    #!/bin/sh
    # Serein's built-in computer, every boot (as root, before Serein's link): the helper comes from
    # the seed disk Serein writes before each start, so it is the one that Serein pins; so does Cua
    # Driver (MIT, Cua AI, Inc.) when this Serein ships it; and the folder the person shares from
    # the Mac, if any, is mounted read-only at /mnt/shared.
    set -u
    seed=/run/serein-seed
    mkdir -p "$seed" /mnt/shared
    if mount -o ro LABEL=cidata "$seed" 2>/dev/null; then
      if [ -f "$seed/\#(helperFile)" ]; then install -m 0755 -o root -g root "$seed/\#(helperFile)" \#(helperPath); fi
      if [ -f "$seed/\#(driverFile)" ]; then
        install -m 0755 -o root -g root "$seed/\#(driverFile)" \#(CuaDriverRelease.guestPath)
        install -d -m 0755 -o root -g root \#(CuaDriverRelease.guestDocs)
        install -m 0644 -o root -g root "$seed/\#(driverLicenseFile)" \#(CuaDriverRelease.guestDocs)/LICENSE
        install -m 0644 -o root -g root "$seed/\#(driverNoticesFile)" \#(CuaDriverRelease.guestDocs)/THIRD_PARTY_NOTICES.md
        install -m 0644 -o root -g root "$seed/\#(CuaDriverRelease.crateNoticesResource).md" \#(CuaDriverRelease.guestDocs)/CRATE_NOTICES.md
      else
        rm -f \#(CuaDriverRelease.guestPath)
      fi
      umount "$seed"
    fi
    mount -t virtiofs -o ro,nosuid,nodev,noexec \#(ComputerSharedFolder.tag) \#(ComputerSharedFolder.mountPoint) 2>/dev/null || true

    """#

  static let bootUnit = """
    [Unit]
    Description=Serein's computer at boot: its pinned helper, and the shared folder read-only
    Before=serein-link.service
    After=local-fs.target

    [Service]
    Type=oneshot
    ExecStart=/bin/sh /opt/serein/boot.sh

    [Install]
    WantedBy=multi-user.target

    """

  /// The helper's link, as the unprivileged user, with no way to gain privileges: every command
  /// the assistant runs starts under it, Cua Driver too, with the driver's telemetry and update
  /// check off (CuaDriverRelease.offSwitches).
  static let linkUnit = """
    [Unit]
    Description=Serein's link to this computer (its virtio socket; there is no network card)
    After=systemd-user-sessions.service serein-boot.service

    [Service]
    User=serein
    WorkingDirectory=/home/serein
    Environment=DISPLAY=:0 \(proxyEnvironment) \(CuaDriverRelease.environmentWords)
    ExecStart=/usr/bin/python3 -I \(helperPath) --vsock
    Restart=always
    RestartSec=1
    NoNewPrivileges=yes

    [Install]
    WantedBy=multi-user.target

    """

  static let sessionScript = #"""
    #!/bin/sh
    # Serein's built-in computer: the desktop session is up. The helper reads the session bus from
    # here, and the screen keeps the size Serein's tools use and never blanks.
    mkdir -p /tmp/serein
    xrandr -s 1280x800 2>/dev/null || true
    xset s off -dpms 2>/dev/null || true
    echo "$DBUS_SESSION_BUS_ADDRESS" > /tmp/serein/dbus-address
    echo ready > /tmp/serein/ready

    """#

  static let sessionAutostart = """
    [Desktop Entry]
    Type=Application
    Name=Serein's computer
    Exec=/opt/serein/session.sh
    NoDisplay=true

    """

  static let autologin = """
    [Seat:*]
    autologin-user=serein
    autologin-user-timeout=0
    autologin-session=xfce
    user-session=xfce

    """

  static let sessionEnvironment = """
    # Serein's computer: the only way out is Serein's proxy, and the accessibility bus is on for the helper.
    export \(proxyEnvironment)
    export NO_AT_BRIDGE=0 GTK_MODULES=gail:atk-bridge
    # Cua Driver, if it is started from the desktop: no telemetry and no update check.
    export \(CuaDriverRelease.environmentWords)

    """

  static let aptProxy = """
    Acquire::http::Proxy "http://127.0.0.1:3128";
    Acquire::https::Proxy "http://127.0.0.1:3128";

    """
}
