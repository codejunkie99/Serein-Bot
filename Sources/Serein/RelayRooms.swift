import Foundation
import SereinCore

/// The app side of rooms (TEAMS-V2-BASE 2.7), and the only code that reads or writes under
/// relay/rooms/ (scripts/check_room_owner.py). One folder per room, 0700, in Serein's private
/// store: room.json, notes.md, seats/<seat>.jsonl, packets/<nnn>.json with its markdown copy
/// <nnn>.md, and reports/<nnn>.md, each 0600. Every write runs off the main actor, in the order
/// it was asked for, so a turn never waits on the disk.
@MainActor final class Rooms {
  static let path = "relay/rooms"
  let folder: URL
  private var rooms: [Workroom.ID: Workroom] = [:]
  /// Packets by hand-off, for readers (`packet(_:takesPrivate:)`): this launch's, or read back
  /// from their sealed JSON.
  private var packets: [AssistantHandoff.ID: HandoffPacket] = [:]
  /// Each room's notes from every seat's log, read on first use.
  private var notes: [Workroom.ID: [RoomNote]] = [:]
  /// The report each seat gave (room_report), or the host wrote at its run's end.
  private var reports: [AssistantHandoff.ID: HandoffReport] = [:]
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

  /// Seals packet `n` of room `id` for `handoff`, once, with room.json and notes.md beside it:
  /// its JSON first, then the markdown copy. A packet already sealed (a launch after a crash) is
  /// read back as it is, and `build` never runs.
  func seal(_ handoff: AssistantHandoff.ID, room id: Workroom.ID, n: Int,
            build: @escaping (Workroom) async -> HandoffPacket) {
    guard seals[handoff] == nil, let room = rooms[id] else { return }
    let dir = folder, file = packetFile(id, n), json = jsonFile(id, n)
    let before = lastWrite
    let task = Task { [weak self] () -> Bool in
      _ = await before?.value
      let (sealed, markdownOnly) = await Task.detached {
        (Library.load(HandoffPacket.self, at: json), FileManager.default.fileExists(atPath: file.path))
      }.value
      // A packet sealed before its JSON was kept has no way back in: it stays as it is.
      var packet = sealed
      if sealed == nil, !markdownOnly { packet = await build(room) }
      if let packet { self?.packets[handoff] = packet }
      return await Task.detached {
        do {
          try RoomFiles.save(room, in: dir)
          if let packet {
            if sealed == nil { try RoomFiles.write(RoomFiles.json(packet), to: json, seal: true) }
            try RoomFiles.write(packet.markdown(), to: file, seal: true)
          }
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
  /// `room` and `n` read a packet this launch did not seal back from its JSON.
  func packet(_ handoff: AssistantHandoff.ID, room: Workroom.ID? = nil, n: Int? = nil, takesPrivate: Bool) -> HandoffPacket? {
    if packets[handoff] == nil, let room, let n, let sealed = Library.load(HandoffPacket.self, at: jsonFile(room, n)),
      sealed.handoff == handoff
    {
      packets[handoff] = sealed
    }
    return packets[handoff].map { takesPrivate ? $0 : $0.withheld() }
  }

  func packetFile(_ room: Workroom.ID, _ n: Int) -> URL {
    folder.appendingPathComponent(room + "/packets/" + String(format: "%03d", n) + ".md")
  }
  func jsonFile(_ room: Workroom.ID, _ n: Int) -> URL {
    folder.appendingPathComponent(room + "/packets/" + String(format: "%03d", n) + ".json")
  }

  /// Room `id`'s notes, every seat's, in `seq` order.
  func notes(in id: Workroom.ID) -> [RoomNote] {
    if let kept = notes[id] { return kept }
    let logs = (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(id + "/seats"), includingPropertiesForKeys: nil)) ?? []
    let read = logs.filter { $0.pathExtension == "jsonl" }.flatMap { RoomFiles.notes(in: $0) }.sorted { $0.seq < $1.seq }
    notes[id] = read
    return read
  }

  /// Appends a note to `seat`'s own log, then rewrites notes.md from every seat's. `names` reads
  /// a seat as its assistant's name.
  @discardableResult
  func note(_ kind: RoomNote.Kind, _ text: String, seat: Workroom.Seat.ID, in id: Workroom.ID, at: Date = Date(),
            names: [Workroom.Seat.ID: String]) -> RoomNote {
    var all = notes(in: id)
    let note = RoomNote(seq: (all.map(\.seq).max() ?? 0) + 1, seat: seat, kind: kind, text: text, at: at)
    all.append(note)
    notes[id] = all
    let own = all.filter { $0.seat == seat }, notesMD = RoomNotes.render(all, names: names)
    let dir = folder.appendingPathComponent(id), before = lastWrite
    lastWrite = Task {
      _ = await before?.value
      return await Task.detached {
        do {
          try RoomFiles.make(dir.appendingPathComponent("seats"))
          try RoomFiles.write(own.map(RoomFiles.json).joined(separator: "\n") + "\n", to: dir.appendingPathComponent("seats/\(seat).jsonl"))
          try RoomFiles.write(notesMD, to: dir.appendingPathComponent("notes.md"))
          return true
        } catch { return false }
      }.value
    }
    return note
  }

  /// The report of `handoff`, once it has one.
  func report(_ handoff: AssistantHandoff.ID) -> HandoffReport? { reports[handoff] }

  /// Keeps a seat's first report (a second room_report changes nothing) and seals it as
  /// reports/<nnn>.md. Returns the report that stands.
  @discardableResult
  func report(_ report: HandoffReport, room id: Workroom.ID) -> HandoffReport {
    if let kept = reports[report.handoff] { return kept }
    reports[report.handoff] = report
    let dir = folder.appendingPathComponent(id), before = lastWrite
    let file = dir.appendingPathComponent("reports/" + String(format: "%03d", report.packet) + ".md")
    lastWrite = Task {
      _ = await before?.value
      return await Task.detached {
        do {
          try RoomFiles.make(dir.appendingPathComponent("reports"))
          try RoomFiles.write(report.markdown(), to: file, seal: true)
          return true
        } catch { return false }
      }.value
    }
    return report
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

  static func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  /// A seat's log, one note per line; a line that does not read is skipped.
  static func notes(in log: URL) -> [RoomNote] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
      .compactMap { try? decoder.decode(RoomNote.self, from: Data($0.utf8)) }
  }

  static func make(_ url: URL) throws {
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
    // What the team settled and still asks so far: the room's notes, as the packet is sealed now.
    let noted = rooms.notes(in: id)
    let decisions = noted.filter { $0.kind == .decision }.map(\.text)
    let asks = noted.filter { $0.kind == .ask }.map { HandoffPacket.OpenAsk(text: $0.text) }
    let parentPacket = parent?.packet, sent = record
    rooms.seal(record.id, room: id, n: n) { [weak self] room in
      let rules = await self?.rulesBlock(profileID: sent.to, thread: sent.threadID) ?? ""
      return HandoffPacket(
        in: room, n: n, handoff: sent.id, parent: parentPacket, from: from, to: to, chain: chain, createdAt: sent.createdAt,
        rules: rules, contract: .init(task: sent.task), personWords: words, summary: sent.task,
        decisions: decisions, openAsks: asks, files: files, trail: trail)
    }
    return record
  }

  /// room_read, room_note and room_report from the run of the hand-off that holds `seatThread`.
  func roomTool(_ name: String, _ a: [String: Any], seatThread: String) throws -> [String: Any] {
    guard let record = handoffLedger.running(thread: seatThread), let id = record.room, let n = record.packet else {
      throw SereinError.invalid("That hand-off is no longer open, so its room is closed.")
    }
    let (seat, names) = seatOf(record, in: id)
    func words(_ key: String) -> String { (a[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func refuseSecret(_ texts: [String]) throws {
      guard texts.allSatisfy({ AgentPrivacy.redact($0) == $0 }) else {
        throw SereinError.invalid("That looks like a key or password. Leave the value out; say where it is kept.")
      }
    }
    switch name {
    case "room_read":
      let part = words("part")
      let text = part == "notes" ? RoomNotes.render(rooms.notes(in: id), names: names)
        : rooms.packet(record.id, room: id, n: n, takesPrivate: true)?.read(part)
      guard let text else { throw SereinError.invalid("Nothing to read there: part is packet, notes, trail or files.") }
      let offset = max(0, a["offset"] as? Int ?? 0)
      let page = String(text.dropFirst(offset).prefix(HandoffPacket.Cap.brief))
      let next = offset + page.count
      return ["result": UntrustedText.wrap("room_read", UntrustedText.escape(page), ref: "\(id)/\(part)")
        + (next < text.count ? "\n… (more: room_read part=\(part) offset=\(next))" : "")]
    case "room_note":
      let text = words("text")
      guard let kind = RoomNote.Kind(rawValue: words("kind")), kind != .done, !text.isEmpty else {
        throw SereinError.invalid("A note needs kind (fact, decision, file or ask) and text.")
      }
      try refuseSecret([text])
      rooms.note(kind, text, seat: seat, in: id, names: names)
      return ["result": "Noted for the team."]
    case "room_report":
      let summary = words("summary")
      let state: HandoffReport.State? = switch words("state") {
      case "done": .done
      case "failed": .failed
      case "waiting": .waiting
      default: nil
      }
      guard let state, !summary.isEmpty else { throw SereinError.invalid("A report needs state (done, failed or waiting) and a summary.") }
      let list = { (key: String) in (a[key] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
      try refuseSecret([summary] + list("decisions") + list("files") + list("open"))
      let filed = reportOnce(HandoffReport(
        handoff: record.id, packet: n, state: state, summary: summary, decisions: list("decisions"),
        files: list("files").map { HandoffPacket.FileRef(path: $0) }, open: list("open").map { HandoffPacket.OpenAsk(text: $0) },
        byHost: false), record: record)
      return ["result": filed.byHost ? "Your report was already written." : "Reported to \(profileName(record.from)). End your turn now."]
    default:
      throw SereinError.invalid("Serein has no tool \(name).")
    }
  }

  /// A seat's report, kept once with its trace in the room's notes: a `.done` note with the
  /// summary and a `.file` note per file. The first report stands.
  @discardableResult
  func reportOnce(_ report: HandoffReport, record: AssistantHandoff) -> HandoffReport {
    guard let id = record.room else { return report }
    if let kept = rooms.report(record.id) { return kept }
    let filed = rooms.report(report, room: id)
    let (seat, names) = seatOf(record, in: id)
    if !filed.summary.isEmpty { rooms.note(.done, filed.summary, seat: seat, in: id, names: names) }
    for file in filed.files { rooms.note(.file, file.path, seat: seat, in: id, names: names) }
    return filed
  }

  /// `record`'s seat in room `id` (a stand-in id before its launch recorded one) and each seat's
  /// assistant name, for notes.
  private func seatOf(_ record: AssistantHandoff, in id: Workroom.ID) -> (Workroom.Seat.ID, [Workroom.Seat.ID: String]) {
    let room = rooms.room(id) {
      Workroom(id: id, root: .person(thread: record.askedIn, message: "handoff-" + (record.rootID ?? record.id)),
               lead: record.chain?.first ?? record.from, thread: record.askedIn, reach: Reach.person(personScope), now: record.createdAt)
    }
    let seat = room.seats.first { $0.handoff == record.id }?.id ?? "h-" + record.id
    return (seat, Dictionary(room.seats.map { ($0.id, profileName($0.who)) }, uniquingKeysWith: { a, _ in a }))
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
