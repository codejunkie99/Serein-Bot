import AppKit
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

/// The New team sheet: six starters and four other ways in (Describe it, Blank, Duplicate, Import
/// file), each a push inside the sheet. Presented from New team… (sidebar, Settings), a starter
/// row, File › New Team… and a proposal card's Change…. Nothing is saved before Add team or
/// Create team; every save goes through `changeTeam` (journaled, with Undo on its toast).
/// Describe it runs one turn of the person's own AI app, the same `team_propose` card path.
struct NewTeamSheet: View {
  let start: TeamSheets.Start
  var body: some View {
    if let relay = SereinSurface.controller?.relay {
      NewTeamSheetBody(relay: relay, page: Page(start))
    } else {
      SereinUnavailable().frame(width: 560, height: 200)
    }
  }
  enum Page: Equatable {
    case home
    case starter(TeamStarter)
    case describe
    case blank
    case change(UUID)
    case duplicate(String?)
    case importFile
    /// The page as one word, so a push replaces the view and animates.
    var key: String {
      switch self {
      case .home: return "home"
      case .starter(let starter): return "starter:" + starter.id
      case .describe: return "describe"
      case .blank: return "blank"
      case .change(let id): return "change:" + id.uuidString
      case .duplicate(let id): return "duplicate:" + (id ?? "")
      case .importFile: return "import"
      }
    }
    init(_ start: TeamSheets.Start) {
      switch start {
      case .home: self = .home
      case .starter(let id): self = TeamStarter.all.first { $0.id == id }.map(Page.starter) ?? .home
      case .blank: self = .blank
      case .duplicate(let id): self = .duplicate(id)
      case .describe: self = .describe
      case .importFile: self = .importFile
      case .change(let id): self = .change(id)
      }
    }
  }
}

private struct NewTeamSheetBody: View {
  @ObservedObject var relay: RelayOrchestrator
  @State var page: NewTeamSheet.Page
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  private var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  var body: some View {
    Group {
      switch page {
      case .home: NewTeamHome(relay: relay, page: $page)
      case .starter(let starter): StarterDetail(relay: relay, starter: starter, back: { push(.home) })
      case .describe: DescribeTeam(relay: relay, back: { push(.home) }, blank: { push(.blank) })
      case .blank: BlankTeam(relay: relay, draft: nil, back: { push(.home) })
      case .change(let id):
        if let approval = relay.approvals.first(where: { $0.id == id }), let draft = approval.proposal {
          BlankTeam(relay: relay, draft: (draft, approval), back: { TeamSheets.shared.dismiss() })
        } else {
          SheetFrame(title: "New team", back: nil, footer: { Button("Cancel") { TeamSheets.shared.dismiss() }.buttonStyle(QuietButton()) }) {
            Text("That suggestion is no longer open.").role(.meta)
          }
        }
      case .duplicate(let id): DuplicateTeam(relay: relay, chosen: id, back: { push(.home) })
      case .importFile: ImportTeam(relay: relay, back: { push(.home) })
      }
    }
    .id(page.key)
    .transition(reduceMotion ? .identity : .asymmetric(
      insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: page.key)
    .frame(width: 560)
    .frame(maxHeight: 600)
    .background(p.raised)
    .environment(\.palette, p)
  }
  private func push(_ next: NewTeamSheet.Page) {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { page = next }
  }
}

/// A fixed header (a title, or "‹ New team" over it), a scrolling body and a fixed footer.
struct SheetFrame<Content: View, Footer: View>: View {
  var title: String
  var subtitle: String? = nil
  var back: (() -> Void)?
  var backTitle = "‹ New team"
  @ViewBuilder var footer: () -> Footer
  @ViewBuilder var content: () -> Content
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        if let back {
          Button(action: back) { Text(backTitle).font(UIStyle.meta).foregroundStyle(p.secondary) }
            .buttonStyle(.pressable).keyboardShortcut("[", modifiers: .command)
            .accessibilityLabel("Back")
        }
        Text(title).role(.title).lineLimit(1).accessibilityAddTraits(.isHeader)
        if let subtitle { Text(subtitle).role(.meta) }
      }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
      ScrollView {
        VStack(alignment: .leading, spacing: 16, content: content).padding(.horizontal, 24).padding(.bottom, 16)
          .frame(maxWidth: .infinity, alignment: .leading)
      }.scrollBounceBehavior(.basedOnSize)
      Rectangle().fill(p.line).frame(height: 1)
      HStack(spacing: 8) { footer() }.padding(.horizontal, 24).frame(height: 52)
    }
  }
}

