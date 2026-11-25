#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// The packet is the prompt (TurnPrompt.packet, Rooms): it reaches the seat as an ACP resource or
/// ahead of the volatile part, the stable part never moves, the room tools are offered to a seat
/// only, and notes, reports and sealed packets read back after a relaunch. Temporary folders only.
extension AssistantCoreChecks {
  static func seatPacket(_ check: Check) throws {
    // Non-ACP engines: the packet rides ahead of the volatile part.
    let plain = TurnPrompt(stable: "STABLE", volatile: "now: 9:00", message: "Your task is in the packet.", recovery: nil)
    var carried = plain
    carried.registry = "SLICE"
    carried.packet = .init(uri: "serein-room://r_1/packets/1", text: "BRIEF")
    let moved = carried.contextInVolatile
    try check(moved.stable == plain.stable && moved.volatile == "SLICE\n\nBRIEF\n\nnow: 9:00" && moved.packet == nil
        && moved.registry == nil && moved.message == plain.message,
      "Seat packet: on a non-ACP engine the brief rides in the volatile part and the stable part is byte-identical")

    // ACP: an embedded resource on the first turn and on a resumed one, never in the text block.
    let rig = try ACPCheckRig(GeminiDriver(), name: "gemini")
    defer { try? rig.finish() }
    var first = rig.request("Your task is in the packet.", thread: "seat-h1")
    first.prompt.packet = .init(uri: "serein-room://r_1/packets/1", text: "PACKET-BRIEF-1")
    _ = try rig.turn(first)
    var again = rig.request("Next turn.", thread: "seat-h1")
    again.prompt.packet = .init(uri: "serein-room://r_1/packets/2", text: "PACKET-BRIEF-2")
    _ = try rig.turn(again)
    let resources = rig.lines("resources"), prompts = rig.lines("prompts")
    try check(resources.count == 2 && resources[0].contains("PACKET-BRIEF-1") && resources[0].contains("serein-room://r_1/packets/1")
        && resources[0].contains("text/markdown") && resources[1].contains("PACKET-BRIEF-2"),
      "Seat packet: on ACP the brief is an embedded resource, on a fresh and on a resumed session")
    try check(prompts.count == 2 && prompts[0].contains("STABLE-RULES") && prompts[0].contains("Your task is in the packet.")
        && !prompts.joined().contains("PACKET-BRIEF"),
      "Seat packet: the ACP text block keeps the stable prompt and the short message, never the brief")

    // The room tools: a seat's run only.
    let names = { (args: [String]) in Set(ToolSchema.everyTool(args).compactMap { $0["name"] as? String }) }
    try check(names(["--room"]).isSuperset(of: RelayTools.roomNames) && names(["--relay", "--team"]).isDisjoint(with: RelayTools.roomNames),
      "Seat packet: room_read, room_note and room_report are offered to a hand-off's run, not to Serein's")

    // Seats: each hand-off runs in a hidden chat of its own, never in an assistant's Main chat
    // (a Main chat's id is a UUID, `RelayOrchestrator.State`).
    let seats = ["h1", "h2"].map(RelayOrchestrator.seatThread)
    try check(seats == ["seat-h1", "seat-h2"] && seats.allSatisfy { UUID(uuidString: $0) == nil && $0.hasPrefix(RelayOrchestrator.seatPrefix) },
      "Seats: each hand-off gets its own hidden chat, never an assistant's Main chat")

    try MainActor.assumeIsolated { try seatPacketRooms(check) }
  }

  @MainActor private static func seatPacketRooms(_ check: Check) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-seat-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let root = Workroom.Root.person(thread: "chat", message: "m1")
    func lead() -> Workroom {
      Workroom(root: root, lead: "serein", thread: "chat", reach: .person(AssistantScope(destinations: [.answer])), now: at)
    }
    let rooms = Rooms(folder: folder)
    let id = rooms.open(root, make: lead)
    let n = rooms.number(in: id, personal: false, taken: 0, lost: lead)
    rooms.seal("h1", room: id, n: n) { room in
      HandoffPacket(in: room, n: n, handoff: "h1", parent: nil, from: "Serein", to: "Theo", chain: ["Serein", "Theo"], createdAt: at,
                    rules: "", contract: .init(task: "Find three venues"), personWords: [], summary: "Find three venues",
                    decisions: [], openAsks: [], files: [], trail: [])
    }
    rooms.note(.decision, "Harbour Hall is out", seat: "s2", in: id, names: ["s2": "Theo"])
    rooms.note(.ask, "Is 40 people the cap?", seat: "s2", in: id, names: ["s2": "Theo"])
    let first = rooms.report(HandoffReport(handoff: "h1", packet: n, state: .done, summary: "Casa Alta is cheapest", byHost: false), room: id)
    let second = rooms.report(HandoffReport(handoff: "h1", packet: n, state: .failed, summary: "host words", byHost: true), room: id)
    try check(first == second && second.summary == "Casa Alta is cheapest" && !second.byHost,
      "Seat packet: a seat's first report stands; a second one changes nothing")
    let deadline = Date().addingTimeInterval(5)
    let reportFile = folder.appendingPathComponent(id + "/reports/" + String(format: "%03d", n) + ".md")
    while !FileManager.default.fileExists(atPath: reportFile.path), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    let next = Rooms(folder: folder)
    let notes = next.notes(in: id)
    try check(notes.map(\.kind) == [.decision, .ask] && notes.map(\.seq) == [1, 2] && notes[0].text == "Harbour Hall is out",
      "Seat packet: room notes read back from the seat's log after a relaunch, in order")
    let back = next.packet("h1", room: id, n: n, takesPrivate: true)
    try check(back?.handoff == "h1" && back?.contract.task == "Find three venues" && back?.brief().contains("Find three venues") == true,
      "Seat packet: a sealed packet reads back from its JSON after a relaunch")
    try check(next.packet("h2", room: id, n: n, takesPrivate: true) == nil, "Seat packet: a packet reads back only for its own hand-off")
    try check((try? String(contentsOf: reportFile, encoding: .utf8))?.contains("Casa Alta is cheapest") == true,
      "Seat packet: the report is sealed beside the packet")
  }
}
#endif
