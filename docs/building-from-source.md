# Building from source

[← Back to README](../README.md)

## Requirements

- macOS 14 or later
- Xcode command-line tools and Swift
- Python 3

## Build

```sh
git clone https://github.com/codejunkie99/SereinBot.git
cd SereinBot
bash scripts/build.sh
python3 scripts/verify_package.py
open dist/Serein.app
```

The first build downloads the pinned dependencies: Sparkle 2.10.0 and the transcribe.cpp 0.4.2 framework that runs dictation.

## Output

`scripts/build.sh` writes to `dist/`:

- `Serein.app`
- `Serein-Free-macOS-<arch>.zip`, where `<arch>` is your Mac's chip (`arm64` or `x86_64`)

Set `SEREIN_DIST_DIR` to write somewhere else.

`scripts/verify_package.py` checks the ZIP without changing the app or build inputs.

## Signing

The build signs with your first Apple Development identity, else your first Developer ID Application identity. Set `SEREIN_SIGN_IDENTITY` to pick one. With neither, it signs ad hoc and prints a warning.

## Universal build

`SEREIN_NOTARIZE=1` builds one app for Apple Silicon and Intel, then signs and notarizes it. It needs the project's Developer ID identity and a notary profile (`SEREIN_NOTARY_PROFILE`), so contributors build for their own chip instead.

## Hologram renderer

The assistant's hologram is prebuilt into `Sources/Serein/Avatar/avatar.bundle.js`, so building Serein does not need Node. To change it, see [tools/avatar](../tools/avatar/README.md).
