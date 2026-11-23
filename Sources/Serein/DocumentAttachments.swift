import AppKit
import ImageIO
import PDFKit
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

/// Documents attached to a message: PDF, plain text, Markdown, CSV, Excel (.xlsx), RTF and Word.
/// Their text is read on this Mac by PDFKit, Foundation's and AppKit's own readers and TableFile
/// (an .xlsx's cell values), and goes with the message
/// inside an untrusted block (PageContext.render). The file waits in the private attachment
/// folder until the turn copies it into its own folder, the only place an upload takes a file
/// from (BrowserModel.upload). A picture dropped on Serein's composer goes with the message as a
/// picture instead (`readPicture`): drawn again as a JPEG, and never uploaded.
enum DocumentText {
  enum Kind { case pdf, plain, rtf, word, legacyWord, openDocument, spreadsheet }
  /// Text kept per document; the model reads the first `PageContext.documentTextLimit` of it.
  static let keptText = 200_000
  /// Rows of each sheet an .xlsx's text shows; table_query reads the whole workbook.
  static let previewRows = 2_000

  static func kind(_ url: URL) -> Kind? {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "pdf": return .pdf
    case "rtf": return .rtf
    case "docx": return .word
    case "doc": return .legacyWord
    case "odt": return .openDocument
    case "xlsx": return .spreadsheet
    default:
      if FileKinds.plainText.contains(ext) { return .plain }
      // Other plain text (a source file, a log). Never HTML: a web page is opened, not attached.
      return UTType(filenameExtension: ext)?.conforms(to: .plainText) == true ? .plain : nil
    }
  }

  /// What the open panels offer besides pictures.
  static var types: [UTType] {
    [.pdf, .plainText, .commaSeparatedText, .tabSeparatedText, .rtf]
      + ["md", "markdown", "docx", "doc", "odt", "xlsx"].compactMap { UTType(filenameExtension: $0) }
  }

  /// The text and page count of a document. Throws when the file cannot be read as its kind.
  /// `limit` caps the bytes of plain text read (the file is never followed through a link), and
  /// `keep` the characters kept; task downloads (TaskShelf) page through more than a message.
  static func read(_ url: URL, kind: Kind, limit: Int = TurnAttachments.documentLimit, keep: Int = DocumentText.keptText) throws
    -> (text: String, pages: Int?)
  {
    switch kind {
    case .pdf:
      guard let document = PDFDocument(url: url) else {
        throw SereinError.invalid("\(url.lastPathComponent) is not a PDF Serein can read.")
      }
      // A locked PDF has pages but no text until it is opened with its password.
      return (document.isLocked ? "" : String((document.string ?? "").prefix(keep)), document.pageCount)
    case .plain:
      // The caller names the file in its own words (readDocument), so this error carries none.
      guard let data = SafeFileRead.regularFile(url.path, limit: limit) else { throw CocoaError(.fileReadUnknown) }
      let utf16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
      let text = String(data: data, encoding: utf16 ? .utf16 : .utf8) ?? String(decoding: data, as: UTF8.self)
      return (String(text.prefix(keep)), nil)
    case .spreadsheet:
      // Shared strings and cell values only, as tab-separated text; nothing is evaluated or opened.
      guard let data = SafeFileRead.regularFile(url.path, limit: TableFile.sizeLimit + 1),
        let table = try? TableFile.read(data, name: "workbook.xlsx", firstRows: previewRows)
      else { throw CocoaError(.fileReadUnknown) }
      return (table.previewText(limit: keep), nil)
    case .rtf, .word, .legacyWord, .openDocument:
      let type: NSAttributedString.DocumentType
      switch kind {
      case .rtf: type = .rtf
      case .word: type = .officeOpenXML
      case .legacyWord: type = .docFormat
      default: type = .openDocument
      }
      // The type is named, so a file that is really HTML is never read as a web page.
      let text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
      return (String(text.prefix(keep)), nil)
    }
  }

  /// Everything the chip knows: “2 pages · 120 KB · text only”, or that no text was found.
  static func detail(_ document: PageContext.Document) -> String {
    var parts = [Bytes.file(Int64(document.size))]
    if let pages = document.pages { parts.insert(pages == 1 ? "1 page" : "\(pages) pages", at: 0) }
    return (parts + [hasText(document) ? "text only" : "No text found. Serein can still upload it"])
      .joined(separator: " · ")
  }
  /// The chip's short words after the name.
  static func suffix(_ document: PageContext.Document) -> String {
    hasText(document) ? "text only" : "no text found"
  }
  static func hasText(_ document: PageContext.Document) -> Bool {
    !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

extension ComposerContext {
  /// Copies a document the person dropped, pasted or chose into the private attachment folder and
  /// reads its text from that copy: the text the model reads and the file an upload would send are
  /// the same bytes. Over `TurnAttachments.limit(forName:)` is refused here, at the drop.
  static func readDocument(_ url: URL) async throws -> PageContext.Document {
    // The person chose this file: a link to it attaches the file it points at.
    let source = url.resolvingSymlinksInPath()
    let name = source.lastPathComponent
    // A CSV, TSV or .xlsx may be larger: table_query reads it (TurnAttachments.limit).
    let limit = TurnAttachments.limit(forName: name)
    let tooLarge = "\(name) is over \(Bytes.file(Int64(limit))), so it was not attached."
    guard let kind = DocumentText.kind(source) else {
      throw SereinError.invalid("\(name) cannot be attached. Serein reads PDF, text, Markdown, CSV, Excel, RTF and Word files.")
    }
    let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true, let size = values?.fileSize else {
      throw SereinError.invalid("\(name) could not be attached.")
    }
    guard size <= limit else { throw SereinError.invalid(tooLarge) }
    let ext = String(source.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
    let waiting = try attachmentURL(name: "document", extension: ext.isEmpty ? "bin" : ext)
    return try await Task.detached(priority: .userInitiated) {
      do {
        try FileManager.default.copyItem(at: source, to: waiting)
        // A source swapped for a link after it was resolved is copied as a link; never read
        // through one into the prompt.
        let copy = try waiting.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard copy.isRegularFile == true, copy.isSymbolicLink != true else {
          throw SereinError.invalid("\(name) could not be attached.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: waiting.path)
        // The copy is measured again: the original may have grown since.
        let copied = copy.fileSize ?? .max
        guard copied <= limit else { throw SereinError.invalid(tooLarge) }
        // A PDF or Word file whose first bytes are another type (a renamed file) is refused, as a
        // task download is (FileKinds); an upload would otherwise send it under the wrong type.
        let head = SafeFileRead.regularFile(waiting.path, limit: 1024) ?? Data()
        // A password-protected workbook is an encrypted compound file, not a zip.
        let compound: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        if kind == .spreadsheet && head.starts(with: compound) {
          throw SereinError.invalid("\(name) is password-protected, so Serein cannot read it.")
        }
        if FileKinds.signatureMatches(ext: source.pathExtension.lowercased(), head: head) == false {
          throw SereinError.invalid("\(name) is not the kind of file its name says, so it was not attached.")
        }
        let (text, pages) = try DocumentText.read(waiting, kind: kind)
        return PageContext.Document(path: waiting.path, name: name, size: copied, pages: pages, text: text)
      } catch {
        try? FileManager.default.removeItem(at: waiting)
        if error is SereinError { throw error }
        throw SereinError.invalid("Serein could not read \(name).")
      }
    }.value
  }

  /// The largest picture file Serein reads, and the longest side it keeps.
  static let pictureFileLimit = 30_000_000
  static let pictureSide: CGFloat = 1_600

  /// Whether the file is a picture macOS can read, by its type.
  static func isPicture(_ url: URL) -> Bool {
    let source = url.resolvingSymlinksInPath()
    guard let type = (try? source.resourceValues(forKeys: [.contentTypeKey]))?.contentType
      ?? UTType(filenameExtension: source.pathExtension.lowercased())
    else { return false }
    return type.conforms(to: .image)
  }

  /// A picture the person dropped, or one their pointer was on (`ScreenContextCapture`), drawn
  /// again as a JPEG no longer than `pictureSide` in the private attachment folder (0600). Drawing
  /// it again leaves the original's own details (where and when it was taken) behind, and makes
  /// the copy a picture whatever the file's name said.
  static func readPicture(_ url: URL) throws -> PageContext.Picture {
    let source = url.resolvingSymlinksInPath()
    let name = source.lastPathComponent
    let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true, let size = values?.fileSize else {
      throw SereinError.invalid("\(name) could not be attached.")
    }
    guard size <= pictureFileLimit else {
      throw SereinError.invalid("\(name) is over \(Bytes.file(Int64(pictureFileLimit))), so it was not attached.")
    }
    guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil) else {
      throw SereinError.invalid("Serein could not read \(name) as a picture.")
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: pictureSide,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(reader, 0, options as CFDictionary),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    else { throw SereinError.invalid("Serein could not read \(name) as a picture.") }
    let waiting = try attachmentURL(name: "picture", extension: "jpg")
    do {
      try data.write(to: waiting, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: waiting.path)
    } catch {
      try? FileManager.default.removeItem(at: waiting)
      throw SereinError.invalid("Serein could not read \(name) as a picture.")
    }
    return PageContext.Picture(path: waiting.path, name: name)
  }

  /// A document for the next message from a thread or task panel composer.
  func attachDocument(_ url: URL) {
    let full = "Up to \(PageContext.maxDocuments) documents per message."
    guard documents.count < PageContext.maxDocuments else {
      notice = full
      return
    }
    Task {
      do {
        let document = try await Self.readDocument(url)
        guard documents.count < PageContext.maxDocuments else {
          Self.discard([document.path], keeping: [])
          notice = full
          return
        }
        documents.append(document)
      } catch { notice = error.localizedDescription }
    }
  }
}

extension SereinSurface {
  /// The most pictures one of Serein's messages carries.
  static let maxPictures = 3

  /// A picture for Serein's next message: a chip whose copy goes with the message as a picture.
  /// `name`: what the chip says when the file's own name means nothing (a pasted picture).
  func attachPicture(_ url: URL, name: String? = nil) {
    guard attachments.filter({ $0.picture != nil }).count < Self.maxPictures else {
      ToastCenter.shared.show("Up to \(Self.maxPictures) pictures per message.")
      return
    }
    do {
      var picture = try ComposerContext.readPicture(url)
      if let name { picture.name = name }
      attach(Self.pictureChip(picture))
    } catch { ToastCenter.shared.show(error.localizedDescription) }
  }
  static func pictureChip(_ picture: PageContext.Picture) -> SereinAttachment {
    SereinAttachment(
      title: picture.name, icon: "photo", body: "", suffix: "picture",
      note: "Serein sees this picture with your message", picture: picture)
  }

  /// A document for Serein's next message: a chip whose file goes with the message as its chips
  /// (AgentModel.dispatch), so its text is fenced and only that turn may upload it. A picture
  /// goes as a picture chip instead (`attachPicture`).
  func attachDocument(_ url: URL) {
    if ComposerContext.isPicture(url) {
      attachPicture(url)
      return
    }
    Task {
      do {
        let document = try await ComposerContext.readDocument(url)
        guard attachments.filter({ $0.document != nil }).count < PageContext.maxDocuments else {
          ComposerContext.discard([document.path], keeping: [])
          ToastCenter.shared.show("Up to \(PageContext.maxDocuments) documents per message.")
          return
        }
        // A table over the upload limit is read with the message but never uploaded.
        let uploads: String = document.size > TurnAttachments.documentLimit
          ? "; it is too large to upload" : " and uploads it only if you allow it"
        attach(SereinAttachment(
          title: document.name, icon: "doc.text", body: "", suffix: DocumentText.suffix(document),
          note: DocumentText.detail(document) + ". Serein gets its text with your message" + uploads,
          document: document))
      } catch { ToastCenter.shared.show(error.localizedDescription) }
    }
  }
  /// Files dropped on Serein's composer. Returns whether any was a file.
  func acceptDocuments(_ providers: [NSItemProvider]) -> Bool {
    let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    for provider in files {
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in SereinSurface.main.attachDocument(url) }
      }
    }
    return !files.isEmpty
  }
  /// Pictures dropped on Serein's composer as images (from a browser or Photos), besides files.
  func acceptDropped(_ providers: [NSItemProvider]) -> Bool {
    if acceptDocuments(providers) { return true }
    let images = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
    for provider in images {
      provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
        guard let data else { return }
        Task { @MainActor in SereinSurface.main.attachPictureData(data, name: "Dropped picture") }
      }
    }
    return !images.isEmpty
  }

  /// ⌘V in Serein's composer: a copied picture (a screenshot, an image from a page) or copied
  /// picture files become picture chips. Returns false, leaving the paste to the text field, when
  /// the clipboard holds words or no picture.
  func pastePictures(from board: NSPasteboard = .general) -> Bool {
    let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
      .filter { ComposerContext.isPicture($0) }
    if !files.isEmpty {
      files.forEach { attachPicture($0) }
      return true
    }
    // Words win: text copied with a picture (a web selection) pastes as text.
    if let words = board.string(forType: .string), !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return false
    }
    guard let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
    attachPictureData(png, name: "Pasted picture")
    return true
  }

  /// Picture bytes (a paste or a drop) staged as a file, then attached as any picture is.
  func attachPictureData(_ data: Data, name: String) {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("serein-picture-" + UUID().uuidString + ".png")
    do {
      try data.write(to: file, options: .atomic)
      attachPicture(file, name: name)
      try? FileManager.default.removeItem(at: file)
    } catch { ToastCenter.shared.show("Serein could not add that picture.") }
  }

  /// The paperclip in Serein's composer.
  func chooseDocuments() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = DocumentText.types + [.image]
    panel.prompt = "Attach"
    panel.message = "Choose documents or pictures to send with your message. Serein reads their text on this Mac."
    // From the non-activating ⌥Space panel the open panel would come up behind the front app.
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { attachDocument(url) }
  }
}
