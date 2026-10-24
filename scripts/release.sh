#!/bin/bash
# Publishes the version in Resources/Info.plist, if it has no release yet.
# CI runs this on every push to main (.github/workflows/release.yml), so
# merging a pull request that bumps the version (scripts/bump-version.sh)
# releases it. It also runs from a Mac with the signing keys in the login
# keychain.
#
#   scripts/release.sh            release notes from the commits since the last release
#   scripts/release.sh "notes"    release notes as given
#
# 1. Stops, successfully, when GitHub already has release v<version>.
# 2. Builds the Developer ID signed, notarized DMG (scripts/build-dmg.sh).
#    A release must be Developer ID signed: Sparkle replaces the app in
#    place, and the recovery agent only keeps trusting a bundle whose
#    signature it pinned by team, not by cdhash. The build number is the
#    commit count, or one more than the last release's if that is higher,
#    so it always goes up (Sparkle compares it).
# 3. Writes appcast.xml with Sparkle's generate_appcast, which signs the
#    DMG with the EdDSA key: the file INSOMNIA_SPARKLE_KEY_FILE names, or
#    the one in the login keychain.
# 4. Creates GitHub release v<version> on Aztriltus/Insomnia at this commit,
#    with the DMG and appcast.xml, marked Latest. The app reads
#    releases/latest/download/appcast.xml.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
repo="Aztriltus/Insomnia"
tools="$root/.build/artifacts/sparkle/Sparkle/bin"
cd "$root"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if gh release view "v$version" --repo "$repo" >/dev/null 2>&1; then
  echo "v$version is already released; bump the version to release (scripts/bump-version.sh)."
  exit 0
fi
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
commit="$(git rev-parse HEAD)"
git fetch -q --tags origin
[[ -n "$(git branch -r --contains "$commit")" ]] || { echo "Push this commit first; the release points at it." >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "No Developer ID Application identity in the keychain; a release must be signed with one." >&2; exit 1; }
[[ -x "$tools/generate_appcast" ]] || swift package resolve >/dev/null

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The last release's tag and build number, if there is one.
previous="$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null || true)"
last_build=0
if [[ -n "$previous" ]] && gh release download "$previous" --repo "$repo" --pattern appcast.xml -O "$work/previous.xml" 2>/dev/null; then
  last_build="$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$work/previous.xml" | head -n 1)"
fi
build="$(git rev-list --count HEAD)"
(( build > ${last_build:-0} )) || build=$(( ${last_build:-0} + 1 ))

# Release notes: as given, or the user-facing commit subjects since the last
# release (feat, fix, update, style and perf), without their type prefix.
if [[ -n "${1:-}" ]]; then
  printf '%s\n' "$1" > "$work/notes.txt"
else
  range="HEAD"
  [[ -n "$previous" ]] && git rev-parse -q --verify "$previous^{commit}" >/dev/null && range="$previous..HEAD"
  git log --no-merges --format=%s "$range" \
    | sed -n -E 's/^(feat|fix|update|style|perf)(\([^)]*\))?!?: *(.*)$/\3/p' \
    | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }' > "$work/notes.txt"
  [[ -s "$work/notes.txt" ]] || echo "Small fixes." > "$work/notes.txt"
fi
sed 's/^/- /' "$work/notes.txt" > "$work/notes.md"

echo "Releasing v$version, build $build, from $commit"
INSOMNIA_BUILD_NUMBER="$build" "$here/build-dmg.sh"
dmg="$root/dist/Insomnia-$version.dmg"

mkdir "$work/feed"
cp "$dmg" "$work/feed/"
python3 -I -c 'import html, sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
print("<ul>" + "".join("<li>%s</li>" % html.escape(l) for l in lines) + "</ul>")' "$work/notes.txt" > "$work/feed/Insomnia-$version.html"
key=()
[[ -n "${INSOMNIA_SPARKLE_KEY_FILE:-}" ]] && key=(--ed-key-file "$INSOMNIA_SPARKLE_KEY_FILE")
"$tools/generate_appcast" ${key[@]+"${key[@]}"} --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
  --embed-release-notes -o "$work/feed/appcast.xml" "$work/feed"

gh release create "v$version" "$dmg" "$work/feed/appcast.xml" --repo "$repo" --target "$commit" \
  --title "Insomnia $version" --notes-file "$work/notes.md" --latest
echo "Released v$version: https://github.com/$repo/releases/tag/v$version"