/// The caption over a group in the sheet (the settings caption).
private struct SheetCaption: View {
  var text: String
  @Environment(\.palette) var p
  var body: some View {
    Text(text.uppercased()).font(UIStyle.micro).tracking(0.4).foregroundStyle(p.faint)
      .accessibilityLabel(text).accessibilityAddTraits(.isHeader)
  }
}

private struct NewTeamHome: View {
  @ObservedObject var relay: RelayOrchestrator
  @Binding var page: NewTeamSheet.Page
  @Environment(\.palette) var p
  private var starters: [TeamStarter] { TeamStarter.offered(person: relay.personPlaces) }
  var body: some View {
    SheetFrame(title: "New team", subtitle: "Pick a starter, or make your own.", back: nil, footer: {
      Spacer(minLength: 0)
      Button("Cancel") { TeamSheets.shared.dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
    }) {
      SheetCaption(text: "Starters").padding(.top, 8)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
        ForEach(starters) { starter in StarterCard(starter: starter) { page = .starter(starter) } }
      }
      SheetCaption(text: "Or").padding(.top, 4)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
        tile("Describe it", icon: "square.and.pencil", label: "Describe it: Serein suggests a team") { page = .describe }
        tile("Blank", icon: "plus", label: "Blank team") { page = .blank }
        tile("Duplicate", icon: "doc.on.doc", label: "Duplicate a team", disabled: relay.team.teams.isEmpty,
             help: relay.team.teams.isEmpty ? "No team to copy yet." : "Copy a team") { page = .duplicate(nil) }
        tile("Import file", icon: "arrow.down", label: "Import a team file") { page = .importFile }
      }
    }
  }
  private func tile(_ word: String, icon: String, label: String, disabled: Bool = false, help: String? = nil,
                    action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 6) {
        InterfaceIcon(systemName: icon, size: 16).foregroundStyle(p.secondary)
        Text(word).font(UIStyle.meta).foregroundStyle(p.ink)
      }.frame(maxWidth: .infinity).frame(height: 56).contentShape(Rectangle())
        .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
    }.buttonStyle(.pressable).hoverWash(in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .disabled(disabled).opacity(disabled ? 0.4 : 1)
      .help(help ?? word).accessibilityLabel(label)
  }
}

/// One starter: overlapping petals and the team name, its members, and one line on what it does.
/// Also the Marketplace's Teams page.
struct StarterCard: View {
  let starter: TeamStarter
  var open: () -> Void
  @State private var hovered = false
  @Environment(\.palette) var p
  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          ZStack(alignment: .leading) {
            ForEach(Array(starter.members.enumerated()), id: \.offset) { index, member in
              AssistantMark(tint: member.colour, size: 14).offset(x: CGFloat(index) * 9)
            }
          }.frame(width: 14 + CGFloat(max(0, starter.members.count - 1)) * 9, height: 14, alignment: .leading)
          Text(starter.name).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(1)
        }
        Text(starter.members.map(\.name).joined(separator: " · ")).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1)
        Text(starter.line).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }.padding(12).frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading).contentShape(Rectangle())
        .background(hovered ? p.hover : p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: UIStyle.panelRadius).strokeBorder(hovered ? p.borderStrong : p.line, lineWidth: UIStyle.hairline))
    }.buttonStyle(.pressable).onHover { hovered = $0 }
      .accessibilityLabel("\(starter.name). \(starter.members.map(\.name).joined(separator: " and ")). \(starter.line)")
      .accessibilityHint("Shows the team before you add it")
  }
}

