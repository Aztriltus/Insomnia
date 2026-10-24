#!/bin/bash
# Publishes a release that installed copies update to on their own.
#
#   scripts/release.sh 0.2.0 "What changed, in a sentence or two."
#
# 1. Sets the version in Resources/Info.plist (build number = commit count)
#    and commits it.
# 2. Builds the Developer ID signed, notarized DMG (scripts/build-dmg.sh).
#    A release must be Developer ID signed: Sparkle replaces the app in
#    place, and the recovery agent only keeps trusting a bundle whose
#    signature it pinned by team, not by cdhash.
# 3. Writes appcast.xml with Sparkle's generate_appcast, which signs the
#    DMG with the EdDSA key in your login keychain.
# 4. Pushes the branch and creates GitHub release v<version> on
#    Aztriltus/Insomnia with the DMG and appcast.xml, marked Latest. The app
#    reads releases/latest/download/appcast.xml.
set -euo pipefail

version="${1:?usage: scripts/release.sh <version> [notes]}"
notes="${2:-Insomnia $version}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
repo="Aztriltus/Insomnia"
plist="$root/Resources/Info.plist"
tools="$root/.build/artifacts/sparkle/Sparkle/bin"

cd "$root"
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "No Developer ID Application identity in the keychain; a release must be signed with one." >&2; exit 1; }
[[ -x "$tools/generate_appcast" ]] || swift package resolve >/dev/null

build="$(git rev-list --count HEAD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $((build + 1))" "$plist"
git commit -q -m "chore: release $version" -- "$plist"

"$here/build-dmg.sh"
dmg="$root/dist/Insomnia-$version.dmg"
feed="$(mktemp -d)"
trap 'rm -rf "$feed"' EXIT
cp "$dmg" "$feed/"
printf '<p>%s</p>\n' "$notes" > "$feed/Insomnia-$version.html"
"$tools/generate_appcast" --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
  --embed-release-notes -o "$feed/appcast.xml" "$feed"

branch="$(git branch --show-current)"
git push -q origin "$branch"
gh release create "v$version" "$dmg" "$feed/appcast.xml" --repo "$repo" --target "$branch" \
  --title "Insomnia $version" --notes "$notes" --latest
echo "Released v$version: https://github.com/$repo/releases/tag/v$version"
