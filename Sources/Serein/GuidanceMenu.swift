import AppKit
import SereinCore

/// Standard macOS Help actions, available independently of a tab or a running task.
@MainActor final class GuidanceMenu: NSObject {
  static let shared = GuidanceMenu()
  func install(in main: NSMenu) {
    let help = NSMenu(title: "Help")
    func add(_ title: String, _ action: Selector) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      help.addItem(item)
    }
    add("Talk to Serein", #selector(talkToSerein))
    add("Keyboard Shortcuts", #selector(shortcuts))
    help.addItem(.separator())
    add("Serein Website", #selector(website))
    add("Privacy Policy", #selector(privacy))
    let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
    item.submenu = help
    main.addItem(item)
    NSApp.helpMenu = help
  }
  @objc private func talkToSerein() {
    // Leave a nested confirmation or sign-in sheet in place; ordinary Settings can give the
    // conversation back without changing its draft or any setup choices.
    let window = (NSApp.delegate as? AppDelegate)?.window
    if window?.attachedSheet?.attachedSheet == nil, NSApp.modalWindow == nil,
      !SereinConnect.shared.presented {
      SereinRouter.browser?.showSettings = false
    }
    SereinRouter.bringWindowForward?()
    SereinRouter.show()
  }
  @objc private func shortcuts() { RelayController.shared?.openSettings("Keyboard") }
  @objc private func website() { open("https://serein.pro") }
  @objc private func privacy() { open("https://serein.pro/privacy.html") }
  private func open(_ address: String) {
    guard let browser = BrowserContext.browser else { return }
    browser.openInDefaultBrowser(address)
    SereinRouter.bringWindowForward?()
  }
}
