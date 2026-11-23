import Foundation

/// The few HTML entities Serein's plain-text readers decode (page text, watched pages, imported
/// titles). `&amp;` goes last, so each entity is decoded once: "&amp;lt;" reads as the text
/// "&lt;", never as "<".
public enum HTMLEntities {
  private static let named: [(entity: String, text: String)] = [
    ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&"),
  ]
  public static func decode(_ text: String) -> String {
    named.reduce(text) { $0.replacingOccurrences(of: $1.entity, with: $1.text) }
  }
}
