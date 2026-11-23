(() => {
  if (globalThis.__sereinKept) return;
  // Text-quote anchoring for kept passages and "new since your last visit" highlights.
  // Matching ignores all whitespace so line breaks and layout never break an anchor.
  const SKIP = 'script,style,noscript,input,textarea,select,[contenteditable=true],[contenteditable=""],[hidden]';
  const NAMES = { kept: 'serein-kept', fresh: 'serein-new' };
  const COLORS = { kept: 'rgba(125,185,255,.34)', fresh: 'rgba(160,215,190,.30)' };
  const state = { kept: [], fresh: [], ranges: { kept: [], fresh: [] }, overlay: null, timer: 0, styled: false, observing: false, mutations: null, resize: null };

  const strip = s => s.replace(/\s+/g, '');
  const visible = el => { try { const s = getComputedStyle(el); return s.visibility !== 'hidden' && s.display !== 'none'; } catch (_) { return false; } };

  // Normalize bounded pieces natively, retaining one segment per text node/chunk rather
  // than three 600,000-entry character arrays. Raw offsets are needed only for matched
  // endpoints and are filled lazily for those segments, in UTF-16 units as Range requires.
  function textMap() {
    const segments = [], out = [];
    const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
    let node, total = 0;
    while ((node = walker.nextNode()) && total < 600000) {
      const p = node.parentElement;
      if (!p || p.closest(SKIP) || !visible(p)) continue;
      const d = node.data;
      for (let at = 0; at < d.length && total < 600000; at += 16384) {
        const raw = d.slice(at, at + 16384), text = strip(raw).slice(0, 600000 - total);
        if (!text.length) continue;
        segments.push({ node, start: total, length: text.length, raw, rawOffset: at, offsets: null });
        out.push(text); total += text.length;
      }
    }
    return { text: out.join(''), segments };
  }
  function commonSuffix(a, b) { let n = 0; while (n < a.length && n < b.length && a[a.length - 1 - n] === b[b.length - 1 - n]) n++; return n; }
  function commonPrefix(a, b) { let n = 0; while (n < a.length && n < b.length && a[n] === b[n]) n++; return n; }
  function occurrences(hay, needle, cap = 60) {
    const found = []; let i = hay.indexOf(needle);
    while (i !== -1 && found.length < cap) { found.push(i); i = hay.indexOf(needle, i + 1); }
    return found;
  }
  function point(map, index) {
    let low = 0, high = map.segments.length - 1;
    while (low <= high) {
      const mid = (low + high) >>> 1, segment = map.segments[mid];
      if (index < segment.start) { high = mid - 1; continue; }
      if (index >= segment.start + segment.length) { low = mid + 1; continue; }
      if (!segment.offsets) {
        const offsets = new Uint32Array(segment.length);
        let count = 0;
        for (let i = 0; i < segment.raw.length && count < offsets.length; i++) {
          if (!/\s/.test(segment.raw[i])) offsets[count++] = i;
        }
        segment.offsets = offsets;
      }
      return { node: segment.node, offset: segment.rawOffset + segment.offsets[index - segment.start] };
    }
    return null;
  }
  function toRange(map, start, end) {
    try {
      const first = point(map, start), last = point(map, end - 1);
      if (!first || !last) return null;
      const r = document.createRange();
      r.setStart(first.node, first.offset);
      r.setEnd(last.node, last.offset + 1);
      return r;
    } catch (_) { return null; }
  }
  function locate(map, a) {
    const needle = strip(a.exact || '');
    if (needle.length < 4) return null;
    const prefix = strip(a.prefix || ''), suffix = strip(a.suffix || '');
    const score = i => commonSuffix(map.text.slice(Math.max(0, i - prefix.length), i), prefix) + commonPrefix(map.text.slice(i + needle.length, i + needle.length + suffix.length), suffix);
    const best = list => list.map(i => [i, score(i)]).sort((x, y) => y[1] - x[1])[0];
    const exact = occurrences(map.text, needle);
    if (exact.length) { const i = best(exact)[0]; return toRange(map, i, i + needle.length); }
    // The page changed inside the passage: find its first and last words and span between them.
    if (needle.length < 40) return null;
    const head = needle.slice(0, 24), tail = needle.slice(-24);
    const heads = occurrences(map.text, head);
    if (!heads.length) return null;
    const i = best(heads)[0];
    const j = map.text.indexOf(tail, i + 24);
    if (j === -1 || j + 24 - i > needle.length * 1.6 + 80) return null;
    return toRange(map, i, j + 24);
  }

  // Known limit: highlights live in the page's document, so the page's own scripts could read
  // CSS.highlights or the overlay and learn which passages are kept on that page. Nothing is
  // stored in the page and the overlay carries no Serein marker. Highlighting is skipped on
  // sensitive pages and in private tabs (see KeptPassages.eligible).
  function ensureStyle() {
    if (state.styled) return true;
    const css = Object.keys(NAMES).map(k => `::highlight(${NAMES[k]}){background-color:${COLORS[k]};color:inherit;}`).join('');
    try {
      const sheet = new CSSStyleSheet(); sheet.replaceSync(css);
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      state.styled = true; return true;
    } catch (_) {}
    try {
      const el = document.createElement('style'); el.textContent = css;
      (document.head || document.documentElement).appendChild(el);
      state.styled = true; return true;
    } catch (_) { return false; }
  }
  const canHighlight = () => typeof CSS !== 'undefined' && CSS.highlights && typeof Highlight !== 'undefined' && ensureStyle();

  function overlayRoot() {
    if (state.overlay && state.overlay.isConnected) return state.overlay;
    const el = document.createElement('div');
    el.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;pointer-events:none;z-index:2147483646;';
    document.documentElement.appendChild(el);
    state.overlay = el; return el;
  }
  function paintOverlay() {
    const root = overlayRoot();
    root.textContent = '';
    const sx = scrollX, sy = scrollY;
    for (const kind of Object.keys(NAMES)) {
      for (const r of state.ranges[kind]) {
        for (const rect of r.getClientRects()) {
          if (rect.width < 1 || rect.height < 1) continue;
          const d = document.createElement('div');
          d.style.cssText = `position:absolute;left:${rect.left + sx}px;top:${rect.top + sy}px;width:${rect.width}px;height:${rect.height}px;background:${COLORS[kind]};border-radius:2px;`;
          root.appendChild(d);
        }
      }
    }
  }
  function paint() {
    if (canHighlight()) {
      for (const kind of Object.keys(NAMES)) {
        if (state.ranges[kind].length) CSS.highlights.set(NAMES[kind], new Highlight(...state.ranges[kind]));
        else CSS.highlights.delete(NAMES[kind]);
      }
      if (state.overlay) state.overlay.textContent = '';
    } else paintOverlay();
  }

  // Re-run after the page changes (single-page apps, lazy content, late images).
  function schedule() {
    if (!state.kept.length && !state.fresh.length) return;
    clearTimeout(state.timer);
    state.timer = setTimeout(() => { state.timer = 0; relocate(); }, 450);
  }
  function watch() {
    if (!state.kept.length && !state.fresh.length) return;
    if (state.observing) return; state.observing = true;
    try { state.mutations = new MutationObserver(schedule); state.mutations.observe(document.body, { childList: true, subtree: true, characterData: true }); } catch (_) {}
    try { state.resize = new ResizeObserver(schedule); state.resize.observe(document.documentElement); } catch (_) {}
    addEventListener('resize', schedule); addEventListener('load', schedule);
  }
  // Only the highlighting helper's observers are stopped. PageKit's document revision
  // and sensitive-field observers are separate and must keep protecting the page.
  function unwatch() {
    clearTimeout(state.timer); state.timer = 0;
    state.mutations?.disconnect(); state.mutations = null;
    state.resize?.disconnect(); state.resize = null;
    removeEventListener('resize', schedule); removeEventListener('load', schedule);
    state.observing = false;
  }

  // Located ranges keyed by id, rebuilt on every refresh.
  let located = { kept: new Map(), fresh: [] };
  function relocate() {
    if (!state.kept.length && !state.fresh.length) {
      unwatch();
      located.kept = new Map(); located.fresh = [];
      state.ranges.kept = []; state.ranges.fresh = [];
      if (typeof CSS !== 'undefined' && CSS.highlights) for (const name of Object.values(NAMES)) CSS.highlights.delete(name);
      state.overlay?.remove(); state.overlay = null;
      return summary();
    }
    const map = textMap();
    located.kept = new Map();
    for (const a of state.kept) { const r = locate(map, a); if (r) located.kept.set(a.id, r); }
    located.fresh = [];
    for (const b of state.fresh) { const r = locate(map, { exact: b }); if (r) located.fresh.push(r); }
    located.fresh.sort((x, y) => x.compareBoundaryPoints(Range.START_TO_START, y));
    state.ranges.kept = [...located.kept.values()];
    state.ranges.fresh = located.fresh;
    paint();
    return summary();
  }
  function summary() { return { kept: [...located.kept.keys()], fresh: located.fresh.length }; }

  const api = {
    sensitive() {
      return !!document.querySelector('input[type=password],input[autocomplete*="cc-"],input[autocomplete="one-time-code"],input[autocomplete="current-password"],input[autocomplete="new-password"]');
    },
    // The current selection with some text on each side, or null.
    capture() {
      const sel = getSelection();
      if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
      const range = sel.getRangeAt(0);
      for (const n of [sel.anchorNode, sel.focusNode, range.commonAncestorContainer]) {
        const el = n && (n.nodeType === 1 ? n : n.parentElement);
        if (el && el.closest('input,textarea,select,[contenteditable=true],[contenteditable=""]')) return { error: 'field' };
      }
      const exact = sel.toString().trim().slice(0, 1000);
      if (strip(exact).length < 4) return null;
      const map = textMap(), needle = strip(exact);
      let picked = -1;
      for (const i of occurrences(map.text, needle)) {
        try { const p = point(map, i); if (p && range.comparePoint(p.node, p.offset) === 0) { picked = i; break; } } catch (_) {}
      }
      if (picked === -1) picked = map.text.indexOf(needle);
      const prefix = picked > 0 ? map.text.slice(Math.max(0, picked - 64), picked) : '';
      const suffix = picked >= 0 ? map.text.slice(picked + needle.length, picked + needle.length + 64) : '';
      return { exact, prefix, suffix };
    },
    setKept(items) {
      state.kept = (items || []).slice(0, 100); watch(); return relocate();
    },
    setFresh(blocks) {
      state.fresh = (blocks || []).slice(0, 200).map(b => String(b).slice(0, 2000)); watch(); return relocate();
    },
    clearFresh() { state.fresh = []; return relocate(); },
    jump(kind, id) {
      relocate();
      const r = kind === 'kept' ? located.kept.get(id) : located.fresh[0];
      if (!r) return false;
      const el = r.startContainer.nodeType === 1 ? r.startContainer : r.startContainer.parentElement;
      if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
      return true;
    },
  };
  globalThis.__sereinKept = api;
})();
