import AppKit
import SereinCore
import SwiftUI

enum BrowserOnboardingPreview {
  static var profiles: [BrowserImportProfile] = []
}

private struct BrowserImportChoice {
  var selected = true
  var bookmarks = true
  var history = true
}

@MainActor final class BrowserImportModel: ObservableObject {
  @Published var profiles: [BrowserImportProfile]
  @Published private var choices: [String: BrowserImportChoice] = [:]
  @Published var previews: [String: BrowserImportPreview] = [:]
  @Published var phase = "Finding browser profiles on this Mac…"
  @Published var busy = false
  @Published var completed = false
  @Published var progress = 0
  @Published var result: String?

  private let suppliedProfiles: [BrowserImportProfile]?
  private var task: Task<Void, Never>?
  private var worker: Task<BrowserImportPreview, Error>?
  private var importWorker: Task<BrowserImportMergeResult, Error>?
  private var loaded = false

  init(profiles: [BrowserImportProfile]? = nil) {
    suppliedProfiles = profiles
    self.profiles = profiles ?? []
    if let profiles { setDefaults(for: profiles) }
  }

  deinit {
    task?.cancel()
    worker?.cancel()
    importWorker?.cancel()
  }

  var selectedCount: Int { profiles.filter { choices[$0.id]?.selected == true }.count }
  var hasPreview: Bool { !previews.isEmpty }
  var previewBookmarks: Int { previews.values.reduce(0) { $0 + $1.bookmarks.count } }
  var previewVisits: Int { previews.values.reduce(0) { $0 + $1.visits.count } }
  var previewSkipped: Int { previews.values.reduce(0) { $0 + $1.skipped } }
  var previewMessages: [String] {
    profiles.flatMap { profile in
      previews[profile.id]?.messages.map { "\(profile.browser) · \(profile.profile): \($0)" } ?? []
    }
  }

  fileprivate func choice(_ profile: BrowserImportProfile) -> BrowserImportChoice {
    choices[profile.id]
      ?? BrowserImportChoice(
        selected: true, bookmarks: profile.bookmarks != nil, history: profile.history != nil)
  }

