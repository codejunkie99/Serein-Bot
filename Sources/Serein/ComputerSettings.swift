import AppKit
import SereinCore
import SwiftUI

/// Settings › Serein's computer, in the order people look for things: the logo with one status line,
/// the switch that lets assistants use the computer and the next step; then where computers run
/// (built-in, Docker, E2B, Daytona, your own over SSH), one row each with its status and its own
/// settings folded under it; then each assistant's computer (mode, a ⋯ menu for checkpoint, reset,
/// move and delete, and every switch that loosens its internet or schedules, always shown); then
/// Advanced (Docker's RAM and CPU caps and its image). The long explanations sit in info popovers.
struct ComputerSettings: View {
  @ObservedObject private var host = ComputerHost.shared
  @GateStorage(ComputerPolicy.enabledKey) private var enabled = false
  @GateStorage(ComputerPolicy.memoryKey) private var memoryMB = ComputerPolicy.defaultMemoryMB
  @GateStorage(ComputerPolicy.cpuKey) private var cpus = ComputerPolicy.defaultCPUs
  @State private var deleting: ComputerHost.Computer?
  @State private var resetting: ComputerHost.Computer?
  @State private var deletingImage = false
  @State private var moving: (computer: ComputerHost.Computer, to: ComputerPlace)?
  @State private var removing: ComputerHost.Computer?
  @State private var connecting = false
  @Environment(\.palette) var p

  /// The Remove dialog's message, built in typed steps (one concatenation is too much for the
  /// type checker).
  private var removeMessage: String {
    let lost: String = removing.map(host.lossList) ?? "what Serein put there"
    let place: String = removing.map(host.placeName) ?? "the machine"
    let home: String = removing.map { host.homePlace($0).label } ?? "this Mac"
    return "Remove deletes \(lost), and Serein forgets the host key it kept. Nothing else on \(place) changes, and the computer moves to \(home)."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      ComputerOverview(enabled: $enabled)
      if let notice = host.notice {
        Text(notice).role(.meta).accessibilityAddTraits(.updatesFrequently)
      }
      VStack(alignment: .leading, spacing: 8) {
        SettingsCaption("Each assistant's computer", info: Self.computersInfo)
        if let relay = RelayController.shared?.relay {
          ComputerList(relay: relay, deleting: $deleting, resetting: $resetting, moving: $moving, removing: $removing)
        } else {
          Text("Serein is not set up yet.").role(.meta)
        }
      }
      // Where computers run and Docker's limits are set up once (docs/demos/simple-settings.decision.md):
      // folded, with every switch that loosens an assistant's computer still in view above.
      SettingsAdvanced(page: "Computer", count: 8) {
      VStack(alignment: .leading, spacing: 8) {
        SettingsCaption("Where computers run", info: Self.placesInfo)
        VStack(spacing: 0) {
          BuiltInPlace()
          DockerPlace()
          E2BPlace()
          DaytonaPlace()
          OwnPlace(connecting: $connecting)
        }.frame(maxWidth: .infinity, alignment: .leading).settingsCard()
      }
      VStack(alignment: .leading, spacing: 8) {
        SettingsCaption("Docker limits and image")
        AdvancedComputerSettings(memoryMB: memoryMB, cpus: $cpus, deletingImage: $deletingImage)
      }
      }
    }
    .confirmationDialog(
      "Delete \(deleting.map { host.assistantName($0.id) } ?? "this")'s computer?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible
    ) {
      Button("Delete Computer", role: .destructive) {
        if let computer = deleting { Task { await host.delete(computer) } }
        deleting = nil
      }
    } message: {
      let loss: String = deleting.map(host.lossList) ?? "everything in it"
      let note: String = Self.deleteNote(deleting?.place)
      Text(verbatim: "This loses \(loss).\(note)")
    }
    // Reset empties the home folder, so it asks once, like Delete, and says what follows.
    .confirmationDialog(
      "Reset \(resetting.map { host.assistantName($0.id) } ?? "this")'s computer?",
      isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }), titleVisibility: .visible
    ) {
      Button("Reset Computer", role: .destructive) {
        if let computer = resetting { Task { await host.reset(computer) } }
        resetting = nil
      }
    } message: {
      let name: String = resetting.map { host.assistantName($0.id) } ?? "this assistant"
      let restores: Bool = resetting?.hasCheckpoint == true
      if resetting?.place == .builtIn {
        let back: String = restores ? "to its checkpoint." : "to how it was set up; nothing since can be recovered."
        Text(verbatim: "This puts \(name)'s whole computer back \(back)")
      } else {
        let after: String = restores ? " and puts the checkpoint back." : "; nothing in it can be recovered."
        Text(verbatim: "This empties \(name)'s home folder\(after)")
      }
    }
    // Moving deletes the computer where it is now: nothing moves across.
    .confirmationDialog(
      "Move \(moving.map { host.assistantName($0.computer.id) } ?? "this")'s computer to \(moving?.to.label ?? "another place")?",
      isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }), titleVisibility: .visible
    ) {
      Button("Move Computer", role: .destructive) {
        if let move = moving { Task { await host.setPlace(move.to, for: move.computer) } }
        moving = nil
      }
    } message: {
      let place: String = moving.map { host.placeName($0.computer) } ?? "its current place"
      let loss: String = moving.map { host.lossList($0.computer) } ?? "everything in it"
      if moving?.computer.place == .unavailable {
        Text(ComputerPlace.unavailableMove)
      } else if moving?.to == .macOS, moving?.computer.place == .builtIn {
        Text("The Linux disk is kept. The virtual Mac is installed separately, in a folder you choose.")
      } else {
        Text(verbatim: "Its computer on \(place) is deleted first, and with it \(loss). The new one starts empty.")
      }
    }
    // Remove on the person's own machine: what it deletes there, then the computer moves to its default place (homePlace).
    .confirmationDialog(
      "Remove \(removing.map { host.assistantName($0.id) } ?? "this")'s computer from \(removing.map(host.placeName) ?? "your machine")?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        if let computer = removing { Task { await host.setPlace(host.homePlace(computer), for: computer) } }
        removing = nil
      }
    } message: {
      Text(removeMessage)
    }
    .sheet(isPresented: $connecting) {
      if let relay = RelayController.shared?.relay {
        ConnectOwnSheet(relay: relay) { connecting = false }.environment(\.palette, p)
      }
    }
    .confirmationDialog("Delete the computer's image?", isPresented: $deletingImage, titleVisibility: .visible) {
      Button("Delete Image", role: .destructive) { Task { await host.deleteImage() } }
    } message: {
      Text("Every assistant's computer on Docker is stopped and deleted with it: their files, sign-ins inside and checkpoints. Computers on E2B and Daytona stay. Building again downloads the base image and packages once more.")
    }
    .onAppear { Task { await host.refreshBackend() } }
  }

  /// What the Delete confirmation adds about where the computer is.
  private static func deleteNote(_ place: ComputerPlace?) -> String {
    guard let place else { return " The image stays, so a new computer starts at once." }
    if place.capabilities.paid { return " It is deleted on \(place.label), and stays listed here until \(place.label) confirms it." }
    if place == .builtIn { return " The downloaded system image stays, so a new computer is set up from it without downloading it again." }
    return " The image stays, so a new computer starts at once."
  }

  static let placesInfo = "Each assistant's computer runs in one place, picked in its ⋯ menu below. Virtual Mac runs real macOS; its one-time download and install starts from the computer panel, then you finish its account and guest permissions. It stays between tasks and is online by itself once set up, through Apple's normal networking, which Serein cannot limit to sites; turn it off under More in its computer panel. The built-in Linux computer and Docker use Serein's proxy and site rules. E2B and Daytona run on their servers under your account and may cost money. Your own computer or VM connects over SSH. No personal folder is shared unless you explicitly choose one in a place that supports it."

  static let computersInfo = "Throwaway resets a computer's home folder after every task; Keep leaves it. A checkpoint is a copy of the home folder you can reset to; on the built-in computer it is the whole computer, its disk and memory, and a reset puts all of it back (or the computer as it was set up). One task uses a computer at a time; others wait in line, shown in the task's view. On E2B and Daytona a reset replaces the computer with a new one that starts from the checkpoint, and Pause keeps its memory, so its apps carry on."

  static func gigabytes(_ mb: Int) -> String { ComputerPolicy.gigabytes(mb) }
}

