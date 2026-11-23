# Serein’s hologram

The renderer behind the assistant’s hologram in Serein: rings in a formation around a core of points, drawn with [three.js](https://threejs.org) on a transparent canvas. Serein ships it as `Sources/Serein/Avatar/avatar.bundle.js` and runs it in an isolated web view (`Sources/Serein/RelayAvatar.swift`).

## Build

```sh
scripts/build-avatar.sh
```

It installs the pinned three.js and esbuild (`package-lock.json`) the first time, bundles `src/` into `Sources/Serein/Avatar/avatar.bundle.js`, and copies `src/presets.json` into `Sources/SereinCore/RelayLook.swift`. Commit the bundle with the source: building Serein does not need Node.

## Files

| File | What it holds |
|---|---|
| `src/look.js` | The look format: states, formations, cores, ring styles, effects, and a normalizer that keeps the renderer safe. Serein validates every look first (`RelayLook`). |
| `src/presets.json` | The six built-in looks. Serein reads the same list. |
| `src/formations.js` | The 12 ring formations. Each state picks one. |
| `src/cores.js` | The 12 core shapes, as point clouds. |
| `src/avatar.js` | The renderer: morphs between formations and cores, reacts to voice, words and jobs, draws the glow. |
| `src/entry.js` | `window.RelayAvatar`: `create(element, options)` for any page, `boot(config)` for Serein. |

## Use it in a page

```html
<div id="stage" style="width:480px;height:240px"></div>
<script src="avatar.bundle.js"></script>
<script>
  const avatar = RelayAvatar.create(document.getElementById('stage'), { look: RelayAvatar.presets[0], state: 'idle' });
  avatar.setState('thinking');     // idle, listening, thinking, speaking, working, alert, error, dormant
  avatar.setLevel(0.6);            // microphone level, 0 to 1
  avatar.pulse(0.8);               // a spoken word
  avatar.setJobs([{ id: 'a', state: 'running' }]);   // running, done or failed
  avatar.event('done');            // a burst; 'error' fractures it
  avatar.preview('tour', 12);      // every state in turn
  avatar.setTheme('light');        // colored ink for light backgrounds
</script>
```

Options: `look`, `state`, `transparent` (default true), `theme` (`dark` or `light`), `quality` (`high` or `low`), `still` (one settled frame), `onEvent` (receives `ready`, `tap` and `error`).

## Look at it

`dev/harness.html` shows one look full screen (`?preset=Aurora&state=thinking`). With [Playwright](https://playwright.dev) installed anywhere, these write PNGs:

```sh
PLAYWRIGHT=/path/to/node_modules/playwright node dev/capture.cjs shots Serein Aurora   # every state, per look
PLAYWRIGHT=/path/to/node_modules/playwright node dev/themes.cjs shots Serein           # on dark and light backgrounds
PLAYWRIGHT=/path/to/node_modules/playwright node dev/frame.cjs shots                   # panel sizes and a morph filmstrip
```

## Add a formation or a core

1. Add it to `src/formations.js` or `src/cores.js`, and to the lists in `src/look.js`.
2. Add it with a one-line description to `RelayLook.formations` or `RelayLook.cores` in `Sources/SereinCore/RelayLook.swift`.
3. Run `scripts/build-avatar.sh`, then `swift build` and `.build/debug/Serein --verify-avatar`.

