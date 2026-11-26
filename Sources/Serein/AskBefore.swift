import SereinCore
import SwiftUI

/// “Serein asks before” as a dial (affectUI Autonomy Dial): Every step, Only risky steps or
/// Proactive as stops, the chosen level's note, then the real actions that level lets Serein do on
/// its own and those it asks about first, judged by the gate itself (`AutonomyDial`). Hard stops
/// carry a lock and never move. Under them every standing yes with its Ask again
/// (`StandingYesList`) and every site rule with its Remove. The same control sits in Settings ›
/// Assistants › Asks first and in the popover every approval card opens. A stop calls
/// RelayController.setLevel, so a freer level still shows its confirmation first.
struct AskBeforeControl: View {
  @ObservedObject var relay: RelayOrchestrator
  let controller: RelayController

  var body: some View {
    let level: ApprovalLevel = relay.level
    VStack(alignment: .leading, spacing: 12) {
      GoalSegments(
        label: "Serein asks before", options: ApprovalLevel.chatChoices.map { ($0, $0.title) },
        selection: Binding(get: { relay.level }, set: { controller.setLevel($0) }))
      Group {
        Text(level.note).role(.meta).fixedSize(horizontal: false, vertical: true)
        AutonomyDialGroups(level: level)
      }
      // The stops' pill glides; the actions change places at once (layout never animates).
      .transaction { $0.animation = nil }
      StandingYesList(relay: relay)
      SiteRuleRows()
    }
    .onChange(of: relay.level) { AccessibilityNotification.Announcement(AutonomyDial.announcement(at: relay.level)).post() }
  }
}

/// The dial's two ends, On its own and Asks first, then Never. Each risk shows as a word before
/// its actions, never as a colour.
private struct AutonomyDialGroups: View {
  let level: ApprovalLevel
  @Environment(\.palette) private var p
  var body: some View {
    let alone: [AutonomyDial.Action] = AutonomyDial.actions(.alone, at: level)
    let asks: [AutonomyDial.Action] = AutonomyDial.actions(.asks, at: level) + AutonomyDial.actions(.alwaysAsks, at: level)
    VStack(alignment: .leading, spacing: 12) {
      group("On its own", alone, empty: "Nothing. Every step waits for you.")
      group("Asks first", asks, empty: nil)
      group("Never, even if you allow it", AutonomyDial.actions(.never, at: level), empty: nil, risk: false)
    }
  }
  @ViewBuilder private func group(_ title: String, _ actions: [AutonomyDial.Action], empty: String?, risk: Bool = true)
    -> some View
  {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).role(.meta).accessibilityAddTraits(.isHeader)
      if actions.isEmpty, let empty {
        Text(empty).font(UIStyle.font(11)).foregroundStyle(p.secondary)
      }
      FlowLayout(spacing: 4) {
        ForEach(ApprovalRisk.allCases, id: \.self) { tier in
          let these: [AutonomyDial.Action] = actions.filter { $0.risk == tier }
          if !these.isEmpty {
            if risk {
              Text(tier.word).font(UIStyle.font(11)).foregroundStyle(p.secondary).frame(height: UIStyle.wide(20))
                .help(tier.why)
            }
            ForEach(these) { chip($0) }
          }
        }
      }
    }
  }
  private func chip(_ action: AutonomyDial.Action) -> some View {
    let locked: Bool = AutonomyDial.locked(action)
    return HStack(spacing: 4) {
      if locked { InterfaceIcon(systemName: "lock", size: 10).foregroundStyle(p.secondary) }
      Text(action.title).font(UIStyle.font(11)).foregroundStyle(p.ink)
    }.padding(.horizontal, 6).frame(height: UIStyle.wide(20))
      .background(p.track, in: Capsule())
      .help(locked ? "The same at every level." : action.risk.why)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(action.title + ", " + action.risk.word + (locked ? ", the same at every level" : ""))
  }
}

