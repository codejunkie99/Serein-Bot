import Foundation

/// A mail send card as the person edits it in place (affectUI Email Draft): the subject and the
/// body. When they allow it, Mail sends `mail()` and nothing else, so what goes out is what they
/// approved, held to mail_send's own limits. The recipients are Serein's and never change: the
/// card's new-recipient warning was worked out on them before it showed.
public struct EmailDraft: Equatable, Sendable {
  public let to: [String]
  public let cc: [String]
  public let bcc: [String]
  public var subject: String
  public var body: String

  public init(to: [String], cc: [String] = [], bcc: [String] = [], subject: String, body: String) {
    self.to = to
    self.cc = cc
    self.bcc = bcc
    self.subject = subject
    self.body = body
  }

  /// The email Mail would send.
  public struct Mail: Equatable, Sendable {
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let body: String
    /// The send script's values, in mail_send's order.
    public var values: [String] {
      [to.joined(separator: "\n"), cc.joined(separator: "\n"), bcc.joined(separator: "\n"), subject, body]
    }
  }

  /// The fields as Mail would send them, or why it cannot (the card shows that instead of sending).
  public func mail() throws -> Mail {
    guard !to.isEmpty else { throw SereinError.invalid("Add at least one address in To.") }
    guard to.count + cc.count + bcc.count <= Connections.maxRecipients else {
      throw SereinError.invalid("At most \(Connections.maxRecipients) recipients in one email.")
    }
    let subject = subject.replacingOccurrences(of: "\n", with: " ")
    guard !subject.trimmingCharacters(in: .whitespaces).isEmpty, subject.count <= 300 else {
      throw SereinError.invalid("Give a subject of up to 300 characters.")
    }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= Connections.maxBody else {
      throw SereinError.invalid("Write a message of up to \(Connections.maxBody) characters.")
    }
    return Mail(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
  }
}
