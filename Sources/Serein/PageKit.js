(() => {
  if (globalThis.__serein) return;
  let refs = new Map(), generation = 0;
  // Fields a secure card filled, by the ref the card named. A read clears refs, not these, so the
  // press after a fill can still find its form (sameForm).
  const filled = new Map();
  // File fields from the latest read, by their own ids (`u…`): only `upload` resolves one, so no
  // click, type or describe ever reaches a file field through them.
  const uploads = new Map();
  const documentID=Array.from(crypto.getRandomValues(new Uint32Array(4)),x=>x.toString(16)).join('-');
  let revision=0;
  const secretFields=new WeakSet();
  const stepHistory=new WeakMap();
  const remember=records=>{for(const r of records)if(r.type==='attributes'&&r.attributeName==='type'&&r.oldValue==='password')secretFields.add(r.target);};
  // Every mutation still changes the document revision, but class/style/feed updates do
  // not need old attribute values retained or a JavaScript pass over every record.
  // Keep old values only for type: Show password must never make a password shareable.
  const mutations=new MutationObserver(()=>{revision++});
  mutations.observe(document,{subtree:true,childList:true,attributes:true,characterData:true});
  const types=new MutationObserver(remember);
  types.observe(document,{subtree:true,attributes:true,attributeFilter:['type'],attributeOldValue:true});
  const version=()=>{remember(types.takeRecords());if(mutations.takeRecords().length)revision++;return revision;};
  const register=()=>{try{webkit.messageHandlers.sereinFrame.postMessage(documentID)}catch(_){}};
  register();
  const visible = e => { const r=e.getBoundingClientRect(), s=getComputedStyle(e); return r.width>0 && r.height>0 && s.visibility!=='hidden' && s.display!=='none'; };
  // Fields a person cannot type into hold no password or code, whatever their names say: GitHub's
  // hidden authenticity_token inputs and a donation radio labelled "One time" made whole pages
  // count as code steps. Their values never reach the agent (hidden, or a checked state only).
  const noEntry='input[type=hidden],input[type=radio],input[type=checkbox],input[type=submit],input[type=button],input[type=reset],input[type=image],input[type=range],input[type=color]';
  // The field words (SensitiveFields.names) and a pressable control's own words (SensitiveFields.controls),
  // filled in by Serein when it loads this script. Left empty they match everything: fail closed.
  const sensitiveName=new RegExp(/*SENSITIVE_NAMES*/'','i'), controlWords=new RegExp(/*SENSITIVE_CONTROLS*/'','i');
  const sensitive = e => { if(!secretFields.has(e)&&e.matches(noEntry))return false; const yes=secretFields.has(e) || e.matches('input[type=password],input[type=file]') || /(^|\s)(cc-[a-z-]+|one-time-code|current-password|new-password)(\s|$)/i.test(e.autocomplete||'') || sensitiveName.test([e.name,e.id,e.getAttribute('aria-label'),e.getAttribute('placeholder'),e.labels?Array.from(e.labels).map(l=>l.textContent).join(' '):''].join(' ')); if(yes)secretFields.add(e);return yes; };
  // Pictures cannot be text-redacted. Refuse them when recognizable credentials appear in
  // rendered text or in any field, including a password changed to type=text by Show password.
  const secretRE = /-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[A-Z0-9]{16})\b|\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b|\b(?:authorization|proxy-authorization)\s*[:=]\s*(?:bearer|basic)\s+\S+|\b(?:password|passwd|pwd|passphrase|(?:access|refresh|auth|session|id)[_-]?token|token|api[_-]?key|client[_-]?secret|secret[_-]?key)\b["']?\s*[:=]\s*[^\s]/i;
  const hasSecrets = text => secretRE.test(String(text||''));
  // The same patterns, each match through the end of its value, for cutting out of text.
  const secretAllRE = new RegExp(secretRE.source.replace(/\[\^\\s\]$/,'\\S+'),'gi');
  // Steps that stay with the user: passwords, card details, codes, CAPTCHAs and files.
  const yours = "This step is yours: the user types passwords, card details and codes, solves CAPTCHAs and chooses files (upload takes only a document the user attached to this message, after the user allows it). Routes: secure_card on a field marked secure; person_step with kind check on this tab for any other such field; ask_person_takeover on this tab for a CAPTCHA or bot check. Carry on with every other part, and pass this tab as result_tab when you finish.";
  const fieldWords = e => [e.name,e.id,e.getAttribute('aria-label'),e.getAttribute('placeholder'),e.labels?Array.from(e.labels).map(l=>l.textContent).join(' '):''].join(' ');
  const secretKind = e => { const ac=e.autocomplete||'', words=fieldWords(e);
    if(e.matches('input[type=password]')||/password/.test(ac))return 'password';
    if(/(^|\s)cc-/.test(ac)||/card|cvv|cvc|security.?code|expir/i.test(words))return 'card'; if(/captcha/i.test(words))return 'captcha'; return /password|passwd/i.test(words)?'password':'code'; };
  // Open shadow roots are searched too; closed ones stay private to the page.
  // Discover open roots once per read/probe. Reusing them only within that synchronous
  // operation avoids stale security results when a page attaches or replaces a root.
  const searchRoots = (root, out=[]) => { out.push(root);for(const h of root.querySelectorAll('*'))if(h.shadowRoot)searchRoots(h.shadowRoot,out);return out; };
  const deep = (root, sel, out=[], scopes=searchRoots(root)) => { for(const scope of scopes)for(const e of scope.querySelectorAll(sel))out.push(e);return out; };
  // A human-verification check is the person's: a frame from a verification service, a widget
  // the page draws, or a whole "verify you are human" page. A scoring widget that asks nothing
  // (a corner badge, size=invisible, hidden or tiny) does not count. Known by address and words
  // only: nothing is fetched and nothing is answered. The lists are BotCheck's (SereinCore), the
  // Mac's and Serein's computer's too; one list of services and widgets serves both the read's
  // user steps (captchaSelector) and `challenge`.
  const checkHosts=/*CHECK_HOSTS*/[], checkWidget=/*CHECK_WIDGETS*/'*', checkName=new RegExp(/*CHECK_NAMES*/'','i');
  const captchaSelector=['iframe[src*="captcha" i]','iframe[title*="captcha" i]',...checkHosts.map(h=>`iframe[src*="${h}"]`),checkWidget].join(',');
  const checkHost=new RegExp('(^|\\.)('+checkHosts.map(h=>h.replace(/\./g,'\\.')).join('|')+')$','i');
  // A service's host, or a path that is a check's own (/recaptcha/..., /captcha.js), not one that only
  // mentions it (/blog/how-captchas-work).
  const checkAddress = src => { try { const u=new URL(src,location.href); return /captcha/i.test(u.hostname)||/\/(re|h)?captcha(\/|$|[._-])/i.test(u.pathname)||checkHost.test(u.hostname)?u.hostname:''; } catch(_) { return ''; } };
  // An interstitial's own words. A page that only talks about checks (a help article, a sign-up
  // note) does not say these in its first lines; the verify and confirm phrasings must open a line
  // or a sentence, or follow "please" ("We use a check to verify you are human" is a note).
  const checkWords=new RegExp(/*CHECK_WORDS*/'','im');
  const asksNothing = e => { const r=e.getBoundingClientRect(); return !visible(e)||r.width<20||r.height<20||/invisible/i.test(e.getAttribute('src')||'')||e.getAttribute('data-size')==='invisible'||!!e.closest('.grecaptcha-badge'); };
  // A check that covers 30% or more of the page's viewport (a modal challenge) stops the whole page.
  // A sub-frame's viewport is not the page's, so there only the target decides.
  const covers = e => { if(window.top!==window)return false; const r=e.getBoundingClientRect();
    const w=Math.max(0,Math.min(r.right,innerWidth)-Math.max(r.left,0)), h=Math.max(0,Math.min(r.bottom,innerHeight)-Math.max(r.top,0));
    return w*h>=.3*innerWidth*innerHeight; };
  // This document is itself a check's frame; the page around it decides whether it shows.
  const checkFrame = () => window.top!==window&&!!checkAddress(location.href);
  const insideCheck = e => checkFrame()||!!e.closest(checkWidget)||pictureChecks(e.ownerDocument).has(e)||(e.matches('iframe,frame')&&!!checkAddress(e.getAttribute('src')||''));
  const checkAsks=new RegExp(/*CHECK_ASKS*/'','i'), checkSums=new RegExp(/*CHECK_SUMS*/'','i'), checkAnswers=new RegExp(/*CHECK_ANSWERS*/'','i'),
    checkRedraws=new RegExp(/*CHECK_REDRAWS*/'','i'), checkConfirms=new RegExp(/*CHECK_CONFIRMS*/'','i'), checkOwns=new RegExp(/*CHECK_OWNS*/'(?!)','i'), imageWords=new RegExp(/*CHECK_IMAGE_WORDS*/'','i'),
    wordsOver=new RegExp(/*CHECK_OVER*/'','i'), wordsUnder=new RegExp(/*CHECK_UNDER*/'','i'), checkNear=/*CHECK_NEAR*/1e9, redrawReach=/*CHECK_REACH*/1e9;
  const pictureSetsThisTick=new Map();
  const pictureChecks = doc => { let out=pictureSetsThisTick.get(doc); if(out)return out; out=new Set();
    if(!doc||doc.nodeType!==9||!(doc.body||doc.documentElement))return out;
    if(!pictureSetsThisTick.size)queueMicrotask(()=>pictureSetsThisTick.clear()); pictureSetsThisTick.set(doc,out);
    const rows=deep(doc.body||doc.documentElement,'*').filter(e=>!e.matches('script,style,noscript,template')), at=new Map(rows.map((e,i)=>[e,i]));
    const memo=fn=>{const cache=new WeakMap();return e=>{if(!cache.has(e))cache.set(e,fn(e));return cache.get(e);};};
    const transparent=e=>{for(let node=e;node;node=node.parentElement)if(getComputedStyle(node).opacity==='0')return true;return false;};
    const shown=memo(e=>visible(e)&&!e.closest('[hidden],[inert]')&&(e.checkVisibility?e.checkVisibility({opacityProperty:true,checkOpacity:true,visibilityProperty:true}):!transparent(e))), press=e=>e.matches('a[href],button,input[type=button],input[type=submit],input[type=image],[role=button],[role=link]');
    const field=e=>e.matches(textSelector)&&!e.disabled&&shown(e), named=w=>/[\p{L}\p{N}]/u.test(w||'');
    const shownText=memo(e=>{const walk=doc.createTreeWalker(e,NodeFilter.SHOW_TEXT);const parts=[];let n;
      while((n=walk.nextNode()))if(n.parentElement&&shown(n.parentElement))parts.push(n.data);return parts.join(' ');});
    const words=new Map(), say=e=>{ if(!words.has(e)){ const attr=n=>e.getAttribute(n)||'';
        const own=press(e)?[shownText(e),e.matches('input')?e.value:'',...Array.from(e.querySelectorAll('img[alt]')).filter(shown).map(i=>i.alt)]:Array.from(e.childNodes,n=>n.nodeType===3?n.data:'');
        words.set(e,[attr('alt'),attr('aria-label'),attr('title'),attr('placeholder'),...own,...Array.from(e.labels||[],shownText)].join(' ').replace(/\s+/g,' ').trim()); }
      return words.get(e); }, says=(e,re)=>re.test(say(e));
    const fieldName=memo(e=>[e.getAttribute('aria-label'),e.getAttribute('placeholder'),e.getAttribute('title'),...Array.from(e.labels||[],shownText)].join(' '));
    const article=memo(e=>e.closest('article,figure,[role=article],[role=figure]')), form=memo(e=>e.form||e.closest('form'));
    const related=(a,b)=>form(a)&&form(b)?form(a)===form(b):article(a)===article(b);
    for(const e of rows)if(e.matches('img,canvas,[role=img]')&&shown(e)&&/\bcaptcha\b/i.test(say(e))
      &&(!article(e)||e.closest('button,[role=button]')))out.add(e);
    if(!rows.some(e=>e.matches(textSelector)))return out;
    rows.forEach((a,i)=>{
      const blank=a.matches('img[alt=""],img[role=presentation],img[role=none]')||(a.matches('div,p')&&!a.firstElementChild&&!named(a.textContent)&&!named(say(a)));
      const picture=!blank&&a.matches('img,canvas,[role=img]')&&(!says(a,checkOwns)||/\bcaptcha\b/i.test(say(a)));
      const arithmetic=says(a,checkSums);
      if(!(picture||blank||arithmetic)||!shown(a))return;
      const around=rows.slice(Math.max(0,i-checkNear),i+checkNear+1).filter(k=>related(a,k)), sum=arithmetic&&around.some(k=>k!==a&&shown(k)&&says(k,checkName));
      if(!(picture||blank||sum))return;
      const fields=around.filter(field), answers=fields.filter(f=>!named(fieldName(f))||checkAnswers.test(fieldName(f)));
      const order=k=>(at.get(k)<i?rows.length:0)+Math.abs(at.get(k)-i);
      const f=field(a)?a:answers.sort((x,y)=>order(x)-order(y))[0]||fields.find(k=>at.get(k)>i); if(!f)return;
      const lo=Math.min(i,at.get(f))-redrawReach, hi=Math.max(i,at.get(f))+redrawReach;
      const redraws=around.filter(k=>at.get(k)>=lo&&at.get(k)<=hi&&press(k)&&shown(k)&&says(k,checkRedraws)&&!says(k,checkOwns));
      const asked=around.some(k=>shown(k)&&(says(k,checkAsks)||says(k,imageWords)||at.get(k)>i&&says(k,wordsOver)||at.get(k)<i&&says(k,wordsUnder)));
      const plain=!named(say(a))||says(a,checkAnswers)||says(a,imageWords)||says(a,checkRedraws);
      const linked=!!(a.parentElement&&a.parentElement.closest('a[href]')), fieldNotYetThePersons=!sensitive(f);
      const bareShape=plain&&!linked&&answers.includes(f)&&fieldNotYetThePersons, pictureCheck=says(a,checkName)||redraws.length>0||bareShape||asked;
      if(sum||picture&&pictureCheck||blank&&asked){
        for(const k of [a,f,...redraws])out.add(k);
        for(const k of around)if(at.get(k)>=lo&&at.get(k)<=hi&&press(k)&&shown(k)&&related(f,k)
          &&form(k)===form(f)&&(says(k,checkConfirms)||checkConfirms.test(labelOf(k))))out.add(k);
      } });
    return out; };
  // The check this document shows: {kind: frame|widget|page, frame: the check's frame host or null,
  // blocks}; null when there is none. `blocks` is true for an interstitial, a check covering 30% of
  // the viewport, this document being a check's frame, or `ref` being inside a check: then no action
  // goes on here and the person takes over. An inline check (a widget in a sign-up form) leaves the
  // rest of the page to the agent; only actions inside it are refused.
  const challenge = (ref, scopes=searchRoots(document)) => {
    if(checkFrame())return {kind:'frame',frame:location.hostname,blocks:true};
    const e=ref?refs.get(ref):null, inside=!!(e&&e.isConnected&&insideCheck(e));
    let found=null, covered=false;
    for(const f of deep(document,'iframe,frame',[],scopes)){ const host=checkAddress(f.getAttribute('src')||'');
      if((host||checkName.test(f.title||''))&&!asksNothing(f)){ found=found||{kind:'frame',frame:host||null}; covered=covered||covers(f); } }
    for(const w of deep(document,checkWidget,[],scopes))if(!asksNothing(w)){ found=found||{kind:'widget',frame:null}; covered=covered||covers(w); }
    if(pictureChecks(document).size)found=found||{kind:'widget',frame:null};
    if(found&&(covered||inside))return {...found,blocks:true};
    // A short page only: innerText lays the page out, and an interstitial runs 300-700 visible characters.
    const body=document.body; if(body&&(body.textContent||'').length<20000){ const shown=String(body.innerText||''); if(shown.length<1500&&checkWords.test(document.title+'\n'+shown.slice(0,600)))return {kind:'page',frame:null,blocks:true}; }
    if(found)return {...found,blocks:false};
    return inside?{kind:'widget',frame:null,blocks:true}:null; };
  // A cookie, consent, survey or newsletter overlay over this page: a consent platform's own box,
  // or a box the site itself marked as one that holds consent or sign-up words, shown and covering
  // part of the view. The marker is an id or class whose name starts with the kind's word; never an
  // aria-label, which sites fill with titles and names. A plain dialog never counts, whatever its text.
  // Each control in it gets a kind: private (shares the least), neutral, or accept (agrees to
  // everything). In a survey or newsletter box only its close control counts, and it is private:
  // nothing in such a box is ever submitted. Swift decides the effect (ApprovalGate.rate); a kind
  // here only raises, except a private kind whose whole label Swift's own list also has.
  // shortcut: main document only; a consent form in its own cross-origin frame is left to the agent.
  const consentBoxes='#onetrust-banner-sdk,#onetrust-consent-sdk,#CybotCookiebotDialog,#didomi-popup,#didomi-notice,.qc-cmp2-container,#truste-consent-track,#usercentrics-root,.osano-cm-dialog,.cmplz-cookiebanner,.cky-consent-container,#iubenda-cs-banner,#cookie-law-info-bar,.cc-window,#cookiescript_injected,.fc-consent-root';
  const consentMarks='[id^=cookie i],[id^=consent i],[id^=gdpr i],[class^=cookie i],[class*=" cookie" i],[class^=consent i],[class*=" consent" i],[class^=gdpr i],[class*=" gdpr" i]';
  const surveyMarks='[id^=newsletter i],[id^=survey i],[class^=newsletter i],[class*=" newsletter" i],[class^=survey i],[class*=" survey" i]';
  const overlayBoxes=consentMarks+','+surveyMarks;
  // A generic box needs its kind's marker on the box element itself and that kind's words: page
  // text alone (an invite or a ticket that mentions cookies) never makes a site's own modal an
  // overlay, and user content cannot be a covering ancestor of the site's button. The marker is
  // anchored to the start of the id or of a class token, so a title or slug copied into an id
  // ("review-pr-fix-cookie-parsing") or a sanitizer's prefix ("x_cookie-banner") does not qualify.
  // A consent platform's own box needs no words.
  const consentWords=/\bcookies?\b|tracking technologies|legitimate interest/i;
  const surveyWords=/\bsurvey\b|\bnewsletter\b|mailing list|email updates|how likely are you/i;
  // Private kinds match the whole label against the same list as Swift's consent entries
  // (ApprovalGate.privateConsentLabels; keep the two identical): a word inside a longer label
  // ("Close account", "Reject and subscribe") is never private.
  const privateLabels=new Set(['reject','reject all','reject cookies','reject all cookies','reject non-essential','reject non-essential cookies',
    'reject optional cookies','reject additional cookies','decline','decline all','decline cookies',
    'decline all cookies','decline optional cookies','refuse','refuse all','refuse cookies','deny','deny all',
    'disagree','essential only','only essential','essential cookies only','only essential cookies',
    'use essential cookies only','necessary only','only necessary','necessary cookies only',
    'only necessary cookies','use necessary cookies only','required only','only required',
    'strictly necessary only','strictly necessary cookies only','continue without accepting',
    'continue without agreeing','do not accept','do not consent','accept only essential cookies',
    'accept only necessary cookies','allow only necessary cookies','allow necessary only','accept necessary only']);
  const consentAccept=/\b(accept|agree|allow|consent|ok|okay|got it|understood|continue|yes)\b/i;
  const surveyClose=/^(close|dismiss|no,? thanks|not now|maybe later|\u00d7|\u2715|\u2716|x)$/i;
  // Inside `box`, across open shadow roots.
  const within = (box, e) => { for(let x=e;x;x=x.parentNode||x.host)if(x===box)return true; return false; };
  const pinned = e => { for(let x=e;x&&x.nodeType===1&&x!==document.body;x=x.parentElement||x.getRootNode().host){ const p=getComputedStyle(x).position; if(p==='fixed'||p==='sticky')return true; } return false; };
  const viewShare = e => { const r=e.getBoundingClientRect(), w=Math.max(0,Math.min(r.right,innerWidth)-Math.max(r.left,0)), h=Math.max(0,Math.min(r.bottom,innerHeight)-Math.max(r.top,0)); return w*h/Math.max(1,innerWidth*innerHeight); };
  const covering = e => visible(e) && e!==document.body && e!==document.documentElement && viewShare(e)>=.03 && (e.matches('dialog[open],[aria-modal=true]')||pinned(e));
  // innerText lays out the whole box: a long one (a pinned app shell) is cut from its raw text.
  const boxText = e => { const raw=e.textContent||''; return (raw.length>12000?raw:String(e.innerText||raw)).slice(0,4000); };
  // The pinned box around a matched part (a banner's text block), so its buttons are inside; a
  // page whose whole shell is pinned keeps the part, or every control on it would count.
  const lift = e => { let top=e; for(let x=e.parentElement||e.getRootNode().host;x&&x.nodeType===1&&x!==document.body;x=x.parentElement||x.getRootNode().host){ const p=getComputedStyle(x).position; if((p==='fixed'||p==='sticky')&&(x.textContent||'').length<6000&&boxText(x).length<3000)top=x; } return top; };
  // The covering box: {e, survey}. A consent platform's box wins over a generic one.
  const overlayBox = (scopes=searchRoots(document)) => {
    if(window.top!==window)return null;
    for(const e of deep(document,consentBoxes,[],scopes))if(covering(e))return {e:lift(e),survey:false};
    let seen=0;
    for(const e of deep(document,overlayBoxes,[],scopes)){
      if(++seen>200)break; if(!covering(e))continue; const t=boxText(e); if(t.length>=3000)continue;
      if(e.matches(consentMarks)&&consentWords.test(t))return {e:lift(e),survey:false};
      if(e.matches(surveyMarks)&&surveyWords.test(t))return {e:lift(e),survey:true}; }
    return null; };
  const optionKind = (label, survey) => { const t=String(label||'').replace(/\s+/g,' ').trim(); if(!t)return '';
    if(survey)return surveyClose.test(t)?'private':'';
    const k=t.toLowerCase().replace(/^[.!]+|[.!]+$/g,''); if(t.length<=60&&privateLabels.has(k))return 'private';
    return consentAccept.test(t)?'accept':'neutral'; };
  // The kind of the control `e`, as the gate reads it (describe): empty outside an overlay. Only the
  // box around `e` is classified (its first covering ancestor marked for a kind and holding that
  // kind's words; an unqualified one is stepped past), with no document scan. An aria-label that
  // differs from the shown words is private only when both are, and accept when either is.
  const kindIn = e => {
    if(window.top!==window||!e||!e.isConnected)return '';
    let box=null, survey=false;
    for(let x=e;x;x=x.parentNode||x.host){
      if(x.nodeType!==1||!x.matches(consentBoxes+','+overlayBoxes)||!covering(x))continue;
      if(!x.matches(consentBoxes)){ const t=boxText(x); if(t.length>=3000)return '';
        if(x.matches(consentMarks)&&consentWords.test(t))survey=false; else if(x.matches(surveyMarks)&&surveyWords.test(t))survey=true; else continue; }
      box=x; break; }
    if(!box)return '';
    const aria=String(e.getAttribute('aria-label')||'').replace(/\s+/g,' ').trim(), shown=String(e.innerText||'').replace(/\s+/g,' ').trim();
    if(!aria||!shown||aria===shown)return optionKind(labelOf(e),survey);
    const a=optionKind(aria,survey), b=optionKind(shown,survey);
    return a==='accept'||b==='accept'?'accept':a==='private'&&b==='private'?'private':survey?'':'neutral'; };
  // A private choice only answers the overlay, so its press reaches nothing else. The press is one
  // click event (no pointer or mouse down/up), and it travels the flat tree: a slotted node's slot
  // first, then its parent or shadow host. The choice itself is a button, a plain element (a div or
  // span with a button role) or a link that stays on this page: "#" on an address with no fragment
  // (an empty href reloads, a <base> moves "#" to another page, "#" leaves a "#/…" route, a
  // download saves a file) or javascript:. Every element above it is a plain
  // container (a div, span, section, aside, header, footer, paragraph or list) with no handler
  // attribute (on…, hx-, x-on:, @…, jsaction), no link, and no role but a container's (dialog,
  // region, group…). Anything else there (a site's row, cell, card, link, label, button, form,
  // custom element, or a component's slot inside one) can act on the click, so the choice asks.
  // The body and the root element may carry any attribute but onclick or a widget role.
  const staysHere = a => { const h=String(a.getAttribute('href')||'').trim(); if(/^javascript:/i.test(h))return true;
    return h==='#'&&!location.hash&&!a.hasAttribute('download')&&a.href===location.href.replace(/#.*$/,'')+'#'; };
  const pathUp = x => x.assignedSlot||x.parentNode||x.host;
  const plainTag = /^(div|span|section|aside|header|footer|p|ul|ol|li|b|strong|i|em|small|center|font)$/;
  const plainRole = /^\s*(dialog|alertdialog|region|group|presentation|none|document|generic|banner|contentinfo|complementary|status|alert|note)\s*$/i;
  const plainAttr = n => /^(id|class|style|dir|lang|title|hidden|tabindex|translate|slot|part|aria-[a-z]+|data-[\w.:-]+)$/.test(n)&&!/^data-(hx|ng)-/.test(n);
  const plain = x => { const top=x===document.body||x===document.documentElement;
    return (top||plainTag.test(x.localName))&&x.getAttributeNames().every(n=>n==='role'?plainRole.test(x.getAttribute(n)):top?n!=='onclick':plainAttr(n)); };
  const pressesOnly = e => { if(e.form||e.matches('[popovertarget],[commandfor]'))return false;
    if(e.matches('a[*|href]')?!(e instanceof HTMLAnchorElement&&staysHere(e)):!/^(a|button)$/.test(e.localName)&&!plainTag.test(e.localName))return false;
    for(let x=pathUp(e);x;x=pathUp(x))if(x.nodeType===1&&!plain(x))return false;
    return true; };
  // A consent banner almost never sits inside the page's main content, and user content (a post, a
  // message, a feed item) almost always does: a choice there is never private. The walk is the
  // press's own path, across slots and shadow roots.
  const inContent = e => { for(let x=e;x;x=pathUp(x))if(x.nodeType===1&&x.matches('main,article,[role=main],[role=article],[role=feed],[role=log]'))return true; return false; };
  const consentKind = e => { const k=kindIn(e); return k==='private'&&(!pressesOnly(e)||inContent(e))?'neutral':k; };
  // For read: the overlay's host and its controls. A banner sits late in a long page, so its
  // controls past the read's row cap are added as rows here (at most 20).
  const consentOf = (rows, scopes) => { const box=overlayBox(scopes); if(!box)return null; const options=[];
    const listed=new Set(rows.map(row=>row.ref&&refs.get(row.ref)).filter(Boolean)); let added=0;
    for(const e of deep(box.e,'a[href],button,[role=button]')){ if(added>=20)break; if(listed.has(e)||!visible(e)||sensitive(e)||hasSecrets(labelOf(e)))continue;
      const ref=`e${documentID}_${generation}_${rows.length+1}`; refs.set(ref,e); added++;
      rows.push({ref,role:e.getAttribute('role')||e.tagName.toLowerCase(),label:labelOf(e),acts:['click'],...center(e)}); }
    for(const row of rows){ const e=row.ref&&refs.get(row.ref); if(!e||!within(box.e,e))continue; const label=labelOf(e)||row.label;
      const kind=consentKind(e); if(kind&&!hasSecrets(label))options.push({ref:row.ref,label:label.slice(0,80),kind}); }
    return options.length?{host:location.hostname,kind:box.survey?'survey':'consent',options,untrusted:true}:null; };
  const fieldSelector='input,textarea,select,[contenteditable=true],[role=textbox],[role=spinbutton]', secureSelector='input:not([type=file]),select';
  const textSelector='textarea,input:not([type=checkbox],[type=radio],[type=submit],[type=button],[type=reset],[type=image],[type=hidden],[type=range],[type=color],[type=file],[type=password])';
  // A file input hides nothing on the page (X's composer always holds one); act still refuses it.
  const userSteps = (root=document, scopes=searchRoots(root)) => { version(); const kinds=stepHistory.get(root)||new Set();
    for(const e of deep(root,fieldSelector+','+captchaSelector,[],scopes)){
      if(e.matches(fieldSelector)){if(!e.matches('input[type=file]')&&(sensitive(e)||hasSecrets(fieldText(e)))){kinds.add(secretKind(e));keepField(e);}}
      else kinds.add('captcha');
      // A field can itself carry the CAPTCHA class too.
      if(e.matches(captchaSelector))kinds.add('captcha');
    }
    if(hasSecrets((root.body||root.documentElement||root).innerText))kinds.add('secret');
    if(pictureChecks(root).size)kinds.add('captcha');
    stepHistory.set(root,kinds); return Array.from(kinds); };
  // For the host's fail-closed check: this document's steps, its id and how many frames it holds.
  // Empty or inline frames (no src, about:blank, srcdoc) that this page can read are probed through the parent's
  // contentDocument and not counted as unchecked; cross-origin, sandboxed or unreadable frames still count.
  const inlineFrame = f => f.tagName==='IFRAME' && (f.hasAttribute('srcdoc') || !f.getAttribute('src') || f.getAttribute('src')==='about:blank');
  const frameInfo = (root, depth, scopes=searchRoots(root)) => { let count=0, steps=false;
    for(const f of deep(root,'iframe,frame',[],scopes)){ let d=null; try{ d=depth<3&&inlineFrame(f)?f.contentDocument:null; }catch(_){ d=null; }
      if(d&&d.documentElement){ const childScopes=searchRoots(d);if(userSteps(d,childScopes).length>0)steps=true; const r=frameInfo(d,depth+1,childScopes); count+=r.count; steps=steps||r.steps; } else count++; }
    return {count,steps}; };
  const probe = () => { const scopes=searchRoots(document),r=frameInfo(document,0,scopes); return {steps:userSteps(document,scopes).length>0||r.steps,frames:r.count,id:documentID,revision:version()}; };
  // Quiet means no change to the page for `quiet` ms. Style-only changes are animation (carousels,
  // tickers) and do not count, or such a page would never be quiet.
  const settle = (quiet=500, max=8000) => new Promise(done => { const start=Date.now(); let last=start; const mo=new MutationObserver(list=>{if(list.some(m=>m.attributeName!=='style'))last=Date.now()});
    mo.observe(document.documentElement,{subtree:true,childList:true,attributes:true,characterData:true});
    const tick=()=>{const now=Date.now(); if((now-last>=quiet&&document.readyState!=='loading')||now-start>=max){mo.disconnect();done({settled:now-start<max,waited_ms:now-start});}else setTimeout(tick,50);}; setTimeout(tick,50); });
  const invalidate = () => { refs.clear(); uploads.clear(); generation++; };
  // The centre in viewport CSS pixels; Serein matches it to the accessibility tree and drops it.
  const center = e => { const b=e.getBoundingClientRect(); return {x:Math.round(b.x+b.width/2),y:Math.round(b.y+b.height/2)}; };
  const controls='a[href],button,input,textarea,select,[role=button],[contenteditable=true]';
  const fileLabel = e => (e.getAttribute('aria-label')||(e.labels?Array.from(e.labels).map(l=>l.textContent).join(' '):'')||e.name||'File').replace(/\s+/g,' ').trim().slice(0,160);
  // Clickable by role, or a label or summary: never pressed for the agent when it names a password, card or code.
  // A control's own words count too, so "Show recovery code" is the person's (ownWords, controlWords).
  const ownWords=n=>[n.getAttribute&&n.getAttribute('aria-label'),n.getAttribute&&n.getAttribute('title'),n.innerText].join(' ');
  const pressables='summary,label,[role=link],[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=tab],[role=option],[role=treeitem],[role=gridcell],[role=checkbox],[role=radio],[role=switch]';
  // The page's own inline handler for an event click_point sends: clickable too.
  const handled='[onclick],[onmousedown],[onmouseup],[onpointerdown],[onpointerup]';
  // Each group of radio choices in one short line, so the agent sees at once what the page asks
  // for, what is picked and what is locked: "Finish: Burgundy | Glacier | [Silver] | Black (locked)".
  const firstLine = t => String(t||'').split('\n').map(s=>s.trim()).find(Boolean)||'';
  const groupTitle = e => {
    const g=e.closest('fieldset,[role=radiogroup]');
    const own=g&&(g.querySelector('legend')?.innerText||g.getAttribute('aria-label')||(g.getAttribute('aria-labelledby')||'').split(/\s+/).map(id=>document.getElementById(id)?.innerText||'').join(' '));
    if(own&&own.trim())return firstLine(own);
    for(let n=e.parentElement;n&&n!==document.body;n=n.parentElement){
      const h=Array.from(n.querySelectorAll('legend,h1,h2,h3,h4,h5,h6,[role=heading]')).filter(h=>h.compareDocumentPosition(e)&Node.DOCUMENT_POSITION_FOLLOWING).pop();
      if(h)return firstLine(h.innerText); }
    return e.name; };
  // An option's words as drawn: text in boxes of 1 px or less is for screen readers ("Footnote").
  const shownText = l => { const out=[]; for(const w=document.createTreeWalker(l,NodeFilter.SHOW_TEXT);w.nextNode();){
    const n=w.currentNode,p=n.parentElement,t=n.textContent.trim(); if(!t||!p)continue; const r=p.getBoundingClientRect(); if(r.width>1&&r.height>1)out.push(t); }
    return out.join(' ').replace(/\s+/g,' '); };
  const choices = scopes => { const groups=new Map();
    for(const e of deep(document,'input[type=radio]',[],scopes)){ if(!e.name||sensitive(e))continue; const k=e.name; if(!groups.has(k))groups.set(k,[]); groups.get(k).push(e); }
    return Array.from(groups.values()).filter(list=>list.length>1&&list.some(e=>visible(e)||Array.from(e.labels||[]).some(visible))).slice(0,12).map(list=>
      groupTitle(list[0]).slice(0,60)+': '+list.slice(0,12).map(e=>{ const t=(e.getAttribute('aria-label')||(e.labels?.[0]?shownText(e.labels[0]):'')||e.value).slice(0,40);
        return (e.checked?`[${t}]`:t)+(e.disabled?' (locked)':''); }).join(' | ')).filter(line=>!hasSecrets(line)); };
  // Tools the page offers agents (PageTools): a script registry, relayed from the page world as
  // messages from this same window (Serein's registry there, in agent tabs while the switch is
  // on), and forms marked toolname. Listing only reads what the page wrote: no page code runs
  // for it. Names, descriptions and schemas are the page's words. Top document only: a frame is
  // another site.
  const topDocument=window.top===window;
  let scriptTools=[];const toolCalls=new Map();
  const toolText=(v,n)=>typeof v==='string'?v.slice(0,n):'';
  if(topDocument)addEventListener('message',ev=>{ if(ev.source!==window)return; const d=ev.data; if(!d||typeof d!=='object')return;
    if(d.sereinPageTools==='list'&&Array.isArray(d.tools))scriptTools=d.tools.slice(0,32).map(t=>({kind:'script',name:toolText(t&&t.name,64),description:toolText(t&&t.description,1000),schema:toolText(t&&t.schema,8000)}));
    else if(d.sereinPageTools==='result'){const done=toolCalls.get(toolText(d.id,64));if(done)done({ok:d.ok===true,text:toolText(d.text,20000)});} });
  const toolFieldSkip='button,fieldset,output,object,input[type=submit],input[type=button],input[type=reset],input[type=image],input[type=hidden]';
  const toolFields=f=>Array.from(f.elements).filter(e=>e.name&&!e.disabled&&!e.matches(toolFieldSkip));
  const toolForms=()=>Array.from(document.querySelectorAll('form[toolname]')).slice(0,32);
  const formName=f=>String(f.getAttribute('toolname')||'').trim().slice(0,64);
  // A form holding a password, card, code or file field is the user's: it is never a tool.
  const formTool=f=>{ const fields=toolFields(f); if(fields.some(e=>e.matches('input[type=file]')||sensitive(e)||hasSecrets(fieldText(e))))return null;
    const properties=Object.create(null),required=[];
    for(const e of fields){ if(properties[e.name])continue;
      const words=String(e.getAttribute('toolparamdescription')||(e.labels?Array.from(e.labels).map(l=>l.textContent).join(' '):'')||e.getAttribute('aria-description')||'').trim().replace(/\s+/g,' ').slice(0,200);
      const p={title:String(e.getAttribute('toolparamtitle')||e.name).slice(0,80)}; if(words)p.description=words;
      if(e.matches('input[type=checkbox]'))p.type='boolean';
      else if(e.matches('input[type=number],input[type=range]'))p.type='number';
      else if(e.matches('input[type=radio]')){p.type='string';p.enum=fields.filter(r=>r.name===e.name&&r.matches('input[type=radio]')).map(r=>r.value).slice(0,50);}
      else if(e.tagName==='SELECT'){p.type='string';p.enum=Array.from(e.options).map(o=>o.value).slice(0,100);}
      else p.type='string';
      properties[e.name]=p; if(e.required)required.push(e.name); }
    return {kind:'form',name:formName(f),description:String(f.getAttribute('tooldescription')||'').trim().slice(0,1000),schema:JSON.stringify({type:'object',properties,required}).slice(0,8000)}; };
  // The stamp is the document and the whole listing: a reload, or a changed description or
  // schema, is another tool.
  // None on a page with the user's own password, card or code fields: their words could echo there.
  const pageTools=()=>{ if(!topDocument||userSteps().length)return []; const out=[],names=new Set();
    for(const t of [...scriptTools,...toolForms().map(formTool).filter(Boolean)]){
      if(out.length>=32)break; if(!/^[A-Za-z0-9_.-]{1,64}$/.test(t.name)||names.has(t.name)||hasSecrets(t.description+'\n'+t.schema))continue;
      names.add(t.name); out.push({...t,stamp:JSON.stringify([documentID,t.kind,t.name,t.description,t.schema])}); }
    return out; };
  // A form tool fills its fields and never sends the form: sending is the form's own button, a
  // click the person approves as usual. Values that hold a card number or a credential are refused.
  const fillForm=(name,input)=>{ const f=toolForms().find(f=>formName(f)===name); if(!f)return {ok:false,changed:true};
    let values; try{values=JSON.parse(String(input))}catch(_){return {ok:false,text:'The arguments are not JSON.'}}
    if(!values||typeof values!=='object'||Array.isArray(values))return {ok:false,text:'The arguments must be a JSON object.'};
    const fields=toolFields(f); if(fields.some(e=>e.matches('input[type=file]')||sensitive(e)))return {ok:false,text:yours};
    for(const v of Object.values(values)){const t=typeof v==='string'?v:JSON.stringify(v);if(hasCard(t)||hasSecrets(t))return {ok:false,text:yours};}
    const filled=[],skipped=[];
    for(const key of Object.keys(values)){ const list=fields.filter(e=>e.name===key),v=values[key]; let e=list[0]; if(!e){skipped.push(key);continue;}
      if(e.matches('input[type=checkbox]'))e.checked=v===true||v==='true';
      else if(e.matches('input[type=radio]')){const r=list.find(r=>r.value===String(v));if(!r){skipped.push(key);continue;}r.checked=true;e=r;}
      else if(e.tagName==='SELECT'){const o=Array.from(e.options).find(o=>o.value===String(v));if(!o||o.disabled){skipped.push(key);continue;}e.value=o.value;}
      else{const proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;Object.getOwnPropertyDescriptor(proto,'value').set.call(e,v==null?'':String(v));}
      if(globalThis.__sereinDraft)globalThis.__sereinDraft(e);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));filled.push(key); }
    invalidate(); return {ok:true,text:JSON.stringify({filled,skipped,sent:false,note:'Filled only; the form was not sent.'})}; };
  // Calls the tool approved as `stamp` with the exact JSON text the person saw. A listing that
  // changed since is refused here, in the same step that hands the call to the page.
  const callTool=(name,input,stamp,ms=30000)=>new Promise(done=>{
    const tool=pageTools().find(t=>t.name===name);
    if(!tool||tool.stamp!==stamp)return done({ok:false,changed:true});
    if(hasSecrets(String(input)))return done({ok:false,text:yours});
    if(tool.kind==='form')return done(fillForm(tool.name,input));
    const id=Array.from(crypto.getRandomValues(new Uint32Array(4)),x=>x.toString(16)).join('');
    const timer=setTimeout(()=>{toolCalls.delete(id);done({ok:false,text:'The page did not answer within 30 seconds.'});},ms);
    toolCalls.set(id,r=>{clearTimeout(timer);toolCalls.delete(id);done(r);});
    window.postMessage({sereinPageTools:'call',id,name:tool.name,input:String(input)},'*'); });
  const read = (start = 0, includeElements = true) => {
    register(); invalidate(); const scopes=searchRoots(document);let rows=[],inspected=0,withheld=0;
    if(includeElements)for (const e of deep(document,controls,[],scopes)) {
      // Preserve sensitive metadata history beyond the action-reference cap, without
      // forcing geometry/style measurements for those unusable extra elements.
      if(rows.length>=300){sensitive(e);continue;}
      // A file field has no ref: the user chooses its files, or `upload` puts in one the user attached
      // to this chat, after the user allows it. A hidden one (a styled upload button) is listed too.
      if (e.matches('input[type=file]')) { if(e.disabled)continue; const upload=`u${documentID}_${generation}_${rows.length+1}`; uploads.set(upload,e); const shown=visible(e); rows.push({role:'file',label:fileLabel(e),acts:[],upload,note:'The user chooses files. A file the user attached to this chat can go here with upload, after the user allows it.',...(shown?center(e):{hidden:true})}); continue; }
      // Counted for the read's redaction note: controls looked at, and the user's own that were left out.
      inspected++; if (!visible(e)) continue;
      // A password, card, sign-in code or key field is listed without its value, for secure_card only.
      if (sensitive(e)) { withheld++; const kind=e.matches(secureSelector)?secureKind(e):''; if(!['password','code','card','key'].includes(kind))continue;
        const ref=`e${documentID}_${generation}_${rows.length+1}`; refs.set(ref,e);
        const words=(e.getAttribute('aria-label')||(e.labels?Array.from(e.labels).map(l=>l.textContent).join(' '):'')||e.getAttribute('placeholder')||e.name||'').trim().slice(0,160);
        rows.push({ref,role:'textbox',label:words&&!hasSecrets(words)?words:kind,acts:['secure_card'],secure:kind,...center(e)}); continue; }
      const ref=`e${documentID}_${generation}_${rows.length+1}`; refs.set(ref,e);
      const label=(e.getAttribute('aria-label')||(e.labels?Array.from(e.labels).map(l=>l.textContent).join(' '):'')||e.innerText||e.getAttribute('placeholder')||e.name||e.tagName).trim().slice(0,160);
      // The tools each control takes follow from the page itself: lists select, text fields type, the rest click.
      const isList=e.tagName==='SELECT',typed=e.isContentEditable||e.matches(textSelector),toggle=e.matches('input[type=checkbox],input[type=radio]');
      const current=isList?(e.selectedOptions[0]?.text??''):typed?fieldText(e):'';
      rows.push({ref,role:e.getAttribute('role')||e.tagName.toLowerCase(),label,acts:[isList?'select':typed?'type':'click'],value:current&&!hasSecrets(current)?String(current).slice(0,80):undefined,checked:toggle?e.checked:undefined,options:isList?Array.from(e.options).map(o=>({value:o.value,label:o.text})):undefined,...center(e)});
    }
    // A page that handles clicks on its root (React and others) leaves its controls without a tag,
    // a role or a handler of their own; only the pointer shows them. Take the outermost pointer
    // element with text and no control inside. ponytail: first 4,000 elements, a cap for huge pages.
    if(includeElements&&rows.length<300&&document.body){ let seen=0;
      for(const e of document.body.querySelectorAll('div,span,li,p,img,svg,td,th,h1,h2,h3,h4')){
        if(++seen>4000||rows.length>=300)break;
        if(e.closest(controls)||getComputedStyle(e).cursor!=='pointer'||(e.parentElement&&getComputedStyle(e.parentElement).cursor==='pointer'))continue;
        if(!visible(e)||sensitive(e)||e.querySelector(controls))continue;
        const label=(e.getAttribute('aria-label')||e.innerText||e.getAttribute('title')||e.getAttribute('alt')||'').trim().replace(/\s+/g,' ').slice(0,160);
        if(!label||hasSecrets(label)||controlWords.test(ownWords(e)))continue;
        const ref=`e${documentID}_${generation}_${rows.length+1}`; refs.set(ref,e);
        rows.push({ref,role:'clickable',label,acts:['click'],...center(e)});
      }
    }
    // Text nodes exclude forms, scripts, hidden nodes, and editable regions, and on a page with the
    // user's own fields the area around each one (a code split over boxes can echo there).
    const nearby=nearFields(scopes);
    const walker=document.createTreeWalker(document.body||document.documentElement,NodeFilter.SHOW_TEXT);
    const textLimit=includeElements?240000:24000;
    let node,parts=[],length=0;
    while((node=walker.nextNode()) && length<textLimit) {
      const p=node.parentElement;
      if (!p || p.closest('script,style,noscript,input,textarea,select,[contenteditable=true]') || inside(p,nearby) || !visible(p)) continue;
      const t=node.textContent.trim(); if(t){for(let i=0;i<t.length&&length<textLimit;i+=2000){const chunk=t.slice(i,i+2000);parts.push(chunk);length+=chunk.length;}}
    }
    const offset=Math.max(0,Number(start)||0),page=[];let chars=0,end=offset;while(end<parts.length&&chars<24000){const value=parts[end++];page.push(value);chars+=value.length+1;}
    const steps=userSteps(document,scopes);
    // With the user's own fields on the page, the text goes without what was typed there or any
    // credential; when that cannot be confirmed (a field the page removed, a value still found),
    // no text goes. Choices stay out on such a page.
    let text=page.join('\n').slice(0,24000);
    if(steps.length){ const strict=privateKinds(document); text=removedField(document)?'':redact(text,strict); if(text&&leaks(text,strict))text=''; }
    return {documentID,revision:version(),url:location.href,title:document.title,text,start:offset,next_start:!includeElements||(steps.length&&!text)?null:(end<parts.length?end:null),elements:rows,choices:includeElements&&!steps.length?choices(scopes):undefined,untrusted:true,sensitive:steps.length>0,user_steps:steps,challenge:challenge(null,scopes),page_tools:includeElements&&topDocument?pageTools():undefined,consent:includeElements?consentOf(rows,scopes):null,redaction:{inspected,withheld},viewport:[innerWidth,innerHeight],
      // Frames a person can see here (40 by 20 CSS pixels or more): Serein reads child frames only when there are some.
      shown_frames:includeElements?deep(document,'iframe,frame',[],scopes).filter(f=>{const b=f.getBoundingClientRect();return b.width>=40&&b.height>=20&&visible(f);}).length:0};
  };
  // A Luhn-valid run of 13-19 digits, ignoring separators, anywhere in a field's final value.
  const hasCard = text => { let ds=[]; const check=()=>{const n=ds.length,ok=n>=13&&n<=19&&ds.reduceRight((s,d,i)=>{const k=n-1-i;let v=d;if(k%2===1){v*=2;if(v>9)v-=9;}return s+v;},0)%10===0;ds=[];return ok;};
    for(const ch of String(text??'')){ if(ch>='0'&&ch<='9')ds.push(+ch); else if(/[\s.\/-]/.test(ch)&&ds.length)continue; else if(check())return true; } return check(); };
  const fieldText = e => e.isContentEditable||!('value' in e) ? e.textContent : (e.value ?? '');
  // What the user typed or a page set in their own fields (4 characters or more), and its
  // digits for a card number, so it is cut out of text and pictures wherever it shows again.
  // A card's security code is shorter: 3 characters count from such a field, and match only a whole
  // text or element, so a "737" elsewhere in the page does not.
  const typed=new Set(), short=new Set();
  const isCode = e => /(^|\s)cc-csc(\s|$)/i.test(e.autocomplete||'')||/cvc|cvv|csc|security.?code/i.test([e.name,e.id,e.getAttribute('aria-label'),e.getAttribute('placeholder')].join(' '));
  const keep = (v,small) => { v=String(v??'').trim(); if(v.length>=4){ typed.add(v); const d=v.replace(/\D/g,''); if(d.length>=8)typed.add(d); } else if(small&&v.length>=3)short.add(v); };
  const keepField = e => keep(fieldText(e),isCode(e));
  addEventListener('input',ev=>{ const e=ev.target; if(e&&e.matches&&e.matches(fieldSelector)&&!e.matches('input[type=file]')&&sensitive(e))keepField(e); },true);
  const holdsTyped = text => { const t=String(text||''),digits=t.replace(/\D/g,''); if(short.has(t.trim()))return true;
    for(const v of typed){ if(t.includes(v)||(/^\d+$/.test(v)&&digits.includes(v)))return true; } return false; };
  // Beside a code field a page can show a setup secret: a base32 seed (16 or more of A-Z and
  // 2-7, in groups or not, with at least two of those digits). `strict`: a page with the user's
  // own password, card or code fields.
  const seedRE=/[A-Za-z2-7]{4,8}(?:[ -][A-Za-z2-7]{4,8}){3,}|[A-Za-z2-7]{16,}/g;
  const seeds = text => (String(text||'').match(seedRE)||[]).filter(m=>{ const c=m.replace(/[ -]/g,''); return c.length>=16&&(c.match(/[2-7]/g)||[]).length>=2; });
  // Recovery codes: three or more codes of 8-12 letters and digits (a dash allowed in the middle).
  const codeRE=/\b(?=[A-Za-z0-9-]*\d)(?=[A-Za-z0-9-]*[A-Za-z])[A-Za-z0-9]{4,6}-?[A-Za-z0-9]{4,6}\b/g;
  const codes = text => { const m=String(text||'').match(codeRE)||[]; return m.length>=3?m:[]; };
  const leaks = (text,strict) => hasSecrets(text)||hasCard(text)||holdsTyped(text)||(strict&&(seeds(text).length>0||codes(text).length>0));
  const redact = (text,strict) => { let t=String(text||'').replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/g,'[hidden]').replace(secretAllRE,'[hidden]');
    if(strict)for(const m of [...seeds(t),...codes(t)])t=t.split(m).join('[hidden]');
    if(short.size)t=t.split('\n').map(line=>short.has(line.trim())?'[hidden]':line).join('\n');
    for(const v of typed)t=t.split(v).join('[hidden]'); return t; };
  // The area around each of the user's own fields: its parent's parent (a code split over
  // boxes, a mirrored value, a show/hide label).
  const nearFieldList = scopes => { const out=new Set(); for(const scope of scopes)for(const e of scope.querySelectorAll(fieldSelector)){ if(e.matches('input[type=file]')||!(sensitive(e)||hasSecrets(fieldText(e))))continue; keepField(e); const n=e.parentElement&&(e.parentElement.parentElement||e.parentElement); if(n&&n!==document.body&&n!==document.documentElement&&n.tagName!=='BODY'&&n.tagName!=='HTML')out.add(n); } return out; };
  const nearFields = scopes => nearFieldList(scopes);
  const inside = (e,set) => { for(let x=e;x;x=x.parentElement)if(set.has(x))return true; return false; };
  // A document that had a password, card or code field which is gone now: what was typed there
  // may show anywhere, so the document is treated as before (no text, no picture).
  const removedField = d => { if(!privateKinds(d))return false;
    for(const scope of searchRoots(d))for(const e of scope.querySelectorAll(fieldSelector))if(!e.matches('input[type=file]')&&sensitive(e))return false; return true; };
  // Scroll as a person does with the wheel over the middle of the page. Many pages do not scroll
  // the window: a feed, a chat or a mail list scrolls an inner box (TikTok's video feed is a
  // full-height snap box in a body that cannot scroll), so a window scroll does nothing there.
  // Order: the box under the middle of the view when it fills 30% or more of the view, then the
  // window, then (only if neither can scroll at all) the largest box on the view that can still
  // move. A feed with no scroll box that moves only on wheel or key events gets a wheel event, then
  // an arrow key (Home or End for top and bottom) if no script took the wheel.
  const scrollPage = a => {
    const dir=a.direction, edge=dir==='top'||dir==='bottom', sign=dir==='up'||dir==='top'?-1:1;
    const root=document.scrollingElement||document.documentElement, cx=innerWidth/2, cy=innerHeight/2;
    // The body is the window's own scroller unless the html element clips: then a body with its own
    // overflow scrolls as a box. The window's overflow is the html element's, or the body's when html
    // leaves it visible.
    const htmlFlow=getComputedStyle(document.documentElement).overflowY, ownBody=htmlFlow!=='visible';
    const isRoot = n => n===root||n===document.documentElement||(n===document.body&&!ownBody);
    const range = n => n&&n.nodeType===1&&!isRoot(n)&&/(auto|scroll|overlay)/.test(getComputedStyle(n).overflowY)&&n.scrollHeight-n.clientHeight>=1;
    // A column-reverse box (a chat that opens at its newest message) counts scrollTop from 0 at the
    // bottom to a negative value at the top.
    const span = n => { const max=n.scrollHeight-n.clientHeight; return getComputedStyle(n).flexDirection==='column-reverse'?[-max,0]:[0,max]; };
    const room = n => { const [lo,hi]=span(n); return sign<0?n.scrollTop>lo+.5:n.scrollTop<hi-1; };
    // A snap box moves one full box height, so it reaches the next item (one video) even where the
    // browser does not snap a script scroll; other boxes move 75% of their height, like the window.
    const snaps = n => /(^|\s)(y|block|both)(\s|$)/.test(getComputedStyle(n).scrollSnapType);
    const move = n => { const before=n.scrollTop, [lo,hi]=span(n), to=edge?(sign<0?lo:hi):before+sign*n.clientHeight*(snaps(n)?1:.75);
      n.scrollTo({top:to,behavior:'instant'}); return n.scrollTop!==before; };
    // The box's name is checked whole, with the same rules as page text, before any of it is returned.
    const done = (n,how) => { invalidate(); const label=n&&String(n.getAttribute('aria-label')||'').trim();
      return {performed:'scroll',scrolled:how,...(label&&!leaks(label,privateKinds(document))?{area:label.slice(0,80)}:{})}; };
    const boxes=[];
    for(let x=document.elementFromPoint(cx,cy);x&&x.nodeType===1;x=x.parentElement||x.getRootNode().host)if(range(x))boxes.push(x);
    const big=boxes.find(n=>viewShare(n)>=.3);
    if(big&&room(big)&&move(big))return done(big,'area');
    const viewFlow=ownBody||!document.body?htmlFlow:getComputedStyle(document.body).overflowY;
    const windowRange=!/hidden|clip/.test(viewFlow)&&root.scrollHeight>innerHeight+1;
    const y=scrollY; if(edge)scrollTo({top:sign<0?0:root.scrollHeight,behavior:'instant'}); else scrollBy({top:sign*innerHeight*.75,behavior:'instant'});
    if(scrollY!==y)return done(null,'page');
    // A page or a middle box at its end: never move another box (a side menu, a code sample) in its place.
    const fallback=!big&&!windowRange;
    if(fallback)for(const h of searchRoots(document))for(const n of h.querySelectorAll('*'))if(n.scrollHeight-n.clientHeight>=1&&!boxes.includes(n)&&range(n)&&visible(n))boxes.push(n);
    const shown=boxes.filter(n=>viewShare(n)>0).sort((p,q)=>viewShare(q)-viewShare(p));
    if(fallback)for(const n of shown)if(room(n)&&move(n))return done(n,'area');
    // Something can scroll, but not this way: say so, and do not send keys that a feed could act on.
    if(big||windowRange||shown.length){ invalidate(); return {performed:'scroll',scrolled:'none',note:`Already at the ${sign<0?'top':'bottom'}. A feed can load more: wait, then read the page again.`}; }
    const at=document.elementFromPoint(cx,cy)||document.body||root;
    const taken=!at.dispatchEvent(new WheelEvent('wheel',{deltaY:sign*Math.round(edge?root.scrollHeight||innerHeight:innerHeight*.75),deltaMode:0,clientX:cx,clientY:cy,bubbles:true,cancelable:true,composed:true}));
    let sent='wheel';
    if(!taken){
      // keyCode stays 0: a property set in Serein's own script world does not reach the page's world.
      const key=edge?(sign<0?'Home':'End'):(sign<0?'ArrowUp':'ArrowDown');
      // The key goes to the body, never to a focused control (a spin button, a slider, a field),
      // which would take it as input. A feed's key listener on the document or window still gets it.
      const target=document.body||root;
      for(const type of ['keydown','keyup'])target.dispatchEvent(new KeyboardEvent(type,{key,code:key,bubbles:true,cancelable:true,composed:true}));
      sent='wheel, then '+key;
    }
    invalidate();
    return {performed:'scroll',scrolled:'events',sent,verification:'Nothing on this page scrolls, so Serein sent '+sent+' for a feed that moves on its own. Check the page that comes back with this result.'};
  };
  const act = (name, a) => {
    // Nothing is pressed, typed or scrolled in a verification check, whatever was approved: on an
    // interstitial, under a modal check, in a check's frame or on a target inside one. Serein hands
    // the tab to the person on this answer (FrameBridge.frameAction).
    const check=challenge(a.ref||''); if(check&&check.blocks)return {needs_user:true,reason:'captcha'};
    if(name==='scroll')return scrollPage(a);
    const e=refs.get(a.ref);
    if(!e||!e.isConnected)throw Error('Stale element reference. Read the page again.');
    if(sensitive(e)||hasSecrets(fieldText(e))||insideCheck(e))throw Error(yours);
    if(e.disabled)throw Error('Element is disabled.');
    const hit=aim(e); if(hit.error)throw Error(hit.error);
    if(name==='click') hit.node.click();
    else if(name==='type'){
      if(!e.matches('input,textarea,[contenteditable=true]'))throw Error('Element is not a text field.');
      if(hasCard((a.append?fieldText(e):'')+String(a.text??''))||hasSecrets((a.append?fieldText(e):'')+String(a.text??'')))throw Error(yours);
      if(e.isContentEditable)e.textContent=(a.append?e.textContent:'')+a.text;
      else { const proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;Object.getOwnPropertyDescriptor(proto,'value').set.call(e,(a.append?e.value:'')+a.text); }
      if(globalThis.__sereinDraft)globalThis.__sereinDraft(e);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));if(a.press_enter&&e.form)e.form.requestSubmit();
    }else if(name==='select'){
      // Match the value first, then the option's words: exact, beginning, anywhere.
      if(e.tagName!=='SELECT')throw Error('This element is not a list. Read the page for the list.');
      const norm=t=>String(t??'').trim().replace(/\s+/g,' ').toLowerCase(),want=norm(a.value),opts=Array.from(e.options);
      const o=opts.find(o=>o.value===a.value)||(want?opts.find(o=>norm(o.text)===want)||opts.find(o=>norm(o.text).startsWith(want))||opts.find(o=>norm(o.text).includes(want)):null);
      if(!o)throw Error('Unknown option. Read the page for the options.'); if(o.disabled)throw Error('That option is unavailable.');
      e.value=o.value;e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
      invalidate(); return {performed:name,selected:o.text.trim().slice(0,160),verification:'Check the page that comes back with this result.'};
    }else if(name==='hover'){
      e.dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));e.dispatchEvent(new MouseEvent('mouseenter',{bubbles:false}));
    }else if(name==='key'){
      if(!['Enter','Escape','Tab','Space','ArrowUp','ArrowDown','ArrowLeft','ArrowRight'].includes(a.key))throw Error('Unsupported key');
      if(e.matches('input,textarea,[contenteditable=true]')&&hasCard(fieldText(e)))throw Error(yours);
      // Script key events do not step a number field; step it, then tell the page as a key would.
      if(e.matches('input[type=number],input[type=range]')&&['ArrowUp','ArrowDown'].includes(a.key)){ e.focus(); e.dispatchEvent(new KeyboardEvent('keydown',{key:a.key,bubbles:true})); a.key==='ArrowUp'?e.stepUp():e.stepDown(); e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true})); e.dispatchEvent(new KeyboardEvent('keyup',{key:a.key,bubbles:true})); invalidate(); return {performed:name,value:e.value,verification:'Check the page that comes back with this result.'}; }
      e.focus(); e.dispatchEvent(new KeyboardEvent('keydown',{key:a.key,bubbles:true}));e.dispatchEvent(new KeyboardEvent('keyup',{key:a.key,bubbles:true}));
    } else throw Error('Unknown action');
    invalidate(); return {performed:name,...(hit.node===e?{}:{via:'label'}),verification:'Check the page that comes back with this result.'};
  };
  // Where a person presses e: the centre, else four inner points, so a badge or a bar over part
  // of a control does not block it. A hit on e's own label, or on the link or button around e,
  // counts as a clear point; e itself is pressed then, never the wrapper (a card link around an
  // "Add to cart" button would navigate). A radio or checkbox that the page hides and draws with
  // its label (Apple's colour circles and storage cards) is pressed through a visible label of its own.
  const aim = e => {
    const host=e.getRootNode(),at=(x,y)=>(host.elementFromPoint?host:document).elementFromPoint(x,y);
    const wrap=e.parentElement?.closest('a[href],button,label,[role=button],[role=link]');
    const own=t=>!!t&&(e===t||e.contains(t)||t===wrap||t.closest('label')?.control===e);
    const spot=n=>{ n.scrollIntoView({block:'center',behavior:'instant'}); const r=n.getBoundingClientRect();
      for(const [fx,fy] of [[.5,.5],[.2,.5],[.8,.5],[.5,.2],[.5,.8]]){
        const x=r.x+r.width*fx,y=r.y+r.height*fy,t=x>=0&&y>=0&&x<innerWidth&&y<innerHeight?at(x,y):null;
        if(own(t))return {node:e===t||e.contains(t)||(t===wrap&&!wrap.matches('label'))?e:t,x,y}; }
      return null; };
    const hit=spot(e)||(e.matches('input[type=radio],input[type=checkbox]')?Array.from(e.labels||[]).filter(visible).map(spot).find(Boolean):null);
    if(hit)return hit;
    e.scrollIntoView({block:'center',behavior:'instant'});
    const r=e.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;
    if(x<0||y<0||x>=innerWidth||y>=innerHeight)return {error:'Element is outside the viewport. Scroll its container or read the page again.'};
    const t=at(x,y),box=t?.closest('dialog,[role=dialog],[role=alertdialog],[aria-modal=true]')||t;
    const words=String(box?.innerText||box?.getAttribute?.('aria-label')||'').replace(/\s+/g,' ').trim().slice(0,80);
    return {error:words&&!hasSecrets(words)?`Element is covered by "${words}". Close or move that first.`:'Element is covered by another part of the page. Read the page again.'};
  };
  // Where an action will land, so Serein can draw its pointer there before acting. Scrolls the
  // element into view first, as act does.
  const target = ref => { const e=refs.get(ref); if(!e||!e.isConnected)return null; const hit=aim(e);
    if(!hit.error)return {x:hit.x,y:hit.y}; const r=e.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; };
  // Composer chips need text, not thousands of actionable element measurements. The
  // same fresh security scan, document id and revision accompany both forms of read.
  const readContext = () => read(0,false);
  // Pictures: what the user typed in their own fields, the area around each field, and any text
  // that shows a credential, a card number or a typed value is made transparent for the
  // picture (blank), confirmed transparent at the moment of capture (confirmBlank) and shown
  // again (unblank). A document that had such a field and lost it is not pictured at all.
  const docs = () => { const out=[document]; const walk=(d,depth)=>{ for(const f of deep(d,'iframe,frame')){ let c=null; try{ c=depth<3&&inlineFrame(f)?f.contentDocument:null; }catch(_){ c=null; } if(c&&c.documentElement){ out.push(c); walk(c,depth+1); } } }; walk(document,0); return out; };
  // With the user's own fields on a page, a visible canvas or a custom element that draws through
  // a closed shadow root could hold one Serein cannot see, so the picture is refused.
  // What Serein cannot look inside, beside the user's own fields, is hidden whole for a picture:
  // a canvas; a host of a closed shadow root (marked by the page-world script); and an element that
  // could host one built by the HTML parser (declarative shadow DOM leaves no mark): nothing of its
  // own inside, yet it takes room. Opacity on a host hides everything in its root.
  const unseen = e => e.tagName==='CANVAS'||e.hasAttribute('data-serein-closed')
    ||((hostTag.test(e.tagName)||e.tagName.includes('-'))&&!e.shadowRoot&&!e.firstElementChild&&!(e.textContent||'').trim());
  const hostTag=/^(DIV|SPAN|P|SECTION|ARTICLE|ASIDE|HEADER|FOOTER|MAIN|NAV|BLOCKQUOTE|H[1-6])$/;
  const privateKinds = d => { const kinds=stepHistory.get(d)||new Set(); return ['password','card','code'].some(k=>kinds.has(k)); };
  // On a page with the user's own fields, pictures also hide every image (a QR code of a setup
  // secret is one) and background image.
  const targets = () => { const text=new Set(),images=new Set(),backs=new Set(); let gone=false;
    for(const d of docs()){ const scopes=searchRoots(d); userSteps(d,scopes); const strict=privateKinds(d); if(removedField(d))gone=true;
      for(const e of deep(d,fieldSelector,[],scopes)){ if(e.matches('input[type=file]')||!(sensitive(e)||hasSecrets(fieldText(e))))continue; keepField(e); text.add(e); }
      for(const n of nearFieldList(scopes))for(const x of [n,...n.querySelectorAll('*')])text.add(x);
      for(const scope of scopes){ const w=d.createTreeWalker(scope,NodeFilter.SHOW_TEXT); let t; while((t=w.nextNode())){ if(t.parentElement&&leaks(t.textContent,strict))text.add(t.parentElement); } }
      // A value split over elements (a card preview's groups in spans, SVG text): each element's
      // whole text, up to 400 characters, is tested too, and the smallest element that holds it
      // is hidden (not its parents, so the rest of the page stays in the picture).
      const leaking=new Set();
      for(const scope of scopes)for(const e of scope.querySelectorAll('*')){ if(e.matches('script,style,noscript,template'))continue; const t=e.textContent||''; if(t.length<=400&&leaks(t,strict))leaking.add(e); }
      for(const e of leaking)if(!Array.from(e.children).some(c=>leaking.has(c)))text.add(e);
      if(strict)for(const scope of scopes)for(const e of scope.querySelectorAll('*')){
        if(e.matches('img,svg,picture,video,object,embed,[role=img]')||(unseen(e)&&visible(e)))images.add(e); else if(getComputedStyle(e).backgroundImage!=='none')backs.add(e); } }
    return {text:Array.from(text),images:Array.from(images),backs:Array.from(backs),gone}; };
  // Opacity 0 takes an element and everything inside it out of the picture, whatever paints it
  // (text colour, SVG fill, stroke, autofill, images, a closed root's content); a child cannot
  // undo it. No transition or animation, so it holds at once.
  const hideStyles=[['opacity','0'],['transition','none'],['animation','none']];
  // Each element's own style before the picture, once, however many rules hide it.
  let blanked=new Map();
  const isBlank = e => getComputedStyle(e).opacity==='0';
  const answer = ok => ({ok,frames:frameInfo(document,0).count,id:documentID});
  const unblank = () => { for(const [e,s] of blanked){ if(s===null)e.removeAttribute('style'); else e.setAttribute('style',s); } blanked=new Map(); return {ok:true}; };
  const confirmBlank = () => { const t=targets(); return answer(!t.gone&&t.text.every(isBlank)
    &&t.images.every(isBlank)&&t.backs.every(e=>getComputedStyle(e).backgroundImage==='none')); };
  const hide = (e,styles) => { if(!blanked.has(e))blanked.set(e,e.getAttribute('style')); for(const [k,v] of styles)e.style.setProperty(k,v,'important'); };
  const blank = () => { unblank(); const t=targets(); if(t.gone)return answer(false);
    for(const e of t.text)hide(e,hideStyles); for(const e of t.images)hide(e,hideStyles); for(const e of t.backs)hide(e,[['background-image','none'],['transition','none']]);
    return confirmBlank(); };
  // Facts about this control, read before any click or key. The host judges the effect.
  // A missing or replaced node comes back disconnected so the host presses nothing.
  // Card fields and prices are reported raw. Swift decides that they are a payment.
  const formOf = e => e.form || e.closest('form');
  const labelOf = e => String(e.getAttribute('aria-label') || e.innerText || e.getAttribute('value') || e.name || '').replace(/\s+/g,' ').trim().slice(0,160);
  const textOf = root => String(root && (root.innerText || root.textContent) || '').replace(/\s+/g,' ').trim();
  const fieldOf = e => ({
    name: e.getAttribute('name') || '', id: e.id || '',
    type: String(e.getAttribute('type') || e.tagName || '').toLowerCase(),
    autocomplete: e.getAttribute('autocomplete') || '', label: labelOf(e),
  });
  // Open shadow roots hold frames too. A closed root stays private to the page.
  // Same-origin documents inside those frames are walked; a seen-document set stops a cycle.
  const frameList = (doc, depth, seen, out) => {
    if (!doc || seen.has(doc) || depth > 4 || out.length >= 40) return;
    seen.add(doc);
    let frames = [];
    try { frames = deep(doc, 'iframe', [], searchRoots(doc)); } catch (_) { return; }
    for (const frame of frames) {
      if (out.length >= 40) return;
      out.push(frame);
      let child = null;
      try { child = frame.contentDocument; } catch (_) { child = null; }
      if (child && child.documentElement) frameList(child, depth + 1, seen, out);
    }
  };
  const fieldsOf = () => {
    const out = [];
    const seen = new Set();
    const take = root => { if (!root || !root.querySelectorAll) return;
      for (const e of root.querySelectorAll('input,textarea,select')) out.push(fieldOf(e)); };
    const walk = (doc, depth) => {
      if (!doc || seen.has(doc) || depth > 4 || out.length >= 80) return;
      seen.add(doc);
      try { for (const scope of searchRoots(doc)) take(scope); } catch (_) {}
      let frames = [];
      try { frames = deep(doc, 'iframe', [], searchRoots(doc)); } catch (_) { frames = []; }
      for (const frame of frames) {
        let child = null;
        try { child = frame.contentDocument; } catch (_) { child = null; }
        if (child && child.documentElement) walk(child, depth + 1);
      }
    };
    walk(document, 0);
    return out.slice(0, 80);
  };
  const framesOf = () => {
    const frames = [];
    frameList(document, 0, new Set(), frames);
    return frames.map(frame => ({
      src: frame.getAttribute('src') || (frame.hasAttribute('srcdoc') ? 'about:srcdoc' : ''),
      title: frame.getAttribute('title') || '',
      name: frame.getAttribute('name') || '', id: frame.id || '',
    }));
  };
  const submitsForm = (e, name, a) => {
    const form = formOf(e);
    if (!form) return false;
    if (name === 'type' && a && a.press_enter) return true;
    if (name === 'key' && a && /^(enter|return|keypadenter|kpenter|numpadenter)$/i.test(String(a.key||''))) return true;
    if (name !== 'click') return false;
    const type = String(e.getAttribute('type')||'').toLowerCase();
    if (type === 'button' || type === 'reset') return false;
    if (e.matches('input[type=submit],input[type=image]')) return true;
    return e.tagName === 'BUTTON';
  };
  // A password, a card, a code or a file is the user's. The gate refuses it; act refuses it too.
  const secretOf = e => sensitive(e) || hasSecrets(fieldText(e));
  const passwordForms = new WeakMap();
  const formElements = Object.getOwnPropertyDescriptor(HTMLFormElement.prototype, 'elements').get;
  const passwordFormOf = form => {
    if (!form || !Array.from(formElements.call(form)).some(field =>
      field.matches('input[type=password i],input[autocomplete~="current-password" i],input[autocomplete~="new-password" i]'))) return '';
    if (!passwordForms.has(form)) passwordForms.set(form, Array.from(crypto.getRandomValues(new Uint8Array(12)), b => b.toString(16).padStart(2,'0')).join(''));
    return passwordForms.get(form);
  };
  const describeElement = (e, name, a) => {
    if (!e || !e.isConnected) return {connected:false};
    if (!e.dataset.sereinBind) {
      e.dataset.sereinBind = Array.from(crypto.getRandomValues(new Uint8Array(8)), b => b.toString(16).padStart(2,'0')).join('');
    }
    const form = formOf(e);
    const submits = submitsForm(e, name, a || {});
    const passwordForm = submits ? passwordFormOf(form) : '';
    const near = e.closest('form,section,article,li,dialog,[role=dialog],main') || e.parentElement || e;
    return {
      connected:true, bind:e.dataset.sereinBind, label:labelOf(e),
      tag: (e.tagName || '').toLowerCase(), type: String(e.getAttribute('type') || '').toLowerCase(),
      role: String(e.getAttribute('role') || '').toLowerCase(),
      nearbyText: textOf(near).slice(0, 1200), pageText: textOf(document.body).slice(0, 8000),
      frames: framesOf(), fields: fieldsOf(), submits, passwordForm,
      secret: !!secretOf(e),
      consent: consentKind(e),
      editable: !!e.isContentEditable,
      formBlob: form ? [form.getAttribute('action')||'', form.id||'', form.getAttribute('name')||'', form.className||''].join(' ') : '',
    };
  };
  const describe = (ref, name, a) => {
    if (!ref) return {connected:true, bind:'page', label:'', tag:'', type:'', role:'', nearbyText:'', pageText:'', frames:[], fields:[], submits:false, secret:false, formBlob:'', consent:''};
    return describeElement(refs.get(ref), name, a);
  };
  // The file field listed as `field`, as `describe` reports a control, for the upload's ask and
  // its check before the files are set.
  const describeUpload = field => { const e=uploads.get(field), d=describeElement(e,'upload',{}); if(d.connected)d.label=fileLabel(e); return d; };
  // Puts one file into the file field listed as `field`, only while it is the element Serein bound
  // and the person approved (`bind`), outside any verification check. `data` is the file's bytes
  // in base64, from the turn's own folder; the page receives an ordinary chosen file and its
  // input and change events.
  const upload = (field, bind, name, type, data) => {
    const e=uploads.get(field);
    if(!e||!e.isConnected||!e.matches('input[type=file]')||e.dataset.sereinBind!==bind)return {ok:false,changed:true};
    const check=challenge(''); if((check&&check.blocks)||insideCheck(e))return {needs_user:true,reason:'captcha'};
    if(e.disabled)return {ok:false,text:'The file field is disabled.'};
    const raw=atob(String(data)),bytes=new Uint8Array(raw.length); for(let i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);
    const list=new DataTransfer(); list.items.add(new File([bytes],String(name),{type:String(type),lastModified:Date.now()}));
    e.files=list.files;
    e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true}));
    const ok=!!(e.files&&e.files.length===1&&e.files[0].name===String(name)); const label=fileLabel(e); invalidate();
    return {ok,uploaded:ok?String(name):undefined,field:label};
  };
  // act invalidates every public reference. Keep only this exact node in the private
  // call's local scope; a replacement with the same label/bind is not it. Read on the next
  // event-loop turn so the handler's microtasks (including nested ones) have drained.
  // No handle survives the call, and an ordinary describe still refuses the stale ref.
  const actAndDescribe = async (name, a) => {
    const e = refs.get(a.ref);
    const result = act(name, a);
    if (result.reason === 'captcha') return {result};
    await new Promise(resolve => setTimeout(resolve, 0));
    return {result, reading:describeElement(e, name, a)};
  };
  // click_point: the viewport a screenshot shows, and what a person would press at a spot in it.
  const view = () => ({document:documentID,width:innerWidth,height:innerHeight,x:scrollX,y:scrollY});
  // The topmost element at (x, y) in the viewport, through open shadow roots; closed ones stay the page's.
  const deepAt = (x,y) => { let e=document.elementFromPoint(x,y);
    for(let n=0;e&&e.shadowRoot&&n<8;n++){ const inner=e.shadowRoot.elementFromPoint(x,y); if(!inner||inner===e)break; e=inner; } return e; };
  let pointRefs=0,pointHit=null;
  // Never at a check, on a page with the person's own fields, over a frame (its document is not
  // this one), or on a file chooser or the label that opens one. A control under the spot is
  // named and referenced as a read would, so the host clicks it as `click` does; anything else
  // is referenced only for the gate's reading. The words are the page's: untrusted, card only.
  const atPoint = (x, y) => {
    register(); const v=view(); pointHit=null;
    const check=challenge(''); if(check&&check.blocks)return {...v,refused:'captcha'};
    if(userSteps().length)return {...v,refused:'yours'};
    const e=deepAt(x,y); if(!e)return {...v,refused:'none'};
    if(e.matches('iframe,frame,embed,object'))return {...v,refused:'frame'};
    // Every element a click here reaches, as the event travels: the slot it is assigned to, each parent, and each shadow root's host.
    const path=[]; for(let n=e;n;n=n.assignedSlot||n.parentElement||(n.parentNode&&n.parentNode.host)||null)path.push(n);
    const up=sel=>path.find(n=>n.matches(sel))||null;
    if(path.some(insideCheck))return {...v,refused:'captcha'};
    const label=up('label'), labelled=label&&label.control;
    if(up('input[type=file]')||(labelled&&labelled.matches('input[type=file]')))return {...v,refused:'yours'};
    const field=up(fieldSelector); if(field&&(sensitive(field)||hasSecrets(fieldText(field))))return {...v,refused:'yours'};
    // Every real control the press would reach (an ancestor, a shadow host, or a label's control): any
    // sensitive one refuses, and the nearest goes the element path.
    const owners=path.filter(n=>n.matches(controls)).concat(labelled&&labelled.matches(controls)?[labelled]:[]);
    // A pressable whose own words name a secret ("Show recovery code") refuses too.
    const secretPress=n=>secretOf(n)||controlWords.test(ownWords(n));
    if(owners.some(secretPress)||path.some(n=>(n.matches(pressables)||n.matches(handled)||getComputedStyle(n).cursor==='pointer')&&secretPress(n)))return {...v,refused:'yours'};
    // What the click is for: the nearest control, else the nearest element clickable by role (a menu
    // item, not its icon), else the element hit. pointAct presses only this same hit.
    const control=owners[0]||null,node=control||up(pressables)||e; pointHit={e,node};
    const ref=`e${documentID}_${generation}_p${++pointRefs}`; refs.set(ref,node);
    const own=String(node.getAttribute('aria-label')||node.getAttribute('title')||node.getAttribute('alt')||'').replace(/\s+/g,' ').trim();
    const shown=String(node.innerText||'').replace(/\s+/g,' ').trim();
    let words=control?labelOf(control):own||(shown.length<=80?shown:''); words=hasSecrets(words)?'':words.slice(0,80);
    const role=String(node.getAttribute('role')||'').toLowerCase(), tag=String(node.tagName||'').toLowerCase();
    const kind=/^[a-z]{1,20}$/.test(role)?role:/^[a-z][a-z0-9-]{0,30}$/.test(tag)?tag:'element';
    return {...v,ref,control:!!control,what:words?`${kind} “${words}”`:kind};
  };
  // The press, in one turn with its last check: the same document, viewport and scroll as the
  // screenshot, no check and none of the person's fields, and the very element approved under
  // the spot. Mouse events at the spot, as a page script would send them; no OS input.
  const pointAct = (x, y, want) => {
    const v=view();
    if(v.document!==want.document||v.width!==want.width||v.height!==want.height||v.x!==want.x||v.y!==want.y)return {changed:true};
    const check=challenge(''); if(check&&check.blocks)return {needs_user:true,reason:'captcha'};
    if(userSteps().length)throw Error(yours);
    const e=deepAt(x,y); if(!e||!pointHit||e!==pointHit.e||!want.bind||!pointHit.node.dataset||pointHit.node.dataset.sereinBind!==want.bind||insideCheck(e))return {changed:true};
    const at={bubbles:true,cancelable:true,composed:true,clientX:x,clientY:y,button:0},pointer={pointerId:1,pointerType:'mouse',isPrimary:true};
    e.dispatchEvent(new PointerEvent('pointerdown',{...at,...pointer,buttons:1}));
    e.dispatchEvent(new MouseEvent('mousedown',{...at,buttons:1}));
    e.dispatchEvent(new PointerEvent('pointerup',{...at,...pointer,buttons:0}));
    e.dispatchEvent(new MouseEvent('mouseup',{...at,buttons:0}));
    e.dispatchEvent(new MouseEvent('click',{...at,buttons:0,detail:1}));
    invalidate(); return {performed:'click_point',verification:'Check the page that comes back with this result.'};
  };
  // Show me once: while the person records this tab, each click, typed value, choice and Enter
  // they make is posted to Serein as a step, described by role, label and nearby text. Only
  // trusted events count, so a page script and Serein's own actions are never recorded. A
  // password, card, code or file field is posted as the person's own step with no value, and so
  // is a value that reads as a card number or a credential. Each new document starts off.
  let recording=false,labelled=null;
  const recordedValues=new WeakMap();
  const textField = e => e.isContentEditable||e.matches(textSelector);
  const stepLabel = e => firstLine(e.getAttribute('aria-label')||(e.labels&&e.labels.length?Array.from(e.labels).map(l=>l.textContent).join(' '):'')
    ||(textField(e)||e.tagName==='SELECT'?'':e.innerText)||e.getAttribute('placeholder')||e.getAttribute('title')||e.getAttribute('alt')
    ||(e.matches('input[type=submit],input[type=button]')?e.value:'')||e.getAttribute('name')||'');
  const stepClean = t => { t=String(t||'').replace(/\s+/g,' ').trim().slice(0,120); return leaks(t,false)?'':t; };
  const stepOf = (kind,e,extra) => Object.assign({kind,role:stepClean(e.getAttribute('role')||e.tagName.toLowerCase()),label:stepClean(stepLabel(e)),near:stepClean(groupTitle(e))},extra||{});
  const postStep = step => { try{webkit.messageHandlers.sereinFrame.postMessage('step:'+JSON.stringify(step))}catch(_){} };
  const ownField = e => e.matches('input[type=file]')||sensitive(e)||hasSecrets(fieldText(e));
  const yoursStep = (e,field) => postStep(stepOf('yours',e,{field:field||(e.matches('input[type=file]')?'file':secretKind(e))}));
  // One step per field: a click and a focus on the same password field (or Tab, autofill, Enter) post it once.
  let yoursSeen=new WeakSet(); const yoursOnce = (e,field) => { if(yoursSeen.has(e))return; yoursSeen.add(e); yoursStep(e,field); };
  const typedStep = e => { const v=String(fieldText(e)??''); if(recordedValues.get(e)===v)return; recordedValues.set(e,v);
    if(ownField(e)||leaks(v,true)){yoursOnce(e);return;} postStep(stepOf('type',e,{value:v.slice(0,500)})); };
  const stepTarget = ev => { const t=ev.composedPath()[0]; return t&&t.matches?t:null; };
  addEventListener('focusin',ev=>{ if(!recording||!ev.isTrusted)return; const e=stepTarget(ev);
    if(e&&e.matches('input,textarea,select,[contenteditable=true]')&&ownField(e)){yoursOnce(e);return;}
    if(e&&textField(e))recordedValues.set(e,String(fieldText(e)??'')); },true);
  addEventListener('click',ev=>{ if(!recording||!ev.isTrusted)return; const t=stepTarget(ev); if(!t)return;
    let e=t.closest('a[href],button,input,select,textarea,summary,label,[role=button],[role=link],[role=menuitem],[role=tab],[role=option],[role=checkbox],[role=radio],[role=switch],[contenteditable=true]');
    // A label presses its control: the step is the control's, and the click the label forwards is not counted twice.
    if(e&&e.tagName==='LABEL'&&e.control){ e=e.control; labelled={e,at:performance.now()}; }
    else if(e&&labelled&&labelled.e===e&&performance.now()-labelled.at<100){ labelled=null; return; }
    if(!e&&getComputedStyle(t).cursor==='pointer')e=t;
    // Typing and choices are recorded when they are made, not when the field is clicked.
    if(!e||e.tagName==='SELECT'||textField(e))return;
    // A click inside an inline verification widget is the person's own CAPTCHA step.
    const inCheck=insideCheck(e);
    if(inCheck||ownField(e)){yoursOnce(e,inCheck?'captcha':'');return;}
    postStep(stepOf('click',e)); },true);
  addEventListener('change',ev=>{ if(!recording||!ev.isTrusted)return; const e=stepTarget(ev); if(!e)return;
    if(e.tagName==='SELECT'){ const o=e.selectedOptions[0],v=o?o.text.trim().slice(0,160):''; if(ownField(e)||leaks(v,true)){yoursOnce(e);return;} postStep(stepOf('select',e,{value:v})); return; }
    if(textField(e))typedStep(e); },true);
  addEventListener('focusout',ev=>{ if(!recording||!ev.isTrusted)return; const e=stepTarget(ev); if(e&&e.isContentEditable)typedStep(e); },true);
  addEventListener('keydown',ev=>{ if(!recording||!ev.isTrusted||ev.key!=='Enter'||ev.isComposing)return; const e=stepTarget(ev);
    if(!e||e.tagName!=='INPUT'||!textField(e))return;
    typedStep(e); if(!ownField(e))postStep(stepOf('key',e,{value:'Enter'})); },true);
  const record = on => { recording=!!on; if(recording)yoursSeen=new WeakSet(); return recording; };
  // What a secure card fills: a password, card details, a sign-in code, or an API key, token or
  // recovery secret ('key').
  const secureKind = e => { const k=secretKind(e), words=fieldWords(e);
    if(!['code','password'].includes(k)||/(^|\s)one-time-code(\s|$)/i.test(e.autocomplete||''))return k;
    if(k==='code'&&/recovery|backup|seed|passphrase/i.test(words))return 'key';
    return /api.?key|secret|token|credential/i.test(words)?'key':k; };
  // Where a form sends: its action and any button's formaction. Another origin among them wins.
  const sendsTo = form => { if(!form)return null; let out=location.origin;
    for(const raw of [form.getAttribute('action'),...Array.from(form.querySelectorAll('[formaction]'),b=>b.getAttribute('formaction'))]){
      if(raw==null||raw==='')continue; let o; try{o=new URL(raw,location.href).origin;}catch(_){o='null';} if(o!==location.origin)out=o; }
    return out; };
  const cardPart = e => { const ac=(e.autocomplete||'').toLowerCase(), w=fieldWords(e);
    if(/cc-number/.test(ac))return 'number'; if(/cc-csc/.test(ac))return 'cvc'; if(/cc-name|cc-given|cc-family/.test(ac))return 'holder';
    if(/cc-exp-month/.test(ac))return 'month'; if(/cc-exp-year/.test(ac))return 'year'; if(/cc-exp/.test(ac))return 'expiry';
    if(/cvc|cvv|csc|security.?code/i.test(w))return 'cvc'; if(/month/i.test(w)&&/exp/i.test(w))return 'month'; if(/year/i.test(w)&&/exp/i.test(w))return 'year';
    if(/expir|mm.?\/?.?yy/i.test(w))return 'expiry'; if(/name|holder/i.test(w))return 'holder'; if(/card|number/i.test(w))return 'number'; return ''; };
  // A card's fields: the target's form, or this document without one. Only fields a person can see.
  const cardFields = e => { const scope=e.form?Array.from(e.form.elements):deep(document,secureSelector);
    return scope.filter(f=>f.isConnected&&visible(f)&&f.matches(secureSelector)&&sensitive(f)&&secureKind(f)==='card'&&cardPart(f)); };
  const secureField = ref => { const e=refs.get(ref);
    if(!e||!e.isConnected||!e.matches(secureSelector)||!sensitive(e))return {connected:!!(e&&e.isConnected),kind:null};
    const kind=secureKind(e), parts=kind==='card'?Array.from(new Set(cardFields(e).map(cardPart).map(p=>p==='month'||p==='year'?'expiry':p))):[];
    return {connected:true,kind,autocomplete:e.autocomplete||'',document:documentID,origin:location.origin,form:sendsTo(e.form),parts}; };
  const setField = (e,v) => { if(e.tagName==='SELECT'){ const o=Array.from(e.options).find(o=>!o.disabled&&(o.value===v||Number(o.value)===Number(v)&&/^\d+$/.test(o.value)||o.text.trim()===v));
      if(!o)return false; e.value=o.value; }
    else Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,v);
    e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true})); return true; };
  // The person's submit, filled by Serein: the field is the one the card was raised for, on the
  // same document and site, still secret and of the same kind, in a form that sends to this site.
  const fillSecure = (ref,doc,origin,kind,values) => { const e=refs.get(ref);
    if(doc!==documentID||origin!==location.origin||!e||!e.isConnected||!sensitive(e)||secureKind(e)!==kind||sendsTo(e.form)!==null&&sendsTo(e.form)!==location.origin)return 'changed';
    filled.set(ref,e);
    // Undo on a fill's receipt: Serein empties the fields it filled.
    if(values.clear==='1'){ for(const f of kind==='card'?cardFields(e):[e]) if(f.tagName!=='SELECT')setField(f,''); return 'ok'; }
    if(kind!=='card')return setField(e,String(values.value))?'ok':'changed';
    const [mm,yy]=String(values.expiry||'').split('/');
    for(const f of cardFields(e)){ const part=cardPart(f); let v=values[part];
      if(part==='month')v=mm; else if(part==='year')v=f.tagName==='SELECT'?(Array.from(f.options).some(o=>/^\d{4}$/.test(o.value))?'20'+yy:yy):(f.maxLength===2?yy:'20'+yy);
      else if(part==='expiry'&&f.maxLength===7)v=mm+'/20'+yy;
      if(v==null||v===''||!setField(f,String(v)))return 'changed'; }
    return 'ok'; };
  const sameForm = (a,b) => { const f=filled.get(a)||refs.get(a), p=refs.get(b);
    return !!(f&&p&&f.isConnected&&p.isConnected&&f.form&&(p.form===f.form||f.form.contains(p))); };
  globalThis.__serein={secureField,fillSecure,sameForm,read,readContext,act,actAndDescribe,invalidate,settle,userSteps,probe,target,blank,confirmBlank,unblank,describe,describeUpload,upload,challenge,record,pageTools,callTool,view,atPoint,pointAct};
  // Route changes are reported by PageNav.js, installed at document start in the page world.
  // Dropping the refs here keeps a later read from handing out elements from the previous route.
  addEventListener('popstate',()=>{invalidate();});
  addEventListener('hashchange',()=>{invalidate();});
  // Shift-hover a link and Serein previews it (in a split's other pane). Throttled: one post
  // per link, and none while Shift is up.
  let previewed=null;
  addEventListener('mousemove',ev=>{ const a=ev.shiftKey?ev.target&&ev.target.closest&&ev.target.closest('a[href]'):null;
    const href=a?a.href:null;
    if(href&&href!==previewed){ previewed=href; try{webkit.messageHandlers.sereinFrame.postMessage('preview:'+href)}catch(_){}}
    else if(!href)previewed=null; },true);
})();
