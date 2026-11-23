import SereinCore
import SwiftUI

/// The routes a chat moves to when its engine fails, in the order the person set (the model list's
/// Backups tab). Kept in user defaults beside the task default; no key or token is ever stored.
/// Checks, previews and stress runs start with none and never write the person's list.
/// Also holds what one automatic move left behind: its banner per chat, and the chats whose next
/// ending run is the one retry, which never moves again.
@MainActor final class ModelBackups: ObservableObject {
  static let shared = ModelBackups()
  private static let defaultsKey = "serein.modelBackups"
  struct Entry: Codable, Hashable, Identifiable {
    var provider: Provider
    /// The model id; empty is the harness's own default.
    var model: String
    var id: String { ModelFavorites.key(provider, model) }
  }
  /// One automatic same-cost move, shown in its chat until Undo or Dismiss.
  struct Notice: Equatable {
    var from: ModelRoute
    var to: ModelRoute
    var fromName: String
    var toName: String
    var text: String { "Switched from \(fromName) to \(toName) (same cost). Pending approvals were reset." }
  }
  @Published private(set) var entries: [Entry] = [] {
    didSet {
      guard RelayOrchestrator.persists, let data = try? JSONEncoder().encode(entries) else { return }
      UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
  }
  @Published var notices: [String: Notice] = [:]
  /// Chats whose failed turn is being sent again on a backup: at most one automatic move a turn.
  var retrying: Set<String> = []
  /// Plain chats that failed in the background with a backup that could answer; their banner offers it.
  @Published var unused: Set<String> = []
  init() {
    entries = RelayOrchestrator.persists
      // A backup on an app Serein no longer has is dropped.
      ? (UserDefaults.standard.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? [])
        .filter { Provider.allCases.contains($0.provider) }
      : []
  }
  func contains(_ id: String) -> Bool { entries.contains { $0.id == id } }
  /// A new backup goes last.
  func add(_ route: ModelRoute) {
    guard !contains(route.id) else { return }
    entries.append(Entry(provider: Provider(rawValue: route.provider), model: route.model))
  }
  func remove(_ id: String) { entries.removeAll { $0.id == id } }
  /// Puts a backup at `index` (a drop on that row, or Move up / Move down). An id that is not on
  /// the list, such as text dragged in from elsewhere, changes nothing. True when the order changed.
  @discardableResult func move(_ id: String, to index: Int) -> Bool {
    guard let from = entries.firstIndex(where: { $0.id == id }) else { return false }
    let to = min(max(index, 0), entries.count - 1)
    guard from != to else { return false }
    var next = entries
    next.insert(next.remove(at: from), at: to)
    entries = next
    return true
  }
  /// A route's model as the chat header names it.
  static func name(_ provider: Provider, _ model: String) -> String {
    ModelPill.name(AgentModel.ChatEngine(provider: provider, model: model, mode: .answer, link: nil, edits: false,
                                         permission: .supervised))
  }
  static func name(_ route: ModelRoute) -> String { name(Provider(rawValue: route.provider), route.model) }
}

// MARK: - Backups tab

/// The model list's Backups tab: the ordered backups, each with its tag (free, your key, your
/// plan), dragged to reorder (or Move up / Move down with VoiceOver), removed with ×, and added
/// from every route that can answer now. A backup that cannot answer stays greyed with its reason
/// and is skipped when a chat fails.
struct ModelBackupsList: View {
  @ObservedObject var agent: AgentModel
  @ObservedObject private var backups = ModelBackups.shared
  @ObservedObject private var registry = HarnessRegistry.shared
  @State private var target: String?
  @Environment(\.palette) var p
  var dark: Bool { p.isDark }
  init(agent: AgentModel) { self.agent = agent }

