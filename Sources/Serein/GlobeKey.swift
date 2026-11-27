import Darwin
import Foundation
import SereinCore

/// Applies `GlobeConflict.takeover` to this Mac: the Globe (Fn) key's macOS action goes to Do
/// Nothing while Fn calls Serein, and comes back when it no longer does.
@MainActor enum GlobeKey {
  private typealias Update = @convention(c) (Int32) -> Void

  static func apply(fnCalls: Bool, defaults: UserDefaults = .standard) {
    let saved = defaults.object(forKey: GlobeConflict.savedKey) as? Int
    switch GlobeConflict.takeover(fnCalls: fnCalls, current: GlobeConflict.current(), saved: saved) {
    case .keep: return
    case .take(let before):
      defaults.set(before, forKey: GlobeConflict.savedKey)
      set(GlobeConflict.doNothing)
    case .giveBack(let before):
      set(before)
      defaults.removeObject(forKey: GlobeConflict.savedKey)
    case .forget:
      defaults.removeObject(forKey: GlobeConflict.savedKey)
    }
  }

  private static func set(_ usage: Int) {
    // HIToolbox's own call, the one System Settings makes: it stores the choice and applies it at once.
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "TISUpdateFnUsageType") {
      unsafeBitCast(symbol, to: Update.self)(Int32(usage))
      return
    }
    // shortcut: without that call the stored value applies from the next login; fine while macOS keeps it.
    let hiToolbox = UserDefaults(suiteName: "com.apple.HIToolbox")
    hiToolbox?.set(usage, forKey: "AppleFnUsageType")
    hiToolbox?.synchronize()
  }
}
