import Foundation
import SereinCore

/// What the chat's level opens natively, one rule for every CLI (R7): at Allow all on a run that
/// asks nothing, home is writable past the protected folders and Serein's own data, and the
/// network is on. At Auto and Manual the task folder only.
extension TurnRequest {
  var opensHome: Bool { ACPGrant.of(self).opensHome }
}
