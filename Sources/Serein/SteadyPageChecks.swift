#if DEBUG
import AppKit
import SereinCore
import SwiftUI
import WebKit

/// Synthetic pages, deterministic clock schedules and nonpersistent stores only.
@MainActor func checkSteadyPagePerformance() async throws {
  var checks = 0
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("Steady page check failed: " + label) }
    checks += 1
  }
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  func item(_ outcome: RunRecord.Outcome, ended: Date? = nil) -> AtWorkList.Item {
    AtWorkList.Item(id: UUID().uuidString, outcome: outcome,
      startedAt: now.addingTimeInterval(-100), endedAt: ended)
  }
  let running = item(.running)
  let liveDates = Array(AtWorkTimelineSchedule(items: [running]).entries(from: now, mode: .normal).prefix(65))
  try check(liveDates.count == 65 && liveDates[64].timeIntervalSince(liveDates[0]) == 64,
    "Running sidebar tasks retain one-second clock entries")
  let waiting = item(.waiting, ended: now.addingTimeInterval(-10))
  let failed = item(.stuck, ended: now.addingTimeInterval(-10))
  try check(Array(AtWorkTimelineSchedule(items: [waiting, failed]).entries(from: now, mode: .normal)) == [now],
    "Static waiting and failed tasks have no repeated idle clock entries")
  let finished = item(.done, ended: now.addingTimeInterval(-59.6))
  let fadeDates = Array(AtWorkTimelineSchedule(items: [finished]).entries(from: now, mode: .normal))
  try check(fadeDates.count == 2 && abs(fadeDates[1].timeIntervalSince(now) - 0.4) < 0.001,
    "The finite schedule includes the exact 60-second expiry")
  try check(!AtWorkList.rows([finished], now: fadeDates[0]).isEmpty
    && AtWorkList.rows([finished], now: fadeDates[1]).isEmpty,
    "Finished rows disappear at the final scheduled tick")
  try check(AtWorkList.opacity(finished, now: now) > 0
    && AtWorkList.opacity(finished, now: fadeDates[1]) == 0,
    "Finished-row fading is preserved")
  let expired = item(.stopped, ended: now.addingTimeInterval(-80))
  try check(Array(AtWorkTimelineSchedule(items: [expired]).entries(from: now, mode: .normal)) == [now],
    "Expired retained tasks do not keep the invisible sidebar card ticking")
  try check(Array(AtWorkTimelineSchedule(items: []).entries(from: now, mode: .normal)) == [now],
    "An empty schedule still supplies its initial presentation")
  try check(Array(AtWorkTimelineSchedule(items: [expired, running]).entries(from: now, mode: .normal).prefix(3)).count == 3,
    "A new running task reactivates the clock after an idle schedule")
  let newest = item(.done, ended: now.addingTimeInterval(-58))
  let deadlines = Array(AtWorkTimelineSchedule(items: [finished, newest]).entries(from: now, mode: .normal))
  try check(deadlines.last == now.addingTimeInterval(2),
    "Multiple completed tasks retain ticks through the latest expiry")

  guard let sourceURL = Bundle.assets.url(forResource: "KeptPassages", withExtension: "js") else {
    throw SereinError.invalid("Missing synthetic highlight helper.")
  }
  let currentSource = try String(contentsOf: sourceURL, encoding: .utf8)
  // Optional, explicitly supplied source snapshot for a before/after synthetic benchmark.
  // The fixture remains generated and the store remains isolated in either case.
  let baselineSource = try ProcessInfo.processInfo.environment["SEREIN_HIGHLIGHT_BASELINE"].map {
    try String(contentsOfFile: $0, encoding: .utf8)
  }
  func fixture(_ source: String, verify: Bool) async throws -> [String: Any] {
    let tab = BrowserTab(privateMode: true, owner: "synthetic-steady-page-check", store: .nonPersistent())
    defer { tab.discardPage() }
    let title = UUID().uuidString
    tab.web.loadHTMLString("""
      <!doctype html><title>\(title)</title><main id='feed'></main>
      <script>const feed=document.getElementById('feed');for(let i=0;i<3000;i++){
        const post=document.createElement('p');post.textContent='Synthetic anchor '+i+' '+ 'abcdefghij'.repeat(24);feed.append(post);
      }</script>
      """, baseURL: URL(string: "http://127.0.0.1/serein-synthetic-steady-page"))
    var loaded = false
    for _ in 0..<100 {
      if !tab.web.isLoading, (try? await tab.script("document.title")) as? String == title {
        loaded = true
        break
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard loaded else { throw SereinError.invalid("Synthetic highlight feed did not load.") }
    _ = try await tab.script("""
      globalThis.__sereinHighlightScans=0;
      const originalWalker=document.createTreeWalker.bind(document);
      document.createTreeWalker=(...args)=>{globalThis.__sereinHighlightScans++;return originalWalker(...args);};
      \(source)
      true;
      """)
    let raw = try await tab.web.callAsyncJavaScript("""
      const api=globalThis.__sereinKept;
      const feed=document.getElementById('feed');
      const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
      const timed=fn=>{const start=performance.now();const result=fn();return {ms:performance.now()-start,result};};
      const activation=timed(()=>api.setFresh(['Synthetic anchor 0']));
      await wait(650);
      const beforeClear=globalThis.__sereinHighlightScans;
      const clearing=timed(()=>api.clearFresh());
      const clearScans=globalThis.__sereinHighlightScans-beforeClear;
      const beforeIdle=globalThis.__sereinHighlightScans;
      for(let i=0;i<3;i++){
        feed.firstElementChild.firstChild.textContent+='x';
        dispatchEvent(new Event('resize'));
        await wait(650);
      }
      const idleScans=globalThis.__sereinHighlightScans-beforeIdle;
      return {characters:feed.textContent.length,activation_ms:activation.ms,
        activation_found:activation.result.fresh,clear_ms:clearing.ms,clear_scans:clearScans,
        idle_scans:idleScans,clear_fresh:clearing.result.fresh};
      """, arguments: [:], in: nil, contentWorld: BrowserTab.world)
    guard let profile = raw as? [String: Any] else {
      throw SereinError.invalid("Missing synthetic highlight measurements.")
    }
    if verify {
      try check((profile["characters"] as? Int ?? 0) >= 600_000,
        "Highlight lifecycle uses a synthetic feed beyond the 600,000-character map budget")
      try check(profile["activation_found"] as? Int == 1 && profile["clear_fresh"] as? Int == 0,
        "Fresh highlights activate and clear without changing their results")
      try check(profile["clear_scans"] as? Int == 0 && profile["idle_scans"] as? Int == 0,
        "Clearing the final highlight stops immediate and later mutation/resize text-map scans")
      let result = try await tab.web.callAsyncJavaScript("""
        const api=globalThis.__sereinKept,feed=document.getElementById('feed');
        const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
        const scans=()=>globalThis.__sereinHighlightScans;
        const reactivated=api.setFresh(['Synthetic anchor 0']);
        await wait(650);
        let before=scans();
        const replacement=document.createElement('p');replacement.textContent='Synthetic anchor 0 replacement';
        feed.firstElementChild.replaceWith(replacement);
        dispatchEvent(new Event('resize'));
        await wait(650);
        const relocated=scans()>before;
        const range=typeof CSS!=='undefined'&&CSS.highlights?[...(CSS.highlights.get('serein-new')||[])][0]:null;
        const replacementAnchored=!range||range.startContainer.parentElement===replacement;
        const kept=api.setKept([{id:'synthetic-kept',exact:'Synthetic anchor 1'}]);
        const freshCleared=api.clearFresh();
        await wait(650);before=scans();
        feed.children[1].firstChild.textContent+='x';await wait(650);
        const keptStillWatching=scans()>before;
        api.setKept([]);before=scans();
        feed.children[1].firstChild.textContent+='x';dispatchEvent(new Event('resize'));await wait(650);
        const allStopped=scans()===before;
        const editable=document.createElement('div');editable.contentEditable='true';
        editable.textContent='SEREIN_SYNTHETIC_EDITABLE_ONLY';document.body.append(editable);
        const input=document.createElement('input');input.value='SEREIN_SYNTHETIC_FIELD_ONLY';document.body.append(input);
        const excluded=api.setKept([{id:'editable-secret',exact:editable.textContent},{id:'field-secret',exact:input.value}]);
        const selected=document.createRange();selected.selectNodeContents(editable);
        const selection=getSelection();selection.removeAllRanges();selection.addRange(selected);
        const capture=api.capture();selection.removeAllRanges();api.setKept([]);
        const giant=document.createElement('p');
        giant.textContent='a'.repeat(599900)+'SEREIN_VISIBLE_INSIDE_LIMIT'+'a'.repeat(100)+'SEREIN_OUTSIDE_LIMIT';
        document.body.replaceChildren(giant);
        const boundary=api.setFresh(['SEREIN_VISIBLE_INSIDE_LIMIT','SEREIN_OUTSIDE_LIMIT']);api.clearFresh();
        const beforeRevision=globalThis.__serein.probe().revision;
        const password=document.createElement('input');password.type='password';document.body.append(password);password.type='text';
        const privacy=globalThis.__serein.probe();
        return {reactivated:reactivated.fresh===1,relocated,replacementAnchored,
          keptFound:kept.kept.includes('synthetic-kept'),keptAfterFreshClear:freshCleared.kept.includes('synthetic-kept'),
          keptStillWatching,allStopped,excluded:excluded.kept.length===0,captureExcluded:capture.error==='field',
          boundedLargeNode:boundary.fresh===1,securityAlive:privacy.steps&&privacy.revision>beforeRevision};
        """, arguments: [:], in: nil, contentWorld: BrowserTab.world) as? [String: Any] ?? [:]
      try check(result["reactivated"] as? Bool == true && result["relocated"] as? Bool == true,
        "Later highlights reactivate mutation and resize observation")
      try check(result["replacementAnchored"] as? Bool == true,
        "A replaced feed node is reanchored before further scrolling")
      try check(result["keptFound"] as? Bool == true && result["keptAfterFreshClear"] as? Bool == true
        && result["keptStillWatching"] as? Bool == true,
        "Clearing fresh highlights preserves kept highlights and their observers")
      try check(result["allStopped"] as? Bool == true,
        "Removing the final kept highlight also stops idle observers")
      try check(result["excluded"] as? Bool == true && result["captureExcluded"] as? Bool == true,
        "Editable and input-field text remains excluded from anchoring and capture")
      try check(result["boundedLargeNode"] as? Bool == true,
        "A single text node over 600,000 characters respects the map boundary")
      try check(result["securityAlive"] as? Bool == true,
        "Stopping highlight observers preserves PageKit revision and revealed-password protection")
    }
    return profile
  }
  var measurements: [String: Any] = [:]
  if let baselineSource { measurements["baseline"] = try await fixture(baselineSource, verify: false) }
  measurements["current"] = try await fixture(currentSource, verify: true)
  let data = try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys])
  print("BENCH: synthetic highlight lifecycle " + String(decoding: data, as: UTF8.self))
  print("PASS: \(checks) synthetic steady-page highlight and sidebar clock checks")
  try await checkCompactHighlightMaps()
}
#endif
