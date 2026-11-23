import SereinCore
import SwiftUI

/// Answer choices below the current assistant message. Each click sends that answer to the
/// conversation; the questions and replies themselves live in the regular transcript.
struct SereinChatSetupCard: View {
  @ObservedObject var relay: RelayOrchestrator
  let offeredIn: String
  @ObservedObject private var setup = SereinChatSetup.shared
  @ObservedObject private var registry = HarnessRegistry.shared
  @ObservedObject private var connect = SereinConnect.shared
  @Environment(\.palette) private var p
  @State private var allHarnesses = false
  @State private var query = ""

  private var current: Bool { relay.threadID == offeredIn && setup.isActive(in: relay) }
  private var routes: [ModelRoute] { setup.models(relay) }
  /// The two main accounts stay where they were when the list opens; the rest go under them.
  private var shownHarnesses: [HarnessDriver] {
    let accounts = SereinChatSetup.accounts
    return allHarnesses ? accounts + setup.harnesses.filter { !accounts.contains($0) } : accounts
  }
  private var shownRoutes: [ModelRoute] {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return routes.filter {
      search.isEmpty || modelName($0).localizedCaseInsensitiveContains(search)
        || $0.model.localizedCaseInsensitiveContains(search)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch setup.state.phase {
      case .computer:
        if let computer = ComputerHost.shared.computers[RelayTeam.mainID] {
          InitialMacSetupStatus(computer: computer) { if current { setup.showComputerSetup(relay) } }
        } else {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Preparing Serein’s Mac…").font(UIStyle.meta).foregroundStyle(p.secondary)
          }
        }
      // Answered in the message box under the question; typing “skip” passes over it
      // (`SereinChatSetup.handleText`). Nothing is drawn: the box is the answer.
      case .name, .about, .complete, .skipped: EmptyView()
      case .harness: harnessChoices
      case .connecting:
        if connect.flow != nil {
          SereinConnectSheet(agent: relay.agent, inline: true)
        } else {
          Text("Choose another app or try connecting again.").font(UIStyle.meta).foregroundStyle(p.secondary)
        }
        Button("Choose another AI app") { if current { setup.back(relay) } }
          .buttonStyle(QuietButton())
      case .model: modelChoices
      }
      if let error = setup.error {
        Text(error).font(UIStyle.meta).foregroundStyle(p.danger)
          .fixedSize(horizontal: false, vertical: true)
      } else if let guidance = setup.guidance {
        Text(guidance).font(UIStyle.meta).foregroundStyle(p.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: UIStyle.wide(480), alignment: .leading)
    .accessibilityElement(children: .contain)
    .disabled(!current || setup.busy)
    .onChange(of: setup.state.phase) {
      allHarnesses = false
      query = ""
    }
  }

  private var harnessChoices: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(spacing: 6) {
        // The two accounts most people have, named by the plan they pay for; the other apps
        // are one click away.
        ForEach(shownHarnesses, id: \.rawValue) { driver in
          let ready = setup.harnessReady(driver, relay: relay)
          let account = SereinChatSetup.accounts.contains(driver)
          choice(title: account || ready ? setup.accountTitle(driver) : "Connect \(driver.displayName)",
                 detail: setup.harnessDetail(driver), enabled: true,
                 hint: ready ? "Use this account" : "Serein installs or signs in, then uses it",
                 provider: Provider(driver)) {
            guard current else { return }
            setup.chooseHarness(driver, relay: relay)
          }
        }
      }.frame(maxWidth: UIStyle.wide(Self.accountWidth))
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { harnessListButton; laterButton }
        VStack(alignment: .leading, spacing: 4) { harnessListButton; laterButton }
      }
    }
  }

  @ViewBuilder private var harnessListButton: some View {
    if setup.harnesses.count > SereinChatSetup.accounts.count {
      Button(allHarnesses ? "Fewer AI apps" : "Other AI apps") { allHarnesses.toggle() }
        .buttonStyle(QuietButton())
    }
  }

  private var modelChoices: some View {
    VStack(alignment: .leading, spacing: 8) {
      if routes.count > 6 {
        TextField("Find a model", text: $query).textFieldStyle(.roundedBorder)
          .accessibilityLabel("Find a model")
      }
      if shownRoutes.isEmpty {
        Text(query.isEmpty ? "Checking available models…" : "No models match that name.")
          .font(UIStyle.meta).foregroundStyle(p.secondary)
      } else if shownRoutes.count > 6 {
        ScrollView {
          LazyVStack(spacing: 6) { modelRows }
        }.frame(maxHeight: UIStyle.wide(300))
      } else {
        VStack(spacing: 6) { modelRows }
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { backButton; laterButton }
        VStack(alignment: .leading, spacing: 4) { backButton; laterButton }
      }
    }
  }

  @ViewBuilder private var modelRows: some View {
    ForEach(shownRoutes) { route in
      choice(title: modelName(route), detail: route.reason ?? modelDetail(route),
             enabled: route.selectable, hint: "Use this model") {
        guard current else { return }
        setup.chooseModel(route, relay: relay)
      }
    }
  }

  private func modelName(_ route: ModelRoute) -> String {
    if route.model.isEmpty { return "Use \(setup.state.selectedHarness?.displayName ?? "the AI app")’s default" }
    return registry.models(Provider(rawValue: route.provider)).first { $0.id == route.model }?.name ?? route.model
  }

  /// Said only where choosing it costs money outside the person's plan.
  private func modelDetail(_ route: ModelRoute) -> String? {
    route.costClass == .yourKey ? "Uses your API key" : nil
  }

  /// As wide as “Continue with ChatGPT” needs with room to breathe, not the chat's width.
  private static let accountWidth: CGFloat = 300

  private func choice(title: String, detail: String?, enabled: Bool, hint: String,
                      provider: Provider? = nil,
                      choose: @escaping () -> Void) -> some View {
    Button(action: choose) {
      HStack(alignment: .center, spacing: 10) {
        if let provider { HarnessGlyph(provider: provider, size: 18, logo: true) }
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(UIStyle.bodyStrong).foregroundStyle(enabled ? p.ink : p.secondary)
          if let detail { Text(detail).font(UIStyle.meta).foregroundStyle(p.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }.padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
        .overlay(RoundedRectangle(cornerRadius: UIStyle.rowRadius).strokeBorder(p.borderStrong, lineWidth: 1))
        .hoverWash(in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
    }.buttonStyle(AssistantPressStyle()).disabled(!enabled)
      .accessibilityElement(children: .combine)
      .accessibilityHint(hint)
  }

  private var laterButton: some View {
    Button("Not now") { if current { setup.skip(relay) } }.buttonStyle(QuietButton())
  }

  private var backButton: some View {
    Button("Change AI app") { if current { setup.back(relay) } }.buttonStyle(QuietButton())
  }
}

private struct InitialMacSetupStatus: View {
  @ObservedObject var computer: ComputerHost.Computer
  var show: () -> Void
  @ObservedObject private var network = NetworkMonitor.shared
  @Environment(\.palette) private var p

  private var message: String {
    if let line = computer.setupLine { return line }
    if case .error(let text) = computer.state { return text }
    if !network.known { return "Checking the connection…" }
    if !network.online { return "Waiting for an internet connection." }
    if network.metered { return "Waiting for a connection without a data limit." }
    return "Preparing Serein’s Mac…"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(message).font(UIStyle.meta).foregroundStyle(p.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Show setup", action: show).buttonStyle(QuietButton())
    }
  }
}
