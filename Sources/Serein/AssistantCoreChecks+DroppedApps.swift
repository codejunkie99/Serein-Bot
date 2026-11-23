#if DEBUG
import Foundation
import SereinCore

/// Saved state from before Serein dropped two AI apps still reads: their entries go, or fall back
/// to the usual default, and nothing else is lost.
extension AssistantCoreChecks {
  static func droppedApps(_ check: Check) throws {
    let decoder = JSONDecoder()
    func instance(_ driver: String, path: String? = nil) -> String {
      #"{"id":"\#(driver)","driver":"\#(driver)","enabled":false,"userChose":true,"environment":{}"#
        + (path.map { #","binaryPath":"\#($0)""# } ?? "") + "}"
    }
    let saved = #"{"instances":["#
      + [instance("hermes"), instance("commandcode"), instance("commandCode"), instance("pi", path: "/opt/pi/bin/pi")]
        .joined(separator: ",") + "]}"
    var settings = try decoder.decode(HarnessSettings.self, from: Data(saved.utf8))
    let kept = settings.instances
    settings.normalize()
    try check(
      kept.map(\.driver) == [.pi] && kept.first?.binaryPath == "/opt/pi/bin/pi"
        && settings.instances.map(\.driver) == HarnessDriver.allCases
        && settings.instance(.pi).binaryPath == "/opt/pi/bin/pi" && settings.instance(.pi).enabled == false,
      "AI app settings with Hermes and Command Code entries keep the valid entry and drop only those")

    func setup(_ json: String) -> SereinChatSetupState? {
      try? decoder.decode(SereinChatSetupState.self, from: Data(json.utf8))
    }
    let connecting = setup(#"{"phase":"model","selectedHarness":"hermes","threadID":"t1"}"#)
    let finished = setup(#"{"phase":"complete","selectedHarness":"commandcode","selectedModel":"m","threadID":"t1"}"#)
    try check(
      connecting?.phase == .harness && connecting?.selectedHarness == nil && connecting?.selectedModel == nil
        && finished?.phase == .complete && finished?.selectedHarness == nil,
      "A setup on a dropped app asks for the app again; a finished one stays finished")

    let ledger = try decoder.decode([AgentHistoryHarness].self, from: Data(#"["hermes","commandcode","pi"]"#.utf8))
    try check(
      ledger == [.hermes, .commandCode, .pi] && ledger.map(\.displayName) == ["Hermes Agent", "Command Code", "Pi"],
      "Agent history recorded on a dropped app still reads, under its old name")

    let dropped = [Provider(rawValue: "hermes"), Provider(rawValue: "commandcode")]
    try check(
      dropped.allSatisfy { !Provider.allCases.contains($0) && $0.driver == nil && !$0.thinksForSerein }
        && HarnessDriver(rawValue: "hermes") == nil && HarnessDriver(rawValue: "commandcode") == nil,
      "A saved choice of a dropped app is unknown, so a chat or default on it moves to the usual default")

    let owners = ["hermes", "commandcode", Provider.codex.rawValue]
    let threads = "[" + owners.map {
      #"{"id":"\#($0)","title":"t","messages":[{"id":"m","role":"you","text":"hi"}],"provider":"\#($0)","mode":"Answer","#
        + #""scope":"","updatedAt":0,"link":{"driver":"\#($0)","nativeID":"n"}}"#
    }.joined(separator: ",") + "]"
    let chats = try decoder.decode([Conversation].self, from: Data(threads.utf8))
    try check(
      chats.map(\.id) == owners && chats.allSatisfy { $0.messages.map(\.text) == ["hi"] },
      "Saved chats on a dropped app load beside the others, with their messages")

    let index = try decoder.decode(SessionHistory.self, from: Data(#"{"entries":{},"format":2}"#.utf8))
    try check(
      !index.isCurrent && SessionHistory().isCurrent,
      "An index of other apps' chats saved before the drop is read again whole, so their chats leave it")
  }
}
#endif
