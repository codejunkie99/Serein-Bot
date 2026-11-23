import AppKit
import SereinCore
import SwiftUI

/// Mac tools while Accessibility is off (MacAccessWait). The first `mac_observe` or `mac_act` of
/// an assistant's chat puts one card in it and tells the model Serein waits; the person opens
/// Accessibility and drags Serein into the list. Serein looks again every 2 seconds and when it
/// becomes active; once macOS says yes the card becomes its line and the chat carries on in a
/// turn of its own, as a hand-off's result does. Serein never asks macOS or changes a setting here.
extension RelayOrchestrator {
  /// BrowserModel.perform: nil lets the call go ahead; else the result the model gets.
  func macAccessCall(_ tool: String, taskID: String) -> String? {
    guard MacAccessWait.tools.contains(tool) else { return nil }
    let thread = browser.threadID(forTask: taskID) ?? threadID
    // A task Serein started shows its card in the chat that started it.
    let chat = state.children.first { $0.threadID == thread }?.chatID ?? thread
    guard let result = macAccess.call(tool, chat: chat, granted: MacControl.accessibilityGranted(prompt: false)) else { return nil }
    saveMacAccess()
    watchMacAccess()
    return result
  }
  /// Every 2 seconds while a card waits, when Serein becomes active, on every tick, and when the
  /// floating drag card closes.
  func checkMacAccess() {
    guard !RunMode.automated else { return }
    if macAccess.waiting, MacControl.accessibilityGranted(prompt: false), macAccess.grant() { saveMacAccess() }
    if macAccess.waiting { watchMacAccess() } else { stopWatchingMacAccess() }
    deliverMacAccess()
  }
  /// The chat on screen whose grant came carries on once it is idle; another chat waits until it is
  /// opened (the next tick).
  private func deliverMacAccess() {
    guard !working, !state.paused, macAccess.carryOn(chat: threadID) else { return }
    saveMacAccess()
    startOwnTurn(MacAccessWait.followUp)
  }
  private func saveMacAccess() { persist(macAccess, Self.macAccessFile) }
  private func watchMacAccess() {
    guard macAccessWatch == nil, macAccess.waiting, !RunMode.automated else { return }
    macAccessActive = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkMacAccess() }
    }
    macAccessWatch = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        self?.checkMacAccess()
      }
    }
  }
  private func stopWatchingMacAccess() {
    macAccessWatch?.cancel()
    macAccessWatch = nil
    if let observer = macAccessActive { NotificationCenter.default.removeObserver(observer) }
    macAccessActive = nil
  }
}

/// The chat's one card while Serein waits for Accessibility, and the line once macOS said yes.
struct MacAccessCard: View {
  let state: MacAccessWait.State
  @Environment(\.palette) private var p
  var body: some View {
    switch state {
    // The same line the follow-up turn leaves in the chat.
    case .granted: AutomaticTurnLine(prompt: MacAccessWait.followUp, kind: .macAccess)
    case .waiting: card
    }
  }
  private var card: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        InterfaceIcon(systemName: MacAccess.Grant.accessibility.icon, size: 13)
          .foregroundStyle(p.secondary).padding(.top, 2).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("Let Serein use your Mac").font(UIStyle.bodyStrong).foregroundStyle(p.ink)
          Text("Open Accessibility, then drag Serein into the list.")
            .font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack(spacing: 10) {
        SereinAppTile(size: 32)
        Spacer(minLength: 0)
        Button("Open Accessibility") {
          MacAccess.openSettings(.accessibility)
        }.buttonStyle(PrimaryButton()).fixedSize()
          .help("Opens System Settings › Privacy & Security › Accessibility")
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .overlay(RoundedRectangle(cornerRadius: UIStyle.panelRadius).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Let Serein use your Mac")
  }
}
