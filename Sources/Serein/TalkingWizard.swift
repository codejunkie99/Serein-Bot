import AppKit
import SereinCore
import SwiftUI

/// Three short steps: microphone, key, first try. Used in Settings › Voice and as the last setup step.
/// Recognition is Apple Speech with on-device recognition required, so nothing is downloaded.
struct TalkingWizard: View {
  @Environment(\.palette) private var p
  @AppStorage(TalkKey.enabledKey) private var enabled = false
  @AppStorage(TalkKey.defaultsKey) private var keyName = TalkKey.fn.rawValue
  @StateObject private var meter = MicMeter()
  @StateObject private var dictation = Dictation()
  @State private var stage = 0
  @State private var usage = GlobeConflict.current()
  @State private var heard = ""
  @State private var trying = false
  @State private var finished = false
  private let sample = "The quiet browser keeps my work in one place."
  private var key: TalkKey { TalkKey(rawValue: keyName) ?? .fn }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Runs on this Mac with Apple Speech. There is no speech model to download.").role(.meta)
      HStack(spacing: 8) {
        ForEach(0..<3, id: \.self) { i in
          Capsule().fill(i <= stage ? p.accent : p.track).frame(height: 3)
        }
      }.accessibilityHidden(true)
      switch stage {
      case 0: microphone
      case 1: keyChoice
      default: tryIt
      }
    }.onChange(of: dictation.error) { _, error in
      if error != nil { trying = false }
    }.onDisappear {
      meter.stop()
      dictation.stop()
    }
  }

  private var microphone: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("1. Microphone").role(.section)
      Text("Say anything. The bar should move. Serein only measures loudness here; nothing is recognized or saved.")
        .role(.meta)
      HStack(spacing: 12) {
        Button(meter.running ? "Stop test" : "Test microphone") { meter.toggle() }
          .buttonStyle(QuietButton())
        ZStack(alignment: .leading) {
          Capsule().fill(p.track)
          Capsule().fill(p.accent).frame(width: max(4, 200 * CGFloat(meter.level)))
        }.frame(width: 200, height: 4).accessibilityElement()
          .accessibilityLabel("Microphone level")
          .accessibilityValue("\(Int(meter.level * 100)) percent")
        Spacer()
      }
      if let message = meter.message { Text(message).role(.meta).foregroundStyle(p.warning) }
      HStack {
        Spacer()
        Button("Next") {
          meter.stop()
          stage = 1
        }.buttonStyle(PrimaryButton())
      }
    }
  }

  private var keyChoice: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("2. Choose the key").role(.section)
      Text("Hold it while Serein is in front, speak, and let go.").role(.meta)
      Picker("Key", selection: $keyName) {
        ForEach(TalkKey.allCases) { Text($0.title).tag($0.rawValue) }
      }.fixedSize()
      if let warning = GlobeConflict.warning(for: key, usage: usage) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          InterfaceIcon(systemName: "exclamationmark.triangle", size: 13).foregroundStyle(p.warning)
          Text(warning).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button("Check again") { usage = GlobeConflict.current() }
        }.font(UIStyle.meta)
      } else if key == .fn {
        Text("The Globe key does nothing else on this Mac, so there is no conflict.").role(.meta)
      }
      HStack {
        Button("Back") { stage = 0 }
        Spacer()
        Button("Next") { stage = 2 }.buttonStyle(PrimaryButton())
      }
    }
  }

  private var tryIt: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("3. Try it").role(.section)
      Text("Choose Start, read this sentence aloud, then choose Stop.").role(.meta)
      Text("“\(sample)”").role(.reading).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      HStack(spacing: 12) {
        Button(trying ? "Stop" : (heard.isEmpty ? "Start" : "Try again")) { toggleTry() }
          .buttonStyle(PrimaryButton())
        if trying {
          DictationLevelBar(meter: dictation.meter)
        }
      }
      if !heard.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Heard").role(.micro)
          Text(heard).role(.reading).textSelection(.enabled)
        }
      }
      if let error = dictation.error { Text(error).role(.meta).foregroundStyle(p.warning) }
      if finished {
        HStack(spacing: 6) {
          InterfaceIcon(systemName: "checkmark.circle.fill", size: 13).foregroundStyle(p.success)
          Text("Talking is on. Hold \(key.title) in any field while Serein is in front.").role(.meta)
        }
      }
      HStack {
        Button("Back") {
          dictation.stop()
          trying = false
          stage = 1
        }
        Spacer()
        Button(finished ? "Keep talking on" : "Turn talking on") {
          dictation.stop()
          trying = false
          enabled = true
          finished = true
        }.buttonStyle(PrimaryButton()).disabled(finished)
      }
    }
  }

  private func toggleTry() {
    if trying {
      trying = false
      Task {
        let text = await dictation.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        heard = text.isEmpty ? "Nothing was heard. Check the microphone and try again." : text
      }
    } else {
      heard = ""
      meter.stop()
      trying = true
      dictation.start { _ in }
      // start() can fail asynchronously (permission denied); the error is shown from dictation.error.
    }
  }
}

/// The live level while the sample is read: it watches only the meter, so the step around it does
/// not redraw with every block of audio.
private struct DictationLevelBar: View {
  @ObservedObject var meter: DictationMeter
  @Environment(\.palette) private var p
  var body: some View {
    ZStack(alignment: .leading) {
      Capsule().fill(p.track)
      Capsule().fill(p.accent).frame(width: max(4, 160 * CGFloat(meter.level)))
    }.frame(width: 160, height: 4).accessibilityHidden(true)
  }
}
