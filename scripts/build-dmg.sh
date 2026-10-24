#!/bin/bash
# Builds dist/Insomnia-<version>.dmg for handing to other people.
#
# The disk image holds Insomnia.app and a shortcut to Applications, over a
# background asking the user to drag one onto the other
# (scripts/generate-dmg-background.swift). The app sets itself up the first
# time it opens (AppSetup). The window layout is written by dmgbuild,
# pinned below and installed into .build/dmgbuild, which writes Finder's
# layout file directly, so no Finder scripting is needed (CI has none).
#
# Signing: with a "Developer ID Application" identity in the keychain (or
# named by INSOMNIA_SIGN_IDENTITY), the app is signed with the hardened
# runtime, notarized and stapled, and so is the disk image. The notary
# credentials are an App Store Connect API key when INSOMNIA_NOTARY_KEY (the
# .p8 file), INSOMNIA_NOTARY_KEY_ID and INSOMNIA_NOTARY_ISSUER are set, as in
# CI; otherwise a keychain profile, INSOMNIA_NOTARY_PROFILE (default
# "insomnia-notary"), stored once with:
#
#   xcrun notarytool store-credentials insomnia-notary \
#     --apple-id you@example.com --team-id TEAMID
#
# Without an identity the build is ad-hoc signed and not notarized, and
# macOS blocks the app's first launch until the user allows it.
#
#   scripts/build-dmg.sh            build the app, then the disk image
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
dist="$root/dist"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

identity="${INSOMNIA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}"
# "-" forces an ad-hoc, unnotarized build, for checking the layout quickly.
[[ "$identity" == "-" ]] && identity=""
profile="${INSOMNIA_NOTARY_PROFILE:-insomnia-notary}"
if [[ -n "${INSOMNIA_NOTARY_KEY:-}" ]]; then
  notary=(--key "$INSOMNIA_NOTARY_KEY" --key-id "${INSOMNIA_NOTARY_KEY_ID:?}" --issuer "${INSOMNIA_NOTARY_ISSUER:?}")
  via="an App Store Connect API key"
else
  notary=(--keychain-profile "$profile")
  via="the \"$profile\" keychain profile"
fi
if [[ -n "$identity" ]]; then
  echo "Signing with $identity; notarizing with $via"
else
  echo "No Developer ID identity: ad-hoc signed, not notarized"
fi

# Submits $1 for notarization and staples the ticket to $2.
notarize() {
  xcrun notarytool submit "$1" "${notary[@]}" --wait
  xcrun stapler staple "$2"
}

INSOMNIA_SIGN_IDENTITY="$identity" "$here/build-app.sh" --output "$stage/build" >/dev/null
if [[ -n "$identity" ]]; then
  /usr/bin/ditto -c -k --keepParent "$stage/build/Insomnia.app" "$stage/app.zip"
  notarize "$stage/app.zip" "$stage/build/Insomnia.app"
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/build/Insomnia.app/Contents/Info.plist")"
mkdir -p "$dist"

# The background, drawn at 1x and 2x and combined so Retina screens get the sharp one.
swift "$here/generate-dmg-background.swift" "$stage"
tiffutil -cathidpicheck "$stage/background.png" "$stage/background@2x.png" -out "$stage/background.tiff" 2>/dev/null

dmgbuild_env="$root/.build/dmgbuild"
if [[ ! -x "$dmgbuild_env/bin/dmgbuild" ]]; then
  python3 -m venv "$dmgbuild_env"
  "$dmgbuild_env/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==1.6.7"
fi
cat > "$stage/layout.py" <<'EOF'
# dmgbuild settings: the app on the left, Applications on the right, at the
# centres scripts/generate-dmg-background.swift draws around.
app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]
format = "UDZO"
filesystem = "HFS+"
# The height includes the 32-point title bar above the 400-point background.
window_rect = ((200, 120), (640, 432))
icon_size = 128
text_size = 13
icon_locations = {"Insomnia.app": (180, 210), "Applications": (460, 210)}
hide_extensions = ["Insomnia.app"]
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
EOF

out="$dist/Insomnia-$version.dmg"
rm -f "$out"
"$dmgbuild_env/bin/dmgbuild" -s "$stage/layout.py" \
  -D app="$stage/build/Insomnia.app" -D icon="$root/Resources/AppIcon.icns" -D background="$stage/background.tiff" \
  "Insomnia $version" "$out" >/dev/null
if [[ -n "$identity" ]]; then
  codesign --force --timestamp --sign "$identity" "$out"
  notarize "$out" "$out"
fi
shasum -a 256 "$out" | tee "$out.sha256"
echo "$out"
