import Foundation
import SereinCore

/// The app side of rooms (TEAMS-V2-BASE 2.7), and the only code that reads or writes under
/// relay/rooms/ (scripts/check_room_owner.py). One folder per room, 0700, in Serein's private
/// store: room.json, notes.md and packets/<nnn>.md, each 0600. Every write runs off the main
/// actor, in the order it was asked for, so a turn never waits on the disk.
@MainActor final class Rooms {
  static let path = "relay/rooms"
  let folder: URL
  private var rooms: [Workroom.ID: Workroom] = [:]
  /// This launch's packets, for readers (`packet(_:takesPrivate:)`).
  private var packets: [AssistantHandoff.ID: HandoffPacket] = [:]
  private var seals: [AssistantHandoff.ID: Task<Bool, Never>] = [:]
  private var lastWrite: Task<Bool, Never>?

  init(folder: URL) { self.folder = folder }

  /// The open room for `root`: one root, one room. `make` opens it with its lead seated.
  func open(_ root: Workroom.Root, make: () -> Workroom) -> Workroom.ID {
    if let room = rooms.values.first(where: { $0.root == root && $0.state == .open }) { return room.id }
    let room = make()
    rooms[room.id] = room
    return room.id
  }

  /// Room `id` as this launch knows it, else as its room.json saved it, else `lost` (a crash
  /// before its first write).
  func room(_ id: Workroom.ID, lost: () -> Workroom) -> Workroom {
    if let room = rooms[id] { return room }
    let room = Library.load(Workroom.self, at: folder.appendingPathComponent(id + "/room.json")) ?? lost()
    rooms[id] = room
    return room
  }

  /// The next packet number in room `id`, marking the room personal first when the hand-off is,
  /// so its packet keeps the mark. `taken`: the highest number the ledger gave in this room.
  func number(in id: Workroom.ID, personal: Bool, taken: Int, lost: () -> Workroom) -> Int {
    var room = room(id, lost: lost)
    if personal { room.markPersonal() }
    let n = room.nextPacket(after: taken)
    rooms[id] = room
    return n
  }

  /// Seals packet `n` of room `id` for `handoff`, once, with room.json and notes.md beside it. A
  /// packet file already there (a launch after a crash) is kept as it is, and `build` never runs.
  func seal(_ handoff: AssistantHandoff.ID, room id: Workroom.ID, n: Int,
            build: @escaping (Workroom) async -> HandoffPacket) {
    guard seals[handoff] == nil, let room = rooms[id] else { return }
    let dir = folder, file = packetFile(id, n)
    let before = lastWrite
    let task = Task { [weak self] () -> Bool in
      _ = await before?.value
      let kept = await Task.detached { FileManager.default.fileExists(atPath: file.path) }.value
      let packet = kept ? nil : await build(room)
      if let packet { self?.packets[handoff] = packet }
      return await Task.detached {
        do {
          try RoomFiles.save(room, in: dir)
          if let packet { try RoomFiles.write(packet.markdown(), to: file, seal: true) }
          return true
        } catch { return false }
      }.value
    }
    seals[handoff] = task
    lastWrite = task
  }

  /// Launches `handoff` once its packet is sealed: `start` marks it launched (given whether the
  /// seal held) and says whether it did. Only then is its seat recorded, once per hand-off.
  func launch(_ handoff: AssistantHandoff.ID, room id: Workroom.ID, seat: (Workroom) -> Workroom.Seat,
              start: (_ sealed: Bool) -> Bool) async -> Bool {
    let sealed = await seals[handoff]?.value ?? false
    guard start(sealed) else { return false }
    if var room = rooms[id], !room.seats.contains(where: { $0.handoff == handoff }) {
      room.seats.append(seat(room))
      rooms[id] = room
      save(room)
    }
    return true
  }

  /// What a reader of `handoff`'s packet gets: the whole packet only when it takes private chats.
  func packet(_ handoff: AssistantHandoff.ID, takesPrivate: Bool) -> HandoffPacket? {
    packets[handoff].map { takesPrivate ? $0 : $0.withheld() }
  }

  func packetFile(_ room: Workroom.ID, _ n: Int) -> URL {
    folder.appendingPathComponent(room + "/packets/" + String(format: "%03d", n) + ".md")
  }

  private func save(_ room: Workroom) {
    let dir = folder, before = lastWrite
    lastWrite = Task {
      _ = await before?.value
      return await Task.detached { (try? RoomFiles.save(room, in: dir)) != nil }.value
    }
  }
}

