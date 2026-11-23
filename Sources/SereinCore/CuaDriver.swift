import Foundation

/// The pinned driver provides screen, input and accessibility services inside the Linux guest.
public enum CuaDriverRelease {
  /// The release, from GitHub's public release data (tag `cua-driver-rs-v0.53.2`, published
  /// 2026-11-18). Its `SHA256SUMS` lists each `archiveSHA256`; the other digests are of the files
  /// inside. Two builds: linux-arm64 (the built-in computer, and Serein's box on Apple silicon) and
  /// linux-x86_64 (the box on an Intel Mac's engine). Flat lines, so scripts/cua-driver.sh reads them.
  public static let version = "0.53.2"
  public static let tag = "cua-driver-rs-v0.53.2"
  public static let archive = "cua-driver-rs-0.53.2-linux-arm64.tar.gz"
  public static let archiveSHA256 = "2f74b07519f9a148ecaee62e80a4bd41dd328c8901728f87d87e5bce070f1c4e"
  /// Top-level folder in the driver archive.
  public static let archiveFolder = "cua-driver-rs-0.53.2-linux-arm64"
  public static let binarySHA256 = "b15c1c7300865b6b7033652872a3dfd3b54f14db12714ce7cd0fb0fb18a35df5"
  public static let amd64Archive = "cua-driver-rs-0.53.2-linux-x86_64.tar.gz"
  public static let amd64ArchiveSHA256 = "3ef3c0ba3134c3937e4161869d6cf9a72605b8f497e96845f4b761af1d418ac6"
  public static let amd64ArchiveFolder = "cua-driver-rs-0.53.2-linux-x86_64"
  public static let amd64BinarySHA256 = "fa7f43f1c39b0a51361485b53268f91ef0446a17ade0e957742879112129e9c3"
  /// Both archives carry the same LICENSE and notices.
  public static let licenseSHA256 = "c0779290c1d4783169aa3dbfb55feb505e563ef8a004bbf55298ceffcfbda8d9"
  public static let noticesSHA256 = "5860ee54b73d3d84f8af8a3c3fc996739755297d91e259314416378548ee8f6d"

  public static let crateNoticesSHA256 = "dc4806f636feec4af9b1f08a674299a36626dd06f1efb4cda7957b8bf99afba4"

  /// A Linux architecture the driver ships for, as Docker's `GET /version` names it.
  public enum Arch: String, CaseIterable, Sendable {
    case arm64, amd64
    /// Docker's "Arch" (arm64, aarch64, amd64, x86_64); nil for anything else.
    public init?(engine: String) {
      switch engine.lowercased() {
      case "arm64", "aarch64": self = .arm64
      case "amd64", "x86_64": self = .amd64
      default: return nil
      }
    }
    /// The app's `Computer` resource holding this build's binary (arm64 keeps the built-in
    /// computer's name).
    public var resource: String { self == .arm64 ? binaryResource : "cua-driver-amd64" }
    public var binarySHA256: String { self == .arm64 ? CuaDriverRelease.binarySHA256 : amd64BinarySHA256 }
  }

  /// The release's checksum list and its keyless Sigstore bundle, issued to Cua's release
  /// workflow at this tag (scripts/cua-driver.sh checks both before it keeps the binary).
  public static let sumsFile = "SHA256SUMS"
  public static var signatureFile: String { archive + ".sigstore.json" }
  public static var signerIdentity: String {
    "https://github.com/trycua/cua/.github/workflows/cd-rust-cua-driver.yml@refs/tags/" + tag
  }
  public static let signerIssuer = "https://token.actions.githubusercontent.com"
  public static func downloadURL(_ file: String) -> URL? {
    URL(string: "https://github.com/trycua/cua/releases/download/" + tag + "/" + file)
  }

  /// In the app's `Computer` resources (scripts/cua-driver.sh puts the binary there at build
  /// time; the two text files are in the repository): the binary has no extension.
  public static let binaryResource = "cua-driver"
  public static let licenseResource = "cua-driver-license"
  public static let noticesResource = "cua-driver-notices"
  public static let crateNoticesResource = "cua-driver-crates"
  /// Inside the built-in computer: the binary is root's, 0755, so `serein` runs it and cannot
  /// change it; its licence and notices go beside it.
  public static let guestPath = "/opt/serein/cua-driver"
  public static let guestDocs = "/usr/share/doc/cua-driver"
  /// What one raw link connection runs for Serein's MCP client (DriverWire): the driver's stdio
  /// server owning its runtime in that process, as `serein`.
  public static var mcpCommand: [String] { [guestPath, "mcp", "--direct"] }
  /// The same server in Serein's box and hosted computers: the display, its key where the start
  /// script keeps it (outside the home, so a Reset keeps it), the desktop's shell (a terminal it
  /// opens runs as `shell`, serein-helper.py --term-client), the session bus the start script
  /// recorded and `offSwitches`, then `mcpCommand`. It runs from / with root's empty folder as its
  /// home, so no file the desktop can write (~/.cua-driver/config.json) sets its options.
  public static var boxCommand: [String] {
    ["sh", "-c", "[ ! -r /tmp/serein/xauth ] || export XAUTHORITY=/tmp/serein/xauth; cd / && "
      + "exec env HOME=/usr/share/serein/sealed DISPLAY=:0 SHELL=/opt/serein/term DBUS_SESSION_BUS_ADDRESS=\"$(cat /tmp/serein/dbus-address 2>/dev/null)\" "
      + environmentWords + " " + mcpCommand.joined(separator: " ")]
  }

  /// The driver sends product telemetry to PostHog by default and checks GitHub for updates
  /// (its telemetry.rs and version_check.rs). Inside Serein's computer both stay off three ways:
  /// these variables in the link's and the desktop's environment, and the proxy's fixed refusal
  /// of `posthog.com` (ComputerNetworkPolicy.fixedRefusal) whatever the driver does.
  public static let offSwitches: [(name: String, value: String)] = [
    ("DO_NOT_TRACK", "1"), ("CUA_DRIVER_RS_TELEMETRY_ENABLED", "false"), ("CUA_DRIVER_RS_UPDATE_CHECK", "false"),
  ]
  /// `NAME=value` words, space-separated, for a systemd `Environment=` line and a shell `export`.
  public static var environmentWords: String { offSwitches.map { $0.name + "=" + $0.value }.joined(separator: " ") }

  /// Whether a digest is one SHA-256 in lower-case hex.
  public static func validDigest(_ hex: String) -> Bool {
    hex.count == 64 && hex.allSatisfy { "0123456789abcdef".contains($0) }
  }
  /// The pinned digest of one of the driver's shipped resources, or nil for another name.
  public static func pin(forResource name: String) -> String? {
    switch name {
    case binaryResource: return binarySHA256
    case Arch.amd64.resource: return amd64BinarySHA256
    case licenseResource: return licenseSHA256
    case noticesResource: return noticesSHA256
    case crateNoticesResource: return crateNoticesSHA256
    default: return nil
    }
  }
}