  struct Candidate: Identifiable {
    var provider: Provider
    var name: String
    var route: ModelRoute
    var id: String { route.id }
  }
  /// Every route that can answer now and is not a backup yet, in the model list's order.
  var addable: [Candidate] {
    Provider.allCases.flatMap { provider -> [Candidate] in
      let listed = registry.models(provider).filter { !$0.isLegacy }
      let names = listed.map(\.name)
      return zip(names, agent.routes(provider, models: listed.map(\.id))).compactMap { name, route in
        route.selectable && !backups.contains(route.id) ? Candidate(provider: provider, name: name, route: route) : nil
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Backups").font(UIStyle.font(12, weight: .semibold)).foregroundStyle(KeelPicker.text(dark))
          .accessibilityAddTraits(.isHeader)
        Text("When a chat's model fails, the chat moves to the first backup that can answer. A move at the same cost happens by itself and says so; anything that could cost you asks first.")
          .font(UIStyle.font(11)).foregroundStyle(KeelPicker.muted(dark)).fixedSize(horizontal: false, vertical: true)
      }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
      if backups.entries.isEmpty {
        Text("No backups yet. A chat whose model fails stops with the error.")
          .font(UIStyle.font(12)).foregroundStyle(KeelPicker.muted(dark))
          .multilineTextAlignment(.center).padding(.horizontal, 16)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(Array(backups.entries.enumerated()), id: \.element.id) { index, entry in
              row(entry, index: index)
            }
          }.padding(.horizontal, 6).padding(.vertical, 4)
        }.frame(maxHeight: .infinity)
      }
      addMenu
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  func row(_ entry: ModelBackups.Entry, index: Int) -> some View {
    let route = agent.routes(entry.provider, models: [entry.model]).first
    let name = ModelBackups.name(entry.provider, entry.model)
    let cost = route?.costClass.label ?? ""
    let count = backups.entries.count
    return HStack(spacing: 8) {
      InterfaceIcon(systemName: "line.3.horizontal", size: 11)
        .foregroundStyle(KeelPicker.muted(dark).opacity(0.6)).accessibilityHidden(true)
      HStack(spacing: 8) {
        ModelMonogram(provider: entry.provider, size: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(name).font(UIStyle.font(12.5, weight: .medium)).foregroundStyle(KeelPicker.text(dark)).lineLimit(1)
          // A greyed backup says why on its second line.
          Text(route?.reason ?? entry.provider.name).font(UIStyle.font(11))
            .foregroundStyle(KeelPicker.muted(dark).opacity(0.7)).lineLimit(1)
        }
        Spacer(minLength: 6)
        if let route { RouteTag(cost: route.costClass) }
      }.accessibilityElement(children: .combine)
        .accessibilityLabel("Backup \(index + 1) of \(count): \(name), \(entry.provider.name), \(cost)")
        .accessibilityValue(route?.reason ?? "")
        .accessibilityActions {
          if index > 0 { Button("Move up") { backups.move(entry.id, to: index - 1) } }
          if index < count - 1 { Button("Move down") { backups.move(entry.id, to: index + 1) } }
        }
      Button { backups.remove(entry.id) } label: {
        InterfaceIcon(systemName: "xmark", size: 10).foregroundStyle(KeelPicker.muted(dark))
          .frame(width: 22, height: 22).contentShape(Rectangle())
      }.buttonStyle(.pressable).help("Remove from backups").accessibilityLabel("Remove \(name) from backups")
    }.padding(.horizontal, 8).padding(.vertical, 6)
      .opacity(route?.selectable == true ? 1 : 0.45)
      .background(target == entry.id ? KeelPicker.ink(dark, 0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
      .draggable(entry.id)
      // Dropped text is only matched against the list's own ids (ModelBackups.move).
      .dropDestination(for: String.self) { ids, _ in
        guard let id = ids.first else { return false }
        return backups.move(id, to: index)
      } isTargeted: { over in
        if over { target = entry.id } else if target == entry.id { target = nil }
      }
      .help(route?.reason ?? "Drag to change the order")
  }

  var addMenu: some View {
    Menu {
      let candidates = addable
      if candidates.isEmpty { Text("Every model that can answer is already a backup") }
      ForEach(candidates) { candidate in
        Button("\(candidate.name) · \(candidate.provider.name) · \(candidate.route.costClass.label)") {
          backups.add(candidate.route)
        }
      }
    } label: {
      HStack(spacing: 6) {
        InterfaceIcon(systemName: "plus", size: 11)
        Text("Add a backup").font(UIStyle.font(12))
      }.foregroundStyle(KeelPicker.text(dark))
    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .help("Adds a model at the end of the list")
      .accessibilityLabel("Add a backup model")
      .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .top) { Rectangle().fill(KeelPicker.hairline(dark, 0.08)).frame(height: 1) }
  }
}

// MARK: - Banner

/// Above a chat's composer after an automatic move to a same-cost backup: "Switched from X to Y
/// (same cost). Pending approvals were reset." Undo moves the chat back (AgentModel.switchModel,
/// which resets approvals again); Dismiss only hides the banner. A plain chat that failed in the
/// background instead says no backup was tried and offers one (AgentModel.fallBack).
struct ModelSwitchBanner: View {
  @ObservedObject var agent: AgentModel
  /// The chat it reports on; nil is the selected thread.
  var chat: String? = nil
  @ObservedObject private var backups = ModelBackups.shared
  @Environment(\.palette) var p
  init(agent: AgentModel, chat: String? = nil) {
    self.agent = agent
    self.chat = chat
  }
  var body: some View {
    let id = chat ?? agent.conversationID
    if let notice = backups.notices[id] {
      HStack(alignment: .center, spacing: 10) {
        InterfaceIcon(systemName: "arrow.triangle.branch", size: 14).foregroundStyle(p.secondary)
          .accessibilityHidden(true)
        Text(notice.text).font(UIStyle.body).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button("Undo") { agent.undoFallback(id) }.buttonStyle(QuietButton()).fixedSize()
          .help("Switch this chat back to \(notice.fromName)")
          .accessibilityLabel("Undo, switch back to \(notice.fromName)")
        Button {
          backups.notices[id] = nil
        } label: {
          InterfaceIcon(systemName: "xmark", size: 11)
        }.buttonStyle(QuietButton()).accessibilityLabel("Dismiss")
      }.padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.panel, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
        .frame(maxWidth: UIStyle.composerWidth).padding(.horizontal, 16).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    } else if backups.unused.contains(id), let run = agent.hub.latest(for: id), run.engineFailed {
      // A plain chat cannot be sent again while it is in the background; now that it is shown,
      // the person can try its backups (fallBack, which still asks before a cost change).
      HStack(alignment: .center, spacing: 10) {
        InterfaceIcon(systemName: "arrow.triangle.branch", size: 14).foregroundStyle(p.secondary)
          .accessibilityHidden(true)
        Text("\(ModelBackups.name(run.spec.provider, run.spec.model)) failed while this chat was in the background, so no backup was tried.")
          .font(UIStyle.body).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button("Try a backup") {
          backups.unused.remove(id)
          agent.fallBack(after: run, byPerson: true)
        }.buttonStyle(QuietButton()).fixedSize()
          .accessibilityLabel("Try a backup model for this chat")
        Button {
          backups.unused.remove(id)
        } label: {
          InterfaceIcon(systemName: "xmark", size: 11)
        }.buttonStyle(QuietButton()).accessibilityLabel("Dismiss")
      }.padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.panel, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
        .frame(maxWidth: UIStyle.composerWidth).padding(.horizontal, 16).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
  }
}

// MARK: - Moving a failed chat

extension AgentModel {
  /// A backup as this chat could use it now: its route from the model list (ModelRoutes), with a
  /// reason set when it cannot answer this chat, so ModelFallback skips it without asking: refused
  /// earlier this session, unable to work on this chat's files, or not offered for its destination
  /// (HarnessRegistry.verdict), as the model list greys it.
  func backupRoute(_ entry: ModelBackups.Entry, for engine: ChatEngine) -> ModelRoute? {
    guard var route = routes(entry.provider, models: [entry.model]).first else { return nil }
    guard route.reason == nil else { return route }
    let registry = HarnessRegistry.shared
    let linked = engine.link.flatMap { HarnessDriver(rawValue: $0.driver) }.map(Provider.init)
    if registry.isUnavailable(entry.provider, entry.model) {
      route.reason = "\(entry.provider.name) refused this model earlier"
    } else if [.project, .library].contains(engine.mode), entry.provider != linked,
      !(entry.provider.driver.map(HarnessPolicy.fileDrivers.contains) ?? false)
    {
      route.reason = "\(entry.provider.name) cannot work on this chat's files"
    } else if engine.mode != .auto,
      let why = registry.verdict(entry.provider, mode: engine.mode.runKey, edits: engine.edits, permission: engine.permission).reason
    {
      route.reason = why
    }
    return route
  }

  /// After a run ends (runEnded): when its engine failed (AgentRun.engineFailed), the chat moves
  /// to its next backup (ModelFallback.next) and the failed turn goes once more. A same-cost move
  /// happens by itself with a banner; any other asks first (askToMove). Only the selected thread
  /// and a task Serein started can be sent again, so only they move; a plain chat that fails in the
  /// background keeps its error and its banner offers the backup (ModelBackups.unused). No backup
  /// that can answer: the error stays and nothing moves. The retry's own end never moves again.
  func fallBack(after run: AgentRun, byPerson: Bool = false) {
    let id = run.spec.threadID
    let backups = ModelBackups.shared
    let wasRetry = backups.retrying.remove(id) != nil
    backups.unused.remove(id)
    guard run.engineFailed, !wasRetry, !run.spec.relay, !run.spec.speaksFirstElsewhere else { return }
    let movable = id == conversationID || RelayOrchestrator.shared?.isChild(id) == true
    let base = ClaudeModelID.split(run.spec.model).base
    let chatEngine = self.engine(of: id)
    // A pick made during the turn stands.
    guard chatEngine.provider == run.spec.provider, ClaudeModelID.split(chatEngine.model).base == base,
      let current = routes(run.spec.provider, models: [base]).first,
      let step = ModelFallback.next(current: current, list: backups.entries.compactMap { backupRoute($0, for: chatEngine) })
    else { return }
    // A plain chat in the background cannot be sent again; its banner offers the backup instead.
    guard movable else { backups.unused.insert(id); return }
    // A step of the failed turn has an unknown outcome: nothing sends it again by itself, and
    // the banner offers the backup instead (`StepJournal`). Its button is the person's own word.
    if !byPerson, step.sameCost, case .waits? = browser?.stepJournal.resend(id) { backups.unused.insert(id); return }
    if step.sameCost {
      // After the hub has finished ending the run, so Retry reads its failed outcome.
      DispatchQueue.main.async { [weak self] in
        self?.moveToBackup(id, after: run, from: current, to: step.route, banner: true)
      }
    } else {
      Task { [weak self] in await self?.askToMove(id, after: run, from: current, to: step.route) }
    }
  }

  /// A move that can change the bill waits behind an approval card. Its intent is minted with the
  /// pay effect (ApprovalGate.record), which is in `mustAsk`, so Autopilot never answers it and a
  /// scheduled run asks too. Allow moves the chat and sends the turn again; Stay, a timeout, or a
  /// switch made meanwhile (which declines the card) leaves the chat stopped on its error.
  private func askToMove(_ id: String, after run: AgentRun, from: ModelRoute, to: ModelRoute) async {
    guard let relay = RelayOrchestrator.shared else { return }
    let fromName = ModelBackups.name(from)
    let toName = ModelBackups.name(to)
    let action = ApprovalGate.GateAction(
      kind: "switch_model", label: "Continue on \(toName)", effect: .pay, elementID: to.id, pageVersion: from.id)
    let intent = ApprovalGate.record(action, effect: .pay) { UUID().uuidString }
    let bill = to.costClass == .free ? "" : ApprovalGate.askLine(.pay) + " "
    let human = await relay.confirmAnswer(
      "\(fromName) failed. Continue on \(toName) (\(to.costClass.label))?",
      RouteTag.help(to.costClass) + ". " + bill + "This chat's pending approvals are reset.",
      button: "Allow", decline: "Stay", thread: id)
    // Only a yes for this backup while it can still answer, given while the chat is still on the
    // failed route.
    let live = self.engine(of: id)
    let still = ModelBackups.shared.entries.first { $0.id == to.id }.flatMap { backupRoute($0, for: live) }
    guard ApprovalGate.beforeInput(
      intent: intent, answer: human, liveElement: still?.selectable == true ? to.id : "",
      liveVersion: ModelFavorites.key(live.provider, ClaudeModelID.split(live.model).base), liveEffect: .pay)
    else { return }
    moveToBackup(id, after: run, from: from, to: to, banner: false)
  }

  /// Moves the chat off its failed route (switchModel empties its pending approvals and declines
  /// its open cards) and sends the failed turn once on the backup. Nothing moves when a newer turn
  /// or a pick made since owns the chat, or when the turn cannot be sent again.
  private func moveToBackup(_ id: String, after run: AgentRun, from: ModelRoute, to: ModelRoute, banner: Bool) {
    let now = self.engine(of: id)
    // Only a task Serein started is resent through the task path (its own engine and edits).
    let child = id != conversationID && RelayOrchestrator.shared?.isChild(id) == true
    let request = child ? SereinTaskHeader.lastRequest(id, agent: self) : nil
    guard hub.run(for: id) == nil, hub.latest(for: id) === run,
      ModelFavorites.key(now.provider, ClaudeModelID.split(now.model).base) == from.id,
      id == conversationID ? flow.canRetry : request != nil
    else {
      // A plain chat left in the meantime: its banner offers the backup again.
      if id != conversationID && !child { ModelBackups.shared.unused.insert(id) }
      return
    }
    switchModel(chat: id, route: to)
    let backups = ModelBackups.shared
    backups.notices[id] = banner
      ? ModelBackups.Notice(from: from, to: to, fromName: ModelBackups.name(from), toName: ModelBackups.name(to)) : nil
    backups.retrying.insert(id)
    if id == conversationID {
      flow.retry()
      if !running { backups.retrying.remove(id) }
    } else if let request {
      flow.setTaskReplyError(id, nil)
      Task { [weak self] in
        guard let self else { return }
        guard let refused = await self.flow.replyToTask(id, text: request, interrupt: false, sameRequest: true) else { return }
        ModelBackups.shared.retrying.remove(id)
        self.flow.setTaskReplyError(id, refused)
      }
    }
  }

  /// The banner's Undo: the chat goes back to the route that failed, as a pick would move it.
  func undoFallback(_ id: String) {
    let backups = ModelBackups.shared
    guard let notice = backups.notices.removeValue(forKey: id) else { return }
    let provider = Provider(rawValue: notice.from.provider)
    guard let route = routes(provider, models: [notice.from.model]).first else { return }
    switchModel(chat: id, route: route)
  }
}