/// The files under relay/rooms/. Folders 0700; files 0600 from their first byte, written whole
/// to a temporary file and moved in.
enum RoomFiles {
  static func save(_ room: Workroom, in folder: URL) throws {
    let dir = folder.appendingPathComponent(room.id)
    for url in [folder, dir, dir.appendingPathComponent("packets")] { try make(url) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    _ = try write(String(decoding: try encoder.encode(room), as: UTF8.self), to: dir.appendingPathComponent("room.json"))
    // Derived from the seats' notes; written here only while it is missing.
    _ = try write(RoomNotes.render([], names: [:]), to: dir.appendingPathComponent("notes.md"), seal: true)
  }

  /// `seal`: only where no file is, never over one; false when one was already there.
  @discardableResult
  static func write(_ text: String, to url: URL, seal: Bool = false) throws -> Bool {
    let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: temp.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    defer { unlink(temp.path) }
    if renamex_np(temp.path, url.path, seal ? UInt32(RENAME_EXCL) : 0) == 0 { return true }
    if seal && errno == EEXIST { return false }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }

  private static func make(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }
}

extension RelayOrchestrator {
  /// Gives `record` its room and packet number, and seals its packet in the background from what
  /// the sender's turn shows now. Idempotent: a row that has both keeps them, and a packet already
  /// sealed is kept as it is. `root` opens a room only for a record whose chain has none;
  /// `sender` is the sender's live run, whose steps are the trail.
  func pack(_ record: AssistantHandoff, root: Workroom.Root, sender: AgentRun?) -> AssistantHandoff {
    var record = record
    let parent = record.parentID.flatMap { id in handoffLedger.records.first { $0.id == id } }
    let leadID = record.chain?.first ?? record.from
    func make(_ id: Workroom.ID? = nil) -> Workroom {
      let reach = Reach.person(personScope).narrowed(to: profile(id: leadID).scope)
      return id.map { Workroom(id: $0, root: root, lead: leadID, thread: record.askedIn, reach: reach, now: record.createdAt) }
        ?? Workroom(root: root, lead: leadID, thread: record.askedIn, reach: reach, now: record.createdAt)
    }
    let id = record.room ?? parent?.room ?? rooms.open(root) { make() }
    let taken = handoffLedger.records.filter { $0.room == id }.compactMap(\.packet).max() ?? 0
    let room = rooms.room(id) { make(id) }
    let n = record.packet ?? rooms.number(in: id, personal: record.personal == true, taken: taken) { make(id) }
    record.room = id
    record.packet = n

    let steps = sender?.steps ?? []
    let trail = steps.map { HandoffPacket.TrailLine(tool: $0.tool, target: $0.label, ok: $0.failed == nil, at: $0.time) }
    var files: [HandoffPacket.FileRef] = []
    for file in steps.compactMap(Self.file) where !files.contains(file) { files.append(file) }
    let words = personWords(room.root, record)
    let (from, to, chain) = (profileName(record.from), profileName(record.to), record.holders.map(profileName))
    let parentPacket = parent?.packet, sent = record
    rooms.seal(record.id, room: id, n: n) { [weak self] room in
      let rules = await self?.rulesBlock(profileID: sent.to, thread: sent.threadID) ?? ""
      return HandoffPacket(
        in: room, n: n, handoff: sent.id, parent: parentPacket, from: from, to: to, chain: chain, createdAt: sent.createdAt,
        rules: rules, contract: .init(task: sent.task), personWords: words, summary: sent.task,
        decisions: [], openAsks: [], files: files, trail: trail)
    }
    return record
  }

  /// The seat a launching hand-off takes: under the seat that sent it (the lead for a root), at
  /// that seat's reach narrowed to the target's own.
  func seat(for record: AssistantHandoff, target: RelayProfile, in room: Workroom) -> Workroom.Seat {
    let parent = record.parentID.flatMap { id in room.seats.first { $0.handoff == id } } ?? room.seats[0]
    return Workroom.Seat(id: room.nextSeatID, who: target.id, thread: record.threadID, reach: parent.reach.narrowed(to: target.scope),
                         parent: parent.id, handoff: record.id)
  }

  /// The id of the person's newest message in `thread`: the one the turn that hands off answers.
  func lastPersonMessage(_ thread: String) -> String? {
    chatMessages(thread).last { $0.role == "you" && RelayAutomatic.kind(of: $0.text) == nil }?.id
  }

  /// The person's own words since the room opened, verbatim, newest last: their messages in the
  /// root's chat from the root message on, or what they handed over themselves ("board-<id>").
  private func personWords(_ root: Workroom.Root, _ record: AssistantHandoff) -> [HandoffPacket.Quote] {
    guard case .person(let thread, let message) = root else { return [] }
    if message.hasPrefix("board-") {
      let handed = message == "board-" + record.id ? record : handoffLedger.records.first { "board-" + $0.id == message }
      return handed.map { [.init(text: $0.task, at: $0.createdAt)] } ?? []
    }
    let messages = chatMessages(thread)
    guard let start = messages.firstIndex(where: { $0.id == message }) else { return [] }
    return messages[start...].filter { $0.role == "you" && RelayAutomatic.kind(of: $0.text) == nil }
      .map { .init(text: $0.text, at: $0.sentAt ?? Date()) }
  }

  private func chatMessages(_ thread: String) -> [AgentMessage] {
    agent.hub.latest(for: thread)?.transcript ?? agent.conversations.first { $0.id == thread }?.messages ?? []
  }

  /// A file the step wrote ("Edited Sources/App.swift") or a page it opened ("Read example.com").
  static func file(_ step: AgentStep) -> HandoffPacket.FileRef? {
    let edited = step.tool == "edit" ? ["Edited ", "Wrote "].first { step.label.hasPrefix($0) } : nil
    if let edited, case let path = String(step.label.dropFirst(edited.count)), path != "files" {
      return .init(path: path, note: edited == "Wrote " ? "written" : "edited")
    }
    if step.tool == "web", step.label.hasPrefix("Read "), case let host = String(step.label.dropFirst(5)), host != "a page" {
      return .init(path: host, note: "opened")
    }
    return nil
  }
}
