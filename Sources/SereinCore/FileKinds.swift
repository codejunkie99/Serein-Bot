import Foundation

/// Which files Serein reads as text, and whether a file's first bytes are the type its extension
/// names. Shared by task downloads (TaskDownloadPolicy) and attached documents (DocumentText).
public enum FileKinds {
  /// Extensions read as plain text, by downloads and attached documents alike.
  public static let plainText: Set<String> = ["txt", "text", "log", "csv", "tsv", "md", "markdown"]
  /// Structured text a task download may be read as, after its type check admitted it.
  /// Attached documents do not take these.
  public static let structuredText: Set<String> = ["json", "xml", "ics"]

  /// Whether `head` (a file's first bytes) starts as the binary type `ext` names: a disk image
  /// or program renamed .pdf fails. Nil for an extension with no signature here (plain text).
  public static func signatureMatches(ext: String, head: Data) -> Bool? {
    let bytes = [UInt8](head)
    func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
      bytes.count >= offset + prefix.count && Array(bytes[offset..<(offset + prefix.count)]) == prefix
    }
    let ascii = { (text: String) in [UInt8](text.utf8) }
    switch ext {
    case "pdf": return head.prefix(1024).range(of: Data(ascii("%PDF-"))) != nil
    case "png": return starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    case "jpg", "jpeg": return starts([0xFF, 0xD8, 0xFF])
    case "gif": return starts(ascii("GIF87a")) || starts(ascii("GIF89a"))
    case "webp": return starts(ascii("RIFF")) && starts(ascii("WEBP"), at: 8)
    case "heic": return starts(ascii("ftyp"), at: 4)
    case "tif", "tiff": return starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])
    case "docx", "xlsx", "pptx": return starts([0x50, 0x4B, 0x03, 0x04])
    default: return nil
    }
  }
}

/// A byte count as the person reads it ("1.2 MB"), in one style everywhere.
public enum Bytes {
  public static func file(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }
}
