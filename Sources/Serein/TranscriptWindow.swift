import SwiftUI

/// How much of a chat its own layout builds. A chat's rows are eager so their native text keeps
/// stable heights, so a long chat draws only its newest messages itself; the older ones are built
/// above them as the person scrolls up, outside its layout (`EarlierPages`).
enum TranscriptWindow {
  static let newest = 30
}

/// A chat's scroll view: each thread gets its own, which opens at the foot of the chat and stays
/// there while the rows above it settle their heights.
struct TranscriptOpensAtEnd: ViewModifier {
  let thread: String
  func body(content: Content) -> some View {
    content
      .defaultScrollAnchor(.bottom)
      .id(thread)
  }
}