/// One row per assistant. Each computer's record is made once the list appears, never while
/// the view is drawn.
private struct ComputerList: View {
  @ObservedObject var relay: RelayOrchestrator
  @Binding var deleting: ComputerHost.Computer?
  @Binding var resetting: ComputerHost.Computer?
  @Binding var moving: (computer: ComputerHost.Computer, to: ComputerPlace)?
  @Binding var removing: ComputerHost.Computer?
  @ObservedObject private var host = ComputerHost.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(relay.team.profiles) { profile in
        if let computer = host.computers[profile.id] {
          ComputerRow(
            profile: profile, computer: computer, deleting: $deleting, resetting: $resetting, moving: $moving, removing: $removing)
        }
      }
    }
    .onAppear { for profile in relay.team.profiles { _ = host.computer(for: profile.id) } }
    .onChange(of: relay.team.profiles.map(\.id)) { _, ids in for id in ids { _ = host.computer(for: id) } }
  }
}

private struct ComputerRow: View {
  let profile: RelayProfile
  @ObservedObject var computer: ComputerHost.Computer
  @Binding var deleting: ComputerHost.Computer?
  @Binding var resetting: ComputerHost.Computer?
  @Binding var moving: (computer: ComputerHost.Computer, to: ComputerPlace)?
  @Binding var removing: ComputerHost.Computer?
  @ObservedObject private var host = ComputerHost.shared
  // Either key changing changes whether the buttons below can act.
  @ObservedObject private var e2b = E2BAccount.shared
  @ObservedObject private var daytona = DaytonaAccount.shared
  @Environment(\.palette) var p

  private var stateLine: String {
    if computer.place == .unavailable { return ComputerPlace.unavailableReason }
    if let line = computer.setupLine { return line }
    let state = computer.state == .paused && computer.place.capabilities.pauseKeepsMemory
      ? "Paused, its apps keep running" : computer.state.label
    return state + (computer.hasCheckpoint ? " · has a checkpoint" : "")
  }

  /// The place as one word or two, for the chip on the row.
  private var placeChip: String {
    switch computer.place {
    case .macOS: return "macOS"
    case .builtIn: return "Built-in"
    case .docker: return "Docker"
    case .e2b: return "E2B"
    case .daytona: return "Daytona"
    case .ownDesktop, .ownMachine: return host.placeName(computer)
    case .unavailable: return computer.place.label
    }
  }

  private var resetTitle: String {
    if computer.hasCheckpoint { return "Reset to the Checkpoint…" }
    return computer.place == .builtIn ? "Reset to How It Was Set Up…" : "Empty the Home Folder…"
  }
  private var saveTitle: String {
    computer.place == .builtIn ? "Save Checkpoint of the Whole Computer" : "Save Checkpoint of the Home Folder"
  }

  /// Checkpoint, reset, where it runs and delete, in one menu; Delete (or Remove) sits last, apart,
  /// and each still asks in its confirmation.
  private var actions: some View {
    Menu {
      if computer.place.capabilities.isolated, computer.place != .macOS {
        if computer.state == .starting, (computer.machine as? VirtualMachineComputer)?.isSetUp == false {
          // First setup or start in progress: Cancel removes what it made (and an image nobody else uses).
          Button("Cancel Setup") { Task { await host.cancelSetup(computer) } }
        }
        Button(saveTitle) { Task { await host.saveCheckpoint(computer) } }.disabled(!host.ready(computer))
        Button(resetTitle) { resetting = computer }.disabled(!host.ready(computer))
        Divider()
      }
      // The person's own machine is reached through Connect your own…, never picked here.
      SettingsPopUp("Runs on", selection: Binding(get: { computer.place }, set: { place in
        if place != computer.place { moving = (computer: computer, to: place) }
      }), choices: ComputerPlace.allCases.filter { place in
        place != .unavailable && (place == computer.place || !place.isOwn)
      }.map { SettingsChoice(value: $0, label: $0.label) })
      Divider()
      if computer.place.isOwn {
        Button("Remove from \(host.placeName(computer))…", role: .destructive) { removing = computer }
      } else if computer.place != .unavailable {
        // The home volume outlives a relaunch, so Delete works whenever its place can be reached.
        Button("Delete Computer…", role: .destructive) { deleting = computer }
          .disabled(!host.reachable(computer) && !computer.hasCheckpoint)
      }
    } label: {
      InterfaceIcon(systemName: "ellipsis", size: 14).foregroundStyle(p.secondary)
        .frame(width: 28, height: 24).contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .help("Checkpoint, reset, where it runs and delete")
    .accessibilityLabel("Actions for \(profile.name)'s computer")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        AssistantMark(tint: profile.colour, size: 26, icon: profile.icon, owner: profile.id)
        VStack(alignment: .leading, spacing: 2) {
          Text(profile.name).font(UIStyle.body)
          Text(stateLine).role(.meta).lineLimit(2)
        }
        Spacer(minLength: 8)
        Text(placeChip).font(UIStyle.micro).foregroundStyle(p.secondary).lineLimit(1)
          .padding(.horizontal, 8).padding(.vertical, 2).overlay(Capsule().strokeBorder(p.line))
          .accessibilityLabel("Runs on \(computer.place.label)")
        // The person's own machine as it is has no mode, checkpoint or reset: it is theirs.
        if computer.place.capabilities.isolated, computer.place != .macOS {
          Picker("Mode", selection: Binding(get: { computer.mode }, set: { host.setMode($0, for: computer) })) {
            ForEach(ComputerPolicy.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
          }.pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Throwaway empties the home folder after every task; Keep leaves it")
            .accessibilityLabel("Mode of \(profile.name)'s computer")
        }
        actions
      }
      if computer.place == .e2b, computer.hosted.sandboxID == nil, let attempt = computer.hosted.e2bCreateAttempt,
         computer.state != .starting {
        E2BCreateRecoveryRow(computer: computer, attempt: attempt)
      }
      if host.sitesApply(computer) { SitesRow(profile: profile, computer: computer) }
      if computer.place.capabilities.paid { HostedRow(profile: profile, computer: computer) }
      if computer.place.isOwn { OwnRow(profile: profile, computer: computer) }
      if computer.place == .macOS { MacComputerOptions(computer: computer) }
      else if computer.place != .unavailable { ComputerExtras(computer: computer, name: profile.name) }
      if computer.place.showsPersonalScreen {
        // The person's own screen: no step pictures unless they keep them for this machine.
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Keep step pictures for this machine", isOn: Binding(
            get: { computer.keepsStepPictures }, set: { host.setKeepsStepPictures($0, for: computer) }))
            .accessibilityLabel("Keep step pictures for \(profile.name)'s machine")
          Text("Off: no picture is taken, because this screen can show your private windows. On: a small copy of each screenshot stays on this Mac for the step timeline. The AI never sees it, and it is deleted with task recordings.")
            .role(.meta).fixedSize(horizontal: false, vertical: true)
        }.padding(.leading, 38)
      }
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading).card(p)
    .accessibilityElement(children: .contain)
  }
}

