import SereinCore
import SwiftUI

/// The notebook lives with its originating chat. A stop preserves progress; Continue is a
/// person action and rechecks permissions. Finished reports also land in the chat transcript.
struct ResearchCards: View {
  @ObservedObject var research: ResearchCoordinator
  let thread: String
  @Environment(\.palette) private var p
  @State private var actionError: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let problem = research.problem { Text(problem).font(AssistantType.meta).foregroundStyle(p.secondary) }
      ForEach(research.jobs.filter { $0.thread == thread && !$0.delivered }) { job in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(title(job))
              .font(AssistantType.meta)
            Spacer()
            Text("\(job.completed) of \(job.sources.count) sources").font(AssistantType.meta).foregroundStyle(p.secondary)
          }
          Text(job.question).font(UIStyle.font(14, weight: .semibold)).lineLimit(3)
          ProgressView(value: Double(job.completed), total: Double(job.sources.count))
            .accessibilityLabel("Research progress")
          if let follow = job.followUp, follow.phase != .waiting, follow.phase != .done {
            Text(follow.reason ?? "Some claims need stronger evidence. I’m looking for another source.")
              .font(AssistantType.meta).foregroundStyle(p.secondary)
          }
          if job.checksEnabled == true, job.next == nil {
            Text(job.claimSummary).font(AssistantType.meta).foregroundStyle(p.secondary)
            ProgressView(value: Double(job.checkedClaims), total: Double(max(1, job.totalClaims)))
              .accessibilityLabel("Claim check progress")
          }
          if let note = job.note { Text(note).font(AssistantType.meta).foregroundStyle(p.secondary) }
          Text("Progress is saved. Unfinished research can continue after a restart.")
            .font(AssistantType.meta).foregroundStyle(p.secondary)
          HStack {
            if job.runnable {
              Button("Stop") { research.pause(job.id) }.buttonStyle(QuietButton())
            } else if job.state == .paused {
              Button("Continue") {
                do { try research.resume(job.id); actionError = nil }
                catch { actionError = error.localizedDescription }
              }.buttonStyle(QuietButton())
              Button("End research") { research.end(job.id) }.buttonStyle(QuietButton())
            }
            if job.completed > 0 {
              ShareLink("Save findings…", item: job.report).buttonStyle(QuietButton())
            }
          }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).assistantCard(p)
        .accessibilityElement(children: .contain)
      }
      if let actionError { Text(actionError).font(AssistantType.meta).foregroundStyle(p.secondary) }
    }
  }
  private func title(_ job: ResearchJob) -> String {
    guard job.runnable else { return job.state == .paused ? "Research paused" : job.reportTitle }
    switch job.followUp?.phase {
    case .planning, .searching, .selecting: return "Looking for stronger evidence"
    case .reading: return "Reading additional sources"
    case .checking: return "Checking new evidence"
    default: return job.nextCheck != nil ? "Cross-checking claims" : "Researching"
    }
  }
}

/// A checked report as claims tied to their pages (affectUI Cited Answer): each claim carries a
/// number for the page it was quoted from and for each page the claim check compared it with.
/// Pressing a number lights the claim and unfolds that page with the exact passage Serein
/// matched on its saved copy; pressing it again folds it.
struct ResearchCitedReport: View {
  let job: ResearchJob
  @Environment(\.palette) private var p
  /// The open claim and which of its citations shows. `--ui-affect-cited-answer open` opens the first.
  @State private var open: (claim: Int, citation: Int)? = CommandLine.arguments.contains("--ui-preview")
    && CommandLine.arguments.drop(while: { $0 != "--ui-affect-cited-answer" }).dropFirst().first == "open" ? (claim: 0, citation: 0) : nil
  var body: some View {
    let cited = CitedAnswer(research: job)
    VStack(alignment: .leading, spacing: 12) {
      Text("Claims and their pages").font(AssistantType.meta).foregroundStyle(p.secondary)
      ForEach(cited.claims.indices, id: \.self) { index in
        let claim = cited.claims[index]
        let lit = open?.claim == index
        VStack(alignment: .leading, spacing: 8) {
          Text(claim.text).font(AssistantType.body).foregroundStyle(p.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(lit ? p.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
          HStack(spacing: 6) {
            ForEach(claim.citations.indices, id: \.self) { place in
              let citation = claim.citations[place]
              let host = cited.source(citation.number)?.host ?? ""
              let shown = lit && open?.citation == place
              Button { open = shown ? nil : (claim: index, citation: place) } label: {
                CitationNumber(number: citation.number, open: shown)
              }
              .buttonStyle(.plain).help("\(citation.role) \(host)")
              .accessibilityLabel("\(citation.role) source \(citation.number), \(host)")
            }
            if let outcome = claim.outcome {
              Text(outcome).font(UIStyle.micro).foregroundStyle(p.faint).lineLimit(1)
            }
          }
          if let open, open.claim == index, claim.citations.indices.contains(open.citation),
            let source = cited.source(claim.citations[open.citation].number)
          {
            CitedSourceCard(source: source, quote: claim.citations[open.citation].quote,
              note: claim.citations[open.citation].role + ". The passage matches Serein's saved copy of the page. That shows where the words came from, not that they are true.")
          }
        }
      }
    }
  }
}
