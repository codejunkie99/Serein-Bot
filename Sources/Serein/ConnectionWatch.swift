import AppKit
import Combine
import SwiftUI

/// Keeps every connect surface (the Marketplace, the chat's connect cards and pills) current
/// without reopening it. A sign-in finishes in the browser and macOS access changes in System
/// Settings, both outside Serein, so when Serein comes back to the front the watch moves
/// `generation` (views that read macOS or user-default state redraw) and reads Composio's accounts
/// again, at most every few seconds. It reads; it never connects or turns anything on.
@MainActor final class ConnectionWatch: ObservableObject {
  static let shared = ConnectionWatch()
  /// Moves each time Serein comes back to the front.
  @Published private(set) var generation = 0
  private var lastRefresh = Date.distantPast
  private var observer: NSObjectProtocol?
  private static let minGap: TimeInterval = 5

  private init() {
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.cameBack() }
    }
  }

  private func cameBack() {
    generation += 1
    refreshAccounts()
  }

  /// Composio's accounts, read again unless they were read a moment ago or Composio is off.
  func refreshAccounts() {
    guard ComposioApps.available, Date().timeIntervalSince(lastRefresh) >= Self.minGap else { return }
    lastRefresh = Date()
    Task { try? await ComposioApps.shared.refresh() }
  }
}
