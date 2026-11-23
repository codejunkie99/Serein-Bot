#if DEBUG
import Foundation
import SereinCore

/// The owner's rules for Allow all (2026-11-16 and 2026-11-18): nothing asks but the floor.
/// Paying goes to the secure card, a password field and a password manager are the person's,
/// a code-running app is driven only through mac_run, and everything else runs, the person there
/// or not. Each rule is named, so a failure lists every one that broke.
extension AssistantCoreChecks {
  static func proactiveOwner(_ check: Check) throws {
    typealias Door = ApprovalDoor
    typealias Gate = ApprovalGate
    let task = Door.Standing.proactiveTask(present: true)
    let away = Door.Standing.proactiveTask(present: false)
    func door(_ step: Door.Step, _ standing: Door.Standing = task, _ facts: Door.Facts? = nil) -> Door.Answer {
      Door.answer(.init(step, standing), facts: facts ?? DoorTable.facts(for: step))
    }
    func press(_ label: String, kind: String = "click", app: String? = nil, role: String? = nil, text: String? = nil)
      -> Door.Answer
    {
      door(.action(Gate.GateAction(kind: kind, label: label, app: app, role: role, text: text)))
    }
    let acts: [(String, String?, String?)] = [
      ("computer_click", nil, nil), ("computer_type", nil, "hello"), ("computer_key", "return", nil),
      ("computer_key", "cmd+q", nil), ("computer_scroll", nil, nil), ("computer_open_url", nil, nil),
      ("computer_run", nil, "ls"),
    ]
    let pay = Door.Answer.blocked(.pay(ref: ""))
    let hold = Door.Answer.card(.hold(cap: Door.holdCap))
    var rules: [(String, Bool)] = [
      ("a terminal is driven only through mac_run",
       press("Next", app: "Terminal") == .blocked(.codeRunner)
         && press("", kind: "type", app: "Terminal", text: "sudo ls") == .blocked(.codeRunner)
         && press("Run", app: "Script Editor") == .blocked(.codeRunner)),
      ("settings run",
       door(.effect(.settings)) == .run && door(.setting(tool: "settings_set")) == .run
         && press("Wi-Fi", app: "System Settings") == .run),
      ("booking runs", door(.effect(.book)) == .run && press("Book") == .run),
      ("ordinary Mac control runs and a command requesting root stays with the person",
       acts.allSatisfy { door(.ownMachine(tool: $0.0, key: $0.1, text: $0.2)) == .run }
         && door(.ownMachine(tool: "computer_run", key: nil, text: "sudo ls")) == .blocked(.secret)),
      ("signing in runs",
       door(.effect(.access)) == .run && press("Sign out") == .run && door(.setting(tool: "agent_sign_in")) == .run),
      ("a password field is the person's", press("Password", kind: "type", role: "AXSecureTextField") == .blocked(.secret)),
      ("a password manager stays closed", press("Copy", app: "1Password") == .blocked(.privateStore)),
      ("a script that asks for a password is the person's",
       door(.script("do shell script \"ls\" with administrator privileges")) == .blocked(.secret)),
      ("paying goes to the secure card", door(.effect(.pay)) == pay && door(.effect(.pay), away) == pay),
      ("a payment the secure card or a grant covers runs",
       door(.effect(.pay), task, DoorTable.facts(pays: .yes(amount: "$49.00"), covered: true)) == .run),
      ("the secure card shows the amount",
       SecureCard.title(.card, host: "shop.example", amount: "$49.00") == "Pay $49.00 on shop.example"),
      ("a changed host key blocks its host only",
       door(.effect(.change), task, DoorTable.facts(hostKeyChanged: "build.example")) == .blocked(.hostKey(host: "build.example"))
         && door(.effect(.change), task, DoorTable.facts(hostKeyChanged: nil)) == .run),
    ]
    let others = Gate.Effect.allCases.filter { $0 != .pay }
    rules.append(("every other effect runs, the person there or not",
      others.allSatisfy { door(.effect($0)) == .run && door(.effect($0), away) == .run }))
    rules.append(("Only risky steps runs every effect but paying",
      others.allSatisfy { door(.effect($0), .person(.riskyOnly)) == .run } && door(.effect(.pay), .person(.riskyOnly)) == pay))
    rules.append(("Every step runs reads and shows a card for the rest",
      others.allSatisfy { effect in
        door(.effect(effect), .person(.everyStep)) == (Door.reads(.effect(effect)) ? .run : hold)
      }))
    let broken = rules.filter { !$0.1 }.map(\.0)
    try check(
      broken.isEmpty,
      "Allow all follows the owner's rules (\(rules.count) rules)"
        + (broken.isEmpty ? "" : ". Broken: \(broken.joined(separator: "; "))"))
  }
}
#endif
