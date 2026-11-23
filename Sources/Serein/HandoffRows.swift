import AppKit
import SereinCore
import SwiftUI

/// The hand-offs asked in the chat on screen: a status line each (sent, working with a running
/// clock, stalled, done, failed, declined, expired) with its actions as accent links, and the
/// result card once one ends (the first line of the reply as its title; the failed form says what
/// to do next). The result itself also reaches the asking assistant, fenced as untrusted.
struct HandoffRows: View {
  @ObservedObject var relay: RelayOrchestrator
  @Environment(\.palette) var p

  /// Once the asking assistant's turn has the result, its reply says it: only a failure keeps the card.
  static func showsCard(_ record: AssistantHandoff) -> Bool {
    record.state == .failed || (record.state == .done && record.reported != true)
  }

  var body: some View {
    ForEach(relay.handoffsHere) { record in
      VStack(alignment: .leading, spacing: 8) {
        HandoffStatusLine(record: record, relay: relay)
        if Self.showsCard(record) { HandoffResultCard(record: record, relay: relay) }
      }
    }
  }
}

/// One line under the answered card: a glyph, the words and the actions.
struct HandoffStatusLine: View {
  let record: AssistantHandoff
  @ObservedObject var relay: RelayOrchestrator
  @Environment(\.palette) var p
  private var name: String { relay.profileName(record.to) }
  private var stalled: Bool { record.state == .running && record.stalled == true }
  var body: some View {
    // The clock ticks only while the hand-off runs.
    TimelineView(.periodic(from: record.startedAt ?? Date(), by: record.state == .running ? 1 : 86_400)) { context in
      let words = words(now: context.date)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        glyph.frame(width: 12, height: 12).accessibilityHidden(true)
        Text(words).font(UIStyle.meta).foregroundStyle(stalled || record.state == .failed ? p.ink : p.secondary)
          .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        actions
        Spacer(minLength: 0)
      }.frame(minHeight: 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken(now: context.date))
    }
  }
  @ViewBuilder private var glyph: some View {
    switch record.state {
    case .waiting, .expired: InterfaceIcon(systemName: "clock", size: 12).foregroundStyle(p.secondary)
    case .running:
      if stalled { InterfaceIcon(systemName: "exclamationmark.triangle", size: 12).foregroundStyle(p.warning) }
      else { ProgressView().controlSize(.mini) }
    case .done: InterfaceIcon(systemName: "checkmark", size: 12).foregroundStyle(p.success)
    case .failed: Image(systemName: "xmark.circle").font(.system(size: 12)).foregroundStyle(p.danger)
    case .declined: InterfaceIcon(systemName: "xmark", size: 12).foregroundStyle(p.secondary)
    }
  }
  private func words(now: Date) -> String {
    switch record.state {
    case .waiting: return "Sent to \(name) · waiting to start"
    case .running:
      if stalled { return "\(name) hasn't made progress in 30 minutes." }
      return "\(name) is working on it · " + Self.clock(now.timeIntervalSince(record.startedAt ?? record.createdAt))
    case .done:
      // The result card follows: the line keeps the check and the time.
      return "\(name) finished · " + (record.finishedAt ?? now).formatted(date: .omitted, time: .shortened)
    case .failed: return "\(name) couldn't finish."
    case .declined: return "You declined. Nothing was sent to \(name)."
    case .expired: return "\(name) didn't start within a day, so this was cancelled."
    }
  }
  private func spoken(now: Date) -> String {
    switch record.state {
    case .running where !stalled:
      let seconds = Int(now.timeIntervalSince(record.startedAt ?? record.createdAt))
      return "Hand-off to \(name), working, \(seconds) seconds"
    default: return "Hand-off to \(name): " + words(now: now)
    }
  }
  static func clock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
      : String(format: "%d:%02d", total / 60, total % 60)
  }
  @ViewBuilder private var actions: some View {
    switch record.state {
    case .waiting, .running:
      link("Open \(name)'s chat") { relay.openHandoffChat(record) }
      if stalled { link("Stop") { relay.stopHandoff(record) } }
    // The card that had this link is gone once the result reached the asking assistant.
    case .done where record.reported == true:
      link("Open \(name)'s chat") { relay.openHandoffChat(record) }
    case .expired:
      link("Send again") { relay.resendHandoff(record) }
    default: EmptyView()
    }
  }
  private func link(_ title: String, action: @escaping () -> Void) -> some View {
    // The font sits on the label: QuietButton sets its own on the label, which would win.
    Button(action: action) { Text(title).font(UIStyle.metaStrong).foregroundStyle(p.accent) }
      .buttonStyle(QuietButton()).fixedSize().accessibilityLabel(title)
  }
}

