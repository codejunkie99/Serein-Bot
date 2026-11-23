import SereinCore
import SwiftUI

/// One member's picture in a team: Serein's drawn hologram mark, anyone else's mark, on a disc so
/// overlapping pictures stay apart.
struct TeamFace: View {
  let profile: RelayProfile
  let size: CGFloat
  @Environment(\.palette) private var p
  var body: some View {
    ZStack {
      Circle().fill(p.raised)
      if profile.id == RelayTeam.mainID {
        SereinHologramMark(size: size * 0.8)
      } else {
        AssistantMark(profile: profile, size: size * 0.8)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// A team's picture: its members overlapping, the lead in front (`TeamFaces`), with a count of any
/// others. `ground` is what it sits on, for the ring that parts the pictures.
struct TeamFaceStack: View {
  @ObservedObject var relay: RelayOrchestrator
  let group: AssistantGroup
  let size: CGFloat
  let ground: Color
  var limit = TeamFaces.limit
  /// Draws the count of the members past `limit`.
  var counts = true
  @Environment(\.palette) private var p
  private static let overlap: CGFloat = 0.32

  var body: some View {
    let stack = TeamFaces.stack(group, known: Set(relay.team.profiles.map(\.id)), limit: limit)
    let members = stack.ids.compactMap { id in relay.team.profiles.first { $0.id == id } }
    HStack(spacing: -size * Self.overlap) {
      ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
        ringed(TeamFace(profile: member, size: size)).zIndex(Double(members.count - index))
      }
      if counts, stack.more > 0 {
        ringed(
          Text(verbatim: "+\(stack.more)").font(UIStyle.font(size * 0.34, weight: .medium)).foregroundStyle(p.secondary)
            .frame(width: size, height: size).background(p.track, in: Circle()))
      }
    }
    .accessibilityHidden(true)
  }

  private func ringed<Face: View>(_ face: Face) -> some View {
    face.overlay(Circle().strokeBorder(ground, lineWidth: max(1.5, size * 0.05)))
  }
}

/// The right panel's Details in a team chat: the team and its members, the lead first. A member
/// opens its own chat, as a contact does in a group's details.
struct InspectorTeam: View {
  @ObservedObject var relay: RelayOrchestrator
  let group: AssistantGroup
  @Environment(\.palette) private var p

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        TeamFaceStack(relay: relay, group: group, size: 40, ground: p.background)
        Text(verbatim: group.name).font(UIStyle.font(17, weight: .medium)).foregroundStyle(p.ink)
          .lineLimit(1).truncationMode(.tail).accessibilityAddTraits(.isHeader)
          .frame(maxWidth: .infinity, alignment: .leading)
        Menu {
          TeamMenuItems(relay: relay, group: group) { AssistantConfirm.renameTeam(relay, group) }
        } label: {
          InterfaceIcon(systemName: "ellipsis", size: 14).foregroundStyle(p.secondary)
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Change \(group.name)").accessibilityLabel("More for \(group.name)")
      }
      VStack(alignment: .leading, spacing: 2) {
        ForEach(members) { member in row(member) }
      }
    }
  }

  private var members: [RelayProfile] {
    TeamFaces.ordered(group, known: Set(relay.team.profiles.map(\.id))).compactMap { id in
      relay.team.profiles.first { $0.id == id }
    }
  }

  private func row(_ member: RelayProfile) -> some View {
    let lead: Bool = group.leadID == member.id
    return Button {
      _ = relay.openAssistant(member.id)
    } label: {
      HStack(spacing: 10) {
        TeamFace(profile: member, size: 32)
        Text(verbatim: member.name).font(AssistantType.name).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        if lead { Text("Lead").font(AssistantType.meta).foregroundStyle(p.secondary) }
      }
      .padding(.vertical, 6).contentShape(Rectangle())
    }
    .buttonStyle(AssistantPressStyle())
    .help("Open \(member.name)'s chat")
    .accessibilityLabel(lead ? "\(member.name), lead" : member.name)
    .accessibilityHint("Opens its chat")
    .contextMenu {
      Button("Settings…") { AssistantSettingsKey.open(member.id) }
    }
  }
}
