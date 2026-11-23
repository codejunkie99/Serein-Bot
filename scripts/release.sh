#!/bin/bash
# Ships a new Serein Free: scripts/release.sh [patch|minor|major|X.Y.Z] (default patch).
# Bumps VERSION, builds the notarized universal app, checks the archive, signs it with Sparkle's
# update key, then commits, tags, pushes and publishes a GitHub release carrying the zip and
# appcast.xml. Installed copies read releases/latest/download/appcast.xml, so the new release is
# the update they find. Nothing is pushed if a step fails. Needs the Developer ID certificate and
# notary profile scripts/build.sh uses, the update key (login keychain account "serein", or
# SPARKLE_PRIVATE_KEY), and a gh login with write access to the repository.
set -euo pipefail
cd "$(dirname "$0")/.."
GITHUB_REPO="${SEREIN_GITHUB_REPO:-codejunkie99/Serein-Bot}"
ZIP=dist/Serein-Free-macOS-universal.zip
die() { echo "release: $*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || die "commit or stash your changes first."
BRANCH="$(git branch --show-current)"
[ "$BRANCH" = main ] || [ "${SEREIN_ALLOW_BRANCH:-0}" = 1 ] || die "release from main (or set SEREIN_ALLOW_BRANCH=1)."
git fetch -q origin "$BRANCH"
git merge-base --is-ancestor "origin/$BRANCH" HEAD || die "$BRANCH is behind origin; pull first."
gh auth status >/dev/null 2>&1 || die "log in with gh auth login first."

CURRENT="$(tr -d '[:space:]' < VERSION)"
IFS=. read -r MAJOR MINOR PATCH <<< "$CURRENT"
case "${1:-patch}" in
  patch) NEXT="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  minor) NEXT="$MAJOR.$((MINOR + 1)).0" ;;
  major) NEXT="$((MAJOR + 1)).0.0" ;;
  [0-9]*.[0-9]*.[0-9]*) NEXT="$1" ;;
  *) die "usage: scripts/release.sh [patch|minor|major|X.Y.Z]" ;;
esac
git rev-parse -q --verify "refs/tags/v$NEXT" >/dev/null && die "tag v$NEXT already exists."
echo "Releasing Serein Free $NEXT (repo $CURRENT) from $BRANCH to $GITHUB_REPO"

trap 'git checkout -q -- VERSION 2>/dev/null || true' EXIT
echo "$NEXT" > VERSION

echo "== Notarized app"
SEREIN_NOTARIZE=1 bash scripts/build.sh
python3 scripts/verify_package.py --archive "$ZIP"

PLIST=dist/Serein.app/Contents/Info.plist
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST" >/dev/null 2>&1 || die "the built app has no update feed."

echo "== Update signature"
SIGN=.build/artifacts/sparkle/Sparkle/bin/sign_update
# Prints sparkle:edSignature="…" length="…" for the enclosure.
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  ENCLOSURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - "$ZIP")"
else
  ENCLOSURE="$("$SIGN" --account serein "$ZIP")"
fi
[[ $ENCLOSURE == *edSignature=* ]] || die "the update signature is empty: the update key was not found."
APPCAST="$(mktemp -d)/appcast.xml"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Serein Free</title>
    <link>https://github.com/$GITHUB_REPO</link>
    <item>
      <title>Serein Free $NEXT</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <link>https://github.com/$GITHUB_REPO/releases/tag/v$NEXT</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$NEXT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/$GITHUB_REPO/releases/download/v$NEXT/$(basename "$ZIP")" type="application/octet-stream" $ENCLOSURE />
    </item>
  </channel>
</rss>
XML

echo "== Commit, tag, push and publish"
trap - EXIT
git commit -q -m "Release Serein Free $NEXT." VERSION
git tag -a "v$NEXT" -m "Serein Free $NEXT"
git push -q origin "$BRANCH" "v$NEXT"
gh release create "v$NEXT" "$ZIP" "$APPCAST" -R "$GITHUB_REPO" --title "Serein Free $NEXT" --generate-notes --latest >/dev/null
SERVED="$(curl -fsSL -m 30 "https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml" || true)"
printf '%s' "$SERVED" | grep -q "<sparkle:shortVersionString>$NEXT</sparkle:shortVersionString>" \
  || echo "release: the latest appcast.xml does not offer $NEXT yet. While the repository is private, installed copies cannot read it." >&2
echo "Serein Free $NEXT is published: https://github.com/$GITHUB_REPO/releases/tag/v$NEXT"