/// The sites with a rule of their own (Ask every step or Never), each with Remove, as Settings ›
/// Privacy › Sites Serein treats differently removes it. Rules are added there.
private struct SiteRuleRows: View {
  @ObservedObject private var gates = GateWatch.shared
  @Environment(\.palette) private var p
  var body: some View {
    let rules: [String: SiteRule] = SiteRules.all()
    if !rules.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Sites with their own rule").role(.meta).accessibilityAddTraits(.isHeader)
        ForEach(rules.keys.sorted(), id: \.self) { site in
          HStack(spacing: 8) {
            Text(site + " · " + (rules[site] ?? .normal).label).font(UIStyle.body).foregroundStyle(p.ink)
              .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Remove") {
              SiteRules.set(.normal, for: site)
              SereinPageChip.shared.refresh()
            }.buttonStyle(QuietButton())
              .accessibilityLabel("Remove the rule for \(site)")
          }
        }
      }
    }
  }
}

/// The popover behind an approval card's “Change what Serein asks about”. After a change, it
/// says the card it came from still waits: the new level applies to the next steps.
struct AskBeforePopover: View {
  @ObservedObject var relay: RelayOrchestrator
  let controller: RelayController
  let p: Palette
  @State private var changed = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Serein asks before").font(UIStyle.bodyStrong).foregroundStyle(p.ink)
        .accessibilityAddTraits(.isHeader)
      AskBeforeControl(relay: relay, controller: controller)
      if changed {
        Text(ApprovalCopy.levelChangedNote).role(.meta).fixedSize(horizontal: false, vertical: true)
      }
      Divider().overlay(p.line)
      Text(ApprovalLevel.footnote(killLabel: controller.killLabel)).role(.meta)
        .fixedSize(horizontal: false, vertical: true)
    }.padding(16).frame(width: 320, alignment: .leading)
      .environment(\.palette, p)
      .background(p.panel)
      .onChange(of: relay.level) { changed = true }
      .onAppear { if RelayOrchestrator.previewLevelChanged { changed = true } }
  }
}

/// One approval: what will happen, what follows from it, the Automation line when macOS still has
/// a say, Decline and the primary (Allow or Start), and the link to what Serein asks about. No
/// timeout; the buttons are never disabled. Docked (Serein's chat, `DecisionDock`), the dock draws
/// the card, its source and the question, and the detail reads as facts.
extension RelayOrchestrator.Approval {
  /// macOS itself says no right now: Allow cannot work, so Open System Settings takes its place.
  /// A denial Serein only remembers (the app is closed) keeps Allow.
  var blocked: Bool { automation == .denied && automationLive }
  var risk: ApprovalRisk { ApprovalRisk.of(effect: effect, words: title + " " + button, routine: routine) }
  /// A mail send card's draft, when the person can edit it in place.
  @MainActor var email: EditableEmail? { EmailDrafts.shared.draft(for: self) }
  /// Its yes: a draft Mail could not send as it stands answers nothing until it is fixed.
  @MainActor func allow() {
    guard email?.problem == nil else { return }
    answer(.yes)
  }
}

/// The card's risk as a word in a neutral capsule (affectUI Approval Card's badge), never a
/// colour on the answers. Its help says what the level means.
struct RiskBadge: View {
  let risk: ApprovalRisk
  @Environment(\.palette) private var p
  var body: some View {
    Text(risk.word).font(UIStyle.font(11)).foregroundStyle(p.ink).lineLimit(1)
      .padding(.horizontal, 7).frame(height: 20)
      .background(p.track, in: Capsule())
      .help(risk.why)
      .accessibilityLabel("\(risk.word). \(risk.why)")
  }
}

struct RelayApprovalCard: View {
  let approval: RelayOrchestrator.Approval
  @ObservedObject var relay: RelayOrchestrator
  let controller: RelayController
  let p: Palette
  /// In the ⌥Space bar: Later puts the bar away and the card waits in Serein's chat.
  var later: (() -> Void)?
  var docked = false
  /// Docked: true while a mail draft's field has the keyboard, so the dock's number keys wait.
  @Binding var typing: Bool
  @State private var showLevels: Bool
  @State private var showScript = false

  init(approval: RelayOrchestrator.Approval, relay: RelayOrchestrator, controller: RelayController, p: Palette,
       showLevels: Bool = false, later: (() -> Void)? = nil, docked: Bool = false, typing: Binding<Bool> = .constant(false)) {
    self.approval = approval
    self.relay = relay
    self.controller = controller
    self.p = p
    self.later = later
    self.docked = docked
    _typing = typing
    _showLevels = State(initialValue: showLevels)
    _showScript = State(initialValue: approval.moreOpen)
  }
  private var denied: Bool { approval.automation == .denied }
  private var blocked: Bool { approval.blocked }

