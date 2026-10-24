#!/bin/bash
# Sets the version in Resources/Info.plist. Commit it in a pull request;
# merging that pull request into main releases it (scripts/release.sh).
#
#   scripts/bump-version.sh 0.3.0
set -euo pipefail

version="${1:?usage: scripts/bump-version.sh <major.minor.patch>}"
plist="$(cd "$(dirname "$0")/.." && pwd)/Resources/Info.plist"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Use major.minor.patch, like 0.3.0." >&2; exit 1; }
current="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
newest="$(printf '%s\n%s\n' "$current" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
[[ "$version" != "$current" && "$newest" == "$version" ]] || { echo "$version isn't newer than $current." >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
echo "Version $current -> $version. Commit Resources/Info.plist; merging it into main releases it."
