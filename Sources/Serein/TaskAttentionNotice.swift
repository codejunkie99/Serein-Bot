import SereinCore
import SwiftUI

/// Visible even when a task ended before writing a reply. The ledger supplies the same
/// explanation after the run leaves memory; observing the run also catches text-free failures.
struct TaskAttentionNotice: View {
  let id: String
  @ObservedObject var hub: AgentHub
  var onDetail: (() -> Void)? = nil
  @ObservedObject private var tray = SereinTray.shared
  var body: some View {
    if let run = hub.latest(for: id) {
      LiveTaskAttentionNotice(run: run, onDetail: onDetail)
    } else if let record = tray.record(id),
      let detail = RunAttention.detail(outcome: record.outcome, saved: record.attentionDetail, summary: record.summary)
    {
      TaskAttentionContent(outcome: record.outcome, detail: detail)
        .onAppear { onDetail?() }
        .onChange(of: detail) { _, _ in onDetail?() }
    }
  }
}

private struct LiveTaskAttentionNotice: View {
  @ObservedObject var run: AgentRun
  var onDetail: (() -> Void)?
  var body: some View {
    if let detail = run.attentionDetail {
      TaskAttentionContent(outcome: run.record.outcome, detail: detail)
        .onAppear { onDetail?() }
        .onChange(of: detail) { _, _ in onDetail?() }
    }
  }
}

private struct TaskAttentionContent: View {
  let outcome: RunRecord.Outcome
  let detail: String
  @Environment(\.palette) var p
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      InterfaceIcon(systemName: outcome == .stuck ? "exclamationmark.circle" : "questionmark.circle", size: 15)
        .foregroundStyle(outcome == .stuck ? p.danger : p.warning).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(outcome == .stuck ? "Could not finish" : "Needs your input")
          .font(UIStyle.bodyStrong).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
        Text(detail).font(UIStyle.body).foregroundStyle(p.ink)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .accessibilityElement(children: .contain)
  }
}