  var body: some View {
    let email = approval.email
    // The detail's "To: …" and "Subject: …" lines as rows; a mail draft shows those as fields.
    let preview = ApprovalPreview.split(approval.detail)
    let rows = preview.rows.filter { email == nil || !ApprovalPreview.mailLabels.contains($0.label) }
    VStack(alignment: .leading, spacing: 0) {
      if !docked {
        HStack(alignment: .top, spacing: 10) {
          tile
          VStack(alignment: .leading, spacing: 2) {
            Text(approval.title).font(UIStyle.font(14, weight: .medium)).foregroundStyle(p.ink)
              .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
              Text(approval.app ?? "Serein").font(UIStyle.font(14)).foregroundStyle(p.secondary)
              RiskBadge(risk: approval.risk)
            }
          }.padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
          if showsLevels { levelsButton }
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        if docked {
          HStack(alignment: .top, spacing: 8) {
            // One quiet line: the question above already names the app and the step.
            Text(verbatim: [approval.site, approval.detail].compactMap { $0 }.joined(separator: " · "))
              .font(UIStyle.font(13)).foregroundStyle(p.secondary)
              .fixedSize(horizontal: false, vertical: true).lineLimit(4)
              .frame(maxWidth: .infinity, alignment: .leading)
            if showsLevels { levelsButton }
          }
        } else {
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in fact(row.label, row.value) }
          if !preview.note.isEmpty {
            Text(preview.note).font(UIStyle.font(14)).foregroundStyle(p.ink)
              .fixedSize(horizontal: false, vertical: true).lineLimit(12)
          }
        }
        if let email { EmailDraftFields(email: email, typing: $typing) }
        if let picture = approval.picture {
          // The screenshot the point comes from, with the spot ringed: the question itself.
          Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: PointPicture.width, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.line, lineWidth: UIStyle.hairline))
            .accessibilityLabel(PointClick.pictureLabel)
            .accessibilityAddTraits(.isImage)
        }
        if let app = approval.app,
          let line = ApprovalCopy.automation(approval.automation, app: app, live: approval.automationLive) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            InterfaceIcon(systemName: denied ? "exclamationmark.triangle" : "info.circle", size: 11)
            Text(line).fixedSize(horizontal: false, vertical: true)
          }.font(UIStyle.meta).foregroundStyle(denied ? p.warning : p.secondary)
            .accessibilityElement(children: .combine)
        }
        if let more = approval.more, email == nil {
          // Open from the start, the text is the question itself: shown whole, and scrolled when long.
          if approval.moreOpen {
            Text("Sent exactly as shown:").font(UIStyle.meta).foregroundStyle(p.secondary)
          } else {
            quietLink(showScript ? "Hide \(approval.moreName)" : "Show \(approval.moreName)") { showScript.toggle() }
          }
          if showScript {
            ScrollView {
              Text(verbatim: more).font(UIStyle.monoMeta).foregroundStyle(approval.moreOpen ? p.ink : p.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: approval.moreOpen ? (later == nil ? 240 : 140) : 140)
              .padding(.horizontal, 10).padding(.vertical, 8)
              .background(p.codePanel, in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }.padding(.top, docked ? 0 : 12)
      // The same shape on every card at every width: the answers across the card, then any lasting choice.
      // Docked, the dock shows every answer as a numbered row instead.
      if !docked { buttons.padding(.top, 14) }
      if !docked, showsAlways || showsRoutine {
        VStack(alignment: .leading, spacing: 2) {
          alwaysLink
          routineLink
        }.padding(.top, 8)
      }
    }.padding(docked ? 0 : 16)
      .background(docked ? .clear : p.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(docked ? .clear : p.line, lineWidth: UIStyle.hairline))
      .shadow(color: docked ? .clear : p.shadow(0.088), radius: 4, y: 2)
      .frame(maxWidth: docked ? .infinity : 414, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Serein needs your OK: \(approval.title)")
  }

  private func fact(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label).foregroundStyle(p.secondary).frame(width: 96, alignment: .leading)
      Text(value).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true).lineLimit(12)
    }.font(UIStyle.font(14)).lineSpacing(3)
      .accessibilityElement(children: .combine)
  }

  /// The app asked about, or Serein's mark when the step is Serein's own.
  /// Grok's 44 logo slot. A Mac app icon already has its own tile, so it stands bare.
  private var tile: some View {
    let icon = approval.app.flatMap(Self.appIcon) ?? NSApp.applicationIconImage ?? NSImage()
    return Image(nsImage: icon).resizable().interpolation(.high).frame(width: 44, height: 44)
      .accessibilityHidden(true)
  }
  private static func appIcon(_ name: String) -> NSImage? {
    for folder in ["/System/Applications", "/Applications", "/System/Applications/Utilities"] {
      let path = "\(folder)/\(name).app"
      if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
    }
    return nil
  }
  private func quietLink(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Text(title) }
      .buttonStyle(.pressable).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize()
      .padding(.vertical, 2)
  }

  private var buttons: some View {
    HStack(spacing: 8) {
      if let later {
        Button(action: later) { Text("Later").foregroundStyle(p.secondary) }
          .buttonStyle(PillButton(kind: .quiet)).fixedSize()
          .help("Answer in Serein\u{2019}s chat later. Nothing happens until you do.")
      }
      Button { relay.decline(approval) } label: { grow(approval.decline) }.buttonStyle(PillButton(kind: .tinted))
      if denied {
        // Allowing cannot work until macOS lets Serein control the app; when that is only
        // remembered, the user may have turned it on since, so Allow stays.
        let settings = Button { relay.openAutomationSettings(for: approval.app) } label: { grow("Open System Settings") }
          .help("Privacy & Security \u{203A} Automation. Turn on \(approval.app ?? "the app") under Serein.")
        if blocked { settings.buttonStyle(PillButton(kind: .solid)) } else { settings.buttonStyle(PillButton(kind: .tinted)) }
      }
      if !blocked {
        // A routine step can be allowed for the rest of the task; hard stops only ever get the one yes.
        if let grants = approval.grants, grants.offersTask {
          Button { grants.forTask(); approval.answer(.yes) } label: { grow("For this task") }
            .buttonStyle(PillButton(kind: .tinted))
            .help("Clicks, typing and moving between pages on \(grants.site) go ahead until this task ends. Sending, paying, deleting and forms still ask.")
        }
        Button { approval.allow() } label: { grow(approval.grants == nil ? approval.button : "Allow once") }
          .buttonStyle(PillButton(kind: .solid))
      }
    }
  }
  private func grow(_ title: String) -> some View {
    Text(title).lineLimit(1).frame(maxWidth: .infinity)
  }
  /// The lasting choice, under the answers: routine steps on a site (until removed in Settings ›
  /// Privacy), or a connected app's reads (until turned off in the Marketplace (Your apps, On this Mac)). It never
  /// covers a hard stop.
  private var showsAlways: Bool { approval.grants != nil && !blocked }
  @ViewBuilder private var alwaysLink: some View {
    if let grants = approval.grants, !blocked {
      Button(grants.alwaysTitle ?? "Always allow routine steps on \(grants.site)") { grants.always(); approval.answer(.yes) }
        .buttonStyle(.pressable).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize()
        .help(grants.alwaysHelp ?? "Clicks, typing and moving between pages there go ahead in your tasks. Sending, paying, deleting and forms still ask, and scheduled runs always ask. Take it back with Ask again under Serein asks before.")
    }
  }

  /// Asked only because of Every step: allow this step and stop asking for routine ones, in one
  /// place, after the same confirmation Settings shows. Cancelling leaves the card as it was.
  private var showsLevels: Bool {
    guard !showsRoutine, approval.picture == nil else { return false }
    return approval.button != CurrentPageContext.workHereCard(title: "").button
      && approval.button != BrowserModel.uploadButton
  }
  private var showsRoutine: Bool { approval.routine && !blocked && relay.level == .everyStep }
  @ViewBuilder private var routineLink: some View {
    if showsRoutine {
      Button("Allow, and stop asking for routine steps") {
        controller.setLevel(.riskyOnly)
        if relay.level == .riskyOnly { approval.answer(.yes) }
      }
      .buttonStyle(.pressable).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize()
      .help(ApprovalLevel.riskyOnly.note)
    }
  }

  /// A quiet 28 circle in the head's corner instead of a loose line under the answers.
  private var levelsButton: some View {
    Button { showLevels = true } label: {
      InterfaceIcon(systemName: "slider.horizontal.3", size: 13).foregroundStyle(p.secondary)
        .frame(width: 28, height: 28).contentShape(Circle())
    }
      .buttonStyle(GlyphButtonStyle())
      .help("Change what Serein asks about").accessibilityLabel("Change what Serein asks about")
      .popover(isPresented: $showLevels, arrowEdge: .bottom) {
        AskBeforePopover(relay: relay, controller: controller, p: p)
      }
  }
}