private struct E2BCreateRecoveryRow: View {
  @ObservedObject var computer: ComputerHost.Computer
  let attempt: String
  @State private var confirming = false
  @ObservedObject private var host = ComputerHost.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Resume checks E2B for the original computer. If it never appears, ask E2B to confirm the request cannot still create one. Give them its serein-create tag.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      Text(E2BWire.createTag(attempt)).font(.caption.monospaced()).textSelection(.enabled)
      Button("E2B confirmed the request failed…") { confirming = true }
    }
    .confirmationDialog("Did E2B confirm this request cannot still create a computer?", isPresented: $confirming, titleVisibility: .visible) {
      Button("Clear this request", role: .destructive) {
        Task {
          guard let machine = host.machine(for: computer) as? E2BComputer else { return }
          do {
            try await machine.clearVerifiedUncreatedAttempt(attempt)
            host.notice = "Cleared the failed E2B request."
          } catch { host.notice = error.localizedDescription }
        }
      }
    } message: {
      Text("An empty sandbox list alone is insufficient. Serein will check again with the original key. Once cleared, the next authorized start can order a billable computer.")
    }
  }
}

/// The person's own machine under its row: where it is and the host key Serein trusts for it, what
/// Serein cannot limit there, a changed key's warning with Check the New Key, Forget Without
/// Removing after a Remove that did not reach it, the desktop's caps, and, for the machine as it
/// is, what the assistant may do (Watch only by default; every act asks).
private struct OwnRow: View {
  let profile: RelayProfile
  @ObservedObject var computer: ComputerHost.Computer
  @ObservedObject private var host = ComputerHost.shared
  @State private var fingerprint: String?
  @State private var forgetting = false
  @Environment(\.palette) var p

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let own = computer.own {
        Text(verbatim: "On \(own.target.text)" + (fingerprint.map { " · host key \($0)" } ?? " · host key not trusted yet"))
          .font(UIStyle.monoMeta).foregroundStyle(p.secondary).lineLimit(2).textSelection(.enabled)
        Text(computer.place == .ownMachine ? OwnCard.network : OwnCard.desktopNetwork)
          .role(.meta).fixedSize(horizontal: false, vertical: true)
        if computer.keyChanged {
          HStack(alignment: .firstTextBaseline) {
            Text(OwnCard.keyChanged(target: own.target.text)).font(UIStyle.meta).foregroundStyle(p.warning)
              .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Check the New Key…") { Task { await host.checkNewKey(computer) } }.controlSize(.small)
              .accessibilityLabel("Check the new host key of \(own.target.text)")
          }
        }
        if computer.removeFailed {
          HStack(alignment: .firstTextBaseline) {
            Text("Remove did not reach \(own.target.text). If it is gone for good, Serein can forget it here.")
              .font(UIStyle.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Forget Without Removing…") { forgetting = true }.controlSize(.small)
              .accessibilityLabel("Forget \(own.target.text) without removing what Serein put there")
          }
        }
        if computer.place == .ownDesktop {
          Text(computer.capsLine ?? "Its memory and processor caps are set from \(own.target.text) when it is made: at most half of its memory and processors, within the limits under Advanced.")
            .role(.meta).fixedSize(horizontal: false, vertical: true)
        }
        if computer.place == .ownMachine {
          HStack(spacing: 8) {
            Text("\(profile.name) may").role(.meta)
            SettingsPopUp("What \(profile.name) may do on \(own.target.text)", selection: Binding(
              get: { own.access }, set: { access in host.setOwn(computer) { $0.access = access } }),
              choices: OwnMachineAccess.allCases.map { SettingsChoice(value: $0, label: $0.label) }, showsTitle: false)
            Spacer()
          }
          Text(own.access == .watchOnly
            ? "Watch only: screenshots and reading the screen, no input. Can act lets \(profile.name) click, type, run commands, read files and open sites there."
            : "Every click, key, text, command, file read and site asks you first, whatever Serein asks before on this Mac.")
            .role(.meta).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.leading, 38)
    .task(id: computer.state) { fingerprint = host.trustedKey(computer)?.fingerprint }
    .confirmationDialog(
      "Forget \(profile.name)'s computer on \(host.placeName(computer)) without removing it?", isPresented: $forgetting,
      titleVisibility: .visible
    ) {
      Button("Forget", role: .destructive) { host.forgetOwn(computer) }
    } message: {
      let kept: String = host.lossList(computer)
      let note: String = "Serein forgets the machine, its host key and what it keeps on this Mac, and the computer moves to \(host.homePlace(computer).label). These may stay on \(host.placeName(computer)): \(kept)."
      Text(note)
    }
  }
}

/// Connect your own…: which assistant, which machine (an alias from ~/.ssh/config, Host names only,
/// or user@host typed in), and which kind, each explained in one line. Connect moves that assistant's
/// computer there (deleting its current one, as any move) and starts it, which shows the host key
/// card and, for the machine as it is, the helper's install card.
private struct ConnectOwnSheet: View {
  @ObservedObject var relay: RelayOrchestrator
  let done: () -> Void
  @ObservedObject private var host = ComputerHost.shared
  @State private var assistant = ""
  @State private var aliases: [String] = []
  /// The alias picked, or "" to type user@host.
  @State private var alias = ""
  @State private var typed = ""
  @State private var kind: ComputerPlace = .ownMachine
  @Environment(\.palette) var p

