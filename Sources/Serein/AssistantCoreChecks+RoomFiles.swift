#if DEBUG
import Foundation
import SereinCore

/// Packets written in the background (Rooms, RelayRooms.swift): on disk before the hand-off
/// launches, sealed once, redacted, private modes, and reused by the launch after a crash. Only
/// a temporary folder is written.
extension AssistantCoreChecks {
  static func roomFiles(_ check: Check) throws {
    try MainActor.assumeIsolated { try roomFilesOnMain(check) }
  }

  @MainActor private static func roomFilesOnMain(_ check: Check) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-rooms-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    func settle<T>(_ work: @escaping () async -> T) -> T? {
      var result: T?
      Task { result = await work() }
      let end = Date().addingTimeInterval(10)
      while result == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
      return result
    }
    func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1 }
    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let root = Workroom.Root.person(thread: "chat", message: "m1")
    func lead() -> Workroom {
      Workroom(root: root, lead: "serein", thread: "chat", reach: .person(AssistantScope(destinations: [.web, .answer])), now: at)
    }
    var built = 0
    func build(_ task: String) -> (Workroom) async -> HandoffPacket {
      { room in
        built += 1
        return HandoffPacket(
          in: room, n: 1, handoff: "h1", parent: nil, from: "Serein", to: "Theo", chain: ["Serein", "Theo"], createdAt: at,
          rules: "", contract: .init(task: task), personWords: [.init(text: "my key is \(roomKey)", at: at)],
          summary: "password=hunter22", decisions: [], openAsks: [], files: [.init(path: "shared/venues.md")],
          trail: [.init(tool: "web", target: "venues.example", ok: true, at: at)])
      }
    }
    func seat(_ room: Workroom) -> Workroom.Seat {
      Workroom.Seat(id: room.nextSeatID, who: "theo", thread: "chat-theo", reach: room.seats[0].reach, parent: "s1", handoff: "h1")
    }

    // The launch that is cut short: the packet is sealed, then the app ends before the hand-off runs.
    let first = Rooms(folder: folder)
    let id = first.open(root, make: lead)
    try check(first.open(root, make: lead) == id, "rooms: one root opens one room")
    let n = first.number(in: id, personal: true, taken: 0, lost: lead)
    first.seal("h1", room: id, n: n, build: build("Book the venue with \(roomKey)"))
    let file = first.packetFile(id, n)
    var onDisk = false
    let started = settle { await first.launch("h1", room: id, seat: seat) { sealed in
      onDisk = sealed && FileManager.default.fileExists(atPath: file.path)
      return false
    } }
    try check(started == false && onDisk, "rooms: a packet file exists before its hand-off is marked launched")
    let sealedText = text(file)
    try check(!sealedText.contains(roomKey) && !sealedText.contains("hunter22") && sealedText.contains(AgentPrivacy.replacement),
      "rooms: secret-shaped text is redacted in the sealed file")
    try check(sealedText.contains("personal: true"), "rooms: a packet from a personal room keeps the mark in its file")
    let withheld = first.packet("h1", takesPrivate: false)
    try check(withheld?.personal == true && withheld?.privateWithheld == true && withheld?.personWords.isEmpty == true
      && withheld?.trail.isEmpty == true && withheld?.files.isEmpty == true && first.packet("h1", takesPrivate: true)?.files.count == 1,
      "rooms: a reader that does not take private chats gets the withheld copy, still marked")
    let dir = folder.appendingPathComponent(id)
    try check([folder, dir, dir.appendingPathComponent("packets")].allSatisfy { mode($0) == 0o700 },
      "rooms: the rooms folder, the room folder and its packets folder are 0700")
    try check([file, dir.appendingPathComponent("room.json"), dir.appendingPathComponent("notes.md")].allSatisfy { mode($0) == 0o600 },
      "rooms: the packet, room.json and notes.md are 0600")
    let saved = Library.load(Workroom.self, at: dir.appendingPathComponent("room.json"))
    try check(saved?.personal == true && saved?.packets == 1 && saved?.seats.count == 1,
      "rooms: the crash leaves a sealed packet with no seat for it")

    // The next launch: a new Rooms over the same folder, as after a relaunch.
    let next = Rooms(folder: folder)
    try check(next.room(id, lost: lead).personal, "rooms: room.json brings the room back with its mark")
    let before = built
    next.seal("h1", room: id, n: n, build: build("Something else entirely"))
    let relaunched = settle { await next.launch("h1", room: id, seat: seat) { _ in true } }
    try check(relaunched == true && built == before && text(file) == sealedText,
      "rooms: the next launch reuses the sealed packet: it is never built again or rewritten")
    _ = settle { await next.launch("h1", room: id, seat: seat) { _ in true } }
    _ = settle { await next.launch("other", room: id, seat: seat) { _ in false } }
    let reseated = Library.load(Workroom.self, at: dir.appendingPathComponent("room.json"))
    try check(reseated?.seats.filter { $0.handoff == "h1" }.count == 1 && reseated?.seats.count == 2,
      "rooms: the launch records the hand-off's seat once")
    try check(!(try RoomFiles.write("other bytes", to: file, seal: true)) && text(file) == sealedText,
      "rooms: a seal never writes over a sealed file")
    try check(next.number(in: id, personal: false, taken: 4, lost: lead) == 5 && next.number(in: id, personal: false, taken: 0, lost: lead) == 6,
      "rooms: a packet number is never given twice, also when room.json is behind the ledger")
  }

  private static let roomKey = "sk-proj-" + String(repeating: "A1b2", count: 8)
}
#endif