/// One open approval wherever cards show (Serein's chat, the ⌥Space bar, the call view): a
/// proposed team gets its own card, everything else the approval card.
struct ApprovalCardSlot: View {
  let approval: RelayOrchestrator.Approval
  @ObservedObject var relay: RelayOrchestrator
  let controller: RelayController
  let p: Palette
  var showLevels = false
  var later: (() -> Void)? = nil
  var body: some View {
    Group {
      if let draft = approval.proposal {
        // Change… edits the draft in the window's sheet; the card answers with what it held last.
        TeamProposalCard(draft: draft, relay: relay, answer: { approval.answer($0 ? .yes : .no) }, change: {
          SereinRouter.bringWindowForward?()
          TeamSheets.shared.present(.newTeam(.change(approval.id)))
        })
      } else {
        RelayApprovalCard(approval: approval, relay: relay, controller: controller, p: p, showLevels: showLevels, later: later)
      }
    }.environment(\.palette, p)
  }
}

/// An answered approval, folded into one small chip where the turn began, like an answered
/// question's (`AnsweredQuestionChips`): the answer's mark and word, then what was asked. The
/// answer's line (“You declined. Serein will not do it.”) and its time are on hover.
struct RelayAnsweredLine: View {
  let answer: RelayOrchestrator.AnsweredApproval
  let p: Palette
  @ObservedObject private var ends = ApprovalEnds.shared
  var body: some View {
    // A card the person never answered says so: skipped by their next message, or expired.
    let ended = answer.allowed ? nil : ends.ends[answer.id].map(ApprovalLife.line)
    let time = answer.at.formatted(date: .omitted, time: .shortened)
    let line = ended?.why ?? ApprovalCopy.answered(allowed: answer.allowed, at: time, byVoice: answer.byVoice)
    let word = ended?.word ?? (answer.allowed ? "Allowed" : "Declined")
    HStack(spacing: 5) {
      InterfaceIcon(systemName: answer.allowed ? "checkmark" : "xmark", size: 10)
        .foregroundStyle(answer.allowed ? p.success : p.faint)
      Text(word).font(UIStyle.font(12.5, weight: .medium)).foregroundStyle(p.ink).fixedSize()
      Text(answer.title).font(UIStyle.font(12.5)).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
    }
    .padding(.leading, 8).padding(.trailing, 10).frame(height: 26)
    .background(p.track, in: Capsule())
    .frame(maxWidth: AssistantMetrics.cardWide, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(line)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(word): \(answer.title). \(line)")
  }
}

/// Once, before the first routine step that would have asked, for a fresh install given Only
/// risky steps without confirming it (the default since 2026-11-12).
struct RelayConsentCard: View {
  @ObservedObject var relay: RelayOrchestrator
  let p: Palette
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(ApprovalLevel.consentTitle).font(UIStyle.bodyStrong).fixedSize(horizontal: false, vertical: true)
      Text(ApprovalLevel.consentBody).font(UIStyle.meta).foregroundStyle(p.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button(ApprovalLevel.consentAskEvery) { relay.setLevel(.everyStep) }.buttonStyle(QuietButton())
        Button(ApprovalLevel.consentKeep) { relay.setLevel(.riskyOnly) }.buttonStyle(PrimaryButton())
      }
    }.padding(12)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(ApprovalLevel.consentTitle)
  }
}