  private var target: SSHTarget? { SSHTarget.parse(alias.isEmpty ? typed : alias) }
  /// Assistants whose computer is not on their own machine already (Remove first to change it).
  private var candidates: [RelayProfile] { relay.team.profiles.filter { host.computers[$0.id]?.place.isOwn != true } }
  private var current: ComputerHost.Computer? { host.computers[assistant] }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Connect your own computer or VM").font(UIStyle.meta).accessibilityAddTraits(.isHeader)
      Text("Serein runs your Mac's own ssh with your own setup. Your keys and passphrases stay with ssh and the macOS ssh-agent; Serein keeps only the name below, in this assistant's computer record.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      SettingsPopUp("Assistant", selection: $assistant, choices: candidates.map { SettingsChoice(value: $0.id, label: $0.name) })
      SettingsPopUp("Machine", selection: $alias,
        choices: [SettingsChoice(value: "", label: "Type an alias or user@host")] + aliases.map { SettingsChoice(value: $0, label: $0) },
        menuWidth: 260)
      if alias.isEmpty {
        TextField("an alias, user@host or user@host:2222", text: $typed).textFieldStyle(.serein)
          .accessibilityLabel("The machine as an SSH alias or user@host")
        if !typed.isEmpty && target == nil {
          Text("Not an alias or user@host. Use letters, digits, dots, dashes and underscores, and an optional :port.")
            .font(UIStyle.meta).foregroundStyle(p.warning)
        }
      }
      Picker("Kind", selection: $kind) {
        Text("A desktop for Serein").tag(ComputerPlace.ownDesktop)
        Text("Use this machine as it is").tag(ComputerPlace.ownMachine)
      }.pickerStyle(.radioGroup).accessibilityLabel("How Serein uses the machine")
      Text(OwnCard.kindLine(kind)).role(.meta).fixedSize(horizontal: false, vertical: true)
      Text(kind == .ownMachine ? OwnCard.network : OwnCard.desktopNetwork).role(.meta).fixedSize(horizontal: false, vertical: true)
      if current?.place == .unavailable {
        Text(ComputerPlace.unavailableMove).role(.meta)
      } else if let current, current.state != .none || current.hasCheckpoint || current.place.capabilities.paid {
        Text("\(host.assistantName(current.id))'s computer on \(current.place.label) is deleted first, and with it \(host.lossList(current)).")
          .font(UIStyle.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
      }
      Text("The first connection shows the machine's host key fingerprint; Serein trusts it only when you do.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
        Button("Connect") { connect() }.keyboardShortcut(.defaultAction).disabled(target == nil || current == nil)
          .accessibilityLabel("Connect the machine")
      }
    }
    .padding(20).frame(width: 480)
    .onAppear {
      for profile in relay.team.profiles { _ = host.computer(for: profile.id) }
      aliases = SSHAliasFile.load()
      if alias.isEmpty, let first = aliases.first { alias = first }
      assistant = candidates.first?.id ?? ""
    }
  }

  private func connect() {
    guard let target, let computer = current else { return }
    let place = kind
    done()
    Task { await host.connectOwn(computer, as: place, to: target) }
  }
}

/// Only these sites, for a computer whose web traffic goes through Serein's proxy: off by default;
/// on, the proxy refuses every host not on the list (and still every Never site and private
/// address). Turning it off, or adding a site while it is on, asks on the Widening card first
/// (ComputerHost.changeSites); turning it on or removing a site applies at once.
private struct SitesRow: View {
  let profile: RelayProfile
  @ObservedObject var computer: ComputerHost.Computer
  @ObservedObject private var host = ComputerHost.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("Only these sites", isOn: Binding(
        get: { computer.sites.only }, set: { on in Task { await host.changeSites(computer, .only(on)) } }))
        .accessibilityLabel("Only let \(profile.name)'s computer reach the sites on its list")
      Text(computer.sites.only
        ? "On: Serein's proxy refuses every site that is not on this list, and still refuses your Never sites and \(profile.name)'s, this Mac and your network. Each refusal shows in the computer's site log with its reason. Adding a site or turning this off asks you first."
        : "Off: the computer may reach any site but your Never sites and \(profile.name)'s, and never this Mac or your network. On holds it to the list below; turning it off again asks you first.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
      SiteListEditor(
        sites: computer.sites.sites, owner: profile.name, problem: { computer.sites.addProblem($0) },
        add: { site in Task { await host.changeSites(computer, .add(site)) } },
        remove: { site in Task { await host.changeSites(computer, .remove(site)) } })
    }
    .padding(.leading, 38)
  }
}

/// A list of sites with Remove on each and a field to add one (a name, or *.name for every name
/// under it); the field says why a site cannot be added.
private struct SiteListEditor: View {
  let sites: [String]
  let owner: String
  let problem: (String) -> String?
  let add: (String) -> Void
  let remove: (String) -> Void
  @State private var site = ""
  @Environment(\.palette) var p

