import Foundation
import SereinCore

/// Loads the bundled site-specific password rules.
enum SitePasswordQuirks {
  static let shared: PasswordQuirks = {
    guard let url = Bundle.assets.url(forResource: "password-rules", withExtension: "json", subdirectory: "Quirks"),
      let data = try? Data(contentsOf: url), let quirks = try? PasswordQuirks(json: data)
    else { return PasswordQuirks() }
    return quirks
  }()
}