/// A starter before it is added: an editable name, the members with what each may use (places
/// the person turned off are dropped and said so) and their full instructions; Add team.
private struct StarterDetail: View {
  @ObservedObject var relay: RelayOrchestrator
  let starter: TeamStarter
  var back: () -> Void
  @State private var name = ""
  @State private var error: String?
  @Environment(\.palette) var p
  private var proposal: TeamProposal {
    var made = starter.proposal(person: relay.personPlaces, team: relay.team)
    if !name.isEmpty { made.name = name }
    return made
  }
  var body: some View {
    let proposal = proposal
    SheetFrame(title: "", back: back, footer: {
      if let error { Text(error).font(UIStyle.meta).foregroundStyle(p.danger).lineLimit(2) }
      Spacer(minLength: 0)
      Button("Cancel") { TeamSheets.shared.dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
      Button("Add team") { add(proposal) }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
    }) {
      TextField("Team name", text: $name, prompt: Text(proposal.name)).textFieldStyle(.plain).font(UIStyle.title)
        .foregroundStyle(p.ink).padding(.top, -12)
        .onChange(of: name) { _, value in if value.count > AssistantGroup.nameLimit { name = String(value.prefix(AssistantGroup.nameLimit)) } }
        .accessibilityLabel("Team name")
      Text("Each assistant can do only what's listed. You can change this later.").role(.meta)
      // The tints the new assistants will get (the next free ones), not the starter's suggestions.
      let tints = relay.team.nextTints(proposal.members.count)
      VStack(alignment: .leading, spacing: 12) {
        ForEach(Array(proposal.members.enumerated()), id: \.offset) { index, member in
          ProposalMemberView(member: member, lead: index == 0, tint: tints.indices.contains(index) ? tints[index] : nil)
        }
      }
    }
  }
  private func add(_ proposal: TeamProposal) {
    guard !relay.working else { error = "\(relay.team.activeName) is still replying. Try again when it is done."; return }
    if let why = relay.createTeam(fromSheet: proposal) { error = why; return }
    NotificationCenter.default.post(name: SidebarModeSwitch.showAssistants, object: nil)
    if let made = relay.team.teams.last { AssistantSidebarState.shared.folded.remove(made.id) }
    TeamSheets.shared.dismiss()
  }
}

/// Describe the team: the words go to Serein as one turn of the person's own AI app, which
/// makes a team with team_propose (its tool description steers the call), with no card; the
/// sheet closes on the new team.
private struct DescribeTeam: View {
  @ObservedObject var relay: RelayOrchestrator
  var back: () -> Void
  var blank: () -> Void
  @State private var words = ""
  @State private var sentAt: Date?
  @State private var sawCard = false
  @Environment(\.palette) var p
  private var card: RelayOrchestrator.Approval? {
    guard let sentAt else { return nil }
    return relay.approvals.first { $0.proposal != nil && $0.askedAt >= sentAt }
  }
  private var failed: Bool { sentAt != nil && !relay.working && card == nil && !sawCard }
  var body: some View {
    let card = card
    SheetFrame(title: card == nil ? "Describe the team" : "Create the team", back: card == nil ? back : { sentAt = nil; sawCard = false },
               backTitle: card == nil ? "‹ New team" : "‹ Edit description", footer: {
      Spacer(minLength: 0)
      if card == nil {
        if sentAt != nil, relay.working {
          Button("Stop") { relay.stopReply(); sentAt = nil }.buttonStyle(QuietButton())
          Button {} label: {
            HStack(spacing: 6) {
              ProgressView().controlSize(.mini)
              Text("Suggesting…")
            }
          }.buttonStyle(PrimaryButton()).disabled(true).accessibilityLabel("Suggesting a team")
        } else {
          Button("Cancel") { TeamSheets.shared.dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
          Button("Suggest a team", action: suggest).buttonStyle(PrimaryButton())
            .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || relay.working)
            .keyboardShortcut(.return, modifiers: .command)
        }
      }
    }) {
      if let card, let draft = card.proposal {
        TeamProposalCard(draft: draft, relay: relay, answer: { yes in
          card.answer(yes ? .yes : .no)
          TeamSheets.shared.dismiss()
        }, change: { TeamSheets.shared.present(.newTeam(.change(card.id))) })
          .onAppear { sawCard = true }
      } else {
        TextField("What should the team do? For example: plan a trip, find options, compare prices, book the best one.",
                  text: $words, axis: .vertical)
          .textFieldStyle(.plain).font(UIStyle.font(14)).lineLimit(3...6).foregroundStyle(p.ink)
          .padding(10).background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
          .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
          .disabled(sentAt != nil && relay.working)
          .accessibilityLabel("What should the team do?")
        Text("Serein suggests assistants and what each may use. Nothing is saved until you create it.").role(.meta)
        if failed {
          VStack(alignment: .leading, spacing: 6) {
            Text("Serein couldn't suggest a team. Try again, or start blank.").font(UIStyle.meta).foregroundStyle(p.danger)
            HStack(spacing: 12) {
              Button("Try again", action: suggest).buttonStyle(.pressable).font(UIStyle.metaStrong).foregroundStyle(p.accent)
              Button("Start blank", action: blank).buttonStyle(.pressable).font(UIStyle.metaStrong).foregroundStyle(p.accent)
            }
          }
        }
      }
    }
    // The card answered elsewhere (in the chat): the sheet has nothing left to show.
    .onChange(of: relay.approvals.count) { _, _ in if sawCard, self.card == nil { TeamSheets.shared.dismiss() } }
    .onChange(of: relay.team.teams.count) { old, new in
      guard sentAt != nil, new > old else { return }
      NotificationCenter.default.post(name: SidebarModeSwitch.showAssistants, object: nil)
      TeamSheets.shared.dismiss()
    }
  }
  private func suggest() {
    let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !relay.working else { return }
    sawCard = false
    sentAt = Date()
    relay.ask("Suggest a team of assistants for this, so I can create it: " + text)
  }
}

/// Blank: a name, the assistants to include (or a new one, inline), the lead, Create team. The
/// same view edits a proposal from Change… on a card: every member's name, persona, places and
/// instructions, and its Create answers the card.
private struct BlankTeam: View {
  @ObservedObject var relay: RelayOrchestrator
  /// Change…: the card's draft and the card itself.
  let draft: (RelayOrchestrator.TeamProposalDraft, RelayOrchestrator.Approval)?
  var back: () -> Void
  @State private var name = ""
  @State private var members: Set<String> = []
  @State private var lead: String?
  @State private var naming = false
  @State private var newName = ""
  @State private var error: String?
  /// Change…: each member with a stable id, so Remove never leaves a binding on a gone index,
  /// and the lead by that id, so a rename keeps it.
  struct EditedMember: Identifiable {
    let id = UUID()
    var member: TeamProposal.Member
  }
  @State private var edited: [EditedMember] = []
  @State private var editedLead: UUID?
  @Environment(\.palette) var p
  private var editing: Bool { draft != nil }
  private var nameTaken: Bool {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return relay.team.teams.contains { $0.name.caseInsensitiveCompare(clean) == .orderedSame }
  }
  private var canCreate: Bool {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return !clean.isEmpty && !nameTaken && (editing ? !edited.isEmpty : !members.isEmpty)
  }
  var body: some View {
    SheetFrame(title: editing ? "Change the team" : "New team", back: back, footer: {
      if let error { Text(error).font(UIStyle.meta).foregroundStyle(p.danger).lineLimit(2) }
      Spacer(minLength: 0)
      Button("Cancel") { TeamSheets.shared.dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
      Button("Create team", action: create).buttonStyle(PrimaryButton()).disabled(!canCreate)
        .keyboardShortcut(.return, modifiers: .command)
    }) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Name").font(UIStyle.meta).foregroundStyle(p.secondary)
        TextField("Trip planner", text: $name).textFieldStyle(.serein).accessibilityLabel("Team name")
          .onChange(of: name) { _, value in if value.count > AssistantGroup.nameLimit { name = String(value.prefix(AssistantGroup.nameLimit)) } }
        if nameTaken {
          Text("Another team is called \(name.trimmingCharacters(in: .whitespacesAndNewlines)).").font(UIStyle.micro).foregroundStyle(p.danger)
        }
      }
      if editing { editedMembers } else { memberList }
      HStack(spacing: 6) {
        Text("Lead").font(UIStyle.meta).foregroundStyle(p.secondary)
        if editing {
          Menu {
            Button("No lead") { editedLead = nil }
            ForEach(edited) { row in Button(row.member.name) { editedLead = row.id } }
          } label: {
            Text(edited.first { $0.id == editedLead }?.member.name ?? "No lead").font(UIStyle.meta).foregroundStyle(p.ink)
          }.menuStyle(.borderlessButton).fixedSize()
        } else {
          Menu {
            Button("No lead") { lead = nil }
            ForEach(relay.team.profiles.filter { members.contains($0.id) }) { profile in Button(profile.name) { lead = profile.id } }
          } label: { Text(lead.map(relay.profileName) ?? "No lead").font(UIStyle.meta).foregroundStyle(p.ink) }
            .menuStyle(.borderlessButton).fixedSize()
        }
      }
    }
    .onAppear {
      guard let pair = draft else { return }
      name = pair.0.proposal.name
      edited = pair.0.proposal.members.map { EditedMember(member: $0) }
      editedLead = pair.0.proposal.lead.flatMap { lead in
        edited.first { $0.member.name.caseInsensitiveCompare(lead) == .orderedSame }?.id
      }
    }
    .onChange(of: members) { _, now in
      if let lead, !now.contains(lead) { self.lead = nil }
      if lead == nil, let first = relay.team.profiles.first(where: { now.contains($0.id) }) { lead = first.id }
    }
  }
  private var memberList: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Members").font(UIStyle.meta).foregroundStyle(p.secondary)
        Spacer(minLength: 0)
        Text("\(members.count)").font(UIStyle.microMono).foregroundStyle(p.faint)
      }
      ForEach(relay.team.profiles) { profile in
        let on = members.contains(profile.id)
        Toggle(isOn: Binding(get: { on }, set: { if $0 { members.insert(profile.id) } else { members.remove(profile.id) } })) {
          HStack(spacing: 8) {
            AssistantMark(profile: profile, size: 16)
            Text(profile.name).font(UIStyle.body).foregroundStyle(p.ink)
            let teams = relay.team.groups(of: profile.id).map(\.name)
            if !teams.isEmpty { Text(teams.joined(separator: ", ")).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1) }
          }
        }.toggleStyle(.checkbox).frame(height: 30)
          .help(profile.name)
      }
      if naming {
        HStack(spacing: 8) {
          AssistantMark(tint: AssistantColour.next(used: relay.team.profiles.map(\.colour)), size: 16)
          TextField("Name", text: $newName).textFieldStyle(.plain).font(UIStyle.body)
            .onSubmit(addAssistant).onExitCommand { naming = false; newName = "" }
            .accessibilityLabel("New Serein's name")
        }.frame(height: 30).padding(.horizontal, 6).background(p.hover, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      } else {
        Button { naming = true } label: {
          HStack(spacing: 8) {
            InterfaceIcon(systemName: "plus", size: 12).foregroundStyle(p.secondary)
            Text("New Serein").font(UIStyle.body).foregroundStyle(p.ink)
          }.frame(height: 30)
        }.buttonStyle(.pressable)
          .help("Add a new Serein to this team")
      }
    }
  }
  /// Change…: each member's name, persona, places as toggles and instructions, editable.
  private var editedMembers: some View {
    let tints = relay.team.nextTints(edited.count)
    return VStack(alignment: .leading, spacing: 12) {
      Text("Members").font(UIStyle.meta).foregroundStyle(p.secondary)
      ForEach($edited) { $row in
        let index = edited.firstIndex { $0.id == row.id } ?? 0
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            AssistantMark(tint: tints.indices.contains(index) ? tints[index] : nil, size: 14, icon: row.member.icon)
            TextField("Name", text: $row.member.name).textFieldStyle(.serein).frame(maxWidth: 220)
              .accessibilityLabel("Member name")
            Spacer(minLength: 0)
            Button("Remove") { remove(row.id) }.buttonStyle(QuietButton()).font(UIStyle.meta)
              .accessibilityLabel("Remove \(row.member.name)")
          }
          TextField("What it does (one line)", text: $row.member.persona).textFieldStyle(.serein)
            .accessibilityLabel("What \(row.member.name) does")
          HStack(spacing: 10) {
            ForEach(AssistantPlace.allCases, id: \.self) { place in
              let allowed = relay.personPlaces.contains(place)
              Toggle(place.label, isOn: Binding(
                get: { row.member.places.contains(place) },
                set: { if $0 { row.member.places.insert(place) } else { row.member.places.remove(place) } }
              )).toggleStyle(.checkbox).font(UIStyle.meta).disabled(!allowed).opacity(allowed ? 1 : 0.45)
                .help(allowed ? "\(row.member.name) can use \(place.label)" : "Off for Serein. Turn it on in \(TeamSheets.settingsPage(place).name).")
            }
          }
          TextField("Instructions", text: $row.member.instructions, axis: .vertical).textFieldStyle(.serein).lineLimit(2...8)
            .accessibilityLabel("\(row.member.name)'s instructions")
        }.padding(10).background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      }
    }
  }
  private func remove(_ id: UUID) {
    edited.removeAll { $0.id == id }
    if editedLead == id { editedLead = nil }
  }
  private func addAssistant() {
    let clean = RelayProfile.cleanName(newName)
    guard !clean.isEmpty else { naming = false; return }
    guard let made = relay.addAssistant(named: clean) else {
      error = relay.team.profiles.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame })
        ? "Another assistant is called \(clean)." : "\(clean) wasn't made. Try again when the reply is done."
      return
    }
    error = nil
    newName = ""
    naming = false
    members.insert(made.id)
  }
  private func create() {
    error = nil
    if let pair = draft {
      // The edited words go through the same checks a proposal does, then the card's Create.
      let proposal = TeamProposal(name: name, members: edited.map { row in
        var clean = row.member
        clean.dropped = []
        return clean
      }, lead: edited.first { $0.id == editedLead }?.member.name)
      do {
        let checked = try TeamProposal.parse(proposal.arguments, person: relay.personPlaces, team: pair.0.shown)
        pair.0.proposal = checked
        pair.1.answer(.yes)
        TeamSheets.shared.dismiss()
      } catch {
        self.error = error.localizedDescription
      }
      return
    }
    let order = relay.team.profiles.map(\.id).filter(members.contains)
    guard relay.createTeam(named: name, members: order, lead: lead) else {
      error = "The team could not be made. Check its name and members."
      return
    }
    NotificationCenter.default.post(name: SidebarModeSwitch.showAssistants, object: nil)
    TeamSheets.shared.dismiss()
  }
}

