import Foundation

/// Which tabs may leave the app for grouping or comparing. Sign-in, payment and account pages,
/// private tabs, agent tabs and excluded sites never do.
public enum TabEligibility {
  public static func allows(
    address: String, isPrivate: Bool, isAgentTab: Bool, excludedSites: [String]
  ) -> Bool {
    guard !isPrivate, !isAgentTab, !address.isEmpty,
      let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()),
      !SensitivePage.isSensitive(address: address)
    else { return false }
    let host = url.host?.lowercased() ?? ""
    return !excludedSites.contains { !$0.isEmpty && (host == $0 || host.hasSuffix("." + $0)) }
  }
}
