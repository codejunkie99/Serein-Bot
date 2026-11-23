#if DEBUG
import Foundation
import SereinCore

extension AssistantCoreChecks {
  static func launchMode(_ check: Check) throws {
    let temp = ["/private/var/folders/xy/T", "/private/tmp"]
    let real = "/Users/sam/Library/Application Support/Serein/Library"
    let release = LaunchMode(arguments: ["Serein", "--verify-x"], checksBuilt: false)
    try check(!release.checking, "gate: a release build reads --verify… as nothing")
    try check(release.mayOpen(library: real, temporary: temp) && release.mayOpen(library: nil, temporary: temp),
      "gate: a normal launch opens the person's library")
    for (name, arguments) in [("check", ["--verify-x"]), ("preview", ["--ui-preview", "start"]), ("stress", ["--stress"])] {
      let mode = LaunchMode(arguments: ["Serein"] + arguments, checksBuilt: true)
      try check(!mode.mayOpen(library: nil, temporary: temp) && !mode.mayOpen(library: real, temporary: temp)
        && !mode.mayOpen(library: "/private/tmp", temporary: temp) && !mode.mayOpen(library: "/private/tmpx/a", temporary: temp),
        "gate: a \(name) run never opens the person's library, no library, a temp folder itself or a look-alike")
      try check(mode.mayOpen(library: "/private/tmp/serein-x", temporary: temp)
        && mode.mayOpen(library: "/private/var/folders/xy/T/serein-y", temporary: temp),
        "gate: a \(name) run opens a throwaway library under a temp folder")
    }
    let releasePreview = LaunchMode(arguments: ["Serein", "--ui-preview", "start"], checksBuilt: false)
    try check(!releasePreview.mayOpen(library: real, temporary: temp),
      "gate: a release preview still needs a throwaway library")
  }
}
#endif
