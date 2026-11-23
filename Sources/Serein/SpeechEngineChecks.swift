#if DEBUG
import AVFoundation
import CryptoKit
import Foundation
import Network
import SereinCore

/// The speech engine on the real model, with no microphone and no sound played. Alone,
/// `--verify-speech-engine` has the Mac's own voice say a sentence into a file at a microphone's
/// 48 kHz and requires the engine to hear every word. With `<runs> <wav>...` after the flag it
/// feeds each recording at the pace it was spoken and prints the time from its end to the text.
/// A Mac without the model file has only the download to check.
@MainActor func checkSpeechEngine() async throws {
  try await checkSpeechDownload()
  guard SpeechEngine.modelFile() != nil else {
    print("SKIP speech engine: \(SpeechModel.fileName) is not on this Mac")
    return
  }
  func check(_ yes: Bool, _ label: String) throws {
    guard yes else { throw SereinError.invalid("Speech engine: " + label) }
  }
  let started = Date()
  await SpeechEngine.shared.warm()
  try check(SpeechEngine.shared.ready, "the model loads")
  print(String(format: "model loaded and warm in %.0f ms", Date().timeIntervalSince(started) * 1_000))

  final class Words: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ text: String) { lock.withLock { all.append(text) } }
    var seen: [String] { lock.withLock { all } }
  }
  /// One dictation from a file through the same feed and engine calls Dictation makes.
  func dictate(_ file: URL, paced: Bool) async throws -> (heard: SpeechEngine.Heard, release: Double, partials: [String]) {
    let audio = try AVAudioFile(forReading: file)
    let format = audio.processingFormat
    let words = Words()
    guard let id = SpeechEngine.shared.begin(onText: { words.add($0) }),
      let feed = SpeechFeed(from: format, dictation: id)
    else { throw SereinError.invalid("Speech engine: a dictation can begin") }
    try check(SpeechEngine.shared.begin(onText: { _ in }) == nil, "a second dictation cannot take the engine")
    let began = Date()
    var fed = 0.0
    while audio.framePosition < audio.length {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024) else { break }
      try audio.read(into: buffer)
      fed += Double(buffer.frameLength) / format.sampleRate
      let wait = fed - Date().timeIntervalSince(began)
      if paced, wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
      feed.append(buffer)
    }
    let released = Date()
    let heard = await SpeechEngine.shared.finish(id)
    return (heard, Date().timeIntervalSince(released) * 1_000, words.seen)
  }
  func plain(_ text: String) -> [String] {
    text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
  }

  let arguments = CommandLine.arguments
  let extra = Array(arguments[(arguments.firstIndex(of: "--verify-speech-engine")! + 1)...]).filter { !$0.hasPrefix("-") && $0 != "<false/>" }
  if let runs = extra.first.flatMap({ Int($0) }), extra.count > 1 {
    for path in extra.dropFirst() {
      for run in 0..<runs {
        let result = try await dictate(URL(fileURLWithPath: path), paced: true)
        print(String(format: "%@ run %d release_to_text_ms %.0f partials %d", (path as NSString).lastPathComponent, run, result.release, result.partials.count))
        if run == 0 { print("  " + result.heard.text) }
      }
    }
    return
  }

  let sentence = "Please move my meeting with the design team to Thursday morning and send them the new budget."
  let file = FileManager.default.temporaryDirectory.appendingPathComponent("serein-speech-check-\(UUID().uuidString).wav")
  defer { try? FileManager.default.removeItem(at: file) }
  let say = Process()
  say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
  say.arguments = ["-o", file.path, "--data-format=LEF32@48000", sentence]
  try say.run()
  say.waitUntilExit()
  try check(say.terminationStatus == 0, "the Mac's voice writes the test sentence to a file")

  let first = try await dictate(file, paced: false)
  try check(plain(first.heard.text) == plain(sentence), "every word of the sentence is heard, got: " + first.heard.text)
  try check(first.heard.segments.count == plain(sentence).count
    && plain(first.heard.segments.map(\.text).joined(separator: " ")) == plain(sentence),
    "each word is a segment, got: " + first.heard.segments.map(\.text).joined(separator: "|"))
  try check(first.heard.segments.allSatisfy { $0.confidence > 0 && $0.confidence <= 1 }, "each word says how sure the model was")
  try check(TalkProofread.lowSegments(first.heard.segments).isEmpty, "clear speech sends nothing to proofreading")
  try check(!first.partials.isEmpty && first.partials.allSatisfy { !$0.isEmpty || first.partials.count > 1 },
    "words arrive while the sentence is still being fed")
  let second = try await dictate(file, paced: false)
  try check(second.heard.text == first.heard.text, "the engine is free again and hears the same the second time")
  print(String(format: "release_to_text_ms %.0f, then %.0f", first.release, second.release))
  print("speech engine checks passed: " + first.heard.text)
}

