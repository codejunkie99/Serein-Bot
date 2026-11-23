# Third-party notices

## Cua Driver

Serein stages the unmodified Linux arm64 and x86_64 drivers from [cua-driver-rs-v0.53.2](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.53.2). The build checks the release checksums and architecture-specific binary pins. Notarized builds also require the upstream workflow signature for each archive.

Cua is MIT licensed, copyright (c) 2025 Cua AI, Inc. The notice is retained at [licenses/Cua-MIT.txt](licenses/Cua-MIT.txt). Beside the binary the app ships the release's own `LICENSE` as `Computer/cua-driver-license.txt` and its `THIRD_PARTY_NOTICES.md`, unchanged, as `Computer/cua-driver-notices.md` (it names trope-cua, Interface-Agent, yabai, QuickJS-ng, rquickjs and T3 Code, all MIT); the guest gets both under `/usr/share/doc/cua-driver/`. Both files are pinned by SHA-256 to the release archive's copies.

"Cua" and "Cua Driver" are trademarks of Cua AI, Inc. Serein names the binary Cua Driver only because it is the unmodified release; a modified or rebuilt binary must ship under another name ([Cua's trademark rules](https://github.com/trycua/cua/blob/main/legal/TRADEMARKS.md)). No affiliation with or endorsement by Cua AI, Inc. is implied.

Not used, and never to be added: `cua-perception` and its OmniParser model (AGPL-3.0-only), `libs/python/som` (AGPL-3.0-or-later), and Cua Spaces, `cua-spacesd`, `libs/spaces-app-swift`, `CuaSpacesStreaming` and `cua-driver-bench` (FSL-1.1-MIT).

The [bundled Rust dependency notices](../Sources/Serein/Computer/cua-driver-crates.md) cover both Linux GNU targets. For an upgrade, use the upstream release commit and Cargo.lock. For each target, run `cargo tree --locked -p cua-driver --features cua-driver/portal-input --target TARGET -e normal` and resolve the package versions with `cargo metadata --locked --format-version 1`. Include the licence and notice files from each package, using its recorded upstream Git revision when the published crate omits the text. Update the notice digest in CuaDriverRelease with the driver pins.

### Lume offline provisioning

`MacOfflineProvisioning` and `MacOfflineSetup` adapt the offline Data-volume provisioning approach and macOS autologin encoding from [Lume's MacOSOfflineSetupPatcher.swift](https://github.com/trycua/cua/blob/9166817485ae53f3966935c13878a8196d79a399/libs/lume/src/Unattended/MacOSOfflineSetupPatcher.swift), MIT licensed, copyright (c) 2025 Cua AI, Inc. Serein uses its own generated per-VM credentials, guest login service and local finalizer; it does not enable Lume's SSH or networking defaults. The complete notice is retained in [licenses/Cua-MIT.txt](licenses/Cua-MIT.txt) and bundled with Serein Computer as `Contents/Resources/Cua-MIT.txt`. No Lume binary or dependency is included.
