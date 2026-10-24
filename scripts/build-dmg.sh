#!/bin/bash
# Builds dist/Insomnia-<version>.dmg for handing to other people.
#
# The disk image holds what the release zip holds (the app, install.sh and
# uninstall.sh) plus two double-clickable wrappers and a Read Me. Insomnia
# can't be installed by dragging it to Applications: install.sh writes the
# sudoers rule for its four pmset commands and loads the recovery agent.
#
# Signing: with a "Developer ID Application" identity in the keychain (or
# named by INSOMNIA_SIGN_IDENTITY), the app is signed with the hardened
# runtime, notarized and stapled, and so is the disk image. The notary
# credentials are a keychain profile, INSOMNIA_NOTARY_PROFILE (default
# "insomnia-notary"), stored once with:
#
#   xcrun notarytool store-credentials insomnia-notary \
#     --apple-id you@example.com --team-id TEAMID
#
# Without an identity the build is ad-hoc signed and not notarized, and
# macOS blocks the first run of the installer and of the app until the user
# allows each one; the Read Me says how.
#
#   scripts/build-dmg.sh            build the app, then the disk image
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
dist="$root/dist"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

identity="${INSOMNIA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}"
profile="${INSOMNIA_NOTARY_PROFILE:-insomnia-notary}"
if [[ -n "$identity" ]]; then
  echo "Signing with $identity; notarizing with the \"$profile\" keychain profile"
else
  echo "No Developer ID identity: ad-hoc signed, not notarized"
fi

# Submits $1 for notarization and staples the ticket to $2.
notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$profile" --wait
  xcrun stapler staple "$2"
}

INSOMNIA_SIGN_IDENTITY="$identity" "$here/build-app.sh" --output "$stage/build" >/dev/null
if [[ -n "$identity" ]]; then
  /usr/bin/ditto -c -k --keepParent "$stage/build/Insomnia.app" "$stage/app.zip"
  notarize "$stage/app.zip" "$stage/build/Insomnia.app"
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/build/Insomnia.app/Contents/Info.plist")"
volume="$stage/Insomnia"
mkdir -p "$volume" "$dist"

/usr/bin/ditto "$stage/build/Insomnia.app" "$volume/Insomnia.app"
cp "$here/install.sh" "$here/uninstall.sh" "$volume/"

cat > "$volume/Install Insomnia.command" <<'EOF'
#!/bin/bash
# Installs the Insomnia.app beside this file. Asks for your password once,
# for the sudoers rule that lets Insomnia turn sleep off and on.
cd "$(dirname "$0")" || exit 1
./install.sh --app ./Insomnia.app --allow-unverified-origin && open "$HOME/Applications/Insomnia.app"
EOF

cat > "$volume/Uninstall Insomnia.command" <<'EOF'
#!/bin/bash
# Removes Insomnia, its recovery agent and its sudoers rule. Add --purge to
# also remove its settings and logs.
cd "$(dirname "$0")" || exit 1
./uninstall.sh "$@"
EOF
chmod +x "$volume/Install Insomnia.command" "$volume/Uninstall Insomnia.command" "$volume/install.sh" "$volume/uninstall.sh"

cat > "$volume/Read Me.txt" <<EOF
Insomnia $version

Keeps your Mac awake, lid open or closed, for as long as you choose.
Needs macOS 26 or later on an Apple Silicon Mac.

To install
1. Double-click "Install Insomnia". If macOS says it can't open it, open
   System Settings > Privacy & Security, click Open Anyway, then
   double-click it again.
2. Enter your Mac password when Terminal asks. It's used once, to let
   Insomnia turn sleep off and on.
3. Insomnia opens as an eye in the menu bar. It updates itself from then
   on: Check for updates at the top of Settings, or automatically.

For hotspot backup, set System Settings > Wi-Fi > Ask to join hotspots to
Automatically.

To uninstall, double-click "Uninstall Insomnia".
EOF

out="$dist/Insomnia-$version.dmg"
rm -f "$out"
hdiutil create -quiet -volname "Insomnia $version" -srcfolder "$volume" -fs HFS+ -format UDZO "$out"
if [[ -n "$identity" ]]; then
  codesign --force --timestamp --sign "$identity" "$out"
  notarize "$out" "$out"
fi
shasum -a 256 "$out" | tee "$out.sha256"
echo "$out"
