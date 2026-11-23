import SereinCore
import SwiftUI

struct FirstRun<App: View>: View {
  let app: App
  @State private var page = FirstRunPage.opening()
  @Environment(\.palette) private var p

  var body: some View {
    if let page, let relay = RelayOrchestrator.shared {
      VStack(spacing: 0) {
        Spacer(minLength: 56)
        FirstRunPageView(page: page, relay: relay, go: go, finish: { finish(relay) }, deferred: endSetup)
          .frame(maxWidth: UIStyle.wide(440))
        Spacer(minLength: 24)
      }
      .padding(.horizontal, 32).padding(.bottom, 20)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .top) { dots(page).padding(.top, 20) }
      .background(p.background)
      .animation(.easeOut(duration: 0.2), value: page)
      .task {
        guard FirstRunPreview.seed != nil else { return }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if !Task.isCancelled { FirstRunPreview.apply() }
      }
    } else {
      app
    }
  }

  private func go(_ next: FirstRunPage) {
    FirstRunPage.remember(next)
    page = next
  }

  private func finish(_ relay: RelayOrchestrator) {
    endSetup()
    SereinChatSetup.shared.beginIfNeeded(relay)
  }

  private func endSetup() {
    FirstRunPage.remember(nil)
    SereinRouter.home()
    page = nil
  }

  private func dots(_ page: FirstRunPage) -> some View {
    let pages = FirstRunPage.allCases
    return HStack(spacing: 4) {
      ForEach(pages, id: \.self) { step in
        Capsule().fill(step == page ? p.ink : p.line).frame(width: step == page ? 16 : 6, height: 4)
      }
    }
    .accessibilityElement().accessibilityLabel("Step \((pages.firstIndex(of: page) ?? 0) + 1) of \(pages.count)")
  }
}