  private func submit() {
    guard problem(site) == nil else { return }
    let entry = site
    site = ""
    add(entry)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(sites, id: \.self) { entry in
        HStack {
          Text(entry).font(UIStyle.monoMeta).foregroundStyle(p.ink)
          Spacer()
          Button("Remove") { remove(entry) }.controlSize(.small)
            .accessibilityLabel("Remove \(entry) from \(owner)'s allowed sites")
        }
      }
      HStack(spacing: 6) {
        TextField("example.com or *.example.com", text: $site).textFieldStyle(.serein).onSubmit(submit)
          .accessibilityLabel("A site \(owner)'s computer may reach")
        Button("Add") { submit() }.disabled(problem(site) != nil)
          .accessibilityLabel("Allow this site")
      }
      if !site.trimmingCharacters(in: .whitespaces).isEmpty, let why = problem(site) {
        Text(why).font(UIStyle.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// A hosted computer's own settings under its row: its internet (through this Mac unless the
/// person opts in to the provider's, held to their list of sites, which the provider enforces, or
/// on Daytona, after a Widening card, open), the switch that lets a schedule start it, and what it
/// has cost (the provider's report, or Serein's estimate).
private struct HostedRow: View {
  let profile: RelayProfile
  @ObservedObject var computer: ComputerHost.Computer
  @ObservedObject private var host = ComputerHost.shared

  private var provider: String { computer.place.label }
  private var usageLine: String {
    let spent = (computer.machine as? HostedComputer)?.usage ?? computer.hosted.spent
    let estimate = computer.place == .daytona
      ? "Daytona's own report is not available with this key, so this is worked out from its published prices."
      : "\(provider) shows no cost to Serein, so this is worked out from its published prices."
    guard let line = spent.line(provider: provider) else { return "\(HostedUsage.label): nothing yet. " + estimate }
    return line + ". " + (spent.reported != nil ? "Reported by \(provider); it may lag behind." : estimate)
  }
  private var tiered: Bool { computer.place == .daytona }
  private var internetLine: String {
    guard computer.hosted.providerInternet else {
      return "Off: its internet goes through this Mac, so your site rules apply and every site is logged. \(provider)'s own internet stays switched off."
        + (tiered ? " \(provider) switches it off only on its Tiers 3 and 4; on Tiers 1 and 2 the computer does not start this way." : "")
    }
    guard computer.hosted.listOnly || !computer.place.capabilities.openInternet else {
      return "\(provider)'s own internet. \(HostedCard.openLine) Your site rules and \(profile.name)'s Never sites do not apply there, it can reach code hosts and AI services, and nothing it reaches is logged here."
    }
    guard !computer.hosted.allowlist.isEmpty else {
      return "No site is on the list, so this computer does not start this way. Add a site below, or turn \(provider)'s own internet off."
        + (computer.place.capabilities.openInternet ? " You can also turn off Only these sites, which Serein can't limit." : "")
    }
    let dns = computer.place == .e2b ? " (and E2B's DNS server, 8.8.8.8, which can also carry data out)" : ""
    let tiers = tiered
      ? " \(provider) holds it to the list only on its Tiers 3 and 4: Serein reads the list back from \(provider) before it uses the computer, and on Tiers 1 and 2 the computer does not start this way."
      : ""
    return "\(provider)'s own internet, open only to the sites below\(dns). Serein cannot limit it beyond that list: your site rules and \(profile.name)'s Never sites do not apply there, and nothing it reaches is logged here.\(tiers) Adding a site asks you first."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // The running time grows on its own: the line is redrawn every minute.
      TimelineView(.periodic(from: .now, by: 60)) { _ in
        Text(usageLine).role(.meta).fixedSize(horizontal: false, vertical: true)
      }
      Toggle("Use \(provider)'s own internet for this computer", isOn: Binding(
        get: { computer.hosted.providerInternet },
        set: { on in
          Task {
            await host.setHosted(computer) { settings in
              settings.providerInternet = on
              // Off again, the list is back on: an open internet is only ever reached by its Widening card.
              if !on { settings.listOnly = true }
            }
          }
        }))
        .accessibilityLabel("Use \(provider)'s own internet for \(profile.name)'s computer")
      Text(internetLine).role(.meta).fixedSize(horizontal: false, vertical: true)
      if computer.hosted.providerInternet && computer.place.capabilities.enforcedAllowlist {
        // Where the provider also offers its internet open, the list can be turned off: a Widening card.
        if computer.place.capabilities.openInternet {
          Toggle("Only these sites", isOn: Binding(
            get: { computer.hosted.listOnly },
            set: { on in Task { await host.changeHostedSites(computer, .only(on)) } }))
            .accessibilityLabel("Hold \(profile.name)'s computer on \(provider)'s internet to the sites on its list")
        }
        SiteListEditor(
          sites: computer.hosted.allowlist, owner: profile.name,
          problem: { computer.hosted.providerList.addProblem($0, limit: HostedNetwork.maxAllow) },
          add: { site in Task { await host.changeHostedSites(computer, .add(site)) } },
          remove: { site in Task { await host.changeHostedSites(computer, .remove(site)) } })
      }
      Toggle("Let schedules, alerts and webhooks start it", isOn: Binding(
        get: { computer.hosted.fromSchedules },
        set: { on in Task { await host.setHosted(computer) { $0.fromSchedules = on } } }))
        .accessibilityLabel("Let schedules, alerts and webhooks start \(profile.name)'s computer on \(provider)")
      Text("Off by default: a run nobody started by hand never starts this paid computer; it is refused with the reason.")
        .role(.meta).fixedSize(horizontal: false, vertical: true)
    }
    .padding(.leading, 38)
    // The provider's own report of what it cost, read when the row appears.
    .task { await host.refreshUsage(computer) }
  }
}

/// The top of the page: the Serein logo, what the computer is, one status line with the next step,
/// and the switch that lets assistants use it (GateStorage, off by default, always shown).
private struct ComputerOverview: View {
  @Binding var enabled: Bool
  @ObservedObject private var host = ComputerHost.shared
  @ObservedObject private var image = BuiltInImage.shared
  @ObservedObject private var e2b = E2BAccount.shared
  @ObservedObject private var daytona = DaytonaAccount.shared
  @Environment(\.palette) var p

  /// The places a computer can start in now.
  private var ready: [String] {
    var names: [String] = []
    if image.ready { names.append("built-in") }
    let dockerUp: Bool = host.backendName != nil && host.backendProblem == nil
    if dockerUp && host.imageBuilt && !host.imageStale { names.append("Docker") }
    if e2b.hasKey { names.append("E2B") }
    if daytona.hasKey { names.append("Daytona") }
    if host.computers.values.contains(where: { $0.place.isOwn }) { names.append("your own machine") }
    return names
  }
  private var settingUp: Bool { image.working || host.building }
  private var statusText: String {
    if settingUp { return "Setting up…" }
    if !enabled { return "Off · assistants cannot use it" }
    let places: [String] = ready
    if places.isEmpty {
      return ComputerPolicy.setsItselfUp()
        ? "On · sets itself up the first time an assistant needs it (\(VirtualMachinePolicy.sizeLine))"
        : "On, but no place is ready yet. Set up the built-in computer, or pick a place below."
    }
    return "On · ready on " + places.joined(separator: ", ")
  }
  private var statusTint: Color {
    if settingUp { return p.accent }
    if !enabled { return p.faint }
    return ready.isEmpty && !ComputerPolicy.setsItselfUp() ? p.warning : p.success
  }
  /// The one next step: set up the built-in computer when it is on, nothing can start and it won't
  /// set itself up. Where it runs keeps its own Set up for someone who wants it now.
  private var offersSetUp: Bool {
    enabled && ready.isEmpty && !settingUp && VirtualMachineComputer.supported && !ComputerPolicy.setsItselfUp()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 16) {
        SereinAppIcon(size: 56)
        VStack(alignment: .leading, spacing: 6) {
          Text("A separate computer where assistants click, type and run apps. It cannot reach your files, sign-ins, keys or this Mac.")
            .role(.meta).fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 6) {
            Circle().fill(statusTint).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(statusText).font(UIStyle.meta).fixedSize(horizontal: false, vertical: true)
          }.accessibilityElement(children: .combine).accessibilityLabel("Status: \(statusText)")
        }
      }
      Rectangle().fill(p.line).frame(height: 1)
      Toggle("Let assistants use Serein's computer", isOn: $enabled)
      SettingsNote("Steps inside the computer need no approval; a file or text leaving it always asks you, and never in a scheduled run. An assistant uses it only when Serein's computer is in its Can use list.")
      if offersSetUp {
        HStack {
          Spacer()
          Button { image.setUp() } label: {
            Text("Set Up the Built-in Computer").padding(.horizontal, 14).padding(.vertical, 7)
          }.buttonStyle(PrimaryButtonStyle())
            .help("Download Debian's image once (\(VirtualMachinePolicy.sizeLine))")
        }
      }
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading).card(p)
  }
}