/// The speech model's download (SpeechModelDownload) against a server on this Mac alone, with a
/// small file in the model's place: nothing is fetched from the internet and no model is loaded.
@MainActor private func checkSpeechDownload() async throws {
  func check(_ yes: Bool, _ label: String) throws {
    guard yes else { throw SereinError.invalid("Speech model download: " + label) }
  }
  let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
  let sum = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
  let server = try await CheckServer { path in
    switch path {
    case "/model": return ("200 OK", [], body, false)
    case "/other": return ("200 OK", [], Data(body.reversed()), false)
    case "/long": return ("200 OK", [], body + body, false)
    case "/moved": return ("302 Found", ["Location: /model"], Data(), false)
    case "/stall": return ("200 OK", [], body, true)
    default: return ("404 Not Found", [], Data(), false)
    }
  }
  defer { server.stop() }
  let fm = FileManager.default
  let folder = fm.temporaryDirectory.appendingPathComponent("serein-speech-download-\(UUID().uuidString)")
  defer { try? fm.removeItem(at: folder) }
  let target = folder.appendingPathComponent("Models/model.gguf")
  var ran = 0
  func download(_ path: String) -> SpeechModelDownload {
    SpeechModelDownload(
      .init(source: URL(string: "http://127.0.0.1:\(server.port)\(path)")!, bytes: Int64(body.count), sha256: sum, target: target)
    ) { ran += 1 }
  }
  func kept() -> [String] { (try? fm.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)) ?? [] }
  func failed(_ path: String, saying words: String) async -> Bool {
    let one = download(path)
    await one.start()?.value
    guard case .failed(let reason) = one.state else { return false }
    return reason.contains(words) && kept().isEmpty && ran == 0
  }
  try check(await failed("/other", saying: "not the file Serein expects"), "a file with another checksum is deleted")
  try check(await failed("/long", saying: "larger than Serein expects"), "a longer file is stopped and nothing is kept")
  try check(await failed("/moved", saying: "answered 302"), "a redirect to a host that is not Hugging Face's is not followed")
  try check(await failed("/missing", saying: "answered 404"), "an answer that is not the file is not kept")

  let stalled = download("/stall")
  let waiting = stalled.start()
  try check(stalled.working, "a download shows as under way")
  try await Task.sleep(nanoseconds: 300_000_000)
  stalled.cancel()
  await waiting?.value
  try check(stalled.state == .idle && kept().isEmpty && ran == 0, "Cancel stops the download and keeps nothing, got: \(stalled.state)")

  let good = download("/model")
  await good.start()?.value
  try check(good.state == .done && (try? Data(contentsOf: target)) == body && kept() == ["model.gguf"] && ran == 1,
    "the checked file is kept under its own name and the engine is told, got: \(good.state)")
  try check(good.start() == nil, "a finished download does not start again")
  // With SEREIN_SPEECH_MODEL_URL set, the real file from that address too, into a folder of the check's own.
  if ProcessInfo.processInfo.environment["SEREIN_SPEECH_MODEL_URL"] != nil {
    var real = SpeechModelDownload.File.pinned
    real.target = folder.appendingPathComponent("Real/" + SpeechModel.fileName)
    let began = Date()
    let whole = SpeechModelDownload(real) {}
    await whole.start()?.value
    try check(whole.state == .done, "the real model file passes its pinned length and checksum, got: \(whole.state)")
    print(String(format: "real model fetched and checked in %.1f s", Date().timeIntervalSince(began)))
  }
  print("speech model download checks passed")
}

/// A web server on this Mac alone (127.0.0.1) for the download checks. `answer` gives a path its
/// status line, extra headers and body; `hold` sends half the body and then nothing.
private final class CheckServer: @unchecked Sendable {
  private let listener: NWListener
  var port: UInt16 { listener.port?.rawValue ?? 0 }

  init(_ answer: @escaping @Sendable (String) -> (status: String, headers: [String], body: Data, hold: Bool)) async throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, _, _ in
        let path = String(decoding: data ?? Data(), as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let reply = answer(path)
        let head = "HTTP/1.1 \(reply.status)\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n"
          + reply.headers.map { $0 + "\r\n" }.joined() + "\r\n"
        let sent = reply.hold ? reply.body.prefix(reply.body.count / 2) : reply.body
        connection.send(content: Data(head.utf8) + sent, completion: .contentProcessed { _ in
          if !reply.hold { connection.cancel() }
        })
      }
    }
    try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: ready.resume()
        case .failed(let error): ready.resume(throwing: error)
        default: return
        }
        listener.stateUpdateHandler = nil
      }
      listener.start(queue: .global())
    }
  }
  func stop() { listener.cancel() }
}
#endif
