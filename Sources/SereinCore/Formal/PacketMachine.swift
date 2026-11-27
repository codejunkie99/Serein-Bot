import Foundation

/// Hand-off packets (`HandoffPacket`, HandoffPacket.swift) built from a room, sealed to their file
/// and sent, in every order, with the room marked personal at any point and a relaunch building a
/// packet again. The writer lands in commit 4, so the seal is modeled as a write-once map.
struct PacketWorld: Encodable, Equatable {
  var room = Workroom(id: "r1", root: .chat(thread: "main-serein", message: "m1"), lead: "serein", thread: "main-serein",
                      reach: Reach.ofPerson(AssistantScope(destinations: [.web, .mail])), now: PacketWorld.base)
  /// Packet n is `packets[n - 1]`.
  var packets: [HandoffPacket] = []
  /// The room was marked when packet n was (last) built.
  var markedAtBuild: [Bool] = []
  var sealed = SealedFiles()
  var sent: [Sent] = []

  /// `relay/rooms/<room>/packets/`: a file is written once and never again.
  struct SealedFiles: Encodable, Equatable {
    private(set) var files: [String: String] = [:]
    func file(_ n: Int) -> String? { files[String(n)] }
    mutating func seal(_ n: Int, _ bytes: String) {
      guard files[String(n)] == nil else { return }
      files[String(n)] = bytes
    }
  }
  struct Sent: Encodable, Equatable {
    var n: Int
    var withheld: Bool
    /// The packet that went was marked, as the one built was.
    var personal: Bool
    var builtPersonal: Bool
    var brief: String
  }

  static let base = Date(timeIntervalSince1970: 1_800_000_000)
  static let personWords = "Book the table for Friday."
  static let packetsCap = 3

  func build(_ n: Int) -> HandoffPacket {
    HandoffPacket(
      in: room, n: n, handoff: "h\(n)", parent: n > 1 ? n - 1 : nil, from: "Serein", to: "Writer", chain: ["Serein", "Writer"],
      createdAt: Self.base, rules: "", contract: .init(task: "Draft the reply."),
      personWords: [.init(text: Self.personWords, at: Self.base)], summary: "Asked for a draft.", decisions: ["Formal tone"],
      openAsks: [], files: [.init(path: "/tmp/notes.md")],
      trail: [.init(tool: "web_open", target: "example.com", ok: true, at: Self.base)])
  }

  static func steps(_ w: PacketWorld) -> [(label: String, next: PacketWorld)] {
    var out: [(label: String, next: PacketWorld)] = []
    if !w.room.personal {
      var n = w
      n.room.markPersonal()
      out.append(("the room reads private data", n))
    }
    if w.packets.count < packetsCap {
      var n = w
      n.packets.append(w.build(w.packets.count + 1))
      n.markedAtBuild.append(w.room.personal)
      out.append(("packet \(w.packets.count + 1) is built", n))
    }
    for i in w.packets.indices {
      let k = i + 1
      var again = w
      again.packets[i] = w.build(k)
      again.markedAtBuild[i] = w.markedAtBuild[i] || w.room.personal
      if again != w { out.append(("a relaunch builds packet \(k) again", again)) }
      if w.sealed.file(k) == nil {
        var n = w
        n.sealed.seal(k, w.packets[i].markdown())
        out.append(("packet \(k) is sealed", n))
      }
      // Written, then sent: the receiver's room_read reads the sealed file.
      if w.sealed.file(k) != nil && !w.sent.contains(where: { $0.n == k }) {
        for withheld in [false, true] {
          let packet = withheld ? w.packets[i].withheld() : w.packets[i]
          var n = w
          n.sent.append(Sent(n: k, withheld: withheld, personal: packet.personal, builtPersonal: w.packets[i].personal, brief: packet.brief()))
          out.append(("packet \(k) is sent\(withheld ? " withheld" : "")", n))
        }
      }
    }
    return out
  }
}

enum PacketMachine {
  static var machine: FormalMachine<PacketWorld> {
    FormalMachine(
      name: "packet", bounds: "\(PacketWorld.packetsCap) packets, mark at any point, rebuilds, plain and withheld sends",
      start: PacketWorld(), steps: PacketWorld.steps,
      invariants: [
        ("a packet is sent only after it is built and sealed", { w in
          w.sent.allSatisfy { $0.n <= w.packets.count && w.sealed.file($0.n) != nil }
        }),
        ("the personal mark is never dropped", { w in
          zip(w.packets, w.markedAtBuild).allSatisfy { p, marked in
            !marked || (p.personal && p.withheld().personal && p.markdown().contains("personal: true"))
          }
            && w.sent.allSatisfy { s in
              s.personal == s.builtPersonal
                && (!(s.withheld && s.personal) || (s.brief.contains(HandoffPacket.withheldWords) && !s.brief.contains(PacketWorld.personWords)))
            }
        }),
      ],
      transitions: [
        ("a sealed file is never rewritten", { before, _, after in
          before.sealed.files.allSatisfy { after.sealed.files[$0.key] == $0.value }
        }),
        ("a marked room stays marked", { before, _, after in !before.room.personal || after.room.personal }),
      ])
  }
}