/// Serein's app icon (assets/serein-icon.svg, copied into Icons), in the variant for this
/// appearance; drawn as it is, not as a template.
private struct SereinAppIcon: View {
  var size: CGFloat
  @Environment(\.palette) var p
  private static func load(_ name: String) -> NSImage? {
    guard let url = Bundle.assets.url(forResource: name, withExtension: "svg", subdirectory: "Icons") else { return nil }
    return NSImage(contentsOf: url)
  }
  private static let dark = load("serein-app-icon")
  private static let light = load("serein-app-icon-light")
  var body: some View {
    let image: NSImage? = p.isDark ? Self.dark : (Self.light ?? Self.dark)
    if let image {
      Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        .accessibilityLabel("Serein logo")
    } else {
      InterfaceIcon(systemName: "serein.mark", size: size * 0.6).foregroundStyle(p.accent)
        .frame(width: size, height: size).accessibilityLabel("Serein logo")
    }
  }
}

/// Serein's built-in computer: the download (the size line before anything is fetched, then its
/// progress, Cancel), and its memory. Each assistant's computer is set up from the image on its
/// first start.
private struct BuiltInPlace: View {
  @ObservedObject private var image = BuiltInImage.shared
  @GateStorage(VirtualMachinePolicy.memoryKey) private var memoryMB = VirtualMachinePolicy.defaultMemoryMB
  @Environment(\.palette) var p
  private let memoryChoices = VirtualMachinePolicy.memoryChoices(totalBytes: ProcessInfo.processInfo.physicalMemory)
  private let supported = VirtualMachineComputer.supported

  private var status: String {
    if !supported { return VirtualMachinePolicy.unsupported }
    if image.working { return "Setting up…" }
    if image.ready { return "Ready · \(ComputerSettings.gigabytes(memoryMB)) memory · free" }
    return "Not set up · \(VirtualMachinePolicy.sizeLine)"
  }

  var body: some View {
    SettingsListRow(name: "Built-in, on this Mac", status: status, statusTint: image.ready ? p.success : nil, divider: false) {
      InterfaceIcon(systemName: "serein.mark", size: 22).foregroundStyle(p.accent)
    } trailing: {
      if image.working {
        Button("Cancel") { image.cancel() }.accessibilityLabel("Cancel setting up Serein's built-in computer")
      } else if !image.ready {
        Button("Set up") { image.setUp() }.disabled(!supported)
          .help("Download Debian's image once (\(VirtualMachinePolicy.sizeLine))")
          .accessibilityLabel("Set up Serein's built-in computer")
      }
    } live: {
      if let fraction = image.fraction {
        ProgressView(value: fraction).progressViewStyle(.linear).tint(p.accent)
          .accessibilityLabel("Download progress")
      }
      if !image.lines.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(image.lines.enumerated()), id: \.offset) { line in
            Text(line.element).font(UIStyle.microMono).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
          .accessibilityLabel("Set up progress")
      }
    } details: {
      HStack {
        Text("Memory")
        Spacer()
        SettingsPopUp("Memory for Serein's built-in computer", selection: Binding(get: { memoryMB }, set: { mb in
          let now = VirtualMachinePolicy.memoryMB(totalBytes: ProcessInfo.processInfo.physicalMemory)
          Task {
            await ComputerHost.shared.setMemory(mb, key: VirtualMachinePolicy.memoryKey, current: now, which: "Serein's built-in computer")
          }
        }), choices: memoryChoices.map { SettingsChoice(value: $0, label: ComputerSettings.gigabytes($0)) }, showsTitle: false)
      }
      SettingsHelp(
        text: "Free. Runs with Apple's Virtualization framework and no other software. More memory asks you first.",
        more: "Runs on this Mac with Apple's Virtualization framework; no other software. Serein downloads one dated build of Debian's own cloud image from \(VirtualMachinePolicy.imageHost) once, checks it against the SHA-512 this Serein pins and Debian's \(VirtualMachinePolicy.sumsFile) fetched over HTTPS from the same place, and sets up each computer on its first start: a small desktop (XFCE), Chromium and Serein's helper, each at a pinned version from Debian's snapshot archive, installed through Serein's proxy, which allows only Debian's package archive while it sets up. The computer has no network card: every site goes through Serein's proxy and your site rules, and it cannot reach this Mac, your network, files, sign-ins or keys (except one folder you may share with it read-only, in its Computer tab). Nothing pre-built is downloaded. Memory is 2 to 4 GB, at most half of this Mac's, and more memory asks you first; a change applies from the computer's next start from off. Cancel removes everything downloaded so far.")
    }
  }
}

/// Docker on this Mac: found or not, and Check again. The image and its caps are under Advanced.
private struct DockerPlace: View {
  @ObservedObject private var host = ComputerHost.shared
  @Environment(\.palette) var p

  private var status: String {
    guard let name = host.backendName else { return "Not found · install Docker Desktop, Colima, OrbStack or Podman, then check again" }
    if let problem = host.backendProblem { return "\(name) found, but it is not answering: \(problem)" }
    if host.imageBuilt && host.imageStale { return "\(name) found · Rebuild the image in Advanced before computers can start" }
    return host.imageBuilt ? "\(name) found · image built" : "\(name) found · build the image in Advanced"
  }
  private var tint: Color? {
    guard host.backendName != nil else { return nil }
    if host.backendProblem != nil || host.imageStale { return p.warning }
    return host.imageBuilt ? p.success : nil
  }

