#if DEBUG
import Foundation
import SereinCore

/// Launch probes only the AI apps the person chose (HarnessLaunchProbes); the rest wait for the
/// model picker, Settings, setup or a send.
extension AssistantCoreChecks {
  static func lazyLoadProbes(_ check: Check) throws {
    let helpers = Set(HelperWire.drivers)
    func probes(_ newChats: Provider?, _ relay: Provider?) -> Set<HarnessDriver> {
      HarnessLaunchProbes.drivers(newChats: newChats, relay: relay, helpers: helpers)
    }
    let all = Set(HarnessDriver.allCases)
    try check(
      probes(nil, nil) == all,
      "With no AI app chosen (a first launch, or only a local model), launch probes every app, as setup needs")
    try check(
      probes(Provider(.opencode), Provider(.opencode)) == [.opencode]
        && probes(.codex, .claude) == [.codex, .claude],
      "With apps chosen for new chats and for Serein's thinking, launch probes only those")
    try check(
      probes(Provider(.opencode), nil) == [.opencode, .claude, .codex],
      "With no thinking app chosen, Claude Code and Codex are probed too: Serein falls back to them")
    try check(
      !helpers.contains(.gemini)
        && probes(Provider(.gemini), Provider(.gemini)) == [.gemini, .claude, .codex],
      "A chosen app that answers no helper requests (Gemini CLI) brings Claude Code and Codex, which helpers fall back to")
    try check(
      !probes(.claude, .claude).contains(.cursor) && !probes(.claude, .claude).contains(.opencode),
      "Cursor's ACP model list and OpenCode's model list are not read at launch unless chosen")
  }
}
#endif
