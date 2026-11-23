import AVFoundation
import SereinCore
import SwiftUI

/// Plays one kept recording at a time.
@MainActor final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
  /// Recordings playing now: the wake phrase pauses meanwhile, so a kept “Serein …” never asks again.
  private(set) static var active = 0
  @Published var playing: String? {
    didSet {
      guard (playing != nil) != (oldValue != nil) else { return }
      Self.active += playing != nil ? 1 : -1
      NotificationCenter.default.post(name: Dictation.claimsChanged, object: nil)
    }
  }
  private var player: AVAudioPlayer?
  func toggle(_ entry: TalkRecording, store: TalkRecordingStore) {
    if playing == entry.id { return stop() }
    stop()
    guard let next = try? AVAudioPlayer(contentsOf: store.audioURL(entry.id)) else { return }
    next.delegate = self
    player = next
    if next.play() { playing = entry.id }
  }
  func stop() {
    player?.stop()
    player = nil
    playing = nil
  }
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor in
      self.player = nil
      self.playing = nil
    }
  }
}

/// Settings › Voice › Privacy: what was kept, with playback and deletion.
struct TalkRecordingsList: View {
  @Environment(\.palette) var p
  @StateObject private var player = RecordingPlayer()
  @State private var entries: [TalkRecording] = []
  private let store = PushToTalk.recordings
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if entries.isEmpty {
        Text("Nothing is kept yet.").role(.meta)
      } else {
        ForEach(entries) { entry in row(entry) }
        Button("Delete all \(entries.count)") {
          player.stop()
          PushToTalk.deleteAllRecordings()
          reload()
        }.buttonStyle(QuietButton())
      }
    }
    .onAppear(perform: reload)
    .onDisappear { player.stop() }
    .onReceive(NotificationCenter.default.publisher(for: .sereinRecordingsChanged)) { _ in reload() }
  }
  private func reload() { entries = store.entries() }
  private func row(_ entry: TalkRecording) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(entry.date.formatted(date: .abbreviated, time: .shortened)).role(.meta)
          if entry.duration > 0 {
            Text(TaskClock.short(entry.duration.rounded())).font(UIStyle.microMono)
              .foregroundStyle(p.faint)
          }
        }
        Text(entry.text.isEmpty ? "No text was saved." : entry.text).font(UIStyle.body)
          .foregroundStyle(entry.text.isEmpty ? p.faint : p.ink).lineLimit(3)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button(player.playing == entry.id ? "Stop" : "Play") { player.toggle(entry, store: store) }
        .buttonStyle(QuietButton())
        .accessibilityLabel(player.playing == entry.id ? "Stop playback" : "Play recording")
      Button("Delete") {
        if player.playing == entry.id { player.stop() }
        store.remove(entry.id)
        reload()
      }.buttonStyle(QuietButton()).accessibilityLabel("Delete recording")
    }
    .padding(10).background(p.hover, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
  }
}
