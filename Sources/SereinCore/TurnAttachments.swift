import CryptoKit
import Foundation

/// Pictures and documents for one agent turn live in their own folder, readable only by the user
/// (0700). The agent is granted that folder alone, and it is deleted when the run ends, so a turn
/// never sees pictures or uploads files from earlier turns, other threads or other sites.
public enum TurnAttachments {
  /// The largest document a person can attach, and so the largest file an upload sends.
  public static let documentLimit = 10_000_000
  /// The largest attachment of this name: a CSV, TSV or .xlsx that table_query reads may be up to
  /// `TableFile.sizeLimit`; an upload still sends no file over `documentLimit` (`document(named:)`).
  public static func limit(forName name: String) -> Int {
    TableFile.isTable(name) ? max(documentLimit, TableFile.sizeLimit) : documentLimit
  }
  /// The turn folder's subfolder for documents, each under the name the agent sees.
  static let documentsFolder = "documents"

  /// The hex SHA-256 of a document's bytes, kept at staging and compared before an upload.
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Where composer pictures and documents wait before a turn is sent, and where turn folders are made.
  public static func root(base: URL = FileManager.default.temporaryDirectory) -> URL {
    base.appendingPathComponent("SereinAttachments", isDirectory: true)
  }

  /// A new private folder for one turn under `root`.
  public static func makeFolder(root: URL) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let folder = root.appendingPathComponent("turn-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return folder
  }

  /// Copies every picture and document of `turn` into a fresh turn folder and points the turn at
  /// the copies. Files that are missing, not regular files or too large are dropped from the turn.
  /// Returns nil, and creates nothing, when the turn has neither.
  public static func stage(_ turn: inout PageContext.Turn, root: URL) throws -> URL? {
    guard !turn.picturePaths.isEmpty || !turn.documents.isEmpty else { return nil }
    let folder = try makeFolder(root: root)
    var map: [String: String] = [:]
    var digests: [String: String] = [:]
    if !turn.documents.isEmpty {
      let documents = folder.appendingPathComponent(documentsFolder, isDirectory: true)
      do {
        try FileManager.default.createDirectory(
          at: documents, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      } catch {
        remove(folder, root: root)
        throw error
      }
      var taken = Set<String>()
      for document in turn.documents where map[document.path] == nil {
        let source = URL(fileURLWithPath: document.path)
        let cap = limit(forName: document.name)
        guard
          let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          (values.fileSize ?? .max) <= cap
        else { continue }
        let name = uniqueName(SafeFileName.clean(document.name, fallback: "document"), taken: &taken)
        let target = documents.appendingPathComponent(name)
        do {
          try FileManager.default.copyItem(at: source, to: target)
          try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
          // The copy itself, never through a link, and dropped when it grew past the limit.
          guard let data = SafeFileRead.regularFile(target.path, limit: cap + 1), data.count <= cap
          else { try? FileManager.default.removeItem(at: target); continue }
          digests[target.path] = digest(data)
          map[document.path] = target.path
        } catch { continue }
      }
    }
    for (index, path) in turn.picturePaths.enumerated() where map[path] == nil {
      let source = URL(fileURLWithPath: path)
      guard
        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
        values.isRegularFile == true, values.isSymbolicLink != true,
        (values.fileSize ?? .max) <= 8_000_000
      else { continue }
      // A JPEG keeps its ending: an AI app that goes by the name would read it as a PNG.
      let ending = ["jpg", "jpeg"].contains(source.pathExtension.lowercased()) ? "jpg" : "png"
      let target = folder.appendingPathComponent("picture-\(index + 1).\(ending)")
      do {
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        map[path] = target.path
      } catch { continue }
    }
    remap(&turn, map)
    for i in turn.documents.indices { turn.documents[i].digest = digests[turn.documents[i].path] }
    return folder
  }

  /// Rewrites picture and document paths through `map`; files without an entry are removed. A
  /// document takes its staged file's name, the one an upload asks for.
  public static func remap(_ turn: inout PageContext.Turn, _ map: [String: String]) {
    turn.pictures = turn.pictures.compactMap { picture in
      map[picture.path].map { PageContext.Picture(path: $0, name: picture.name) }
    }
    turn.documents = turn.documents.compactMap { document in
      map[document.path].map { path in
        var staged = document
        staged.path = path
        staged.name = URL(fileURLWithPath: path).lastPathComponent
        return staged
      }
    }
    for i in turn.elements.indices {
      if let path = turn.elements[i].picture { turn.elements[i].picture = map[path] }
    }
  }

  /// The document named `name` in a turn folder, the only file an upload may send: a plain name
  /// (no folder, no `..`, not hidden) of a regular file, not a link, directly in the folder's
  /// documents, within the size limit (`limit`: table_query reads a table up to its own). Nil for
  /// anything else, including an earlier turn's folder, which is gone once its run ended.
  public static func document(named name: String, in folder: URL, root: URL, limit: Int = documentLimit) -> URL? {
    let turn = folder.standardizedFileURL
    guard turn.deletingLastPathComponent().path == root.standardizedFileURL.path,
      turn.lastPathComponent.hasPrefix("turn-"),
      !name.isEmpty, name == SafeFileName.clean(name, fallback: "document"), !name.hasPrefix(".")
    else { return nil }
    let documents = turn.appendingPathComponent(documentsFolder, isDirectory: true)
    let file = documents.appendingPathComponent(name)
    guard file.standardizedFileURL.deletingLastPathComponent().path == documents.path,
      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
      values.isRegularFile == true, values.isSymbolicLink != true,
      (values.fileSize ?? .max) <= limit
    else { return nil }
    return file
  }

  /// `name`, or “name 2.ext”, “name 3.ext”… when a document of the turn already has it, within
  /// `SafeFileName.limit`, or no upload could name it.
  static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
    var candidate = name
    var count = 2
    while taken.contains(candidate.lowercased()) {
      candidate = SafeFileName.numbered(name, count)
      count += 1
    }
    taken.insert(candidate.lowercased())
    return candidate
  }

  /// Deletes a turn folder. Only folders directly under `root` named `turn-…` are removed.
  public static func remove(_ folder: URL, root: URL) {
    let standardized = folder.standardizedFileURL
    guard standardized.deletingLastPathComponent().path == root.standardizedFileURL.path,
      standardized.lastPathComponent.hasPrefix("turn-")
    else { return }
    try? FileManager.default.removeItem(at: standardized)
  }

  /// Deletes one waiting composer picture or document directly under `root`.
  public static func discard(_ path: String, root: URL) {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard url.deletingLastPathComponent().path == root.standardizedFileURL.path else { return }
    try? FileManager.default.removeItem(at: url)
  }

  /// Removes everything left from an earlier launch.
  public static func removeStale(root: URL) {
    try? FileManager.default.removeItem(at: root)
  }
}
