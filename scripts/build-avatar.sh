#!/bin/sh
# Builds Relay's hologram (tools/avatar) into Sources/Serein/Avatar/avatar.bundle.js and copies
# its presets into SereinCore/RelayLook.swift, so the renderer and Serein share one list.
# Needs Node 18 or later; three.js and esbuild are pinned in tools/avatar/package-lock.json.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/tools/avatar"
[ -d node_modules ] || npm ci --no-audit --no-fund
npm run build
python3 - "$root" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1])
presets = (root / "tools/avatar/src/presets.json").read_text().rstrip("\n")
swift = root / "Sources/SereinCore/RelayLook.swift"
text = swift.read_text()
start = text.index('  static let presetsJSON = #"""')
end = text.index('"""#', start + 40)
body = "\n".join("    " + line for line in presets.split("\n"))
swift.write_text(text[:start] + '  static let presetsJSON = #"""\n' + body + "\n    " + text[end:])
print("Presets copied into", swift.relative_to(root))
PY