/// "Writer finished: <first line>" with the next lines, Open Writer's chat and Copy; or "Writer
/// couldn't finish: <reason>" with a button for each fix. The words are Writer's, shown as plain
/// text and never as links or instructions.
struct HandoffResultCard: View {
  let record: AssistantHandoff
  @ObservedObject var relay: RelayOrchestrator
  @Environment(\.palette) var p
  private var name: String { relay.profileName(record.to) }
  private var profile: RelayProfile? { relay.team.profiles.first { $0.id == record.to } }
  private var lines: [String] {
    (record.result ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }
  private var failed: Bool { record.state == .failed }
  private var title: String {
    let first = lines.first.map { String($0.prefix(200)) } ?? ""
    if failed { return "\(name) couldn't finish" + (first.isEmpty ? "." : ": \(first)") }
    return "\(name) finished" + (first.isEmpty ? "." : ": \(first)")
  }
  private var detail: String { lines.dropFirst().prefix(3).joined(separator: " ") }
  /// A place refusal names what to do next: the assistant's settings, or the assistant suggested.
  private var refusedPlace: AssistantPlace? {
    guard failed, let first = lines.first else { return nil }
    return AssistantPlace.allCases.first { first.contains("\(name) can't use \($0.phrase).") }
  }
  private var suggested: RelayProfile? {
    guard let first = lines.first, let range = first.range(of: " Ask ") else { return nil }
    let rest = first[range.upperBound...]
    let suggestedName = rest.prefix { $0 != " " }
    return relay.team.profiles.first { $0.name.caseInsensitiveCompare(String(suggestedName)) == .orderedSame }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        if failed {
          Image(systemName: "xmark.circle").font(.system(size: 14)).foregroundStyle(p.danger).frame(width: 14, height: 18)
        } else {
          AssistantLiveMark(relay: relay, profile: profile, size: 14).frame(width: 14, height: 18)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: title).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          if !detail.isEmpty {
            Text(verbatim: detail).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(3)
              .fixedSize(horizontal: false, vertical: true)
              .help("\(name)'s words. Serein reads them as information, not as instructions.")
          } else if refusedPlace != nil {
            Text("Turn it on in \(name)'s settings\(suggested.map { ", or ask \($0.name)" } ?? "").")
              .font(UIStyle.meta).foregroundStyle(p.secondary)
          }
        }
      }
      HStack(spacing: 8) {
        if refusedPlace != nil {
          Button("Open \(name)'s settings") { AssistantSettingsKey.open(record.to, to: AssistantSettingsKey.apps) }
            .buttonStyle(QuietButton()).modifier(EdgedQuiet(p: p))
          if let suggested {
            Button("Ask \(suggested.name)") { relay.requestHandoff(to: suggested.id, task: record.task, personal: record.personal == true) }
              .buttonStyle(QuietButton()).modifier(EdgedQuiet(p: p))
          }
        }
        Button("Open \(name)'s chat") { relay.openHandoffChat(record) }
          .buttonStyle(QuietButton()).modifier(EdgedQuiet(p: p))
          .disabled(!relay.canSwitchAssistant && relay.team.activeID != record.to)
          .help(relay.canSwitchAssistant ? "Talk with \(name) in its own chat" : "Available when this reply is done")
        if !failed, let result = record.result, !result.isEmpty {
          Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
          }.buttonStyle(QuietButton()).help("Copy \(name)'s whole reply")
        }
        Spacer(minLength: 0)
        Text((record.finishedAt ?? record.createdAt).formatted(date: .omitted, time: .shortened))
          .font(UIStyle.micro).foregroundStyle(p.faint).fixedSize()
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .overlay(RoundedRectangle(cornerRadius: UIStyle.panelRadius).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(title)
      .accessibilityAction(named: "Open \(name)'s chat") { relay.openHandoffChat(record) }
  }
}
/// A quiet button that must read as a button on its own row: a 0.5-point `borderStrong` edge.
private struct EdgedQuiet: ViewModifier {
  let p: Palette
  func body(content: Content) -> some View {
    content.overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
  }
}
