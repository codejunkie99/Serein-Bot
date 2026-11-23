import Foundation

/// A message's Reply: the draft starts with that message as one quoted line, and the person's
/// own words follow. Replying again swaps the quote and keeps the words. Pure, so
/// `--verify-assistant-core` checks it.
public enum DraftQuote {
  public static let limit = 280
  public static func draft(quoting text: String, before draft: String) -> String {
    let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("```") }.joined(separator: " ")
    guard !flat.isEmpty else { return draft }
    let quote = flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    let own = draft.hasPrefix("> ") ? draft.range(of: "\n\n").map { String(draft[$0.upperBound...]) } ?? "" : draft
    return "> " + quote + "\n\n" + own.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Any text as one line, for a reply's bar and chip.
  public static func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }.joined(separator: " ")
  }

  /// A sent message that starts with a reply's quote: the quoted words and the person's own, so
  /// the chat draws the quote as a chip above the bubble. Nil when it does not start with one.
  public static func split(_ text: String) -> (quote: String, words: String)? {
    guard text.hasPrefix("> "), let gap = text.range(of: "\n\n") else { return nil }
    let quote = String(text[text.index(text.startIndex, offsetBy: 2)..<gap.lowerBound])
      .trimmingCharacters(in: .whitespaces)
    let words = String(text[gap.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !quote.isEmpty, !quote.contains("\n"), !words.isEmpty else { return nil }
    return (quote, words)
  }
}
