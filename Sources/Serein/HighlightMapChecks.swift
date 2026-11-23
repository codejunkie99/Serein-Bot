#if DEBUG
import Foundation
import SereinCore
import WebKit

/// Verify exact anchor endpoints using generated text, including UTF-16 boundaries. The
/// Range recorder observes the real helper and works with CSS or overlay highlighting.
@MainActor func checkCompactHighlightMaps() async throws {
  guard let resource = Bundle.assets.url(forResource: "KeptPassages", withExtension: "js") else {
    throw SereinError.invalid("Missing synthetic highlight-map resource.")
  }
  let source = try String(contentsOf: resource, encoding: .utf8)
  let tab = BrowserTab(privateMode: true, owner: "synthetic-highlight-map-check", store: .nonPersistent())
  defer { tab.discardPage() }
  let title = UUID().uuidString
  tab.web.loadHTMLString("<!doctype html><title>\(title)</title><p>Synthetic map fixture.</p>",
    baseURL: URL(string: "http://127.0.0.1/serein-synthetic-highlight-map"))
  var loaded = false
  for _ in 0..<100 {
    if !tab.web.isLoading, (try? await tab.script("document.title")) as? String == title {
      loaded = true
      break
    }
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  guard loaded else { throw SereinError.invalid("Synthetic highlight-map document did not load.") }
  let result = try await tab.script("""
    (()=>{
      \(source)
      const api=globalThis.__sereinKept,recorded=[],originalRange=document.createRange.bind(document);
      document.createRange=()=>{const range=originalRange();recorded.push(range);return range;};
      const norm=text=>text.replace(/\\s+/g,'');
      const prepare=html=>{api.clearFresh();api.setKept([]);document.body.innerHTML=html;recorded.length=0;};
      const mark=quote=>{recorded.length=0;const result=api.setFresh([quote]);return result.fresh===1?recorded[0]:null;};
      const checks={};

      prepare('<p id="unicode"> \\t😀Alpha&nbsp;Beta\\n<span>\\u2009中𝄞\\tZ</span><span> \\ufeff fin </span></p>');
      const parent=document.getElementById('unicode'),quote='😀AlphaBeta中𝄞Zfin',unicode=mark(quote);
      checks.unicodeAcrossNodes=!!unicode&&norm(unicode.toString())===quote
        &&unicode.startContainer===parent.firstChild&&unicode.startOffset===2
        &&unicode.endContainer===parent.lastChild.firstChild&&unicode.endOffset===6;

      prepare('<p id="combining"></p>');
      const combining=document.getElementById('combining');combining.textContent='é e\\u0301 \\u0085 \\u200b';
      const combined=mark('ée\\u0301\\u0085\\u200b');
      checks.normalizationSemantics=!!combined&&norm(combined.toString())==='ée\\u0301\\u0085\\u200b';

      prepare('<p id="chunk"></p>');
      const chunk=document.getElementById('chunk');chunk.textContent='a'.repeat(16383)+'😀boundary';
      const split=mark('😀boundary');
      checks.splitSurrogate=!!split&&split.toString()==='😀boundary'
        &&split.startOffset===16383&&split.endOffset===chunk.textContent.length;

      chunk.textContent='a'.repeat(16000)+'\\u00a0'.repeat(600)+'\\t \\u2009cross-chunk';
      const whitespace=mark('cross-chunk');
      checks.whitespaceChunk=!!whitespace&&whitespace.toString()==='cross-chunk'
        &&whitespace.startOffset===16603&&whitespace.endOffset===chunk.textContent.length;

      chunk.textContent='a'.repeat(599980)+'\\n😀END'+'b'.repeat(100)+'SEREIN_OUTSIDE_LIMIT';
      recorded.length=0;const budget=api.setFresh(['😀END','SEREIN_OUTSIDE_LIMIT']);
      checks.budget=budget.fresh===1&&recorded.length===1&&recorded[0].toString()==='😀END'
        &&recorded[0].startOffset===599981;

      prepare('<p id="first">left-one shared quote right-one</p><p id="second">left-two shared quote right-two</p>');
      const duplicate=api.setKept([{id:'duplicate',exact:'shared quote',prefix:'left-two ',suffix:' right-two'}]);
      checks.duplicateContext=duplicate.kept.includes('duplicate')&&recorded.length===1
        &&recorded[0].startContainer.parentElement.id==='second'&&recorded[0].toString()==='shared quote';
      const selected=originalRange(),second=document.getElementById('second').firstChild;
      selected.setStart(second,9);selected.setEnd(second,21);
      const selection=getSelection();selection.removeAllRanges();selection.addRange(selected);
      const captured=api.capture();selection.removeAllRanges();
      checks.captureContext=captured.exact==='shared quote'&&captured.prefix.endsWith('left-two')
        &&captured.suffix.startsWith('right-two');

      prepare('<p><span>the beginning twenty four characters </span><span>changed middle content </span><span>and the ending twenty four characters</span></p>');
      const changed=mark('the beginning twenty four characters original middle and the ending twenty four characters');
      checks.fuzzyAnchor=!!changed&&changed.toString().startsWith('the beginning')
        &&changed.toString().includes('changed middle content')&&changed.toString().endsWith('characters');

      prepare('<p>Allowed quote.</p><textarea>TEXTAREA_CANARY</textarea><input value="INPUT_CANARY"><div contenteditable="true">EDITABLE_CANARY</div><div contenteditable>EMPTY_EDITABLE_CANARY</div><div hidden>HIDDEN_CANARY</div><script type="application/json">SCRIPT_CANARY</script><style>STYLE_CANARY{}</style>');
      const excluded=api.setKept(['Allowed quote.','TEXTAREA_CANARY','INPUT_CANARY','EDITABLE_CANARY',
        'EMPTY_EDITABLE_CANARY','HIDDEN_CANARY','SCRIPT_CANARY','STYLE_CANARY'].map((exact,i)=>({id:String(i),exact})));
      checks.exclusions=excluded.kept.length===1&&excluded.kept[0]==='0'&&recorded.length===1
        &&recorded[0].toString()==='Allowed quote.';
      api.clearFresh();api.setKept([]);
      return checks;
    })()
    """) as? [String: Any] ?? [:]
  let labels = [
    "unicodeAcrossNodes": "UTF-16 endpoints and Unicode whitespace across text nodes",
    "normalizationSemantics": "combining marks and non-whitespace Unicode characters remain intact",
    "splitSurrogate": "surrogate pairs spanning raw chunks retain exact endpoints",
    "whitespaceChunk": "raw offsets remain correct after whitespace spans a chunk boundary",
    "budget": "the normalized map budget bounds a giant node without dropping in-budget anchors",
    "duplicateContext": "duplicate quote context selects the correct node",
    "captureContext": "capture identifies the selected duplicate's prefix and suffix",
    "fuzzyAnchor": "changed-middle anchoring retains cross-node ranges",
    "exclusions": "forms, editable regions, hidden nodes, scripts and styles remain excluded",
  ]
  for (key, label) in labels {
    guard result[key] as? Bool == true else {
      throw SereinError.invalid("Highlight map check failed: " + label)
    }
  }
  print("PASS: \(labels.count) synthetic compact highlight-map endpoint and privacy contracts")
}
#endif
