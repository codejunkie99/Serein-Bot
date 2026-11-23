import Foundation

/// What a driver holds its CLI to once it starts.
enum ExpectedMode: Sendable, Equatable {
  /// The CLI reports these named values (Claude `permissionMode`; Codex `activePermissionProfile.id` and
  /// `approvalPolicy`; an ACP `currentModeId`). Each must come back equal.
  case reports([String: String])
  /// The CLI reports no mode at all. The no-ask flag must really be on the launched argv, in this
  /// order, so a driver cannot claim a flag it forgot to pass.
  case nothing(flagOnArgv: [String])
  /// Each named value may come back as any of the listed values, each one holding the same floor.
  case reportsAnyOf([String: Set<String>])
}

/// The only proof a session may take a prompt. `ModeCheck.verify` is its only maker, so a driver
/// that skips the read-back cannot compile a session.
struct VerifiedMode: Sendable { fileprivate init() {} }

enum ModeCheck {
  /// Native HTTP exposes only task-scoped host tools and cannot launch provider shells.
  static func hostedToolsOnly() -> VerifiedMode { VerifiedMode() }

  /// `reported` holds what the CLI said; a name it left out is a mismatch.
  static func verify(_ expected: ExpectedMode, reported: [String: String], argv: [String]) -> Result<VerifiedMode, StopReason> {
    switch expected {
    case .reports(let values):
      return verify(.reportsAnyOf(values.mapValues { [$0] }), reported: reported, argv: argv)
    case .reportsAnyOf(let values):
      for (name, accepted) in values.sorted(by: { $0.key < $1.key }) where !accepted.contains(reported[name] ?? "") {
        return .failure(.modeMismatch(name: name, expected: accepted.sorted().joined(separator: " or "), reported: reported[name]))
      }
    case .nothing(let flag):
      guard !flag.isEmpty, argv.indices.contains(where: { argv[$0...].starts(with: flag) }) else {
        return .failure(.modeMismatch(name: "argv", expected: flag.joined(separator: " "), reported: nil))
      }
    }
    return .success(VerifiedMode())
  }
}
