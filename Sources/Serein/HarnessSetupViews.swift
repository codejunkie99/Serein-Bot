import AppKit
import SereinCore
import SwiftUI

// MARK: - Setup step

/// First-run "Connect an AI app" (and Serein's “Other AI apps…”): every AI app on this Mac in one list, each with its live
/// state and one action (Install, Sign in, Update, Ready). Actions run the tool's own command in
/// the embedded terminal below; Continue is always available.
struct AgentSetupStep: View {
  @ObservedObject var agent: AgentModel
  /// Serein's “Other AI apps…”: plain words only (no “Without an AI app” note), and the list stays
  /// while an app installs: its row says so, the other rows wait, and the sheet's footer carries
  /// the plain line with Show details (`SereinOtherAppsFooter`).
  var fromSerein = false
  /// From Serein: the list's tallest (it scrolls past it); shorter while the terminal shows.
  var listCap: CGFloat = 560
  @ObservedObject private var registry = HarnessRegistry.shared
  @ObservedObject private var actions = HarnessActions.shared
  @State private var moreOpen = false
  @Environment(\.palette) private var p

  static let intro =
    "You need one AI app. Claude Code or Codex is easiest. Serein installs it and opens a sign-in page in your browser. Serein never asks for your password."
  /// Serein's “Other AI apps…”: you passed Claude Code and Codex to get here, so the list leads.
  static let otherIntro =
    "Serein can think with any of these AI apps, using your own account. Choose Install or Sign in next to one. Serein never asks for your password."
  /// The list's height from Serein (the sheet is as tall as what it holds, up to 560 points).
  @State private var listHeight: CGFloat = 0

  var body: some View {
    Group {
      if let job = actions.job, !fromSerein {
        HarnessTerminalPane(job: job) { actions.close() }.padding(24)
      } else if fromSerein, let job = actions.job {
        HarnessBusyScope(job: job) { list }
      } else {
        list.environment(\.harnessBusy, fromSerein ? HarnessBusy.preview : nil)
      }
    }
    .onAppear {
      actions.setupVisible = true
      agent.discover()
      Task { await registry.detectForSetup() }
    }
    .onDisappear {
      actions.close()
      actions.setupVisible = false
    }
  }

  var list: some View {
    var split = HarnessSetup.order(registry.settings.instances, snapshots: registry.snapshots)
    if fromSerein {
      // You passed Claude Code and Codex to get here: the other apps lead, and those two follow.
      let passed: (HarnessInstance) -> Bool = { $0.driver == .claude || $0.driver == .codex }
      split.detected = split.detected.filter { !passed($0) } + split.detected.filter(passed)
      split.missing = split.missing.filter { !passed($0) } + split.missing.filter(passed)
    }
    return ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text(fromSerein ? Self.otherIntro : Self.intro).role(.reading).foregroundStyle(p.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if split.detected.isEmpty {
          // From Serein the apps you can connect follow at once, so an empty “found” says little.
          if !fromSerein || !registry.refreshing.isEmpty {
            Text(registry.refreshing.isEmpty ? "No AI apps found on this Mac yet." : "Looking for AI apps…")
              .role(.meta)
          }
        } else {
          if fromSerein { Text("On this Mac").role(.section).accessibilityAddTraits(.isHeader) }
          VStack(spacing: 0) {
            ForEach(Array(split.detected.enumerated()), id: \.element.id) { index, instance in
              if index > 0 { Rectangle().fill(p.line).frame(height: 1) }
              HarnessSetupRow(instance: instance, selectable: true, showsLimits: false)
            }
          }.padding(.horizontal, 14).padding(.vertical, 4)
            .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
        }
        if !split.missing.isEmpty {
          let missing = VStack(spacing: 0) {
            ForEach(Array(split.missing.enumerated()), id: \.element.id) { index, instance in
              if index > 0 { Rectangle().fill(p.line).frame(height: 1) }
              HarnessSetupRow(instance: instance, selectable: false, showsLimits: false)
            }
          }.padding(.horizontal, 14).padding(.vertical, 4)
            .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
          if fromSerein {
            // You asked to see the other apps: they are listed, not folded away.
            Text("AI apps you can connect").role(.section).accessibilityAddTraits(.isHeader)
            missing
          } else {
            DisclosureGroup(isExpanded: $moreOpen) {
              missing.padding(.top, 8)
            } label: {
              Text("More AI apps (\(split.missing.count))").role(.section)
            }
          }
        }
        HStack(spacing: 10) {
          Button("Check again") { Task { await registry.refreshAll(includeDisabled: true) } }
            .disabled(!registry.refreshing.isEmpty)
          if !registry.refreshing.isEmpty { ProgressView().controlSize(.small) }
        }
        if !fromSerein {
          VStack(alignment: .leading, spacing: 4) {
            Text("Without an AI app").role(.micro)
            Text(AgentSetup.withoutAgent).role(.meta)
          }
        }
      }.padding(fromSerein ? 24 : 32).frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
    }
    // From Serein the sheet is only as tall as its list (up to `listCap`, then it scrolls).
    .frame(height: fromSerein ? min(max(listHeight, 120), listCap) : nil)
  }
}