  var body: some View {
    SettingsListRow(name: "Docker", status: status, statusTint: tint) {
      BrandLogo(.docker)
    } trailing: {
      Button("Check again") { Task { await host.refreshBackend() } }.accessibilityLabel("Check again for Docker")
    } live: {
      EmptyView()
    } details: {
      SettingsHelp(
        text: host.backendName == nil
          ? "Optional. Without Docker, assistants use the built-in computer."
          : "One hardened container per assistant, with no network of its own and no access to your files, sign-ins or keys.",
        more: host.backendName == nil
          ? "Without Docker, assistants use Serein's built-in computer above. To use a container instead, install Docker Desktop, Colima, OrbStack or Podman, start it and check again."
          : "Serein starts one hardened container per assistant: no network of its own (every site goes through Serein's proxy and your site rules), no access to your files, sign-ins or keys (except one folder you may share with it read-only, in its Computer tab), a read-only system and a home folder of its own.")
    }
  }
}

/// A hosted provider's key: pasted, kept in this Mac's Keychain (this device only), removable,
/// with its status line and a Check that starts nothing.
private struct HostedKeyFields: View {
  @ObservedObject var account: HostedAccount
  let check: () async -> Void
  @State private var key = ""

  var body: some View {
    HStack(spacing: 6) {
      SecureField(account.hasKey ? "Saved in Keychain" : "Paste your \(account.provider) key", text: $key).textFieldStyle(.serein)
        .accessibilityLabel("\(account.provider) key")
      Button("Save Key") { if account.save(key) { key = "" } }.disabled(key.isEmpty)
        .accessibilityLabel("Save the \(account.provider) key in Keychain")
      if account.hasKey {
        Button("Remove Key") { account.remove() }.accessibilityLabel("Remove the \(account.provider) key from Keychain")
      }
    }
    HStack {
      Text(account.status ?? (account.hasKey ? "Key saved in this Mac's Keychain." : "No \(account.provider) key saved.")).role(.meta)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Check") { Task { await check() } }.disabled(!account.hasKey)
        .help("Ask \(account.provider) whether the key works; this starts nothing").accessibilityLabel("Check the \(account.provider) key")
    }
  }
}

/// The E2B account: the key, its status line, the template computers are made from, and what
/// Serein cannot do there.
private struct E2BPlace: View {
  @ObservedObject private var account = E2BAccount.shared
  @AppStorage(E2BWire.templateKey) private var template = E2BWire.defaultTemplate
  @Environment(\.palette) var p

  var body: some View {
    SettingsListRow(
      name: "E2B", badge: "Paid · your account",
      status: account.status ?? (account.hasKey ? "Key saved · template \(template)" : "No key"),
      statusTint: account.hasKey ? p.success : nil
    ) {
      BrandLogo(.e2b)
    } trailing: {
      EmptyView()
    } live: {
      EmptyView()
    } details: {
      HostedKeyFields(account: account) { await account.check() }
      HStack {
        Text("Template")
        Spacer()
        TextField(E2BWire.defaultTemplate, text: $template).textFieldStyle(.serein).frame(width: 200)
          .accessibilityLabel("E2B template Serein's computers are made from")
      }
      HStack {
        Text("Build the template once with E2B's own command-line tool, in the folder Show Recipe opens (a copy in Serein's Library): e2b template create serein-computer -c /opt/serein/start.sh")
          .role(.meta).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        Spacer()
        Button("Show Recipe") {
          if let folder = ComputerHost.shared.recipeFolder() { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }.accessibilityLabel("Show a copy of Serein's computer recipe in Finder")
      }
      SettingsHelp(
        text: "Runs on E2B's servers under your account. It may cost money; the first start asks you. Your key stays in this Mac's Keychain.",
        more: "Choose E2B for an assistant below to run its computer on E2B's servers under your own account; it may cost money there, and the first start asks you. Its internet goes through this Mac unless you turn on E2B's own for it, and each start Serein checks from inside that it cannot reach the internet on its own; a template from an older Serein cannot be checked: rebuild it from the folder Show Recipe opens, then Reset the computer. Its public addresses stay off. Your key stays in this Mac's Keychain and never goes into the computer. Not on E2B: memory and processor limits (the template sets them), adding your saved API tokens to its requests, and a cost figure from E2B (Serein shows its own estimate).")
    }
  }
}

/// The Daytona account: the key, its status line, the snapshot computers are made from, and what
/// Serein cannot do there.
private struct DaytonaPlace: View {
  @ObservedObject private var account = DaytonaAccount.shared
  @AppStorage(DaytonaWire.snapshotKey) private var snapshot = DaytonaWire.defaultSnapshot
  @Environment(\.palette) var p

  var body: some View {
    SettingsListRow(
      name: "Daytona", badge: "Paid · your account",
      status: account.status ?? (account.hasKey ? "Key saved · snapshot \(snapshot)" : "No key"),
      statusTint: account.hasKey ? p.success : nil
    ) {
      BrandLogo(.daytona)
    } trailing: {
      EmptyView()
    } live: {
      EmptyView()
    } details: {
      HostedKeyFields(account: account) { await account.check() }
      HStack {
        Text("Snapshot")
        Spacer()
        TextField(DaytonaWire.defaultSnapshot, text: $snapshot).textFieldStyle(.serein).frame(width: 200)
          .accessibilityLabel("Daytona snapshot Serein's computers are made from")
      }
      HStack {
        Text("Make the snapshot once: build an image from the folder Show Recipe opens (a copy in Serein's Library) with Daytona's desktop packages added (x11vnc and novnc), push it to a registry you own, and create a Linux VM snapshot named serein-computer from it in Daytona.")
          .role(.meta).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Show Recipe") {
          if let folder = ComputerHost.shared.recipeFolder() { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }.accessibilityLabel("Show a copy of Serein's computer recipe in Finder")
      }
      // Kept in view: a key's reach is the one thing to decide before pasting it.
      Text("Use a Daytona organization just for Serein. A Daytona key reaches every computer in its organization.")
        .font(UIStyle.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
      SettingsHelp(
        text: "Runs on Daytona's servers under your account, as a Linux VM. It may cost money; the first start asks you. Your key stays in this Mac's Keychain.",
        more: "Choose Daytona for an assistant below to run its computer on Daytona's servers under your own account, as a Linux VM; it may cost money there, and the first start asks you. Use a Daytona organization just for Serein. A Daytona key reaches every computer in its organization. Its internet goes through this Mac, which Daytona allows only on its Tiers 3 and 4; on Tiers 1 and 2 Serein refuses that. You can turn on Daytona's own internet for it instead, held to your list of sites, which Daytona also enforces only on its Tiers 3 and 4: Serein reads it back before use, and also checks from inside a new computer that it cannot reach a site off the list. A computer goes onto a list only when it is made with it: Reset one made with another setting. With Only these sites off (it asks you first) Serein can't limit it. Each start, Serein also checks from inside that the computer cannot reach the internet on its own, and does not use it if it can; a snapshot from an older Serein cannot be checked: rebuild it from the folder Show Recipe opens, then Reset the computer. A computer that had Daytona's own internet goes back through this Mac only after a Reset, which makes a new one. Its preview stays closed. Your key stays in this Mac's Keychain and never goes into the computer. What it cost is Daytona's own report when your key may read it, otherwise Serein's estimate. Not on Daytona: memory and processor limits (the snapshot sets them) and adding your saved API tokens to its requests.")
    }
  }
}

/// The person's own computer or VM, reached with their own SSH setup: Connect your own….
private struct OwnPlace: View {
  @Binding var connecting: Bool
  private var noSerein: Bool { RelayController.shared?.relay == nil }

