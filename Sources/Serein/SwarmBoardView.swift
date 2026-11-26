import SereinCore
import SwiftUI

/// The chat's line for a swarm ("Created a swarm of 12 bots, 5 done"). The count comes from the
/// board, live or saved; pressing it opens the board over the chat.
struct SwarmCountLine: View {
  let message: AgentMessage
  let link: SwarmLink
  let library: Library
  @ObservedObject private var boards = SwarmBoards.shared
  @Environment(\.palette) private var p
  var body: some View {
    let line: String = boards.board(link, library: library)?.countLine ?? message.line ?? ""
    Button {
      boards.open = link
    } label: {
      HStack(spacing: 6) {
        InterfaceIcon(systemName: "circle.grid.3x3", size: 10)
        Text(verbatim: line)
        InterfaceIcon(systemName: "chevron.right", size: 9)
      }
      .font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
      .padding(.vertical, 6).padding(.horizontal, 12)
      .background(p.track, in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(AssistantPressStyle())
    .frame(maxWidth: .infinity)
    .accessibilityLabel(line)
    .accessibilityHint("Opens the swarm board")
  }
}

/// One swarm's board over the chat (docs/demos/swarm-board.decision.md, layout A): the start tree
/// with each bot's state on the left, every message in order on the right, and a box that speaks
/// to the bot picked in the tree.
struct SwarmBoardPage: View {
  let link: SwarmLink
  @ObservedObject var agent: AgentModel
  let library: Library
  @ObservedObject private var boards = SwarmBoards.shared
  @State private var picked: String?
  @State private var draft = ""
  @Environment(\.palette) private var p

  var body: some View {
    let board: SwarmBoard? = boards.board(link, library: library)
    VStack(spacing: 0) {
      header(board)
      Divider().overlay(p.line)
      if let board {
        HStack(spacing: 0) {
          tree(board).frame(width: 248)
          Divider().overlay(p.line)
          feed(board)
        }
        Divider().overlay(p.line)
        composer(board)
      } else {
        Text("This board is no longer saved.").font(AssistantType.body).foregroundStyle(p.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(p.card)
    .onAppear { if picked == nil { picked = board.flatMap(Self.firstWorking) } }
  }

  private func header(_ board: SwarmBoard?) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: board?.countLine ?? "Swarm").font(AssistantType.title).foregroundStyle(p.ink)
        if let goal = board?.goal, !goal.isEmpty {
          Text(verbatim: goal).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 12)
      Button {
        boards.open = nil
      } label: {
        InterfaceIcon(systemName: "xmark")
      }
      .buttonStyle(QuietButton())
      .keyboardShortcut(.cancelAction)
      .accessibilityLabel("Close the swarm board")
    }
    .padding(16)
  }

  // MARK: Tree

  private func tree(_ board: SwarmBoard) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Self.rows(board), id: \.member.name) { row in
          Button {
            picked = row.member.name
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Circle().fill(color(row.member.state)).frame(width: 8, height: 8)
              // Name over app and state, so nested names keep their width.
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.member.name).font(AssistantType.name).foregroundStyle(p.ink).lineLimit(1)
                Text(verbatim: [row.member.agent, row.member.state.rawValue].compactMap { $0 }.joined(separator: " · "))
                  .font(AssistantType.meta).foregroundStyle(p.faint).lineLimit(1)
              }
              Spacer(minLength: 0)
            }
            .padding(.vertical, 6).padding(.leading, 8 + CGFloat(row.depth) * 16).padding(.trailing, 8)
            .background(picked == row.member.name ? p.selected : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
          }
          .buttonStyle(AssistantPressStyle())
          .accessibilityLabel("\(row.member.name), \(row.member.state.rawValue)")
          .accessibilityAddTraits(picked == row.member.name ? .isSelected : [])
        }
      }.padding(16)
    }
  }

  struct Row {
    var member: SwarmBoard.Member
    var depth: Int
  }

  /// The lead, then each bot under the one that started it, depth first, in seating order.
  static func rows(_ board: SwarmBoard) -> [Row] {
    var out: [Row] = []
    func walk(_ member: SwarmBoard.Member, _ depth: Int) {
      out.append(Row(member: member, depth: depth))
      for child in board.children(of: member.name) { walk(child, depth + 1) }
    }
    if let lead = board.lead { walk(lead, 0) }
    return out
  }

  private static func firstWorking(_ board: SwarmBoard) -> String? {
    let rows = rows(board)
    return (rows.first { $0.depth > 0 && $0.member.state == .working } ?? rows.first)?.member.name
  }

  private func color(_ state: SwarmMemberState) -> Color {
    switch state {
    case .working: return p.accent
    case .waiting: return p.faint
    case .stalled: return p.warning
    case .done: return p.success
    case .stopped: return p.danger
    }
  }

  // MARK: Messages

  private func feed(_ board: SwarmBoard) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(board.posts, id: \.seq) { post in
            postCard(post).id(post.seq)
          }
        }.padding(16)
      }
      // A `#12` in a message scrolls to message 12.
      .environment(\.openURL, OpenURLAction { url in
        guard url.scheme == "swarm-post", let seq = Int(url.host ?? "") else { return .systemAction }
        withAnimation { proxy.scrollTo(seq, anchor: .top) }
        return .handled
      })
      .onAppear { proxy.scrollTo(board.posts.last?.seq, anchor: .bottom) }
      .onChange(of: board.posts.count) { _, _ in withAnimation { proxy.scrollTo(board.posts.last?.seq, anchor: .bottom) } }
    }
  }

  private func postCard(_ post: SwarmPost) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(verbatim: post.author == "you" ? "You" : post.author).font(AssistantType.name).foregroundStyle(p.ink)
        if let to = post.mentions.first {
          Text(verbatim: "to @\(to)").font(AssistantType.meta).foregroundStyle(p.secondary)
        }
        Spacer(minLength: 8)
        Text(verbatim: "#\(post.seq)").font(AssistantType.figures).foregroundStyle(p.faint)
      }
      Text(Self.linked(post.text)).font(AssistantType.body).foregroundStyle(p.ink).lineSpacing(3)
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(post.author == "you" ? p.bubble : p.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  /// The message's words with every `#seq` made a link to that message. Plain text otherwise.
  static func linked(_ text: String) -> AttributedString {
    var out = AttributedString(text)
    guard let regex = try? NSRegularExpression(pattern: #"#(\d+)"#) else { return out }
    let ns = text as NSString
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      guard let range = Range(match.range, in: text), let lower = AttributedString.Index(range.lowerBound, within: out),
        let upper = AttributedString.Index(range.upperBound, within: out)
      else { continue }
      out[lower..<upper].link = URL(string: "swarm-post://\(ns.substring(with: match.range(at: 1)))")
    }
    return out
  }

  // MARK: Composer

  private func composer(_ board: SwarmBoard) -> some View {
    let to: String = picked ?? board.lead?.name ?? ""
    let open: Bool = !board.finished
    return HStack(spacing: 12) {
      Text(verbatim: "To @\(to)").font(AssistantType.name).foregroundStyle(p.ink).lineLimit(1)
      TextField(open ? "Tell this bot what to do now" : "This swarm has ended", text: $draft)
        .textFieldStyle(.plain).font(AssistantType.body)
        .padding(.horizontal, 12).frame(height: 32)
        .background(p.track, in: Capsule())
        .onSubmit { send(to) }
        .disabled(!open)
        .accessibilityLabel("Message to \(to)")
      Button("Send") { send(to) }
        .buttonStyle(QuietButton())
        .disabled(!open || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel("Send to \(to)")
      Button("Stop") { Task { await boards.stop(link, member: to, agent: agent) } }
        .buttonStyle(QuietButton())
        .disabled(!open || board.members[to]?.state.settled != false)
        .accessibilityLabel("Stop \(to)")
    }
    .padding(16)
  }

  private func send(_ to: String) {
    let words = draft
    draft = ""
    Task { await boards.tell(link, member: to, words: words, agent: agent) }
  }
}