/// An app installing or signing in from Serein's “Other AI apps…”: its row says so in place of
/// its button, and the other rows' buttons wait (a second click would stop it and start again).
struct HarnessBusy: Equatable {
  var driver: HarnessDriver
  var kind: HarnessCommand.Kind
  /// `--ui-serein-other-apps installing`: OpenCode installing, in memory (nothing runs).
  nonisolated(unsafe) static var preview: HarnessBusy?
}
private struct HarnessBusyKey: EnvironmentKey { static let defaultValue: HarnessBusy? = nil }
extension EnvironmentValues {
  var harnessBusy: HarnessBusy? {
    get { self[HarnessBusyKey.self] }
    set { self[HarnessBusyKey.self] = newValue }
  }
}
/// Passes a running job down the list as `harnessBusy`; nil once it ends.
private struct HarnessBusyScope<Content: View>: View {
  @ObservedObject var job: HarnessJob
  @ViewBuilder var content: Content
  var body: some View {
    content.environment(\.harnessBusy, job.state == .running ? HarnessBusy(driver: job.driver, kind: job.command.kind) : nil)
  }
}

/// One plain line for an app's job from “Other AI apps…”, in the words the connect sheet uses:
/// what runs now, what it did, or that it did not finish.
struct HarnessJobLine: View {
  let driver: HarnessDriver
  let kind: HarnessCommand.Kind
  let state: HarnessJob.State
  @ObservedObject private var registry = HarnessRegistry.shared
  @Environment(\.palette) private var p
  var body: some View {
    let ready = HarnessPrimaryAction.of(registry.snapshots[driver])
    let words = SereinConnect.jobLine(driver, kind: kind, state: state, ready: ready == .ready || ready == .update)
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Group {
        switch state {
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: InterfaceIcon(systemName: "checkmark", size: 11).foregroundStyle(p.success)
        case .failed, .cancelled: InterfaceIcon(systemName: "exclamationmark.triangle", size: 11).foregroundStyle(p.warning)
        }
      }.frame(width: 14).accessibilityHidden(true)
      Text(words).role(.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
    }.accessibilityElement(children: .combine)
  }
}

// MARK: - Shared row

/// One harness: mark, name, version, live state and one primary action. `selectable` adds the
/// switch that turns a detected harness on or off (on by default).
struct HarnessSetupRow: View {
  var instance: HarnessInstance
  var selectable: Bool
  /// Why Serein limits it (“Used for … only.”). The connect list leaves it out: plain words only.
  var showsLimits = true
  @ObservedObject private var registry = HarnessRegistry.shared
  @Environment(\.palette) private var p
  var snapshot: HarnessSnapshot? { registry.snapshots[instance.driver] }
  var action: HarnessPrimaryAction { HarnessPrimaryAction.of(snapshot) }

