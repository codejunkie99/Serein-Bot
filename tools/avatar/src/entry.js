// Relay's hologram for Serein. `RelayAvatar.boot(config)` starts it in a page whose only host is
// Serein (a WKWebView with no network); `RelayAvatar.create(element, options)` is the same
// renderer for any page, such as the gallery in tools/avatar/dev.
import { Avatar } from './avatar.js';
import { PRESETS, STATES, FORMATIONS, CORES, STYLES, EFFECTS, normalize } from './look.js';

function create(host, options = {}) {
  try {
    return new Avatar(host, options);
  } catch (error) {
    if (typeof options.onEvent === 'function') options.onEvent({ type: 'error', message: String((error && error.message) || error) });
    return null;
  }
}

function boot(config) {
  const post = (message) => {
    try { window.webkit.messageHandlers.avatar.postMessage(message); } catch (_) { /* no host */ }
  };
  if (window.relayAvatar) window.relayAvatar.destroy();
  window.relayAvatar = create(document.getElementById('stage'), Object.assign({}, config, { onEvent: post }));
  return !!window.relayAvatar;
}

window.RelayAvatar = { version: 1, create, boot, normalize, presets: PRESETS, states: STATES, formations: FORMATIONS, cores: CORES, styles: STYLES, effects: EFFECTS };
