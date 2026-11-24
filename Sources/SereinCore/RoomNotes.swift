import Foundation

/// One line a seat left for the team. Each seat appends to its own log, `seats/<seat>.jsonl`, so two
/// seats never write one file; `notes.md` is derived from all logs.
public struct RoomNote: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case fact, decision, file, ask, done }
  /// Room-wide, assigned by the host on append.
  public private(set) var seq: Int
  public private(set) var seat: Workroom.Seat.ID
  public private(set) var kind: Kind
  public private(set) var text: String
  public private(set) var at: Date

  public static let textLimit = 400

  /// Redacted and cut to `textLimit`. The tool refuses secret-shaped text before this; the
  /// redaction is the backstop for host-written notes.
  public init(seq: Int, seat: Workroom.Seat.ID, kind: Kind, text: String, at: Date) {
    self.seq = seq
    self.seat = seat
    self.kind = kind
    self.text = AgentPrivacy.redact(text, limit: Self.textLimit)
    self.at = at
  }
}

public enum RoomNotes {
  public static let renderCap = 24_000, deltaCap = 1_500

  /// `notes.md`: every note in `seq` order. Past `renderCap` the oldest notes fold into one count
  /// line, oldest first; decisions and asks never fold.
  public static func render(_ notes: [RoomNote], names: [Workroom.Seat.ID: String]) -> String {
    var kept = notes.sorted { $0.seq < $1.seq }
    var folded = 0
    func text() -> String {
      ((folded > 0 ? ["(\(folded) older notes folded)"] : []) + kept.map { line($0, names) }).joined(separator: "\n")
    }
    while text().count > renderCap, let i = kept.firstIndex(where: { $0.kind != .decision && $0.kind != .ask }) {
      kept.remove(at: i)
      folded += 1
    }
    return text()
  }

  /// What `seat` has not been shown, with its new cursor. Its own notes are left out. Decisions and
  /// asks first, then the rest, newest first in each; at most `deltaCap` characters. Empty when
  /// nothing is new.
  public static func delta(for seat: Workroom.Seat, in notes: [RoomNote], names: [Workroom.Seat.ID: String]) -> (text: String, cursor: Int) {
    let cursor = notes.map(\.seq).max().map { max($0, seat.notesCursor) } ?? seat.notesCursor
    let new = notes.filter { $0.seq > seat.notesCursor && $0.seat != seat.id }.sorted { $0.seq > $1.seq }
    guard !new.isEmpty else { return ("", cursor) }
    let ordered = new.filter { $0.kind == .decision || $0.kind == .ask } + new.filter { $0.kind != .decision && $0.kind != .ask }
    let head = "Team notes since you last looked:"
    let foot = "Read all notes with room_read part=notes."
    var lines: [String] = []
    for note in ordered {
      let next = line(note, names)
      guard ([head] + lines + [next, foot]).joined(separator: "\n").count <= deltaCap else { break }
      lines.append(next)
    }
    return (([head] + lines + [foot]).joined(separator: "\n"), cursor)
  }

  static func line(_ note: RoomNote, _ names: [Workroom.Seat.ID: String]) -> String {
    "- [\(note.kind.rawValue)] \(names[note.seat] ?? note.seat): \(note.text)"
  }
}