  fileprivate func binding(
    _ profile: BrowserImportProfile, _ keyPath: WritableKeyPath<BrowserImportChoice, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: { self.choice(profile)[keyPath: keyPath] },
      set: { value in
        var choice = self.choice(profile)
        choice[keyPath: keyPath] = value
        if keyPath != \BrowserImportChoice.selected, value { choice.selected = true }
        self.choices[profile.id] = choice
        self.previews = [:]
        self.completed = false
        self.result = nil
        self.phase = "Review the profiles and choose what to bring over."
      })
  }

  func load() {
    guard !loaded else { return }
    loaded = true
    if let suppliedProfiles {
      profiles = suppliedProfiles
      setDefaults(for: suppliedProfiles)
      phase =
        suppliedProfiles.isEmpty
        ? "No synthetic profiles are available."
        : "Synthetic preview profiles are ready."
      return
    }
    busy = true
    task = Task {
      let found = await Task.detached(priority: .userInitiated) { BrowserProfileScanner.scan() }
        .value
      guard !Task.isCancelled else { return }
      profiles = found
      setDefaults(for: found)
      phase =
        found.isEmpty
        ? "No supported profiles were detected. Choose a browser folder to continue."
        : "Found \(found.count) profile\(found.count == 1 ? "" : "s") on this Mac."
      busy = false
    }
  }

  /// Looks again, keeping what is already chosen — the person may have just granted a
  /// permission in System Settings and come back. Onboarding calls this when its window
  /// regains focus; nothing is lost by running it any number of times.
  func redetect() {
    guard suppliedProfiles == nil, importWorker == nil else { return }
    busy = true
    phase = "Looking again…"
    task = Task {
      let found = await Task.detached(priority: .userInitiated) { BrowserProfileScanner.scan() }
        .value
      guard !Task.isCancelled else { return }
      let existing = Set(profiles.map(\.id))
      let fresh = found.filter { !existing.contains($0.id) }
      profiles.append(contentsOf: fresh)
      profiles.sort { ($0.browser, $0.profile) < ($1.browser, $1.profile) }
      setDefaults(for: fresh)
      phase =
        fresh.isEmpty
        ? "Still \(profiles.count) profile\(profiles.count == 1 ? "" : "s"). Nothing new appeared."
        : "Found \(fresh.count) more: \(fresh.map(\.browser).joined(separator: ", "))."
      busy = false
    }
  }

  func add(folder: URL) {
    busy = true
    phase = "Checking the selected folder…"
    task = Task {
      let found = await Task.detached(priority: .userInitiated) {
        BrowserProfileScanner.profiles(in: folder)
      }.value
      guard !Task.isCancelled else { return }
      let existing = Set(profiles.map(\.id))
      let fresh = found.filter { !existing.contains($0.id) }
      profiles.append(contentsOf: fresh)
      profiles.sort { ($0.browser, $0.profile) < ($1.browser, $1.profile) }
      setDefaults(for: fresh)
      phase =
        found.isEmpty
        ? "That folder has no supported Bookmarks, History, places.sqlite, or Safari bookmark files."
        : "Added \(fresh.count) profile\(fresh.count == 1 ? "" : "s") from the selected folder."
      busy = false
    }
  }

  func preview() {
    let work = selectedWork()
    guard !work.isEmpty else {
      phase = "Select at least one bookmark or history source."
      return
    }
    cancel()
    busy = true
    completed = false
    progress = 0
    previews = [:]
    result = nil
    phase = "Reading local copies for preview…"
    task = Task {
      for (index, entry) in work.enumerated() {
        guard !Task.isCancelled else { return }
        phase = "Previewing \(entry.0.browser) · \(entry.0.profile)…"
        let profile = entry.0
        let choice = entry.1
        let worker = Task.detached(priority: .userInitiated) {
          try BrowserDataReader.read(
            profile, includeBookmarks: choice.bookmarks, includeHistory: choice.history,
            cancelled: { Task.isCancelled })
        }
        self.worker = worker
        do {
          previews[profile.id] = try await worker.value
        } catch is CancellationError {
          phase = "Preview cancelled."
          busy = false
          return
        } catch {
          previews[profile.id] = BrowserImportPreview(
            profile: profile, messages: [error.localizedDescription])
        }
        progress = index + 1
      }
      worker = nil
      busy = false
      phase = "Preview ready. Nothing has been imported yet."
    }
  }

  func importPreview(into browser: BrowserModel) {
    guard hasPreview, !busy else { return }
    let sourcePreviews = Array(previews.values)
    let incomingVisits = sourcePreviews.flatMap(\.visits)
    let incomingMarks = sourcePreviews.flatMap(\.bookmarks)
    let root = browser.library.root
    busy = true
    completed = false
    progress = 0
    result = nil
    phase = "Importing into your local Serein library…"
    task = Task {
      // Duplicates are found against every saved day, not only the launch window.
      await browser.loadAllVisits()
      let existingVisits = browser.visits
      let existingMarks = browser.marks
      let operation = Task.detached(priority: .userInitiated) {
        () throws -> BrowserImportMergeResult in
        let merged = BrowserImportMerger.merge(
          visits: incomingVisits, marks: incomingMarks, existingVisits: existingVisits,
          existingMarks: existingMarks)
        let library = try Library(root: root)
        for visit in merged.importedVisits {
          if Task.isCancelled { throw CancellationError() }
          try library.append(visit, to: "history/\(Library.dayKey(visit.date)).jsonl")
        }
        if Task.isCancelled { throw CancellationError() }
        try library.save(merged.allMarks, to: "marks/saved.json")
        return merged
      }
      importWorker = operation
      do {
        let merged = try await operation.value
        if Task.isCancelled {
          let committed = reconcile(
            browser: browser, incomingVisits: incomingVisits, incomingMarks: incomingMarks)
          busy = false
          result = partialResult(committed, prefix: "Import cancelled")
          phase = "The local library was reloaded so a retry will skip records already written."
          importWorker = nil
          return
        }
        // Setup lets this work behind the app, so the person can keep a page or visit one while
        // it runs. What was imported goes on top of what the browser holds now, not on top of
        // the copy from the start; the bookmark file is written again from that.
        let current = BrowserImportMerger.merge(
          visits: merged.importedVisits, marks: merged.importedMarks, existingVisits: browser.visits,
          existingMarks: browser.marks)
        browser.visits = current.allVisits
        browser.marks = current.allMarks
        do {
          try browser.library.save(browser.marks, to: "marks/saved.json")
        } catch {
          // The list in memory is right; the file is not. Say so: a restart would lose it.
          busy = false
          result = "The import is in Serein, but the bookmark file was not saved: \(error.localizedDescription)"
          phase = "Run the import again. Until then a bookmark from this session can be lost at the next start."
          importWorker = nil
          return
        }
        completed = true
        busy = false
        progress = sourcePreviews.count
        let imported = merged.importedMarks.count + merged.importedVisits.count
        result =
          "Imported \(merged.importedMarks.count) bookmarks and \(merged.importedVisits.count) history visits. Skipped \(merged.duplicates + previewSkipped) duplicate or unsupported records."
        phase =
          imported == 0
          ? "Everything in this preview was already in Serein."
          : "Import complete. Your source browser files were not changed."
        importWorker = nil
      } catch is CancellationError {
        let committed = reconcile(
          browser: browser, incomingVisits: incomingVisits, incomingMarks: incomingMarks)
        busy = false
        result = partialResult(committed, prefix: "Import cancelled")
        phase = "The local library was reloaded so a retry will skip records already written."
        importWorker = nil
      } catch {
        let committed = reconcile(
          browser: browser, incomingVisits: incomingVisits, incomingMarks: incomingMarks)
        busy = false
        result = partialResult(committed, prefix: "Import stopped")
        phase = error.localizedDescription
        importWorker = nil
      }
    }
  }

  func cancel() {
    task?.cancel()
    worker?.cancel()
    if let importWorker {
      importWorker.cancel()
      // Keep retries disabled until the writer has stopped and reconciliation finishes.
      phase = "Cancelling import and checking saved records…"
      return
    }
    task = nil
    worker = nil
    importWorker = nil
    if busy { phase = "Cancelled." }
    busy = false
  }

  private func selectedWork() -> [(BrowserImportProfile, BrowserImportChoice)] {
    profiles.compactMap { profile in
      let choice = choice(profile)
      guard choice.selected,
        (choice.bookmarks && profile.bookmarks != nil) || (choice.history && profile.history != nil)
      else { return nil }
      return (profile, choice)
    }
  }

  private func setDefaults(for profiles: [BrowserImportProfile]) {
    for profile in profiles where choices[profile.id] == nil {
      choices[profile.id] = BrowserImportChoice(
        selected: true, bookmarks: profile.bookmarks != nil, history: profile.history != nil)
    }
  }

  private func reconcile(
    browser: BrowserModel, incomingVisits: [Visit], incomingMarks: [Mark]
  ) -> (visits: Int, marks: Int) {
    let visits = browser.library.visits()
    let visitIDs = Set(incomingVisits.map(\.id))
    let markIDs = Set(incomingMarks.map(\.id))
    // The browser's own list holds what the person did while the import worked (a page kept,
    // a name changed); from the file come only the bookmarks that the import wrote.
    // One bookmark for one page: an imported one gives way to the person's own for that address.
    let saved = browser.library.load([Mark].self, from: "marks/saved.json") ?? []
    let have = Set(browser.marks.map(\.id))
    let marks = BrowserImportMerger.merge(
      visits: [], marks: saved.filter { markIDs.contains($0.id) && !have.contains($0.id) },
      existingVisits: [], existingMarks: browser.marks
    ).allMarks
    browser.visits = visits
    browser.marks = marks
    try? browser.library.save(marks, to: "marks/saved.json")
    return (
      visits.filter { visitIDs.contains($0.id) }.count,
      marks.filter { markIDs.contains($0.id) }.count
    )
  }

  private func partialResult(_ committed: (visits: Int, marks: Int), prefix: String) -> String {
    let total = committed.visits + committed.marks
    return total == 0
      ? "\(prefix) before any new records were written."
      : "\(prefix) after \(committed.marks) bookmarks and \(committed.visits) history visits were written. Those records remain in Serein."
  }
}

