import AppKit
import SereinCore
import UniformTypeIdentifiers

/// Export… in a chat's ⋯ menu: the chat as Markdown, only when the person asks, to the file they
/// pick in the save panel. The whole text is redacted before it is written, and pictures never
/// leave the library. The agent has no way to call this.
@MainActor enum ChatExport {
  static let pictureLine = "[picture not exported]"

  /// The chat as Markdown, redacted whole (title, every message, every link), so a secret that a
  /// message quoted or a page put in a link is gone before a byte reaches disk.
  static func markdown(title: String, messages raw: [AgentMessage], assistant: String, date: Date = Date()) -> String {
    let messages = ChatCondense.expanded(raw)
    var parts = ["# \(title)", "Exported from Serein on \(date.formatted(date: .long, time: .shortened))."]
    for (index, message) in messages.enumerated() {
      // As the chat shows them: a check-in with nothing to say is hidden, and a prompt Serein
      // wrote to itself is its short label, never words under “You”; no label when Serein spoke
      // first (a check-in, the brief), whose reply stands alone.
      if message.role == "assistant" && RelayAutomatic.hidesReply(message, after: messages[..<index]) { continue }
      if message.role == "you", let kind = RelayAutomatic.kind(of: message.text), let label = RelayAutomatic.label(message.text) {
        let next = index + 1 < messages.count ? messages[index + 1] : nil
        if let next, next.role == "assistant" && RelayAutomatic.isQuiet(reply: next.text) { continue }
        guard RelayAutomatic.showsLine(kind) else { continue }
        parts.append("*\(label)*")
        continue
      }
      let body = text(message.text)
      let pictures = Array(repeating: pictureLine, count: message.images?.count ?? 0)
      let chips = (message.attached ?? []).map { "Attached: \($0)" }
      guard !body.isEmpty || !pictures.isEmpty || !chips.isEmpty else { continue }
      parts.append(message.role == "you" ? "**You**" : "**\(assistant)**")
      if !body.isEmpty { parts.append(body) }
      parts.append(contentsOf: pictures)
      parts.append(contentsOf: chips)
    }
    return AgentPrivacy.redact(parts.joined(separator: "\n\n") + "\n")
  }

  /// A message's text with each picture line (a Markdown image of a local file, as the chat shows
  /// it) replaced by a note; code blocks keep their fences and are never read as pictures.
  private static func text(_ raw: String) -> String {
    messagePieces(raw).map { piece -> String in
      switch piece.content {
      case .prose(let prose): return prose
      case .code(let code, let language), .graphic(_, let code, let language):
        return messageFence(code, language: language) + "\n"
      case .image: return pictureLine + "\n"
      }
    }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The title as a file name (`SafeFileName.export`): redacted, one line, no path separators,
  /// not hidden, at most 80 characters.
  static func fileName(_ title: String) -> String { SafeFileName.export(title, fallback: "Chat", ext: "md") }

  /// The chat as Markdown through the save panel (`saveText`).
  static func save(title: String, messages: [AgentMessage], assistant: String) {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    saveText(named: fileName(name), panelTitle: "Export Chat",
      message: "Recognised keys, tokens and passwords are replaced, links lose their query, and pictures are left out.",
      types: markdownTypes) {
      markdown(title: name.isEmpty ? "Chat" : name, messages: messages, assistant: assistant)
    }
  }

  static let markdownTypes = [UTType(filenameExtension: "md", conformingTo: .plainText), UTType.plainText].compactMap { $0 }

  /// The one way Serein writes a text file the person asked for: shows the save panel and writes
  /// `text()` only to the file it returns, atomically. Cancel writes nothing; a failed write says
  /// why in an alert. Callers redact what they hand in. Checks and previews never open the panel,
  /// as `SereinTaskActions.confirmDelete` never opens its alert.
  /// Returns where the text was written, or nil when nothing was.
  @discardableResult
  static func saveText(named name: String, panelTitle: String, message: String, types: [UTType], _ text: () -> String) -> URL? {
    guard !RunMode.automated else { return nil }
    let panel = savePanel(named: name, title: panelTitle, message: message, types: types)
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    do {
      try text().write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      NSAlert(error: error).runModal()
      return nil
    }
  }

  /// The save panel every export opens (text here, task and page recordings): its title, an
  /// optional note, only the given types, a suggested name. Callers write only to its URL.
  static func savePanel(named name: String, title: String, message: String? = nil, types: [UTType]) -> NSSavePanel {
    let panel = NSSavePanel()
    panel.title = title
    if let message { panel.message = message }
    panel.allowedContentTypes = types
    panel.allowsOtherFileTypes = false
    panel.nameFieldStringValue = name
    return panel
  }

  /// "Serein task 2026-10-27 09.41.05.mp4": the name a saved video suggests.
  static func movieName(_ kind: String, at date: Date) -> String {
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return "Serein \(kind) " + format.string(from: date) + ".mp4"
  }

  /// Moves a finished file to the place the person chose, replacing a file already there.
  static func place(_ file: URL, at destination: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
    } else {
      try FileManager.default.moveItem(at: file, to: destination)
    }
  }
}
