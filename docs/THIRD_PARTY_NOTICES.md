# Third-party notices

## Relay assistant

Relay in Serein (`Sources/SereinCore/Relay.swift`) ports logic from [Relay](https://github.com/duolahypercho/relay-assistant):
- stop-message matching (`shared/chat-stop.mjs`);
- follow-up steering (`shared/steering.mjs`);
- sourced memory notes (`shared/memory.mjs`);
- simple reminder schedules (`shared/routines.mjs`).

Relay's own instructions (`Sources/Serein/RelayPrompt.swift`) adapt Relay's tool guidance: delegate durable work, act directly on small steps, verify before reporting.

None of Relay's code, styles or artwork ships with Serein. Relay is MIT licensed, copyright (c) 2026 Relay contributors. The notice is retained at [licenses/Relay-MIT.txt](licenses/Relay-MIT.txt).

## jev-ultrafast

The web rules in the fast-step decision prompt (`JevPolicy.rules` in `Sources/SereinCore/JevPolicy.swift`) are adapted from `questions.py` in jev-ultrafast by the [browser-use](https://github.com/browser-use) project. jev-ultrafast is MIT licensed, copyright (c) 2026 Browser Use. The notice is retained at [licenses/jev-ultrafast-MIT.txt](licenses/jev-ultrafast-MIT.txt).

## arc-cua

The risky-phrase list in the fast-step policy (`JevPolicy.riskPhrases` in `Sources/SereinCore/JevPolicy.swift`) is adapted from [arc-cua](https://github.com/shhivv/arc-cua). arc-cua is MIT licensed, copyright (c) 2026; the upstream notice names no holder. The notice is retained at [licenses/arc-cua-MIT.txt](licenses/arc-cua-MIT.txt).

## three.js

Relay's hologram (`Sources/Serein/Avatar/avatar.bundle.js`, built from [`tools/avatar`](../tools/avatar)) bundles [three.js](https://github.com/mrdoob/three.js) 0.160.0, MIT licensed, copyright © 2010-2023 three.js authors. The bundle keeps three.js's license comment at its end, and the text is at [licenses/three.js-MIT.txt](licenses/three.js-MIT.txt). esbuild, which builds the bundle, is a development tool and does not ship.

## Zeron source adaptation

Serein's dark UI tokens, shell measurements and visual component rules are adapted from [Zeron](https://github.com/zeronsh/zeron) at commit [`1074bc540b995d6b7e5a6fa5431f1a2420df8d91`](https://github.com/zeronsh/zeron/tree/1074bc540b995d6b7e5a6fa5431f1a2420df8d91). The inspected local checkout is `../../work/zeron-reference`, relative to the Serein repository root. The former `zeronsh/comet` repository URL redirects to Zeron.

Zeron's own source is MIT licensed, copyright (c) 2026 Wing. The complete copyright and permission notice is retained in [licenses/Zeron-MIT.txt](licenses/Zeron-MIT.txt).

Serein retains its own name and mark. The adaptation does not imply affiliation with or endorsement by Zeron or any asset author.

## Geist and Geist Mono

The `.ttf` files in `Sources/Serein/Fonts/` were copied from Zeron's `crates/ui/assets/fonts/` at the pinned commit. The upstream notice identifies [vercel/geist-font](https://github.com/vercel/geist-font) release `v1.7.2` as their source.

Copyright 2024 The Geist Project Authors. Both families are distributed under the SIL Open Font License 1.1, retained at [Geist-OFL.txt](../Sources/Serein/Fonts/licenses/Geist-OFL.txt). The copied [Geist-NOTICES.md](../Sources/Serein/Fonts/licenses/Geist-NOTICES.md) retains the upstream wording, including the former application name, Comet. Serein registers the fonts through CoreText and uses them through `UIStyle`.

## Outline SVG icons

The SVG files in `Sources/Serein/Icons/` were copied from Zeron's `crates/ui/assets/icons/` at the pinned commit. Their provenance is described in the pinned [`icons.rs`](https://github.com/zeronsh/zeron/blob/1074bc540b995d6b7e5a6fa5431f1a2420df8d91/crates/ui/src/icons.rs).

The set includes **Solar Icons by 480 Design**, Linear weight, licensed under [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/), alongside Zeron's original glyphs under its MIT license. This attribution applies to the copied Solar glyphs; Zeron's MIT license does not replace their CC BY 4.0 terms. The copied SVGs retain the source geometry; `widget-add.svg` is Serein's adaptation of Solar's `widget.svg`, three of its four squares with a plus drawn in place of the fourth. `InterfaceIcon` scales them and applies the current foreground color as native template images, with SF Symbols as a fallback when no source asset matches a control.

The app-bundled [Icons/NOTICE.txt](../Sources/Serein/Icons/NOTICE.txt) records the icon attribution and source revision. Complete license texts are included beside the icons as [Zeron-MIT.txt](../Sources/Serein/Icons/Zeron-MIT.txt) and [CC-BY-4.0.txt](../Sources/Serein/Icons/CC-BY-4.0.txt).

Two harness brand marks, `claude-mark.svg` (Anthropic) and `openai-mark.svg` (OpenAI), were copied from Keel's `crates/ui/assets/icons/` (ports of the marks in keel's `icons.tsx`). They identify the CLI a task runs through and remain their owners' trademarks; no affiliation or endorsement is implied. Zeron's Symbols filename/folder icon library is not copied.

The harness picker, setup and task views show each coding agent's own product mark (`harness-*.svg`). The Claude Code, Codex, Cursor, OpenCode, Pi and Grok marks were copied from [Lobe Icons](https://github.com/lobehub/lobe-icons) (`@lobehub/icons-static-svg` 1.95.1, MIT, copyright 2023 LobeHub; license at [LobeIcons-MIT.txt](../Sources/Serein/Icons/LobeIcons-MIT.txt)); only the Codex path data was respaced (arc flags separated, same shapes) so macOS's SVG renderer draws it correctly. The Oh My Pi mark is `assets/icon.svg` from [Oh My Pi](https://github.com/can1357/oh-my-pi/blob/a4d6f0adc63dda4ccdf4d25c26422219820f865b/assets/icon.svg) (MIT; license at [OhMyPi-MIT.txt](../Sources/Serein/Icons/OhMyPi-MIT.txt)). `HarnessGlyph` renders them as template images in the foreground color. The names and marks remain their owners' trademarks; no affiliation or endorsement is implied.

Settings shows each company it names with its own logo in colour (`logo-*.svg`): Gmail, Google Calendar, Slack, Notion, GitHub, Docker, Composio and the one-click apps (Asana, Cloudflare, Dropbox, Figma, Intercom, Linear, Monday, PayPal, Sentry, Square, Supabase and Vercel) from [SVG Logos](https://github.com/gilbarbara/logos) (CC0-1.0; Google Calendar's masked shading and blur removed so macOS can draw it; Composio's unchanged shape filled in its blue, #31AAFF, on a black rounded tile); Claude, Codex and Gemini from Lobe Icons 1.95.1 (MIT, as above); E2B's fire-orange symbol from its [brand asset pack](https://e2b.dev/brand); and the glyph of Daytona's logotype from its [brand page](https://daytona.io/brand), cut to its own frame with unchanged shapes and drawn in the text colour. More app logos are bundled for Connect Apps, each under the license its source repository states: from SVG Logos and [Simple Icons](https://github.com/simple-icons/simple-icons) (CC0-1.0, except Sanity's mark, which Simple Icons records as MIT; nine Simple Icons shapes filled in the brand colour its data gives), [svgl](https://github.com/pheralb/svgl), [theSVG](https://github.com/glincker/thesvg), [Composio's logo set](https://github.com/ComposioHQ/logo-cdn) and the AgentMail, Context7, Mercury, Remote and ZoomInfo repositories (MIT; notices at [AppLogos-MIT.txt](../Sources/Serein/Icons/AppLogos-MIT.txt); eleven Composio files have their DOCTYPE line removed), and [Meltano Hub](https://github.com/meltano/hub) and [Hive](https://github.com/aden-hive/hive) (Apache-2.0; license at [Apache-2.0.txt](../Sources/Serein/Icons/Apache-2.0.txt)). A mark that is one dark or white colour is drawn in the text colour. Icons/NOTICE.txt names each file's source and revision. The Mac apps on the Marketplace's On this Mac page show their own icons, read from the installed apps at run time; no Apple icon is bundled. The names and marks remain their owners' trademarks; no affiliation or endorsement is implied.

## models.dev catalog

`Sources/Serein/Catalog/models-dev.json` is [models.dev](https://models.dev)'s `https://models.dev/api.json`, downloaded on 2026-11-19 and trimmed to tool-capable text models and the facts Serein shows (tools, pictures, reasoning, context, price, release date). Serein replaces it with a fresh trimmed copy in its library once a day. Provider names and addresses in `Sources/SereinCore/ProviderTable.swift` are the providers' public API facts.

The project is MIT licensed, copyright (c) 2025 models.dev. The complete notice is retained in [licenses/models.dev-MIT.txt](licenses/models.dev-MIT.txt) and ships beside the data as [LICENSE.txt](../Sources/Serein/Catalog/LICENSE.txt).

## Site password rules

`Sources/Serein/Quirks/password-rules.json` is `quirks/password-rules.json` from Apple's [password-manager-resources](https://github.com/apple/password-manager-resources), copied unmodified from the `main` branch on 2026-10-10. Serein's generator uses it when a page has no `passwordrules` attribute.

The project is MIT licensed, copyright 2020 - 2026 Apple Inc. The complete notice is retained in [licenses/Apple-password-manager-resources-MIT.txt](licenses/Apple-password-manager-resources-MIT.txt) and ships beside the data as [LICENSE-password-manager-resources.txt](../Sources/Serein/Quirks/LICENSE-password-manager-resources.txt).

## Cua Driver

Serein stages the unmodified Linux arm64 and x86_64 drivers from [cua-driver-rs-v0.53.2](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.53.2). The build checks the release checksums and architecture-specific binary pins. Notarized builds also require the upstream workflow signature for each archive.

Cua is MIT licensed, copyright (c) 2025 Cua AI, Inc. The notice is retained at [licenses/Cua-MIT.txt](licenses/Cua-MIT.txt). Beside the binary the app ships the release's own `LICENSE` as `Computer/cua-driver-license.txt` and its `THIRD_PARTY_NOTICES.md`, unchanged, as `Computer/cua-driver-notices.md` (it names trope-cua, Interface-Agent, yabai, QuickJS-ng, rquickjs and T3 Code, all MIT); the guest gets both under `/usr/share/doc/cua-driver/`. Both files are pinned by SHA-256 to the release archive's copies.

"Cua" and "Cua Driver" are trademarks of Cua AI, Inc. Serein names the binary Cua Driver only because it is the unmodified release; a modified or rebuilt binary must ship under another name ([Cua's trademark rules](https://github.com/trycua/cua/blob/main/legal/TRADEMARKS.md)). No affiliation with or endorsement by Cua AI, Inc. is implied.

Not used, and never to be added: `cua-perception` and its OmniParser model (AGPL-3.0-only), `libs/python/som` (AGPL-3.0-or-later), and Cua Spaces, `cua-spacesd`, `libs/spaces-app-swift`, `CuaSpacesStreaming` and `cua-driver-bench` (FSL-1.1-MIT).

The [bundled Rust dependency notices](../Sources/Serein/Computer/cua-driver-crates.md) cover both Linux GNU targets. For an upgrade, use the upstream release commit and Cargo.lock. For each target, run `cargo tree --locked -p cua-driver --features cua-driver/portal-input --target TARGET -e normal` and resolve the package versions with `cargo metadata --locked --format-version 1`. Include the licence and notice files from each package, using its recorded upstream Git revision when the published crate omits the text. Update the notice digest in CuaDriverRelease with the driver pins.

## Lume offline provisioning

`MacOfflineProvisioning` and `MacOfflineSetup` adapt the offline Data-volume provisioning approach and macOS autologin encoding from [Lume's MacOSOfflineSetupPatcher.swift](https://github.com/trycua/cua/blob/9166817485ae53f3966935c13878a8196d79a399/libs/lume/src/Unattended/MacOSOfflineSetupPatcher.swift), MIT licensed, copyright (c) 2025 Cua AI, Inc. Serein uses its own generated per-VM credentials, guest login service and local finalizer; it does not enable Lume's SSH or networking defaults. The complete notice is retained in [licenses/Cua-MIT.txt](licenses/Cua-MIT.txt) and bundled with Serein Computer as `Contents/Resources/Cua-MIT.txt`. No Lume binary or dependency is included.

## terminal-mac

Serein's virtual Mac uses native macOS virtualization and a guest mailbox and input helper adapted from [terminal-mac](https://github.com/govijr/terminal-mac) at commit `80dc388cdcafedc6a7e8ef262ea0d15d95056d84`. terminal-mac is MIT licensed, copyright (c) 2026 Govijr. Its complete notice is retained at [licenses/terminal-mac-MIT.txt](licenses/terminal-mac-MIT.txt). Serein embeds the native desktop and supplies its own setup flow; it does not include the terminal renderer.

## Sparkle

Release builds check for updates and replace themselves with [Sparkle](https://github.com/sparkle-project/Sparkle) 2.10.0. The framework is MIT licensed, copyright 2006-2024 Sparkle Project. The notice is retained at [licenses/Sparkle-LICENSE.txt](licenses/Sparkle-LICENSE.txt) and ships in the app as `Contents/Resources/Sparkle-LICENSE.txt`.

## transcribe.cpp

Dictation in English runs NVIDIA's Parakeet speech model with [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) 0.4.2, taken as the framework its release publishes. transcribe.cpp is MIT licensed, copyright (c) 2026 The transcribe.cpp authors, and includes ggml (MIT), miniz (MIT) and the Silero VAD model (MIT). Their notices are retained at [licenses/transcribe.cpp-LICENSES.txt](licenses/transcribe.cpp-LICENSES.txt) and ship in the app as `Contents/Resources/transcribe.cpp-LICENSES.txt`. The speech model file itself is not part of Serein or of this repository. Serein offers to download it from [Hugging Face](https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf), only when the person chooses Download on its card; the card links the [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/) the model is published under.

## UI SDK

Serein's built-in `ui-sdk` skill (`Sources/Serein/Skills/ui-sdk/`) is the agent skill published with [UI SDK](https://github.com/vercel-labs/ui) (`packages/core/skills/ui-sdk`, commit 724a7d6c), so pages and web apps Serein builds or hands off use its behaviors. Its reference files are unchanged; Serein rewrote the skill's description and added an "In Serein" section.

UI SDK is Apache License 2.0, copyright 2026 Vercel, Inc. The license is retained at [licenses/ui-sdk-LICENSE.txt](licenses/ui-sdk-LICENSE.txt).