/// "Can use" chips: one `track` capsule per place, with its icon and word. A dropped place (asked
/// for, but turned off for Serein) is an outlined capsule with the word struck through and a
/// warning triangle. A before-and-after row (an existing team's change) strikes removed chips
/// and outlines added ones in the accent.
struct CanUseChips: View {
  var places: Set<AssistantPlace>
  var dropped: [String] = []
  /// The places before a change, for the before › after row; nil shows the places alone.
  var before: Set<AssistantPlace>? = nil
  @Environment(\.palette) var p
  static func icon(_ place: AssistantPlace) -> String {
    switch place {
    case .web: return "globe"
    case .page: return "doc"
    case .answer: return "bubble.left"
    case .mac: return "macwindow"
    case .project: return "folder"
    case .mail: return "envelope"
    case .messages: return "bubble.left.and.bubble.right"
    case .calendar: return "calendar"
    case .contacts: return "person.crop.circle"
    case .connectedApps: return "square.grid.2x2"
    case .computer: return "desktopcomputer"
    }
  }
  var body: some View {
    let shown = AssistantPlace.allCases.filter(places.contains)
    // The chips wrap onto the next line when the column is narrow.
    FlowLayout(spacing: 4) {
      if let before {
        let old = AssistantPlace.allCases.filter(before.contains)
        ForEach(old, id: \.self) { chip($0.label, icon: Self.icon($0), style: places.contains($0) ? .on : .removed) }
        InterfaceIcon(systemName: "arrow.right", size: 10).foregroundStyle(p.faint).accessibilityHidden(true)
        ForEach(shown, id: \.self) { chip($0.label, icon: Self.icon($0), style: before.contains($0) ? .on : .added) }
      } else {
        if shown.isEmpty && dropped.isEmpty {
          Text("Can use: nothing yet").font(UIStyle.font(11)).foregroundStyle(p.secondary)
        }
        ForEach(shown, id: \.self) { chip($0.label, icon: Self.icon($0), style: .on) }
        ForEach(dropped, id: \.self) { chip($0, icon: nil, style: .dropped) }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }
  private var spoken: String {
    let now = AssistantPlace.words(places)
    if let before { return "Can use: \(AssistantPlace.words(before)), becomes \(now)" }
    let gone = dropped.map { "\($0), left out" }
    return "Can use: " + ([now] + gone).joined(separator: ". ")
  }
  private enum Style { case on, dropped, removed, added }
  private func chip(_ word: String, icon: String?, style: Style) -> some View {
    let border: Color = style == .added ? p.accent : style == .on ? .clear : p.borderStrong
    return HStack(spacing: 4) {
      if let icon, style == .on || style == .added {
        InterfaceIcon(systemName: icon, size: 11).foregroundStyle(p.secondary)
      }
      Text(word).font(UIStyle.font(11)).foregroundStyle(style == .on || style == .added ? p.ink : p.secondary)
        .strikethrough(style == .dropped || style == .removed)
      if style == .dropped {
        InterfaceIcon(systemName: "exclamationmark.triangle", size: 10).foregroundStyle(p.warning)
      }
    }.padding(.horizontal, 6).frame(height: UIStyle.wide(20))
      .background(style == .on ? p.track : .clear, in: Capsule())
      .overlay(Capsule().strokeBorder(border, lineWidth: UIStyle.hairline))
  }
}

/// One member of a proposed team, as the proposal card and the New team sheet show it: the petal,
/// the name, Lead, the persona line, "Can use", the dropped note, and the full instructions.
struct ProposalMemberView: View {
  let member: TeamProposal.Member
  var lead: Bool
  var tint: String?
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        AssistantMark(tint: tint, size: 14, icon: member.icon)
        Text(member.name).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(1)
        if lead {
          Text("Lead").font(UIStyle.micro).foregroundStyle(p.ink).padding(.horizontal, 6).frame(height: 20)
            .background(p.track, in: Capsule())
        }
      }
      if !member.persona.isEmpty {
        Text(member.persona).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }
      CanUseChips(places: member.places, dropped: member.dropped)
      ForEach(member.dropped, id: \.self) { place in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          InterfaceIcon(systemName: "exclamationmark.triangle", size: 10).foregroundStyle(p.warning)
          Text("\(place) was left out. It's off for Serein in ").font(UIStyle.meta).foregroundStyle(p.ink)
            + Text(TeamSheets.settingsPage(label: place).name).font(UIStyle.meta).foregroundStyle(p.accent)
            + Text(".").font(UIStyle.meta).foregroundStyle(p.ink)
        }.fixedSize(horizontal: false, vertical: true)
          .onTapGesture { TeamSheets.openSettings(TeamSheets.settingsPage(label: place)) }
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isButton)
          .accessibilityHint("Opens \(TeamSheets.settingsPage(label: place).name)")
      }
      if !member.instructions.isEmpty {
        Text("Instructions").font(UIStyle.micro).tracking(0.4).foregroundStyle(p.faint)
        Text(verbatim: member.instructions).font(UIStyle.meta).foregroundStyle(p.ink).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
          .padding(8).background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(spoken)
  }
  private var spoken: String {
    var parts = [member.name + (lead ? ", lead" : "")]
    if !member.persona.isEmpty { parts.append(member.persona) }
    parts.append("Can use " + AssistantPlace.words(member.places))
    if !member.instructions.isEmpty { parts.append("Instructions: " + member.instructions) }
    return parts.joined(separator: ". ")
  }
}

