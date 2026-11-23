#if DEBUG
import Foundation
import SereinCore

/// The approval card's risk word and preview rows, and the mail draft the person edits in place.
extension AssistantCoreChecks {
  static func approvalCard(_ check: Check) throws {
    try check(
      ApprovalRisk.of(effect: .send, words: "Serein wants to send this email", routine: false) == .high
        && ApprovalRisk.of(effect: .click, words: "Click “Archive” in Notes?", routine: false) == .low
        && ApprovalRisk.of(effect: .unknown, words: "", routine: true) == .high,
      "A card's risk follows its effect, and an effect Serein cannot name is high")
    try check(
      ApprovalRisk.of(effect: .click, words: "Click “Delete” in Notes?", routine: true) == .high
        && ApprovalRisk.of(effect: .delete, words: "Click “Archive”", routine: true) == .high,
      "Words on the card raise its risk and never lower it")
    try check(
      ApprovalRisk.of(effect: nil, words: "Allow", routine: true) == .low
        && ApprovalRisk.of(effect: nil, words: "Start", routine: false) == .medium,
      "With no effect and no telling words, a step asked only for Every step is low, anything else medium")
    try check(Set(ApprovalRisk.allCases.map(\.word)).count == 3 && ApprovalRisk.allCases.allSatisfy { $0.word.hasSuffix(" risk") },
      "Each level is its own word")

    let card = Connections.sendCard(to: ["ana@example.com"], cc: [], bcc: [], subject: "Friday", body: "See you at 7.",
                                    new: ["ana@example.com"])
    let preview = ApprovalPreview.split(card.detail)
    try check(
      preview.rows.map(\.label) == ["To", "Subject"] && preview.rows[0].value == "ana@example.com (new recipient)"
        && preview.note.hasPrefix("From Mail's default account.") && preview.note.contains("Check the address."),
      "A send card's recipient and subject are preview rows, and its other lines stay a note")
    try check(
      ApprovalPreview.split("This sends it: now.\nPrivacy & Security: Automation").rows.isEmpty,
      "Prose with a colon stays prose")

    var draft = EmailDraft(to: ["ana@example.com"], subject: "Friday", body: "See you at 7.")
    try check((try? draft.mail().values) == ["ana@example.com", "", "", "Friday", "See you at 7."],
      "An unedited draft sends exactly what Serein wrote, in mail_send's order")
    draft.subject = "Friday\nat 7"
    draft.body = "See you at 8."
    let edited = try? draft.mail()
    let keepsRecipients: Bool = edited?.to == ["ana@example.com"]
    let subjectOnOneLine: Bool = edited?.subject == "Friday at 7"
    let keepsEditedBody: Bool = edited?.body == "See you at 8."
    try check(keepsRecipients && subjectOnOneLine && keepsEditedBody,
      "An edited draft keeps Serein's recipients, and a subject stays on one line")
    var empty = draft
    empty.body = "  \n"
    let crowd = EmailDraft(to: ["ana@example.com"], cc: (1...10).map { "p\($0)@example.com" }, subject: "Friday", body: "Hi")
    try check((try? empty.mail()) == nil && (try? crowd.mail()) == nil,
      "A draft with no message or more than 10 recipients is not sendable")
    try check(!ApprovalPreview.mailLabels.contains("To") && ApprovalPreview.mailLabels.contains("Subject"),
      "A mail draft's recipients stay read-only rows on the card; only the subject becomes a field")
  }
}
#endif