  var body: some View {
    HStack(spacing: 12) {
      if selectable {
        Toggle("", isOn: Binding(get: { instance.enabled }, set: { registry.setEnabled(instance.driver, $0) }))
          .toggleStyle(.checkbox).labelsHidden()
          .accessibilityLabel("Use \(instance.name)")
      }
      HarnessGlyph(provider: Provider(instance.driver), size: 17, tinted: true).frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(instance.name).font(UIStyle.bodyStrong)
          if let version = snapshot?.version {
            Text("v" + version).font(UIStyle.monoMeta).foregroundStyle(p.faint)
          }
        }
        Text(stateLine).role(.meta).lineLimit(2)
        if showsLimits, let limit = limitLine {
          Text(limit).role(.meta).foregroundStyle(p.faint).lineLimit(2)
            .help((snapshot?.capabilities ?? .base(instance.driver)).notes.joined(separator: "\n\n"))
        }
      }
      Spacer(minLength: 8)
      HarnessActionButton(driver: instance.driver)
    }.padding(.vertical, 10)
      .accessibilityElement(children: .contain)
  }

  var stateLine: String {
    switch action {
    case .checking: return "Checking…"
    case .install: return "Not installed"
    case .signIn: return "Installed, not signed in"
    case .update:
      return "Update available" + (snapshot?.latestVersion.map { " (\($0))" } ?? "")
    case .ready:
      if !instance.enabled { return "Ready · off for tasks" }
      return [snapshot?.account, "Ready"].compactMap { $0 }.joined(separator: " · ")
    }
  }
  /// Why Serein limits it, when it does.
  var limitLine: String? {
    guard snapshot?.installed == true else { return nil }
    let caps = snapshot?.capabilities ?? .base(instance.driver)
    let offered = HarnessPolicy.offeredModes(driver: instance.driver, capabilities: caps)
    if offered.count == HarnessPolicy.concreteModes.count { return nil }
    if offered.isEmpty { return "Not used for tasks yet: Serein cannot enforce its limits." }
    return "Used for " + offered.map(HarnessPolicy.modeLabel).joined(separator: ", ") + " only."
  }
}

/// Install / Sign in / Update run in the embedded terminal; Ready is a quiet label.
struct HarnessActionButton: View {
  var driver: HarnessDriver
  @ObservedObject private var registry = HarnessRegistry.shared
  @ObservedObject private var actions = HarnessActions.shared
  /// From Serein's “Other AI apps…”: an app installing or signing in (`HarnessBusy`).
  @Environment(\.harnessBusy) private var busy
  @Environment(\.palette) private var p
  var body: some View {
    if let busy, busy.driver == driver {
      // Feedback where you clicked; the footer has the line and Show details.
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini).accessibilityHidden(true)
        Text(SereinConnect.busyWord(busy.kind)).role(.meta).foregroundStyle(p.ink)
      }.fixedSize()
        .accessibilityElement(children: .combine)
    } else if let busy {
      button.disabled(true).help("Wait for \(busy.driver.displayName) to finish first")
    } else {
      button
    }
  }
  @ViewBuilder private var button: some View {
    let action = HarnessPrimaryAction.of(registry.snapshots[driver])
    // Install would only fail in the terminal on a Mac without these tools: say so instead.
    let missing = action == .install ? HarnessActions.missingInstallTools(driver) : []
    switch action {
    case .install where !missing.isEmpty:
      Text("Needs \(AgentSetup.toolList(missing))").role(.meta).fixedSize()
        .help(AgentSetup.missingToolsLine(name: registry.instance(driver).name, tools: missing))
        .accessibilityLabel(AgentSetup.missingToolsLine(name: registry.instance(driver).name, tools: missing))
    case .ready:
      Label("Ready", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
        .font(UIStyle.meta).foregroundStyle(p.success)
        .accessibilityLabel("\(registry.instance(driver).name) is ready")
    case .checking:
      ProgressView().controlSize(.small).accessibilityLabel("Checking")
    default:
      if let command = actions.command(for: driver, action: action) {
        Button(action.label) { actions.run(command, driver: driver) }
          .buttonStyle(PrimaryButton())
          .help("Runs \(command.display)")
          .accessibilityLabel("\(action.label) \(registry.instance(driver).name)")
      } else {
        Link("Install guide", destination: URL(string: driver.docsURL)!).font(UIStyle.font(12))
      }
    }
  }
}
