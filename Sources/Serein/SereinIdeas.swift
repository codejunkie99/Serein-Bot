import AppKit
import SereinCore
import SwiftUI

/// Suggested things to ask Serein with the apps the person connected (IntegrationIdeas): buttons
/// under each connected app in Settings › Connections, and the examples of a new chat. A click is
/// the person's own message: Settings closes, Serein's chat shows and the words are sent. Every
/// step that sends, changes or deletes still asks on its card.
@MainActor enum SereinIdeas {
  /// The apps that are on now, by IntegrationIdeas id.
  static func connectedApps() -> Set<String> {
    var apps: Set<String> = []
    if GateSettings.shared.bool(forKey: Connections.key(.mail)) { apps.insert("mail") }
    if GateSettings.shared.bool(forKey: Connections.key(.messages)) { apps.insert("messages") }
    for connection in NativeConnection.allCases where connection.isOn() { apps.insert(connection.rawValue) }
    let composio = ComposioApps.shared
    if composio.on { for account in composio.accounts { apps.insert(account.app.lowercased()) } }
    return apps
  }

  /// A new chat's ideas: up to `limit` for the connected apps.
  static func forNewChat(limit: Int = 4) -> [SereinIdea] {
    IntegrationIdeas.pick(connected: connectedApps(), limit: limit).map { SereinIdea(app: $0.app, text: $0.text) }
  }

  /// Sends the idea as the person's message. While Serein is replying the words wait in the
  /// composer instead, so a click never stops the reply in progress.
  static func ask(_ text: String) {
    // Leave Settings, unless a nested sheet or an AI-app connection is still open there.
    let window = (NSApp.delegate as? AppDelegate)?.window
    if window?.attachedSheet?.attachedSheet == nil, NSApp.modalWindow == nil, !SereinConnect.shared.presented {
      SereinRouter.browser?.showSettings = false
    }
    SereinRouter.bringWindowForward?()
    guard let relay = RelayController.shared?.relay, !relay.working else {
      SereinRouter.show(draft: text)
      return
    }
    SereinRouter.show()
    relay.ask(text)
  }
}

/// One suggestion in a new chat: its words and the app it uses (nil for a general example).
struct SereinIdea: Hashable {
  var app: String?
  var text: String
}

/// The small icon for an app an idea uses: the Mac app's own icon, or the company's logo.
struct IdeaIcon: View {
  let app: String
  var size: CGFloat = 14
  private static let macApps: [String: String] = [
    "mail": "com.apple.mail", "messages": "com.apple.MobileSMS", "calendar": "com.apple.iCal",
    "reminders": "com.apple.reminders", "contacts": "com.apple.AddressBook", "notes": "com.apple.Notes",
  ]
  var body: some View {
    if let bundleID = Self.macApps[app] {
      MacAppIcon(bundleID: bundleID, size: size, fallback: "arrow.up.right")
    } else {
      BrandLogo(Brand.app(app), size: size, name: ConnectedApps.name(app))
    }
  }
}
