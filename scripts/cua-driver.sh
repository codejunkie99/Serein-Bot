#!/bin/bash
# Puts the pinned Cua Driver (MIT, Cua AI, Inc.) into the app's Computer resources, for the built-in
# computer's seed and Serein's Docker box: scripts/cua-driver.sh <the resource bundle's Computer folder>.
# Both Linux builds are staged: linux-arm64 as `cua-driver`, linux-x86_64 as `cua-driver-amd64`.
#
# The pins are CuaDriverRelease's in Sources/SereinCore/CuaDriver.swift (one source of truth). The
# archive comes from Cua's own GitHub release; its SHA-256 must be the pinned one and the one the
# release's SHA256SUMS lists, and the binary, LICENSE and THIRD_PARTY_NOTICES.md inside must match
# their own pins. With cosign installed, the release's Sigstore bundle must verify for Cua's
# release workflow at the pinned tag; a release build (SEREIN_NOTARIZE=1) requires cosign.
#
# Explicitly disabled builds and offline development builds may use the helper alone.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:?usage: scripts/cua-driver.sh <Computer resources folder>}"
PINS=Sources/SereinCore/CuaDriver.swift
pin() { sed -n "s/.*static let $1 = \"\\([^\"]*\\)\".*/\\1/p" "$PINS" | head -1; }
TAG="$(pin tag)"
LICENSE_SHA="$(pin licenseSHA256)"
NOTICES_SHA="$(pin noticesSHA256)"
# One line per build: resource name, archive, folder, archive digest, binary digest.
BUILDS="cua-driver $(pin archive) $(pin archiveFolder) $(pin archiveSHA256) $(pin binarySHA256)
cua-driver-amd64 $(pin amd64Archive) $(pin amd64ArchiveFolder) $(pin amd64ArchiveSHA256) $(pin amd64BinarySHA256)"
for value in "$TAG" "$LICENSE_SHA" "$NOTICES_SHA"; do
  [ -n "$value" ] || { echo "cua-driver: a pin is missing from $PINS" >&2; exit 1; }
done
while read -r NAME ARCHIVE FOLDER ARCHIVE_SHA BINARY_SHA; do
  [ -n "$BINARY_SHA" ] || { echo "cua-driver: a pin for $NAME is missing from $PINS" >&2; exit 1; }
  for digest in "$ARCHIVE_SHA" "$BINARY_SHA"; do
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo "cua-driver: $digest is not a SHA-256" >&2; exit 1; }
  done
done <<< "$BUILDS"
for digest in "$LICENSE_SHA" "$NOTICES_SHA"; do
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo "cua-driver: $digest is not a SHA-256" >&2; exit 1; }
done
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

# Whatever happens below, no older binary stays in the bundle: it is this release or none.
mkdir -p "$TARGET"
rm -f "$TARGET/cua-driver" "$TARGET/cua-driver-amd64"
RELEASE="${SEREIN_NOTARIZE:-0}"
if [ "${SEREIN_CUA_DRIVER:-1}" = 0 ]; then
  echo "cua-driver: SEREIN_CUA_DRIVER=0, building without Cua Driver"
  exit 0
fi
CRATE_NOTICES=Sources/Serein/Computer/cua-driver-crates.md
[ -f "$CRATE_NOTICES" ] && [ "$(sha256 "$CRATE_NOTICES")" = "$(pin crateNoticesSHA256)" ] || {
  echo "cua-driver: missing or incorrect dependency notices for $TAG" >&2
  exit 1
}
install -m 0644 "$CRATE_NOTICES" "$TARGET/cua-driver-crates.md"

