#if DEBUG
import Foundation
import SereinCore

/// A report's reel (`ReportReel`, `ReportReelMaker`): git's line counts, which files a session
/// made, the day's roll-up for the morning brief, and the words Listen speaks. Synthetic values
/// and a temporary folder only.
extension AssistantCoreChecks {
  static func reels(_ check: Check) throws {
    typealias R = ReportReel
    // Git's numstat, as `git log --numstat --format=` and `git diff --numstat` print it.
    let numstat = """
      12\t3\tSources/App.swift
      -\t-\tAssets/logo.png
      4\t0\tdocs/{old.md => new.md}
      2\t1\tSources/App.swift
      0\t9\tlib/a.py => lib/b.py
      not a line
      """
    let changes = R.numstat(numstat)
    try check(changes.first == R.FileChange(path: "Sources/App.swift", added: 14, removed: 4),
      "A file in a commit and in the open changes adds up, biggest first")
    try check(changes.contains(R.FileChange(path: "docs/new.md", added: 4, removed: 0))
      && changes.contains(R.FileChange(path: "lib/b.py", added: 0, removed: 9)),
      "A renamed file is its new name, braced or plain")
    try check(changes.contains(R.FileChange(path: "Assets/logo.png", added: 0, removed: 0)) && changes.count == 4,
      "A binary file counts as changed with no lines; a stray line is ignored")
    var reel = R(title: "Codex in shop")
    reel.setChanges(changes + [R.FileChange(path: "x", added: 1, removed: 0)])
    try check(reel.files.count == R.fileLimit && reel.filesTotal == 5 && reel.added == 19 && reel.removed == 13,
      "Totals count every file; bars show only the biggest")

    // What a session made: media written during its turn, not the person's older files.
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let end = start.addingTimeInterval(600)
    func file(_ name: String, _ at: TimeInterval, _ bytes: Int = 10_000) -> R.Candidate {
      R.Candidate(path: "/p/" + name, modified: start.addingTimeInterval(at), bytes: bytes)
    }
    // Ten pictures in the turn, more than a report keeps, and two of each other kind.
    let pictures = (0..<10).map { file("shot\($0).png", 10 + Double($0)) }
    let picked = R.pick(pictures + [
      file("old.png", -30), file("run.mp4", 60), file("clip.mp4", 65), file("empty.png", 70, 0),
      file("huge.mp4", 80, 900_000_000), file("notes.txt", 90), file("bell.m4a", 95),
      file("later.png", 900), file("chime.m4a", 100),
    ], since: start, until: end)
    try check(!picked.contains { $0.path.hasSuffix("old.png") || $0.path.hasSuffix("later.png") },
      "Only files written during the turn show")
    try check(!picked.contains { $0.path.hasSuffix("empty.png") || $0.path.hasSuffix("huge.mp4") || $0.path.hasSuffix(".txt") },
      "Empty, oversized and non-media files stay out")
    try check(picked.first?.path == "/p/chime.m4a" && picked.filter { $0.path.hasSuffix(".png") }.count == R.perKind[.image]
      && picked.count == R.mediaLimit, "Newest first, a few of each kind, so pictures do not crowd out a video or a sound")
    try check(R.kind(ofExtension: "MOV") == .video && R.kind(ofExtension: "wav") == .audio && R.kind(ofExtension: "svg") == nil,
      "Media kinds by extension, in any case")
    try check(R.tests([TranscriptActivity(id: "1", tool: "test", label: "Ran tests"),
                       TranscriptActivity(id: "2", tool: "test", label: "Ran tests", failed: true)]) == .failed
      && R.tests([TranscriptActivity(id: "3", tool: "edit", label: "Edited a")]) == nil, "Any failed test run is a failure; none is no badge")

    // The scan walks a project, never its dependencies, build output or hidden folders.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("serein-reel-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for folder in ["shots", "node_modules/pkg", ".build", ".hidden"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let bytes = Data(repeating: 7, count: 64)
    for name in ["shots/home.png", "node_modules/pkg/icon.png", ".build/out.mp4", ".hidden/x.png", "demo.mp4"] {
      try bytes.write(to: root.appendingPathComponent(name))
    }
    let before = Date().addingTimeInterval(-3600 * 5)
    try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: root.appendingPathComponent("demo.mp4").path)
    let scanned = ReportReelMaker.scan(root, since: Date().addingTimeInterval(-120), until: Date().addingTimeInterval(5))
    try check(scanned.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["home.png"],
      "The scan finds what the session made and skips dependencies, build output, hidden folders and older files")
    try check(!ReportReelMaker.scannable(NSHomeDirectory()) && !ReportReelMaker.scannable("/")
      && !ReportReelMaker.scannable(NSHomeDirectory() + "/Documents") && ReportReelMaker.scannable(root.path),
      "The home folder, the root and personal folders are never walked; a project is")

