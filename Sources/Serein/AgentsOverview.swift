import SereinCore
import SwiftUI

/// A scheduled run that did not happen at its time, as a card: the moon, its line, Skip and Run
/// now (off while Serein is stopped or the run limit is used up), in Serein's chat. Automations
/// lists the routine with its problem line and a Fix that brings this card.
struct MissedRunCard: View {
  let missed: RelayMissedRun
  @ObservedObject var relay: RelayOrchestrator
  @Environment(\.palette) var p
  private var line: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      InterfaceIcon(systemName: "moon", size: 13).foregroundStyle(p.warning).accessibilityHidden(true)
      Text(missed.line).font(UIStyle.body).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
    }
  }
  private var buttons: some View {
    HStack(spacing: 6) {
      Button("Skip") { relay.skipMissed(missed) }.buttonStyle(PillButton(kind: .quiet, small: true))
        .accessibilityLabel("Skip \(missed.name)")
      Button("Run now") { relay.runMissed(missed) }.buttonStyle(PillButton(kind: .tinted, small: true))
        .disabled(relay.missedBlocked(missed))
        .help(RelayPanelView.missedHelp(relay))
        .accessibilityLabel("Run \(missed.name) now")
    }.fixedSize()
  }
  var body: some View {
    // Side by side where there is room; in a narrow column the buttons go under the words.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) { line.fixedSize(); Spacer(minLength: 8); buttons }
      VStack(alignment: .leading, spacing: 10) {
        line
        HStack(spacing: 8) { Spacer(minLength: 0); buttons }
      }
    }.padding(14)
      .background(p.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

extension String {
  /// “Nothing new” from “nothing new”: the first letter up, the rest as written.
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// One idea Serein had on its own (a check-in's IDEA line): what it would do, where it came from
/// (“From Mail: Maya, 9:12 AM”), then Do it, which asks Serein to go ahead in your words, and Not
/// now. Once done or set aside it stays readable where it was said, without its buttons.
struct IdeaCard: View {
  let idea: RelayProactive.Idea
  @ObservedObject var relay: RelayOrchestrator
  @Environment(\.palette) var p
  var body: some View {
    let pending = relay.ideas.contains { $0.id == idea.id }
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        InterfaceIcon(systemName: "lightbulb", size: 12).foregroundStyle(p.warning).accessibilityHidden(true)
        Text(idea.text).font(UIStyle.body).foregroundStyle(pending ? p.ink : p.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let source = idea.source {
        Text("From " + source).font(UIStyle.micro).foregroundStyle(p.faint).padding(.leading, 20).lineLimit(1)
      }
      if pending {
        HStack(spacing: 6) {
          Spacer(minLength: 0)
          Button("Not now") { relay.dismissIdea(idea) }.buttonStyle(PillButton(kind: .quiet, small: true))
          Button("Do it") { relay.doIdea(idea) }.buttonStyle(PillButton(kind: .tinted, small: true))
            .help("Asks Serein to go ahead. Anything that sends, pays or changes still asks you.")
        }
      }
    }.padding(12).frame(maxWidth: 520, alignment: .leading)
      .background(p.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .accessibilityElement(children: .contain).accessibilityLabel("Idea: \(idea.text)")
  }
}

/// The hours around now on one line (`ScheduleDay`): each run a mark at its time, the runs before
/// now dimmed, now a tick. A mark is a button that opens its schedule, as the row's Edit does; under
/// the line, the next run.
struct ScheduleDayLine: View {
  let marks: [RoutineList.Mark]
  let now: Date
  /// The assistant that set a schedule, by the schedule's id; nil for the person's own.
  var owner: (String) -> String? = { _ in nil }
  let open: (String) -> Void
  @Environment(\.palette) private var p
  var body: some View {
    let span = ScheduleDay.span(now: now)
    let length = span.upperBound.timeIntervalSince(span.lowerBound)
    func x(_ at: Date, _ width: CGFloat) -> CGFloat {
      CGFloat(min(max(at.timeIntervalSince(span.lowerBound) / length, 0), 1)) * width
    }
    return VStack(alignment: .leading, spacing: 12) {
      GeometryReader { geo in
        let width = geo.size.width
        ZStack(alignment: .leading) {
          Rectangle().fill(p.line).frame(height: 1)
          Rectangle().fill(p.accent).frame(width: 2, height: 16).offset(x: x(now, width) - 1).accessibilityHidden(true)
          ForEach(marks) { mark in
            Button { open(mark.routineID) } label: {
              dot(mark).frame(width: 16, height: 16).contentShape(Rectangle())
            }.buttonStyle(.plain)
              .offset(x: x(mark.at, width) - 8)
              .help(words(mark))
              .accessibilityLabel(words(mark))
          }
        }.frame(height: 16)
      }.frame(height: 16)
      HStack {
        Text(Self.time(span.lowerBound)); Spacer(); Text("Now " + Self.time(now)); Spacer(); Text(Self.time(span.upperBound))
      }.font(UIStyle.micro).foregroundStyle(p.faint).accessibilityHidden(true)
      Text(verbatim: nextLine).font(UIStyle.meta).foregroundStyle(p.secondary)
    }.padding(16).background(p.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .accessibilityElement(children: .contain).accessibilityLabel("Schedules around now")
  }
  @ViewBuilder private func dot(_ mark: RoutineList.Mark) -> some View {
    if mark.outcome != nil {
      Circle().fill(p.faint).frame(width: 8, height: 8)
    } else {
      Circle().strokeBorder(p.ink, lineWidth: 1.5).frame(width: 8, height: 8)
    }
  }
  /// “Ops · Post the numbers · 3:00 PM · Done”, or “… · Coming up” for a run still to come.
  private func words(_ mark: RoutineList.Mark) -> String {
    let parts: [String?] = [owner(mark.routineID), mark.name, Self.time(mark.at), mark.outcome?.capitalizedFirst ?? "Coming up"]
    return parts.compactMap { $0 }.joined(separator: " · ")
  }
  private var nextLine: String {
    guard let next = ScheduleDay.next(marks) else { return "Nothing else runs in the next \(Int(ScheduleDay.reach / 3600)) hours." }
    return "Next: \(next.name) at \(Self.time(next.at))"
  }
  private static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
