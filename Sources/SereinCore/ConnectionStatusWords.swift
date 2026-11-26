/// The status line under each app in the Marketplace (Your apps, On this Mac): one or two words. What the app may
/// do lives behind the row's chevron and the list's info button, not in the row.
public enum ConnectionStatusWords {
  public static let on = "On"
  public static let off = "Off"
  public static let blocked = "Blocked by macOS"

  public static func words(isOn: Bool, blockedByMacOS: Bool) -> String {
    guard isOn else { return off }
    return blockedByMacOS ? blocked : on
  }

  /// The "On this Mac" info button: what reading means, then how Mail and Messages connect.
  public static let onThisMacInfo =
    "Serein reads these on your Mac and sends what it reads to the AI app you chose, so it can answer. "
    + "Sending, changing or deleting always asks you first. Mail and Messages use every account in "
    + "Internet Accounts; Serein keeps no password or token for them. Turning one off stops Serein using it at once."
}