    // Yesterday, rolled up for the morning brief.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_800_014_400)  // midday, UTC
    let today = calendar.startOfDay(for: now)
    func session(_ hoursBefore: Double, project: String, files: [R.FileChange], tests: R.Tests?, minutes: Int, media: [R.Media] = [])
      -> R.Stamped
    {
      var reel = R(title: "Claude Code in " + project)
      reel.setChanges(files)
      reel.tests = tests
      reel.minutes = minutes
      reel.media = media
      return R.Stamped(at: today.addingTimeInterval(-hoursBefore * 3600), project: project, reel: reel)
    }
    let shot = R.Media(kind: .image, path: "chat-images/reel-a.png", name: "home.png", project: "shop", made: today.addingTimeInterval(-3600))
    let log = [
      session(20, project: "shop", files: [R.FileChange(path: "a.swift", added: 10, removed: 2)], tests: .passed, minutes: 30),
      session(2, project: "shop", files: [R.FileChange(path: "a.swift", added: 5, removed: 1), R.FileChange(path: "b.swift", added: 1, removed: 0)],
        tests: .failed, minutes: 45, media: [shot]),
      session(5, project: "api", files: [R.FileChange(path: "main.go", added: 100, removed: 50)], tests: nil, minutes: 70),
      session(30, project: "old", files: [R.FileChange(path: "z", added: 1, removed: 1)], tests: nil, minutes: 5),
      session(-1, project: "today", files: [R.FileChange(path: "y", added: 1, removed: 1)], tests: nil, minutes: 5),
    ]
    guard let day = R.day(log, before: now, calendar: calendar) else { throw SereinError.invalid("FAIL: yesterday has a reel") }
    try check(day.sessions == 3 && day.projects == ["shop", "api"], "Yesterday counts only yesterday's sessions and names their projects")
    try check(day.filesTotal == 3 && day.added == 116 && day.removed == 53 && day.files.first?.path == "api/main.go"
      && day.files.contains(R.FileChange(path: "shop/a.swift", added: 15, removed: 3)),
      "The same file in two sessions is one bar; a file is named with its project")
    try check(day.tests == .failed && day.minutes == 145 && day.media == [shot], "A failed run fails the day; time and media add up")
    try check(day.summary == "3 sessions · +116 −53 in 3 files · tests failed · 2h 25m · 1 picture",
      "The summary line reads as figures")
    try check(day.narration.hasPrefix("Yesterday. 3 sessions in shop and api. 116 lines added and 53 removed across 3 files.")
      && day.narration.contains("Some tests failed.") && day.narration.contains("About 2 hours 25 minutes of work."),
      "Listen speaks plain sentences, not symbols")
    try check(R.day([log[3], log[4]], before: now, calendar: calendar) == nil, "No session yesterday: no reel under the brief")
    try check(R.pruned(log, now: now, days: 1).count == 3, "The log keeps only the last days")
    try check(R(title: "x").isEmpty && !day.isEmpty, "A reel with nothing to show is empty and draws nothing")
  }
}
#endif
