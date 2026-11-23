import Foundation

/// The unreadable guard for Relay state files (SPEC I13, as To do keeps an unreadable
/// todo.json): a file that is on disk but does not decode is kept as it is, nothing writes over
/// it, and the shell says so once. The shell reads its Relay state files through
/// `Library.loadGuarded` and refuses every later save to such a path, so the person's data waits
/// on disk for a later build or for support.
public enum RelayStateFile {
  /// What one read found.
  public enum Read<Value> {
    /// No file is there.
    case missing
    case loaded(Value)
    /// The file is there and does not decode. It stays as it is; the caller must not write it.
    case unreadable

    /// The value, when the file decoded.
    public var value: Value? {
      if case .loaded(let value) = self { return value }
      return nil
    }
  }

  /// The words the person reads, once, for one unreadable file. They name the kind of data,
  /// never a file format.
  public static func words(for path: String) -> String {
    "I could not read \(description(of: path)). I changed nothing, and I will not write over that file."
  }

  /// The kind of data in a Relay state file, in plain words.
  static func description(of path: String) -> String {
    let name = path.split(separator: "/").last.map(String.init) ?? path
    switch name {
    case "reminders.json": return "your reminders and routines"
    case "watches.json": return "your alerts"
    case "schedule-changes.json": return "the list of changes to your reminders"
    case "missed.json": return "the list of missed runs"
    case "handoffs.json": return "the list of hand-offs between your assistants"
    case "held.json": return "your waiting messages"
    case "team.json": return "the list of your assistants"
    case "team-journal.json": return "the list of changes to your assistants"
    case "state.json": return "the chats of one of your assistants"
    case "notes.json": return "the old notes of one of your assistants"
    case "proposals.json": return "the suggested notes of one of your assistants"
    case "journal.json": return "the list of note changes of one of your assistants"
    case "persona.json": return "the personality of one of your assistants"
    case "sidebar.json": return "your pinned and hidden assistants"
    case "links.json": return "the links other apps call to wake your assistants"
    case "links-removed.json": return "the links you removed a moment ago"
    case "make-proposals.json": return "the new assistants your assistants suggested"
    case "assistant-holds.json": return "the work I paused for your paused assistants"
    case "asks.json": return "the questions between your assistants"
    case "routine-offers.json": return "the routines I offered you"
    case "secrets.json": return "the list of your saved keys and cards"
    default: return "one of my saved files"
    }
  }
}

extension Library {
  /// Reads `path` as `load` does, but tells a missing file from one that is there and does not
  /// decode. Such a file is left exactly as it is.
  public func loadGuarded<T: Decodable>(_ type: T.Type, from path: String) -> RelayStateFile.Read<T> {
    let url = root.appendingPathComponent(path)
    // As `load`: a `saveSoon` still waiting is the file's newest content.
    SaveCoalescer.shared.flush(url.path)
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    guard let data = try? Data(contentsOf: url) else { return .unreadable }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let value = try? decoder.decode(type, from: data) else { return .unreadable }
    return .loaded(value)
  }
}
