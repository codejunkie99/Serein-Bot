#!/bin/sh
# The formal gate (TEAMS-V2, "Formal verification without TLA+"): every bounded model checker in
# Sources/SereinCore/Formal passes. swift build rebuilds only what changed. Exit 0 when all pass;
# on a violation it prints the shortest counterexample and exits 1. Usage: scripts/check_formal.sh [machine ...]
cd "$(dirname "$0")/.." || exit 2
log=$(mktemp)
swift build --product Serein >"$log" 2>&1 || { tail -20 "$log"; echo "FAIL: swift build"; exit 2; }
rm -f "$log"
exec .build/debug/Serein --verify-formal "$@"
