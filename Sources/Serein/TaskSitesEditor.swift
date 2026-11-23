import SereinCore
import SwiftUI

/// The sites this task may open. Anything else asks first. Shown under the task's details.
struct TaskSitesEditor: View {
  let taskID: String
  @ObservedObject var browser: BrowserModel
  @Environment(\.palette) var p
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Sites this task may open").font(UIStyle.meta).foregroundStyle(p.ink)
      let sites = browser.sites(for: taskID)
      if sites.isEmpty {
        Text("No sites yet. The first one asks, and a site that is not listed asks.").role(.meta)
      } else {
        ForEach(sites, id: \.self) { host in
          HStack(spacing: 8) {
            Text(host).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1)
            Spacer(minLength: 0)
            Button("Remove") { browser.setSites(sites.filter { $0 != host }, taskID: taskID) }
              .buttonStyle(QuietButton())
              .accessibilityLabel("Remove \(host)")
          }
        }
      }
      HStack(spacing: 8) {
        TextField("Add a site", text: $draft)
          .textFieldStyle(.roundedBorder)
          .onSubmit { add() }
        Button("Add") { add() }.buttonStyle(QuietButton()).disabled(TaskPass.host(draft).isEmpty)
      }
      Text("Navigation and actions on any other site ask first.").role(.meta)
    }.accessibilityElement(children: .contain)
  }

  private func add() {
    let host = TaskPass.host(draft)
    guard !host.isEmpty else { return }
    var sites = browser.sites(for: taskID)
    if !sites.contains(host) { sites.append(host) }
    browser.setSites(sites, taskID: taskID)
    draft = ""
  }
}
