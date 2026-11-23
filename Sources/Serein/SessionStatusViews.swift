import AppKit
import SereinCore
import SwiftUI

/// Sessions in other apps waiting on the person, at the foot of Serein's chat for as long as they
/// wait (`SessionStatusTexts.waiting`): a warning dot and the app's mark, who waits and where, how
/// long, and Open, which brings forward the app it waits in. It goes the moment the session is
/// answered, so the chat never fills with "needs you" lines that stopped being true. Titles show
/// only while the person lets Serein read their chats.
struct WaitingSessionsRow: View {
  let agent: AgentModel
  @ObservedObject private var texts = SessionStatusTexts.shared
  @ObservedObject private var store = ExternalSessionStore.shared
  @Environment(\.palette) private var p

  /// Still waiting, oldest first.
  private var rows: [(session: ExternalSession, since: Date)] {
    texts.waiting.compactMap { id, since in
      store.sessions.first { $0.id == id && $0.state == .needsUser }.map { ($0, since) }
    }.sorted { $0.since < $1.since }
  }

  var body: some View {
    let rows = rows
    if !rows.isEmpty {
      VStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.session.id) { index, item in
          if index > 0 { Rectangle().fill(p.line).frame(height: UIStyle.hairline).padding(.leading, 44) }
          row(item.session, since: item.since)
        }
      }
      .background(p.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
      .frame(maxWidth: 560, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(rows.count == 1 ? "1 session in another app needs you" : "\(rows.count) sessions in other apps need you")
    }
  }

  private func row(_ session: ExternalSession, since: Date) -> some View {
    let place = SessionStatusWords.place(session.cwd, home: NSHomeDirectory())
    let title = SessionReading.allowed && !session.title.isEmpty ? session.title : nil
    let app = WaitingAnswer.app(for: session)?.localizedName ?? session.driver.displayName
    return HStack(spacing: 10) {
      Circle().fill(p.warning).frame(width: 6, height: 6).accessibilityHidden(true)
      ModelMonogram(provider: Provider(session.driver), size: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: session.driver.displayName + " needs you").font(UIStyle.font(14, weight: .medium)).foregroundStyle(p.ink)
          .lineLimit(1)
        Text(verbatim: [place, title].compactMap { $0 }.joined(separator: " \u{00B7} "))
          .font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
      }
      Spacer(minLength: 8)
      // Minutes waited, kept current without a timer of its own.
      TimelineView(.periodic(from: since, by: 30)) { context in
        Text(verbatim: Self.waited(since, now: context.date)).font(AssistantType.meta).foregroundStyle(p.secondary)
          .monospacedDigit().fixedSize()
      }
      Button("Open \(app)") {
        if !AgentsCard.reveal(session) { SessionOpen.openRunning(session, agent: agent) }
      }
      .buttonStyle(PillButton(kind: .tinted, small: true)).fixedSize()
      .help("Answer it in \(app)")
    }
    .padding(.leading, 14).padding(.trailing, 10).frame(minHeight: 52)
    .accessibilityElement(children: .combine)
  }

  /// "now", "4 min", "1 h 5 min".
  static func waited(_ since: Date, now: Date) -> String {
    let minutes = now.timeIntervalSince(since) / 60
    return minutes < 1 ? "now" : SessionStatusWords.duration(minutes)
  }
}

/// Turns in other apps that ended with nothing to report, one row each on one card
/// (`SessionFinishes`) instead of a line each: the app's mark, the chat's title (or its app), where
/// and how long, when it ended, and Open while the session is still listed. The newest four show;
/// the rest fold under "Show more". Words are plain text: titles come from the person's chats.
struct SessionFinishesCard: View {
  let rows: [SessionFinish]
  let agent: AgentModel?
  @ObservedObject private var store = ExternalSessionStore.shared
  @State private var expanded = false
  @Environment(\.palette) private var p
  static let folded = 4

  var body: some View {
    let newest = Array(rows.reversed())
    let shown = expanded ? newest : Array(newest.prefix(Self.folded))
    VStack(alignment: .leading, spacing: 8) {
      Text(rows.count == 1 ? "Session finished" : "\(rows.count) sessions finished")
        .font(AssistantType.name).foregroundStyle(p.secondary)
      VStack(spacing: 0) {
        ForEach(shown) { finish in row(finish) }
      }
      if rows.count > Self.folded {
        Button(expanded ? "Show fewer" : "Show \(rows.count - Self.folded) more") { expanded.toggle() }
          .buttonStyle(.pressable).font(AssistantType.meta).foregroundStyle(p.secondary)
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 12)
    .frame(maxWidth: AssistantMetrics.cardWide, alignment: .leading)
    .assistantCard(p)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(SessionFinishes.text(rows))
  }

  private func row(_ finish: SessionFinish) -> some View {
    let provider = Self.provider(finish)
    let live = store.sessions.first { $0.id == finish.sessionID }
    let detail = [finish.title == nil ? nil : finish.app, finish.folder, finish.minutes.flatMap { $0 >= 1 ? SessionStatusWords.duration($0) : nil }]
      .compactMap { $0 }.joined(separator: " \u{00B7} ")
    return HStack(spacing: 10) {
      if let provider { ModelMonogram(provider: provider, size: 20) } else { Circle().fill(p.track).frame(width: 20, height: 20) }
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: finish.title ?? finish.app).font(UIStyle.font(14)).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
        if !detail.isEmpty {
          Text(verbatim: detail).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      Text(verbatim: Self.time(finish.endedAt)).font(AssistantType.meta).foregroundStyle(p.secondary).monospacedDigit().fixedSize()
      // Every row keeps Open's room, so the times line up; it shows while the session is listed.
      let opens = live != nil && agent != nil
      Button("Open") { if let live, let agent { SessionOpen.openRunning(live, agent: agent) } }
        .buttonStyle(PillButton(kind: .tinted, small: true)).fixedSize()
        .help("Open this \(finish.app) session")
        .opacity(opens ? 1 : 0).disabled(!opens).accessibilityHidden(!opens)
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
  }

  /// The app's mark, from the session's id: "claude:…", or "process:opencode:…" for a session
  /// known only by its process.
  static func provider(_ finish: SessionFinish) -> Provider? {
    let parts = finish.sessionID.split(separator: ":").map(String.init)
    let name = parts.first == "process" ? parts.dropFirst().first : parts.first
    return name.flatMap(HarnessDriver.init(rawValue:)).map(Provider.init)
  }

  /// "5:43 PM" today, "Yesterday" or the day before that.
  static func time(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
      return "Yesterday"
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}
