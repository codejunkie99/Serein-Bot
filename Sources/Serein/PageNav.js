(() => {
  // One notifier per window. A frame created after this script ran (about:blank, srcdoc,
  // or a later navigation) is armed from the parent as well as by the document-start injection.
  const tellFrom = (win, reason) => {
    try { win.webkit.messageHandlers.sereinNav.postMessage('nav:' + reason); } catch (_) {}
  };
  const arm = (win) => {
    if (!win || win.__sereinNav) return;
    let HistoryRef;
    let history;
    try { HistoryRef = win.History; history = win.history; } catch (_) { return; }
    if (!HistoryRef || !history || !HistoryRef.prototype) return;
    win.__sereinNav = true;
    const push = HistoryRef.prototype.pushState;
    const replace = HistoryRef.prototype.replaceState;
    // A child realm that calls this with another window's history must not move that
    // history and must not post a navigation that would make an old yes look current.
    HistoryRef.prototype.pushState = function () {
      if (this !== history) return;
      const result = push.apply(this, arguments);
      tellFrom(win, 'push');
      return result;
    };
    HistoryRef.prototype.replaceState = function () {
      if (this !== history) return;
      const result = replace.apply(this, arguments);
      tellFrom(win, 'replace');
      return result;
    };
    try {
      win.addEventListener('popstate', () => tellFrom(win, 'pop'));
      win.addEventListener('hashchange', () => tellFrom(win, 'hash'));
    } catch (_) {}
  };
  const armFrame = (frame) => {
    try {
      arm(frame.contentWindow);
      if (frame && !frame.__sereinNavLoad) {
        frame.__sereinNavLoad = true;
        frame.addEventListener('load', () => {
          try { arm(frame.contentWindow); } catch (_) {}
        });
      }
    } catch (_) {}
  };
  const armFrames = () => {
    let frames = [];
    try { frames = document.querySelectorAll('iframe'); } catch (_) { frames = []; }
    for (const frame of frames) armFrame(frame);
  };
  arm(globalThis);
  try { globalThis.__sereinArmFrames = armFrames; } catch (_) {}
  try {
    if (typeof MutationObserver === 'function' && document.documentElement) {
      new MutationObserver(armFrames).observe(document.documentElement, { childList: true, subtree: true });
    }
    armFrames();
  } catch (_) {}
})();