  var body: some View {
    SettingsListRow(
      name: "Your own computer or VM",
      status: noSerein ? "Set up Serein first, then connect a machine." : "A cloud VM, a VM in UTM, Parallels or VMware, a spare Mac or a Linux box, over your own SSH"
    ) {
      SettingsGlyphTile(systemName: "terminal")
    } trailing: {
      Button("Connect…") { connecting = true }.disabled(noSerein)
        .accessibilityLabel("Connect your own computer or VM")
    } live: {
      EmptyView()
    } details: {
      SettingsHelp(text: "Pick an alias from ~/.ssh/config or type user@host. Serein runs your Mac's own ssh: your keys and passphrases stay with ssh and the macOS ssh-agent, and the first connection shows the machine's host key for you to check. \(OwnCard.network)")
    }
  }
}

/// Docker's memory and processor caps and its image (build, rebuild, delete), folded; it opens by
/// itself while the image builds or needs a rebuild.
private struct AdvancedComputerSettings: View {
  let memoryMB: Int
  @Binding var cpus: Int
  @Binding var deletingImage: Bool
  @ObservedObject private var host = ComputerHost.shared
  @State private var open = false
  @Environment(\.palette) var p
  private let memoryChoices = ComputerPolicy.memoryChoices(totalBytes: ProcessInfo.processInfo.physicalMemory)
  private let cpuChoices = ComputerPolicy.cpuChoices(cores: ProcessInfo.processInfo.activeProcessorCount)

  private var shown: Bool { open || host.building || !host.buildLines.isEmpty || (host.imageBuilt && host.imageStale) }
  private var summary: String {
    let image: String = host.imageBuilt ? (host.imageStale ? "image needs a rebuild" : "image built") : "image not built"
    return "\(ComputerSettings.gigabytes(memoryMB)) · \(cpus) processors · \(image)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Docker's memory, processors and image")
          Text(summary).font(UIStyle.meta).foregroundStyle(host.imageBuilt && host.imageStale ? p.warning : p.secondary)
        }
        Spacer()
        DisclosureChevron(open: $open, name: "advanced")
      }
      if shown {
        HStack {
          Text("Memory")
          Spacer()
          // More memory waits for the Widening card (ComputerHost.setMemory); less applies at once.
          SettingsPopUp("Memory for Serein's computer", selection: Binding(get: { memoryMB }, set: { mb in
            let now = ComputerPolicy.memoryMB(totalBytes: ProcessInfo.processInfo.physicalMemory)
            Task { await host.setMemory(mb, key: ComputerPolicy.memoryKey, current: now, which: "Serein's computers on Docker") }
          }), choices: memoryChoices.map { SettingsChoice(value: $0, label: ComputerSettings.gigabytes($0)) }, showsTitle: false)
        }
        HStack {
          Text("Processors")
          Spacer()
          SettingsPopUp("Processors for Serein's computer", selection: $cpus,
            choices: cpuChoices.map { SettingsChoice(value: $0, label: "\($0)") }, showsTitle: false)
        }
        SettingsHelp(
          text: "At most half of this Mac. More memory asks you first. Not used on E2B or Daytona.",
          more: "At most half of this Mac's memory and processors; more memory asks you first. On Docker a change applies the next time a computer is created; delete a computer to apply it to that one. The built-in computer uses these processors and its own memory, from its next start from off. Not on E2B or Daytona: there the size comes from the template or snapshot.")
        Rectangle().fill(p.line).frame(height: 1)
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Docker image")
            if let size = host.imageSize {
              Text("Built · \(Bytes.file(size)) on disk").role(.meta)
            } else {
              Text("Not built · about 1.5 GB on disk, a few hundred MB downloaded, usually 3 to 10 minutes").role(.meta)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          Spacer()
          if host.building {
            Button("Cancel") { host.cancelBuild() }.accessibilityLabel("Cancel the build")
          } else {
            Button(host.imageBuilt ? "Rebuild" : "Build") { host.buildImage() }
              .disabled(host.backendName == nil || host.backendProblem != nil)
              .help(host.backendName == nil ? "Needs Docker" : "Build the image on this Mac from Serein's recipe")
              .accessibilityLabel(host.imageBuilt ? "Rebuild Serein's computer" : "Build Serein's computer")
          }
        }
        if !host.buildLines.isEmpty {
          ScrollViewReader { reader in
            ScrollView {
              VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(host.buildLines.enumerated()), id: \.offset) { line in
                  Text(line.element).font(UIStyle.microMono).foregroundStyle(p.secondary).lineLimit(2).id(line.offset)
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 140)
              .background(p.codePanel, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
              .accessibilityLabel("Build progress")
              .onChange(of: host.buildLines.count) { _, count in reader.scrollTo(max(0, count - 1)) }
          }
        }
        if host.imageBuilt && host.imageStale {
          Text("Rebuild needed: this image was built by another version of Serein, so computers on Docker refuse to start until you press Rebuild. Their home folders and sign-ins stay.")
            .font(UIStyle.micro).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
        }
        SettingsHelp(
          text: "Built on this Mac from Serein's fixed recipe. Nothing pre-built is downloaded.",
          more: "For computers on Docker. Serein builds the image on this Mac from its own recipe: Debian pinned by digest, a small desktop (XFCE) and Chromium at versions pinned for this release of Serein, and Serein's pinned helper. Nothing pre-built is downloaded. After each Serein update, press Rebuild: the pins move with each release. Cancel removes what was built so far.")
        if host.imageBuilt && !host.building {
          // Apart from Build: deleting stops and deletes every computer on Docker, and asks first.
          HStack {
            Spacer()
            Button("Delete Image…") { deletingImage = true }.foregroundStyle(p.danger)
              .accessibilityLabel("Delete the computer's image")
          }
        }
      }
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading).card(p)
  }
}
