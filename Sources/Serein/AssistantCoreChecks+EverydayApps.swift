#if DEBUG
import Foundation
import SereinCore

/// Setup's "Control your apps" (EverydayAppsAccess): the apps it asks macOS about, and only those.
extension AssistantCoreChecks {
  static func everydayApps(_ check: Check) throws {
    let ids = Set(EverydayAppsAccess.bundleIDs)
    for app in ["com.apple.systemevents", "com.apple.Safari", "com.apple.Notes", "com.apple.mail", "com.apple.finder"] {
      try check(ids.contains(app), "Setup asks macOS about \(app) once")
    }
    for never in ["com.apple.keychainaccess", "com.apple.Passwords", "com.agilebits.onepassword7", "com.apple.systempreferences", "com.apple.Terminal"] {
      try check(!ids.contains(never), "Setup never asks to control \(never)")
    }
    try check(ids.count == EverydayAppsAccess.bundleIDs.count, "Each app is asked about once")
  }
}
#endif