/// Duplicate: a team to copy, whether its assistants are copied too ("Scout copy", never wider),
/// and the copy's name.
private struct DuplicateTeam: View {
  @ObservedObject var relay: RelayOrchestrator
  @State var chosen: String?
  var back: () -> Void
  @State private var copyMembers = false
  @State private var name = ""
  @State private var error: String?
  @Environment(\.palette) var p
  private var group: AssistantGroup? { chosen.flatMap(relay.team.group) }
  var body: some View {
    SheetFrame(title: "Duplicate a team", back: back, footer: {
      if let error { Text(error).font(UIStyle.meta).foregroundStyle(p.danger).lineLimit(2) }
      Spacer(minLength: 0)
      Button("Cancel") { TeamSheets.shared.dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
      Button("Duplicate", action: duplicate).buttonStyle(PrimaryButton())
        .disabled(group == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
        .keyboardShortcut(.defaultAction)
    }) {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(relay.team.teams) { team in
          Button { choose(team) } label: {
            HStack(spacing: 10) {
              ZStack(alignment: .leading) {
                ForEach(Array(team.memberIDs.prefix(3).enumerated()), id: \.offset) { index, id in
                  AssistantMark(profile: relay.team.profiles.first { $0.id == id }, size: 12).offset(x: CGFloat(index) * 7)
                }
              }.frame(width: 26, height: 16, alignment: .leading)
              Text(team.name).font(UIStyle.body).foregroundStyle(p.ink).lineLimit(1)
              Spacer(minLength: 4)
              Text("\(team.memberIDs.count) assistant\(team.memberIDs.count == 1 ? "" : "s")").font(UIStyle.meta).foregroundStyle(p.secondary)
              if chosen == team.id { InterfaceIcon(systemName: "checkmark", size: 11).foregroundStyle(p.ink) }
            }.padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
              .background(chosen == team.id ? p.selected : .clear, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
          }.buttonStyle(.pressable).hoverWash(in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
            .accessibilityAddTraits(chosen == team.id ? .isSelected : [])
        }
      }
      if group != nil {
        Toggle("Also copy its assistants", isOn: $copyMembers).toggleStyle(SettingsToggleStyle())
        Text("Copies are named “Scout copy” and can do the same, never more.").role(.meta)
        VStack(alignment: .leading, spacing: 4) {
          Text("Name").font(UIStyle.meta).foregroundStyle(p.secondary)
          TextField("Trip planner copy", text: $name).textFieldStyle(.serein).accessibilityLabel("The copy's name")
        }
      }
    }
    .onAppear { if let group { name = "\(group.name) copy" } }
  }
  private func choose(_ team: AssistantGroup) {
    chosen = team.id
    name = "\(team.name) copy"
    error = nil
  }
  private func duplicate() {
    guard let group else { return }
    guard relay.duplicateTeam(group.id, as: name.trimmingCharacters(in: .whitespacesAndNewlines), copyingMembers: copyMembers) else {
      error = "Another team is called \(name.trimmingCharacters(in: .whitespacesAndNewlines))."
      return
    }
    NotificationCenter.default.post(name: SidebarModeSwitch.showAssistants, object: nil)
    TeamSheets.shared.dismiss()
  }
}

/// Import file: the open panel, then the file as a proposal card that starts quiet (nobody speaks
/// first, nothing allowed yet), what the export left out, and Add team. A file Serein cannot read
/// creates nothing.
private struct ImportTeam: View {
  @ObservedObject var relay: RelayOrchestrator
  var back: () -> Void
  @State private var draft: RelayOrchestrator.TeamProposalDraft?
  @State private var failure: String?
  @State private var leftOutOpen = false
  @State private var asked = false
  @Environment(\.palette) var p
  var body: some View {
    SheetFrame(title: "Import a team", back: back, footer: {
      Spacer(minLength: 0)
      Button("Cancel") { TeamSheets.shared.dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
      if draft == nil { Button("Choose a file…", action: choose).buttonStyle(PrimaryButton()) }
    }) {
      if let draft {
        TeamProposalCard(draft: draft, relay: relay, answer: { yes in
          if yes {
            if let why = relay.createTeam(fromSheet: draft.proposal) { failure = why; return }
            NotificationCenter.default.post(name: SidebarModeSwitch.showAssistants, object: nil)
          }
          TeamSheets.shared.dismiss()
        }, createTitle: "Add team")
        DisclosureGroup("Left out of the file", isExpanded: $leftOutOpen) {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(TeamFile.stripped, id: \.self) { Text($0).font(UIStyle.meta).foregroundStyle(p.secondary) }
          }.padding(.top, 4)
        }.font(UIStyle.meta).foregroundStyle(p.ink)
      } else {
        Text("Choose a team file (.serein-team or .json). Serein reads only its names, emoji or symbol icons, instructions and Never sites.")
          .role(.meta)
      }
      if let failure { Text(failure).font(UIStyle.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true) }
    }
    .onAppear { if !asked { asked = true; choose() } }
  }
  private func choose() {
    guard !RunMode.automated else { return }
    let panel = NSOpenPanel()
    panel.title = "Import a team"
    panel.allowedContentTypes = TeamFile.fileTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    // The size first: a file over the limit is never read into memory.
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
    guard size <= TeamFile.maxBytes else {
      draft = nil
      failure = "This file isn't a team Serein can read."
      return
    }
    do {
      let data = try Data(contentsOf: url)
      let proposal = try TeamFile.proposal(from: data, team: relay.team)
      draft = RelayOrchestrator.TeamProposalDraft(proposal: proposal, shown: relay.team, imported: true)
      failure = nil
    } catch {
      draft = nil
      failure = "This file isn't a team Serein can read."
    }
  }
}