CACHE=".build/cua-driver/$TAG"
mkdir -p "$CACHE"
BASE="https://github.com/trycua/cua/releases/download/$TAG"
fetch() {
  [ -s "$CACHE/$1" ] && return 0
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$CACHE/$1.part" "$BASE/$1" && mv "$CACHE/$1.part" "$CACHE/$1"
}
if ! fetch SHA256SUMS; then
  rm -f "$CACHE"/*.part
  if [ "$RELEASE" = 1 ]; then echo "cua-driver: could not fetch $TAG" >&2; exit 1; fi
  echo "cua-driver: could not fetch $TAG; building without Cua Driver"
  exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The repository's copies, which ship beside the binaries, are the release's own.
[ "$(sha256 Sources/Serein/Computer/cua-driver-license.txt)" = "$LICENSE_SHA" ] || { echo "cua-driver: Computer/cua-driver-license.txt changed" >&2; exit 1; }
[ "$(sha256 Sources/Serein/Computer/cua-driver-notices.md)" = "$NOTICES_SHA" ] || { echo "cua-driver: Computer/cua-driver-notices.md changed" >&2; exit 1; }
STAGED=()
while read -r NAME ARCHIVE FOLDER ARCHIVE_SHA BINARY_SHA; do
  case "${SEREIN_CUA_ARCH:-all}:$NAME" in
    all:* | arm64:cua-driver | amd64:cua-driver-amd64) ;;
    arm64:* | amd64:*) continue ;;
    *) echo "cua-driver: SEREIN_CUA_ARCH must be all, arm64 or amd64" >&2; exit 1 ;;
  esac
  if ! fetch "$ARCHIVE"; then
    rm -f "$CACHE"/*.part
    if [ "$RELEASE" = 1 ]; then echo "cua-driver: could not fetch $ARCHIVE" >&2; exit 1; fi
    echo "cua-driver: could not fetch $ARCHIVE; building without it"
    continue
  fi
  LISTED="$(awk -v f="$ARCHIVE" '$2 == f || $2 == "*" f { print tolower($1) }' "$CACHE/SHA256SUMS")"
  [ "$LISTED" = "$ARCHIVE_SHA" ] || { echo "cua-driver: $TAG's SHA256SUMS does not list the pinned digest for $ARCHIVE" >&2; exit 1; }
  [ "$(sha256 "$CACHE/$ARCHIVE")" = "$ARCHIVE_SHA" ] || {
    rm -f "$CACHE/$ARCHIVE"
    echo "cua-driver: $ARCHIVE does not match its pin; removed it" >&2
    exit 1
  }
  if command -v cosign >/dev/null 2>&1; then
    fetch "$ARCHIVE.sigstore.json" || { echo "cua-driver: no Sigstore bundle for $ARCHIVE" >&2; exit 1; }
    cosign verify-blob --bundle "$CACHE/$ARCHIVE.sigstore.json" \
      --certificate-identity "https://github.com/trycua/cua/.github/workflows/cd-rust-cua-driver.yml@refs/tags/$TAG" \
      --certificate-oidc-issuer "https://token.actions.githubusercontent.com" "$CACHE/$ARCHIVE" >/dev/null \
      || { echo "cua-driver: the Sigstore signature of $ARCHIVE did not verify for $TAG" >&2; exit 1; }
  elif [ "$RELEASE" = 1 ]; then
    echo "cua-driver: a release build needs cosign to check the Sigstore signature" >&2
    exit 1
  else
    echo "cua-driver: cosign is not installed; checked $ARCHIVE by its pinned SHA-256 only"
  fi
  tar -xzf "$CACHE/$ARCHIVE" -C "$WORK" "$FOLDER/cua-driver" "$FOLDER/LICENSE" "$FOLDER/THIRD_PARTY_NOTICES.md"
  [ "$(sha256 "$WORK/$FOLDER/cua-driver")" = "$BINARY_SHA" ] || { echo "cua-driver: the $ARCHIVE binary does not match its pin" >&2; exit 1; }
  [ "$(sha256 "$WORK/$FOLDER/LICENSE")" = "$LICENSE_SHA" ] || { echo "cua-driver: $ARCHIVE's LICENSE does not match its pin" >&2; exit 1; }
  [ "$(sha256 "$WORK/$FOLDER/THIRD_PARTY_NOTICES.md")" = "$NOTICES_SHA" ] || { echo "cua-driver: $ARCHIVE's THIRD_PARTY_NOTICES.md does not match its pin" >&2; exit 1; }
  STAGED+=("$NAME" "$WORK/$FOLDER/cua-driver")
done <<< "$BUILDS"
# Only after every fetched build checked out: none or all of what was fetched lands.
i=0
while [ "$i" -lt "${#STAGED[@]}" ]; do
  install -m 0755 "${STAGED[$((i + 1))]}" "$TARGET/${STAGED[$i]}"
  echo "cua-driver: Cua Driver $TAG staged in $TARGET as ${STAGED[$i]}"
  i=$((i + 2))
done
