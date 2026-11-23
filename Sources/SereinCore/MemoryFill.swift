import Foundation

/// How full one assistant's notes are, and which of them leave for the archive, so memory never
/// fills. One assistant's "notes file" is the notes it owns that the person has seen (kept or
/// said), archived ones aside. Past `maxLines` lines or `maxBytes` bytes the oldest leave first;
/// a note past its end date leaves whatever the room. A note in the archive is still in the
/// store (`MemoryStore.archive` never deletes), only out of recall. Pure, so
/// `--verify-assistant-core` checks it.
public enum MemoryFill {
  /// The most lines of text one assistant's notes hold before the oldest are archived.
  public static let maxLines = 200
  /// The most bytes (each note's text and the person's quote, UTF-8).
  public static let maxBytes = 24_000
  /// The gauge warns from this share of either cap.
  public static let warnAt = 0.8

  /// Why a note left for the archive.
  public enum Reason: String, Equatable, Sendable {
    /// Its end date passed.
    case ended
    /// The notes were over a cap, and it was the oldest.
    case full
  }

  /// One note on its way to the archive.
  public struct Move: Equatable, Sendable {
    public var record: MemoryRecord
    public var reason: Reason
  }

  /// How much of the caps a set of notes uses.
  public struct Usage: Equatable, Sendable {
    public var lines: Int
    public var bytes: Int
    public init(lines: Int = 0, bytes: Int = 0) {
      self.lines = lines
      self.bytes = bytes
    }
    /// The fuller of the two caps, 0 to 1 and beyond.
    public var fraction: Double {
      max(Double(lines) / Double(MemoryFill.maxLines), Double(bytes) / Double(MemoryFill.maxBytes))
    }
    /// Whole percent of the fuller cap, at most 100 (whole-number math, so 80 never reads 79).
    public var percent: Int {
      min(100, max(lines * 100 / MemoryFill.maxLines, bytes * 100 / MemoryFill.maxBytes))
    }
    public var warns: Bool { fraction >= MemoryFill.warnAt }
    var isOver: Bool { lines > MemoryFill.maxLines || bytes > MemoryFill.maxBytes }
  }

  /// The lines one note takes: its lines of text, at least one.
  static func lines(_ record: MemoryRecord) -> Int {
    max(1, record.text.split(whereSeparator: \.isNewline).count)
  }
  /// The bytes one note takes: its text and the person's quote.
  static func bytes(_ record: MemoryRecord) -> Int {
    record.text.utf8.count + (record.quote?.utf8.count ?? 0)
  }

  public static func usage(_ records: [MemoryRecord]) -> Usage {
    var used = Usage()
    for record in records {
      used.lines += lines(record)
      used.bytes += bytes(record)
    }
    return used
  }

  /// Words that mark a health fact. Such a note never leaves for room: an allergy matters most
  /// on the day it is old.
  static let healthWords: [String] = [
    "allergy", "allergies", "allergic", "medication", "medications", "medicine", "prescription", "diagnosed",
    "diagnosis", "blood type", "insulin", "epipen", "inhaler", "asthma", "diabetes", "diabetic", "epilepsy",
    "pregnant", "pacemaker", "intolerant", "intolerance",
  ]
  /// Whether a note's words state a health fact.
  public static func isHealth(_ text: String) -> Bool {
    TypedConsent.contains(TypedConsent.normalized(text), any: healthWords)
  }

  /// The notes of `live` that leave now: each one past its end date, then, while the rest is over
  /// a cap, the oldest by its last change. A health fact leaves only when its own end date
  /// passed. Running it again on what stays gives nothing, so a pass is safe to repeat.
  public static func moving(_ live: [MemoryRecord], now: Date = Date()) -> [Move] {
    var moves: [Move] = []
    var staying: [MemoryRecord] = []
    for record in live {
      if let expires = record.expires, expires <= now {
        moves.append(Move(record: record, reason: .ended))
      } else {
        staying.append(record)
      }
    }
    var used = usage(staying)
    guard used.isOver else { return moves }
    let oldestFirst = staying.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt < $1.updatedAt : $0.id < $1.id }
    for record in oldestFirst where used.isOver {
      if isHealth(record.text) { continue }
      moves.append(Move(record: record, reason: .full))
      used.lines -= lines(record)
      used.bytes -= bytes(record)
    }
    return moves
  }
}
