// Serein password helper. Runs in the isolated "SereinPasswords" content world of regular
// (user-owned) tabs only. It notices sign-in submissions and credential-field focus and posts
// them to the host's `sereinPasswords` handler. It never logs, stores or sends values anywhere
// else, and page scripts cannot see or call it.
(() => {
  if (globalThis.__sereinPasswords) return;
  const documentID = crypto.randomUUID();
  const handler = () => {
    try { return window.webkit.messageHandlers.sereinPasswords; } catch (_) { return null; }
  };
  const post = (message) => { const h = handler(); if (h) try { h.postMessage(message); } catch (_) {} };
  const isInput = (e) => e instanceof HTMLInputElement;
  const isPassword = (e) => isInput(e) && e.type === 'password';
  const visible = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const isNewPassword = (e) => /\bnew-password\b/i.test(e.getAttribute('autocomplete') || '');
  const userTypes = new Set(['text', 'email', 'tel', '']);
  const looksLikeUser = (e) => {
    if (!isInput(e) || !userTypes.has(e.type)) return false;
    const ac = (e.getAttribute('autocomplete') || '').toLowerCase();
    if (/\b(one-time-code|cc-|off)\b/.test(ac)) return false;
    if (/\b(username|email)\b/.test(ac) || e.type === 'email') return true;
    return /user|login|email|account|identifier/i.test((e.name || '') + ' ' + (e.id || ''));
  };
  // Recovery and backup code names (SensitiveFields.recovery), filled in by Serein when it loads this
  // script. Left empty it matches every field, so no code is filled: fail closed.
  const recoveryName = new RegExp(/*SENSITIVE_RECOVERY*/'', 'i');
  // A one-time-code field: marked so, or named for a code, never a card field and never a recovery
  // or backup code field (a one-time code typed there is wrong and can use up a recovery code).
  const isCode = (e) => {
    if (!isInput(e) || !['text', 'tel', 'number', ''].includes(e.type)) return false;
    const ac = (e.getAttribute('autocomplete') || '').toLowerCase();
    const words = [e.name, e.id, e.getAttribute('aria-label'), e.getAttribute('placeholder')].join(' ');
    if (recoveryName.test(words)) return false;
    if (/\bone-time-code\b/.test(ac)) return true;
    if (/\bcc-/.test(ac)) return false;
    return /otp|one.?time|verification.?code|2fa|two.?factor|mfa|totp|auth(entication)?.?code/i.test(words);
  };
  const rootOf = (e) => (e && e.form) || document;
  const passwordsIn = (root) => Array.from(root.querySelectorAll('input[type=password]'));
  // The username is the closest plausible field before the first password field.
  const userFor = (root, password) => {
    const inputs = Array.from(root.querySelectorAll('input')).filter((e) => visible(e) || e.value);
    const marked = inputs.filter((e) => /\busername\b/i.test(e.getAttribute('autocomplete') || ''));
    if (marked.length) return marked[0];
    const end = password ? inputs.indexOf(password) : inputs.length;
    const before = inputs.slice(0, end < 0 ? inputs.length : end).filter((e) => userTypes.has(e.type));
    const likely = before.filter(looksLikeUser);
    return likely[likely.length - 1] || before[before.length - 1] || null;
  };
  const clip = (value, n) => String(value || '').slice(0, n);

  // A submission counts only after a real key press or pointer press in this frame. Page
  // scripts can call requestSubmit() or dispatch events with values they chose.
  let lastGesture = 0;
  for (const type of ['keydown', 'mousedown', 'pointerdown', 'touchstart']) {
    document.addEventListener(type, (e) => { if (e.isTrusted) lastGesture = Date.now(); }, true);
  }
  const userActed = (e) =>
    globalThis.__sereinPasswordsTrustSynthetic === true ||
    (e.isTrusted && Date.now() - lastGesture < 5000);

  let lastSignature = '';
  let lastAt = 0;
  const collect = (root) => {
    const filled = passwordsIn(root).filter((e) => e.value);
    if (!filled.length) return;
    let password = filled[0];
    let isNew = isNewPassword(password);
    if (filled.length >= 2) {
      // Sign-up or change-password form: keep the new password, not the current one.
      const fresh = filled.filter(isNewPassword);
      password = fresh.length ? fresh[fresh.length - 1] : filled[filled.length - 1];
      isNew = true;
    }
    const user = userFor(root, filled[0]);
    const username = clip(user ? user.value.trim() : '', 512);
    const value = clip(password.value, 1024);
    const signature = username + '\u0000' + value;
    const now = Date.now();
    if (signature === lastSignature && now - lastAt < 4000) return;
    lastSignature = signature;
    lastAt = now;
    setTimeout(() => { if (Date.now() - lastAt >= 4000) lastSignature = ''; }, 4500);
    post({ type: 'submit', username, password: value, isNew });
  };
  // Only real user actions count; a page script can dispatch synthetic submit, click and
  // keydown events with values it chose.
  document.addEventListener('submit', (e) => {
    if (!userActed(e)) return;
    collect(e.target instanceof HTMLFormElement ? e.target : document);
  }, true);
  // Script-driven sign-in pages often never fire `submit`.
  document.addEventListener('click', (e) => {
    if (!userActed(e)) return;
    const t = e.target instanceof Element ? e.target.closest('button, input[type=submit], input[type=image], [role=button]') : null;
    if (!t) return;
    const root = t.form || t.closest('form') || document;
    if (passwordsIn(root).some((p) => p.value)) setTimeout(() => collect(root), 0);
  }, true);
  document.addEventListener('keydown', (e) => {
    if (!userActed(e) || e.key !== 'Enter' || !isInput(e.target)) return;
    const root = rootOf(e.target);
    if (passwordsIn(root).some((p) => p.value)) setTimeout(() => collect(root), 0);
  }, true);

  // Focus: tell the host where a credential field is, so it can offer saved accounts.
  let lastField = null;
  let offered = false;
  const top = window === window.top;
  document.addEventListener('focusin', (e) => {
    if (!top) return;
    const t = e.target;
    let field = null;
    if (isPassword(t)) field = 'password';
    else if (looksLikeUser(t) && passwordsIn(rootOf(t)).some(visible)) field = 'username';
    if (!field) {
      if (offered) post({ type: 'focus', field: 'other' });
      offered = false;
      return;
    }
    lastField = t;
    offered = true;
    const r = t.getBoundingClientRect();
    const root = rootOf(t);
    const isNew = field === 'password' && (isNewPassword(t) || passwordsIn(root).filter(visible).length >= 2);
    post({
      type: 'focus', field, isNew,
      rules: clip(t.getAttribute('passwordrules'), 2000),
      minLength: t.minLength > 0 ? t.minLength : 0,
      maxLength: t.maxLength > 0 ? t.maxLength : 0,
      rect: { x: r.left, y: r.top, w: r.width, h: r.height },
    });
  }, true);

  // A passkey request from the page world (see the host's page-world probe).
  document.addEventListener('serein:passkey', (e) => {
    if (!top) return;
    post({ type: 'passkey', op: e.detail === 'create' ? 'create' : 'get' });
  });

  const setValue = (e, v) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(e, v);
    e.dispatchEvent(new Event('input', { bubbles: true }));
    e.dispatchEvent(new Event('change', { bubbles: true }));
  };
  const checkForm = (root) => {
    if (root instanceof HTMLFormElement) {
      const action = new URL(root.getAttribute('action') || location.href, location.href);
      if (action.origin !== location.origin) throw Error('This form sends to another site. Nothing was filled.');
    }
  };
  globalThis.__sereinPasswords = {
    documentID,
    fill(origin, username, password, expectedDocument) {
      if (location.origin !== origin) throw Error('The site changed. Nothing was filled.');
      if (expectedDocument !== documentID) throw Error('The sign-in page changed. Nothing was filled.');
      const anchor = lastField && lastField.isConnected ? lastField : null;
      const root = rootOf(anchor);
      checkForm(root);
      const candidates = passwordsIn(root).filter((e) => visible(e) && !isNewPassword(e));
      if (!anchor && candidates.length !== 1) throw Error('Select one sign-in password field first.');
      const pw = anchor && isPassword(anchor) ? anchor : candidates[0] || null;
      const user = anchor && !isPassword(anchor) ? anchor : userFor(root, pw);
      checkForm((pw && pw.form) || (user && user.form) || root);
      if (!pw && !user) throw Error('Click a sign-in field first.');
      if (user && username) setValue(user, username);
      if (pw) setValue(pw, password);
      return 'filled';
    },
    fillNew(origin, password, expectedDocument) {
      if (location.origin !== origin) throw Error('The site changed. Nothing was filled.');
      if (expectedDocument !== documentID) throw Error('The sign-in page changed. Nothing was filled.');
      const anchor = lastField && lastField.isConnected ? lastField : null;
      const root = rootOf(anchor);
      checkForm(root);
      const all = passwordsIn(root).filter(visible);
      const marked = all.filter(isNewPassword);
      const targets = marked.length ? marked : all.length >= 2 ? all.slice(-2) : all;
      if (!targets.length) throw Error('Click a password field first.');
      targets.forEach((e) => setValue(e, password));
      return targets.length;
    },
    // Sign in as … from a task's hand-back. No field has focus, so the fields come from the page:
    // its one current-password field with the username beside it, plus one verification-code field
    // when a code is given. A page with neither field gets nothing. A page with a new or a
    // second password field gets nothing, nor does a code-only page without a saved code. Nothing
    // is sent: the person sees the filled page and presses its own button.
    signIn(origin, username, password, code, expectedDocument) {
      if (location.origin !== origin) throw Error('The site changed. Nothing was filled.');
      if (expectedDocument !== documentID) throw Error('The sign-in page changed. Nothing was filled.');
      const shown = passwordsIn(document).filter(visible);
      if (shown.length > 1 || shown.some(isNewPassword)) throw Error('This page asks for a new password. Nothing was filled.');
      const inputs = Array.from(document.querySelectorAll('input')).filter(visible);
      const codes = code ? inputs.filter(isCode) : [];
      const codeField = codes.length === 1 ? codes[0] : null;
      const pw = shown[0] || null;
      if (!pw && !code && inputs.some(isCode)) throw Error('No verification code is saved for this login. Nothing was filled.');
      if (!pw && !codeField) throw Error('No sign-in field is on this page. Nothing was filled.');
      let user = pw ? userFor(rootOf(pw), pw) : null;
      // Outside a form the nearest text field may be a search box: only a field named for an account counts.
      if (user && (user === codeField || (!user.form && !looksLikeUser(user)))) user = null;
      const fields = [user, pw, codeField].filter(Boolean);
      if (!fields.length) throw Error('No sign-in field is on this page. Nothing was filled.');
      fields.forEach((e) => checkForm(rootOf(e)));
      if (user && username) setValue(user, username);
      if (pw) setValue(pw, password);
      if (codeField) setValue(codeField, code);
      return 'filled';
    },
  };
})();
