import Foundation

/// How much an approval card's step could cost the person, as a word on the card (affectUI
/// Approval Card's risk badge). It only labels a card that already asks: it never decides whether
/// Serein asks, so it cannot weaken a gate. Words in the title or the button raise it, never lower
/// it, the way `ApprovalGate.labelRaises` raises an effect.
public enum ApprovalRisk: Int, Comparable, CaseIterable, Sendable {
  case low, medium, high

  public static func < (a: ApprovalRisk, b: ApprovalRisk) -> Bool { a.rawValue < b.rawValue }

  public var word: String {
    switch self {
    case .low: return "Low risk"
    case .medium: return "Medium risk"
    case .high: return "High risk"
    }
  }
  public var why: String {
    switch self {
    case .low: return "A routine step, such as a click or reading a page."
    case .medium: return "It changes something, such as a setting, a form or a file."
    case .high: return "It may send, pay, delete or share, and may not be undone."
    }
  }

  /// The level of one effect. An effect Serein cannot name counts as high.
  public static func of(_ effect: ApprovalGate.Effect) -> ApprovalRisk {
    switch effect {
    case .read, .scroll, .navigate, .click, .type: return .low
    case .change, .fill, .submit, .merge, .settings, .fileIn, .sharedFolder: return .medium
    case .send, .post, .pay, .delete, .access, .install, .book, .upload, .fileOut, .clipboardOut, .hostedStart,
      .hostKey, .ownInstall, .widening, .unknown:
      return .high
    }
  }

  /// A card's level: the higher of its effect and the effect its words name. With neither, a
  /// step asked only because of Every step is low, and anything else medium.
  public static func of(effect: ApprovalGate.Effect?, words: String, routine: Bool) -> ApprovalRisk {
    let levels = [effect, ApprovalGate.raisedEffect(in: words)].compactMap { $0 }.map { of($0) }
    return levels.max() ?? (routine ? .low : .medium)
  }
}

/// A card's detail as a preview (affectUI Approval Card's key-value rows): each "Label: value"
/// line (To, Subject, File) becomes its own row, and the other lines stay as the card's note.
public enum ApprovalPreview {
  public struct Row: Equatable, Sendable {
    public let label: String
    public let value: String
  }

  /// The rows a mail send card's draft shows as fields instead (`EmailDraft`). To, Cc and Bcc
  /// stay rows: the recipients cannot be edited, and their rows carry "(new recipient)".
  public static let mailLabels: Set<String> = ["Subject"]

  public static func split(_ detail: String) -> (rows: [Row], note: String) {
    var rows: [Row] = []
    var note: [String] = []
    for line in detail.components(separatedBy: "\n") {
      if let row = row(line) { rows.append(row) } else if !line.trimmingCharacters(in: .whitespaces).isEmpty { note.append(line) }
    }
    return (rows, note.joined(separator: "\n"))
  }

  /// One or two capitalised words before ": ", so prose with a colon stays prose.
  static func row(_ line: String) -> Row? {
    guard let colon = line.range(of: ": ") else { return nil }
    let label = String(line[..<colon.lowerBound])
    let value = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty, label.count <= 14,
      label.range(of: #"^[A-Z][A-Za-z]*( [A-Za-z]+)?$"#, options: .regularExpression) != nil
    else { return nil }
    return Row(label: label, value: value)
  }
}
