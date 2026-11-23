// Element pointing for Serein. Runs in the SereinPageReader content world, main frame only.
// Returns facts about the elements the user points at. Never reads field values; on pages with
// password, one-time-code or card fields it returns position and styles only.
(() => {
  if (globalThis.__sereinPoint) return;
  const MAX = 3;
  // Open shadow roots are searched too.
  const deep = (root, sel, out = []) => { if (root.matches && root.matches(sel)) out.push(root); for (const e of root.querySelectorAll(sel)) out.push(e); for (const h of root.querySelectorAll('*')) if (h.shadowRoot) deep(h.shadowRoot, sel, out); if (root.shadowRoot) deep(root.shadowRoot, sel, out); return out; };
  const SECRET = 'input[type=password],input[autocomplete~=one-time-code],input[autocomplete^=cc-],input[autocomplete~=current-password],input[autocomplete~=new-password]';
  const FRAMES = 'iframe,frame,embed,object';
  // Field names from SensitiveFields.names, the list PageKit's `sensitive` uses, filled in by Serein when
  // it loads this script. Left empty it matches every input: fail closed.
  const sensitiveName = new RegExp(/*SENSITIVE_NAMES*/'', 'i');
  const sensitivePage = () => {
    if (globalThis.__serein && globalThis.__serein.probe().steps) return true;
    if (deep(document, SECRET).length) return true;
    // Hidden inputs hold no value the person types (a site's authenticity or CSRF token), as in PageKit.
    return deep(document, 'input:not([type=hidden])').some(e => sensitiveName.test([e.name, e.id, e.placeholder, e.getAttribute('aria-label')].join(' ')));
  };
  // An element is sensitive when it holds a secret field (shadow roots included), is or holds
  // a frame, or overlaps one: a picture of it could show a payment or sign-in frame.
  const overlaps = (a, b) => a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0 && a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
  // An empty or inline same-origin frame (no src, about:blank, srcdoc) that holds no secret field or frame
  // is read through the parent's contentDocument and is not risky; anything unreadable stays risky.
  const risky = f => {
    try {
      const inline = f.tagName === 'IFRAME' && (f.hasAttribute('srcdoc') || !f.getAttribute('src') || f.getAttribute('src') === 'about:blank');
      const d = inline ? f.contentDocument : null;
      return !(d && d.documentElement && !deep(d, SECRET).length && !deep(d, FRAMES).length);
    } catch (_) { return true; }
  };
  const sensitiveElement = e => {
    if (!e || !e.matches) return false;
    if (deep(e, SECRET).length || deep(e, FRAMES).some(risky)) return true;
    const r = e.getBoundingClientRect();
    return deep(document, FRAMES).some(f => risky(f) && overlaps(r, f.getBoundingClientRect()));
  };
  const editable = e => !!(e && (e.isContentEditable || (e.matches && e.matches('input,textarea,select'))));
  const clean = (s, n) => String(s || '').replace(/\s+/g, ' ').trim().slice(0, n);

  // Exact path from :root using nth-of-type wherever a sibling shares the tag.
  const cssPath = e => {
    const parts = [];
    for (let n = e; n && n.nodeType === 1 && n !== document.documentElement; n = n.parentElement) {
      const tag = n.localName;
      const same = n.parentElement ? Array.from(n.parentElement.children).filter(c => c.localName === tag) : [];
      parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(n) + 1})` : tag);
    }
    return [':root'].concat(parts).join(' > ');
  };
  const implicitRole = e => {
    const t = e.localName, type = (e.getAttribute('type') || '').toLowerCase();
    if (t === 'a' && e.hasAttribute('href')) return 'link';
    if (t === 'button' || (t === 'input' && ['button', 'submit', 'reset'].includes(type))) return 'button';
    if (t === 'input' && type === 'checkbox') return 'checkbox';
    if (t === 'input' && type === 'radio') return 'radio';
    if (t === 'input' || t === 'textarea') return 'textbox';
    if (t === 'select') return 'combobox';
    if (/^h[1-6]$/.test(t)) return 'heading';
    if (t === 'img') return 'img';
    if (t === 'nav') return 'navigation';
    if (t === 'main') return 'main';
    if (t === 'ul' || t === 'ol') return 'list';
    if (t === 'li') return 'listitem';
    if (t === 'table') return 'table';
    if (t === 'form') return 'form';
    if (t === 'dialog') return 'dialog';
    return '';
  };
  const accessibleName = e => {
    const labelled = e.getAttribute('aria-labelledby');
    if (labelled) {
      const text = labelled.split(/\s+/).map(id => document.getElementById(id)).filter(Boolean).map(n => n.textContent).join(' ');
      if (clean(text, 1)) return clean(text, 200);
    }
    const direct = e.getAttribute('aria-label') || (e.labels && e.labels.length ? Array.from(e.labels).map(l => l.textContent).join(' ') : '') || e.getAttribute('alt') || e.getAttribute('title');
    if (clean(direct, 1)) return clean(direct, 200);
    if (['button', 'a', 'summary', 'label', 'option'].includes(e.localName) || /^h[1-6]$/.test(e.localName)) return clean(e.innerText, 200);
    return clean(e.getAttribute('placeholder'), 200);
  };
  const STYLE_KEYS = ['display', 'position', 'color', 'background-color', 'background-image', 'font-family', 'font-size', 'font-weight', 'line-height', 'letter-spacing', 'text-align', 'padding', 'margin', 'border', 'border-radius', 'box-shadow', 'opacity', 'gap', 'flex-direction', 'justify-content', 'align-items', 'grid-template-columns', 'width', 'height', 'z-index', 'overflow'];
  const DEFAULTS = new Set(['', 'none', 'normal', 'auto', '0px', 'rgba(0, 0, 0, 0)', 'static', 'visible', '1', 'start', '0px none rgb(0, 0, 0)', 'row']);
  const styles = e => {
    const s = getComputedStyle(e), out = {};
    for (const k of STYLE_KEYS) { const v = s.getPropertyValue(k); if (!DEFAULTS.has(v)) out[k] = clean(v, 160); }
    return out;
  };
  // Source hints that live in DOM attributes (readable from this world).
  const attributeSources = e => {
    const out = [];
    for (let n = e, depth = 0; n && n.nodeType === 1 && depth < 12 && out.length < 3; n = n.parentElement, depth++) {
      const path = n.getAttribute('data-inspector-relative-path');
      if (path) out.push(`${path}:${n.getAttribute('data-inspector-line') || '?'}:${n.getAttribute('data-inspector-column') || '?'} (data-inspector attributes)`);
      const vue = n.getAttribute('data-v-inspector');
      if (vue) out.push(`${vue} (vue inspector attribute)`);
      const astro = n.getAttribute('data-astro-source-file');
      if (astro) out.push(`${astro}:${n.getAttribute('data-astro-source-loc') || '?'} (astro dev metadata)`);
      const component = n.getAttribute('data-component') || n.getAttribute('data-component-name') || n.getAttribute('data-sentry-component');
      if (component) out.push(`component ${component}` + (n.getAttribute('data-sentry-source-file') ? ` in ${n.getAttribute('data-sentry-source-file')}` : '') + ' (data attribute)');
    }
    return out.map(s => clean(s, 300));
  };
  const describe = (e, pageSensitive) => {
    const r = e.getBoundingClientRect();
    const hidden = pageSensitive || sensitiveElement(e);
    return {
      url: location.href,
      tag: e.localName,
      role: clean(e.getAttribute('role') || implicitRole(e), 40),
      name: hidden ? '' : accessibleName(e),
      // Field values are never read; only rendered text of non-form elements.
      text: hidden || editable(e) ? '' : clean(e.innerText, 300),
      cssPath: cssPath(e),
      rect: { x: r.x, y: r.y, width: r.width, height: r.height },
      radius: getComputedStyle(e).borderRadius === '0px' ? '' : getComputedStyle(e).borderRadius,
      styles: styles(e),
      viewport: { x: scrollX, y: scrollY, width: innerWidth, height: innerHeight },
      sources: attributeSources(e),
      sensitive: hidden,
    };
  };

  // Overlay lives in a closed shadow root so page styles cannot restyle it.
  let state = null, lastContext = null;
  addEventListener('contextmenu', ev => { const t = ev.composedPath()[0]; if (t && t.nodeType === 1) lastContext = t; }, true);
  const overlay = () => {
    const host = document.createElement('serein-point');
    host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none;';
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `<style>
      .box{position:fixed;border:2px solid #7C86FF;background:rgba(124,134,255,.12);border-radius:4px;pointer-events:none;box-sizing:border-box;transition:all 60ms linear}
      .picked{border-color:#E5E5E5;background:rgba(229,229,229,.10)}
      .tag{position:fixed;font:500 11px -apple-system,system-ui,sans-serif;color:#0E0E0E;background:#E5E5E5;padding:2px 6px;border-radius:4px;white-space:nowrap;pointer-events:none}
      .hint{position:fixed;left:50%;top:12px;transform:translateX(-50%);font:13px -apple-system,system-ui,sans-serif;color:#E5E5E5;background:rgba(16,16,16,.94);border:1px solid rgba(255,255,255,.14);padding:8px 14px;border-radius:10px;pointer-events:none;box-shadow:0 8px 24px rgba(0,0,0,.4)}
      @media (prefers-reduced-motion: reduce){.box{transition:none}}
    </style><div class="hint"></div><div class="box hover"></div><div class="tag hover"></div>`;
    document.documentElement.appendChild(host);
    return { host, root, hint: root.querySelector('.hint'), box: root.querySelector('.box.hover'), tag: root.querySelector('.tag.hover') };
  };
  const place = (box, tag, e, label) => {
    if (!e) { box.style.display = tag.style.display = 'none'; return; }
    const r = e.getBoundingClientRect();
    Object.assign(box.style, { display: 'block', left: r.x + 'px', top: r.y + 'px', width: r.width + 'px', height: r.height + 'px' });
    tag.textContent = label;
    Object.assign(tag.style, { display: 'block', left: Math.max(4, r.x) + 'px', top: (r.y > 24 ? r.y - 22 : r.bottom + 4) + 'px' });
  };
  const labelFor = e => {
    const r = e.getBoundingClientRect();
    const id = e.id ? '#' + e.id : '';
    return `${e.localName}${id} ${Math.round(r.width)}×${Math.round(r.height)}`;
  };
  const isOurs = e => !!(state && e && (e === state.ui.host || state.ui.host.contains(e)));
  const target = ev => { const t = ev.composedPath ? ev.composedPath()[0] : ev.target; return t && t.nodeType === 1 && !isOurs(t) ? t : null; };
  const render = () => {
    if (!state) return;
    const { ui, picks, current } = state;
    ui.hint.textContent = picks.length
      ? `${picks.length} of ${state.max} chosen. Shift-click adds more. Return finishes. Esc cancels.`
      : 'Click the part you mean. Shift-click adds more. Arrow keys move. Esc cancels.';
    place(ui.box, ui.tag, current, current ? labelFor(current) : '');
    ui.root.querySelectorAll('.picked').forEach(n => n.remove());
    picks.forEach((e, i) => {
      const box = document.createElement('div'), tag = document.createElement('div');
      box.className = 'box picked'; tag.className = 'tag picked';
      ui.root.appendChild(box); ui.root.appendChild(tag);
      place(box, tag, e, String(i + 1));
    });
  };
  const finish = cancelled => {
    if (!state) return;
    const s = state; state = null;
    for (const [type, fn] of s.listeners) removeEventListener(type, fn, true);
    s.ui.host.remove();
    if (cancelled || !s.picks.length) { s.resolve({ cancelled: true }); return; }
    const pageSensitive = sensitivePage();
    s.resolve({ cancelled: false, sensitive: pageSensitive, url: location.href, title: document.title, zoom: devicePixelRatio, picks: s.picks.filter(e => e.isConnected).map(e => describe(e, pageSensitive)) });
  };
  const toggle = (e, add) => {
    const i = state.picks.indexOf(e);
    if (i >= 0) state.picks.splice(i, 1);
    else if (state.picks.length < state.max) state.picks.push(e);
    if (!add || state.picks.length >= state.max) finish(false); else render();
  };
  const block = ev => { if (!state || isOurs(ev.target)) return; ev.preventDefault(); ev.stopPropagation(); ev.stopImmediatePropagation(); };
  const start = (max = MAX) => {
    if (state) finish(true);
    return new Promise(resolve => {
      const ui = overlay();
      state = { resolve, ui, picks: [], current: null, max: Math.max(1, Math.min(MAX, Number(max) || MAX)), listeners: [] };
      const on = (type, fn) => { addEventListener(type, fn, true); state.listeners.push([type, fn]); };
      on('mousemove', ev => { const t = target(ev); if (t && t !== state.current) { state.current = t; render(); } });
      for (const type of ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'auxclick', 'contextmenu', 'submit']) on(type, block);
      on('click', ev => { block(ev); const t = target(ev) || state.current; if (t) toggle(t, ev.shiftKey); });
      on('scroll', () => render());
      on('resize', () => render());
      on('keydown', ev => {
        if (!state) return;
        const c = state.current;
        const step = { ArrowUp: c && c.parentElement !== document.documentElement ? c.parentElement : null, ArrowDown: c && c.firstElementChild, ArrowLeft: c && c.previousElementSibling, ArrowRight: c && c.nextElementSibling };
        if (ev.key === 'Escape') { block(ev); finish(true); }
        else if (ev.key in step) { block(ev); if (step[ev.key]) { state.current = step[ev.key]; state.current.scrollIntoView({ block: 'nearest' }); render(); } }
        else if (ev.key === 'Enter') { block(ev); if (c && !state.picks.includes(c)) toggle(c, ev.shiftKey); else if (state.picks.length) finish(false); }
        else if (['Tab', ' '].includes(ev.key)) block(ev);
      });
      on('keyup', ev => { if (['Escape', 'Enter', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(ev.key)) block(ev); });
      on('pagehide', () => finish(true));
      state.current = document.activeElement && document.activeElement !== document.body ? document.activeElement : null;
      render();
    });
  };
  const fromContext = () => {
    const e = lastContext && lastContext.isConnected ? lastContext : null;
    if (!e) return { cancelled: true };
    const pageSensitive = sensitivePage();
    return { cancelled: false, sensitive: pageSensitive, url: location.href, title: document.title, zoom: devicePixelRatio, picks: [describe(e, pageSensitive)] };
  };
  // Selected text for a chip; empty on sensitive pages and inside form fields.
  const selection = () => {
    if (sensitivePage()) return { text: '', sensitive: true };
    const s = getSelection();
    const node = s && s.anchorNode && (s.anchorNode.nodeType === 1 ? s.anchorNode : s.anchorNode.parentElement);
    if (!s || s.isCollapsed || (node && (editable(node) || node.closest('input,textarea,select')))) return { text: '', sensitive: false };
    return { text: String(s).slice(0, 14000), sensitive: false };
  };
  // Framework hints from JS properties only visible in the page's own world. Swift runs this
  // in the page world with the element's CSS path; the result is treated as untrusted.
  const hintScript = String(function sereinHints(path) {
    const out = [];
    let e = null;
    try { e = document.querySelector(path); } catch (_) { return out; }
    for (let n = e, depth = 0; n && depth < 15 && out.length < 3; n = n.parentElement, depth++) {
      const fiberKey = Object.keys(n).find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
      if (fiberKey) {
        let f = n[fiberKey], names = [];
        for (let i = 0; f && i < 40; f = f.return, i++) {
          const t = f.type, name = t && (t.displayName || t.name);
          if (typeof t === 'function' || (t && typeof t === 'object')) { if (name && names.length < 3) names.push(String(name)); }
          const src = f._debugSource;
          if (src && src.fileName) { out.push(`${src.fileName}:${src.lineNumber || '?'}${names.length ? ' <' + names[0] + '>' : ''} (react debug source)`); break; }
        }
        if (!out.length && names.length) out.push(`components ${names.join(' < ')} (react component names)`);
        break;
      }
      const vue = n.__vueParentComponent;
      if (vue && vue.type) { const file = vue.type.__file; const name = vue.type.__name || vue.type.name; if (file || name) { out.push(`${file || ''}${name ? ' <' + name + '>' : ''} (vue component file)`); break; } }
      if (n.__vue__ && n.__vue__.$options) { const o = n.__vue__.$options; if (o.__file || o.name) { out.push(`${o.__file || ''}${o.name ? ' <' + o.name + '>' : ''} (vue component file)`); break; } }
      const svelte = n.__svelte_meta;
      if (svelte && svelte.loc) { out.push(`${svelte.loc.file}:${svelte.loc.line + 1}:${svelte.loc.column} (svelte dev metadata)`); break; }
    }
    return out.map(s => String(s).replace(/\s+/g, ' ').slice(0, 300));
  });
  globalThis.__sereinPoint = { start, cancel: () => finish(true), fromContext, selection, hintScript, sensitive: sensitivePage };
})();
