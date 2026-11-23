import AVFoundation
import Foundation

/// Who reads Serein's replies aloud: this Mac's own voice, or Grok's or ChatGPT's voice with the
/// person's API key. A cloud voice sends only the reply being read, to that company's own server;
/// the key stays in this Mac's Keychain and never enters a chat, a prompt or a log.
enum VoiceProvider: String, CaseIterable, Identifiable {
  case mac, grok, openai
  static let defaultsKey = "serein.voice.provider"
  static let voiceKey = "serein.voice.name"
  var id: String { rawValue }
  var title: String {
    switch self {
    case .mac: return "This Mac"
    case .grok: return "Grok"
    case .openai: return "ChatGPT"
    }
  }
  var company: String { self == .grok ? "xAI" : "OpenAI" }
  var keyName: String { company + " API key" }
  var keyPage: URL? {
    switch self {
    case .mac: return nil
    case .grok: return URL(string: "https://console.x.ai")
    case .openai: return URL(string: "https://platform.openai.com/api-keys")
    }
  }
  var keyPlaceholder: String { self == .grok ? "xai-…" : "sk-…" }
  /// Voice ids each company documents (xAI: docs.x.ai text-to-speech; OpenAI: audio/speech).
  var voices: [String] {
    switch self {
    case .mac: return []
    case .grok: return ["eve", "ara", "rex", "sal", "leo"]
    case .openai: return ["coral", "alloy", "ash", "ballad", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]
    }
  }
  var keychain: KeychainItem { KeychainItem(service: "local.serein.voice", account: rawValue) }
  var hasKey: Bool { self == .mac || keychain.exists }

  static var chosen: VoiceProvider {
    VoiceProvider(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .mac
  }
  /// The chosen voice id, or the company's first when none of its own is saved.
  static func voice(for provider: VoiceProvider) -> String {
    let saved = UserDefaults.standard.string(forKey: voiceKey) ?? ""
    return provider.voices.contains(saved) ? saved : provider.voices.first ?? ""
  }

  /// One request for the spoken reply as MP3. Error bodies are never read back: they can echo the
  /// key or the text.
  func speech(_ text: String, voice: String) async throws -> Data {
    guard let key = keychain.read(), !key.isEmpty else { throw CloudVoiceError.noKey(self) }
    var request: URLRequest
    let body: [String: Any]
    switch self {
    case .mac: throw CloudVoiceError.failed(self)
    case .grok:
      request = URLRequest(url: URL(string: "https://api.x.ai/v1/tts")!)
      body = ["text": text, "voice_id": voice, "language": "auto", "output_format": ["codec": "mp3"]]
    case .openai:
      request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
      body = ["model": "gpt-4o-mini-tts", "input": text, "voice": voice, "response_format": "mp3"]
    }
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    switch status {
    case 200..<300 where !data.isEmpty: return data
    case 401, 403: throw CloudVoiceError.rejected(self)
    case 402, 429: throw CloudVoiceError.limited(self)
    default: throw CloudVoiceError.failed(self)
    }
  }
}

enum CloudVoiceError: LocalizedError {
  case noKey(VoiceProvider), rejected(VoiceProvider), limited(VoiceProvider), failed(VoiceProvider)
  var errorDescription: String? {
    switch self {
    case .noKey(let p): return "Add your \(p.keyName) under Voice chat to hear \(p.title)'s voice."
    case .rejected(let p): return "\(p.company) didn't accept the API key. Check it under Voice chat."
    case .limited(let p): return "\(p.company) is out of credits or busy. Serein read this one with this Mac's voice."
    case .failed(let p): return "\(p.title)'s voice didn't answer. Serein read this one with this Mac's voice."
    }
  }
}

/// Plays a cloud voice's audio and reports its start, its loudness (for the hologram) and its end.
@MainActor final class CloudVoicePlayer: NSObject, AVAudioPlayerDelegate {
  private var player: AVAudioPlayer?
  private var meter: Timer?
  private var task: Task<Void, Never>?
  private var finished: (() -> Void)?

  /// Fetches and plays `text`. `failed` gets the reason when nothing could be played, so the caller
  /// can read it with this Mac's voice instead.
  func speak(_ text: String, provider: VoiceProvider, started: @escaping () -> Void, level: @escaping (Double) -> Void,
             finished: @escaping () -> Void, failed: @escaping (Error) -> Void) {
    stop()
    // shortcut: one request of at most 4000 characters (OpenAI's limit is 4096); split it into passages if long replies matter.
    let words = String(text.prefix(4000))
    task = Task { [weak self] in
      do {
        let audio = try await provider.speech(words, voice: VoiceProvider.voice(for: provider))
        guard !Task.isCancelled, let self else { return }
        let player = try AVAudioPlayer(data: audio)
        player.delegate = self
        player.isMeteringEnabled = true
        self.player = player
        self.finished = finished
        guard player.play() else { throw CloudVoiceError.failed(provider) }
        started()
        self.meter = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
          Task { @MainActor in
            guard let player = self.player, player.isPlaying else { return }
            player.updateMeters()
            let power = Double(player.averagePower(forChannel: 0))
            if power > -30 { level(min(1, 0.35 + (power + 30) / 40)) }
          }
        }
      } catch {
        guard !Task.isCancelled else { return }
        failed(error)
      }
    }
  }
  func stop() {
    task?.cancel()
    task = nil
    meter?.invalidate()
    meter = nil
    let done = finished
    finished = nil
    if player?.isPlaying == true { player?.stop() }
    player = nil
    done?()
  }
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor in self.stop() }
  }
  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    Task { @MainActor in self.stop() }
  }
}