struct BrowserOnboarding: View {
  @ObservedObject var browser: BrowserModel
  let onFinish: () -> Void
  /// True inside the first-run setup flow, which supplies the frame and glass.
  var embedded = false
  @StateObject private var model: BrowserImportModel
  @Environment(\.palette) private var p

  init(
    browser: BrowserModel, profiles: [BrowserImportProfile]? = nil, embedded: Bool = false,
    onFinish: @escaping () -> Void
  ) {
    self.browser = browser
    self.embedded = embedded
    self.onFinish = onFinish
    _model = StateObject(wrappedValue: BrowserImportModel(profiles: profiles))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 16) {
        InterfaceIcon(systemName: "square.and.arrow.down", size: 19)
          .foregroundStyle(p.onSolid).frame(width: 40, height: 40)
          .background(p.solid, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text("Bring your bookmarks and history").font(UIStyle.font(22, weight: .semibold))
          Text(
            "Choose local profiles, preview the counts, then import bookmarks and history into Serein. Source files stay unchanged."
          ).font(UIStyle.font(13)).foregroundStyle(p.secondary).fixedSize(
            horizontal: false, vertical: true)
        }
        Spacer(minLength: 24)
      }.padding(24)
      Rectangle().fill(p.line).frame(height: 1)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Text("Profiles on this Mac").font(UIStyle.font(13, weight: .medium))
            Text("\(model.profiles.count)").font(UIStyle.mono(11)).foregroundStyle(p.faint)
            Spacer()
            Button("Choose browser folder…", action: chooseFolder).buttonStyle(QuietButton())
              .disabled(model.busy)
          }
          if model.busy && model.profiles.isEmpty {
            HStack(spacing: 10) {
              ProgressView().controlSize(.small)
              Text(model.phase).foregroundStyle(p.secondary)
            }.padding(.vertical, 28).frame(maxWidth: .infinity)
          } else if model.profiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("No supported profiles detected").font(UIStyle.font(14, weight: .medium))
              Text(
                "Serein checks Safari, Chrome, Comet, Arc, Edge, Brave, Vivaldi, Opera, Chromium and Firefox. macOS privacy may hide Safari; you can choose a profile folder above, or export bookmarks from Safari as an HTML file."
              ).foregroundStyle(p.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
              .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
          } else {
            LazyVStack(spacing: 8) {
              ForEach(model.profiles) { profile in profileRow(profile) }
            }
          }

          if model.hasPreview {
            VStack(alignment: .leading, spacing: 10) {
              HStack(spacing: 20) {
                count(model.previewBookmarks, "bookmarks")
                count(model.previewVisits, "history visits")
                if model.previewSkipped > 0 { count(model.previewSkipped, "skipped") }
              }
              if !model.previewMessages.isEmpty {
                Rectangle().fill(p.line).frame(height: 1)
                ForEach(model.previewMessages, id: \.self) { message in
                  Label(message, systemImage: "exclamationmark.triangle")
                    .font(UIStyle.font(11)).foregroundStyle(p.secondary)
                }
              }
              Text(
                "Passwords, cookies, passkeys and sign-in secrets are never scanned by this flow."
              )
              .font(UIStyle.font(11)).foregroundStyle(p.faint)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
              .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
              .overlay(RoundedRectangle(cornerRadius: UIStyle.panelRadius).stroke(p.borderStrong))
          }

          if let result = model.result {
            Text(result).font(UIStyle.font(12)).foregroundStyle(p.secondary)
              .textSelection(.enabled)
              .accessibilityLabel(result)
          }
        }.padding(24)
      }

      Rectangle().fill(p.line).frame(height: 1)
      HStack(spacing: 12) {
        if model.busy {
          ProgressView(value: Double(model.progress), total: Double(max(1, model.selectedCount)))
            .frame(width: 90)
          Text(model.phase).font(UIStyle.font(11)).foregroundStyle(p.secondary).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(model.phase).accessibilityLabel(model.phase)
          Spacer()
          Button("Cancel") { model.cancel() }.buttonStyle(QuietButton())
            .keyboardShortcut(.cancelAction)
        } else {
          Text(model.phase).font(UIStyle.font(11)).foregroundStyle(p.secondary).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(model.phase).accessibilityLabel(model.phase)
          Spacer()
          if model.completed {
            Button("Preview again", action: model.preview).buttonStyle(QuietButton())
            Button("Done", action: onFinish).buttonStyle(PrimaryButton())
              .keyboardShortcut(.defaultAction)
          } else {
            Button("Skip for now", action: onFinish).buttonStyle(QuietButton())
              .keyboardShortcut(.cancelAction)
            if model.hasPreview {
              Button("Import", action: { model.importPreview(into: browser) })
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
            } else {
              Button("Preview selection", action: model.preview).buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedCount == 0)
            }
          }
        }
      }.padding(.horizontal, 24).frame(height: 64).background(p.sidebar)
    }.frame(width: embedded ? nil : 780, height: embedded ? nil : 640)
      .modifier(OptionalGlass(on: !embedded)).foregroundStyle(p.ink)
      .font(UIStyle.font(13)).buttonStyle(QuietButton()).controlSize(.small).tint(p.solid)
      .interactiveDismissDisabled()
      .onAppear { model.load() }
      .onChange(of: model.result) { _, result in
        guard let result, !result.isEmpty else { return }
        NSAccessibility.post(
          element: NSApplication.shared, notification: .announcementRequested,
          userInfo: [.announcement: result, .priority: NSAccessibilityPriorityLevel.low.rawValue])
      }
  }

  @ViewBuilder private func profileRow(_ profile: BrowserImportProfile) -> some View {
    let choice = model.choice(profile)
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Toggle("", isOn: model.binding(profile, \BrowserImportChoice.selected)).labelsHidden()
          .toggleStyle(.checkbox)
          .accessibilityLabel("Import \(profile.browser) \(profile.profile)")
        VStack(alignment: .leading, spacing: 2) {
          Text(profile.browser + " · " + profile.profile).font(UIStyle.font(13, weight: .medium))
          Text(profile.directory.path).font(UIStyle.microMono).foregroundStyle(p.faint)
            .lineLimit(1).truncationMode(.middle)
            .help(profile.directory.path).accessibilityLabel(profile.directory.path)
        }
        Spacer()
        if let preview = model.previews[profile.id] {
          Text("\(preview.bookmarks.count) saved · \(preview.visits.count) visits")
            .font(UIStyle.microMono).foregroundStyle(p.secondary)
        }
      }
      HStack(spacing: 20) {
        Toggle("Bookmarks", isOn: model.binding(profile, \BrowserImportChoice.bookmarks))
          .toggleStyle(.checkbox).disabled(!choice.selected || profile.bookmarks == nil)
        Toggle("History", isOn: model.binding(profile, \BrowserImportChoice.history))
          .toggleStyle(.checkbox).disabled(!choice.selected || profile.history == nil)
          .help("Up to 10,000 most recent history visits per profile.")
        Spacer()
        if profile.bookmarks == nil { Text("No bookmarks file").foregroundStyle(p.faint) }
        if profile.history == nil { Text("No history database").foregroundStyle(p.faint) }
      }.font(UIStyle.font(11)).foregroundStyle(p.secondary).padding(.leading, 24)
    }.padding(14).background(
      choice.selected ? p.selected : p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius)
    )
  }

  private func count(_ value: Int, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(String(value)).font(UIStyle.mono(18)).foregroundStyle(p.ink)
      Text(label).font(UIStyle.font(11)).foregroundStyle(p.secondary)
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.message =
      "Choose a browser profile folder. Serein checks only supported bookmark and history filenames."
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    model.add(folder: folder)
  }
}