/// A proposed team (team_propose in a chat, Describe it, Import file): every member with its
/// full instructions open, because the card is the consent; a Lead menu; Change… (the sheet),
/// Decline and Create team. Stale (the roster changed since) offers only Show the team.
struct TeamProposalCard: View {
  let draft: RelayOrchestrator.TeamProposalDraft
  @ObservedObject var relay: RelayOrchestrator
  /// Create team (true) or Decline (false).
  var answer: (Bool) -> Void
  /// Change…, when the card offers it (not an imported team).
  var change: (() -> Void)? = nil
  /// Create team's words: "Add team" for a starter or an import.
  var createTitle = "Create team"
  @Environment(\.palette) var p
  private var proposal: TeamProposal { draft.proposal }
  private var stale: Bool { relay.team != draft.shown }
  private var tints: [String] { relay.team.nextTints(proposal.members.count) }
  var body: some View {
    let tints = tints
    VStack(alignment: .leading, spacing: 8) {
      Text(draft.imported ? "Add the team “\(proposal.name)”?" : "Create the team “\(proposal.name)”?")
        .font(UIStyle.bodyStrong).fixedSize(horizontal: false, vertical: true)
      if draft.imported {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          InterfaceIcon(systemName: "info.circle", size: 11).foregroundStyle(p.secondary)
          Text("Imported teams start quiet: nobody speaks first and no one can use anything until you turn it on.")
            .font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text("Serein suggests \(proposal.members.count) assistant\(proposal.members.count == 1 ? "" : "s"). Nothing is saved until you create it. Each one can do only what's listed.")
          .font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 12) {
        ForEach(Array(proposal.members.enumerated()), id: \.offset) { index, member in
          ProposalMemberView(member: member, lead: proposal.lead?.caseInsensitiveCompare(member.name) == .orderedSame,
                             tint: tints.indices.contains(index) ? tints[index] : nil)
        }
      }.padding(.top, 4)
      if !stale {
        HStack(spacing: 4) {
          Text("Lead:").font(UIStyle.meta).foregroundStyle(p.secondary)
          Menu {
            Button("No lead") { setLead(nil) }
            ForEach(proposal.members.map(\.name), id: \.self) { name in Button(name) { setLead(name) } }
          } label: {
            Text(proposal.lead ?? "No lead").font(UIStyle.meta).foregroundStyle(p.ink)
          }.menuStyle(.borderlessButton).fixedSize().help("Who answers a message posted to the team")
            .accessibilityLabel("Lead: \(proposal.lead ?? "none")")
        }.padding(.top, 4)
      }
      if stale {
        HStack(spacing: 8) {
          Text("This team changed after Serein suggested this. Ask again to see the latest.")
            .font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("Show the team") {
            NotificationCenter.default.post(name: SidebarModeSwitch.showAssistants, object: nil)
            answer(false)
          }.buttonStyle(QuietButton()).fixedSize()
        }.padding(.top, 2)
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            changeButton
            Spacer(minLength: 0)
            buttons
          }
          VStack(alignment: .leading, spacing: 8) {
            HStack { Spacer(minLength: 0); buttons }
            changeButton
          }
        }.padding(.top, 2)
      }
    }.padding(12)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Serein suggests a team: \(proposal.name), \(proposal.members.count) assistants")
  }
  @ViewBuilder private var changeButton: some View {
    if let change {
      Button("Change…", action: change).buttonStyle(QuietButton()).fixedSize().padding(.leading, -6)
        .help("Edit the members, what each can use and their instructions before creating the team")
    }
  }
  private var buttons: some View {
    HStack(spacing: 8) {
      Button("Decline") { answer(false) }.buttonStyle(QuietButton())
      Button(createTitle) { answer(true) }.buttonStyle(PrimaryButton())
    }.fixedSize()
  }
  private func setLead(_ name: String?) {
    draft.proposal.lead = name
    relay.objectWillChange.send()
  }
}

