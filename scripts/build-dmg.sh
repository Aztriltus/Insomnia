#!/bin/bash
# Builds dist/Insomnia-<version>.dmg for handing to other people.
#
# The disk image holds what the release zip holds (the app, install.sh and
# uninstall.sh) plus two double-clickable wrappers and a Read Me. Insomnia
# can't be installed by dragging it to Applications: install.sh writes the
# sudoers rule for its four pmset commands and loads the recovery agent.
#
# The app is ad-hoc signed and not notarized, so macOS blocks the first run
# of the installer and of the app until the user allows each one; the Read
# Me says how.
#
#   scripts/build-dmg.sh            build the app, then the disk image
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
dist="$root/dist"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

"$here/build-app.sh" --output "$stage/build" >/dev/null
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
1. Double-click "Install Insomnia". If macOS says it can't verify the
   developer, open System Settings > Privacy & Security, click Open Anyway,
   then double-click it again.
2. Enter your Mac password when Terminal asks. It's used once, to let
   Insomnia turn sleep off and on.
3. Insomnia opens as an eye in the menu bar. If macOS blocks it the first
   time, allow it in Privacy & Security the same way.

For hotspot backup, set System Settings > Wi-Fi > Ask to join hotspots to
Automatically.

To uninstall, double-click "Uninstall Insomnia".
EOF

out="$dist/Insomnia-$version.dmg"
rm -f "$out"
hdiutil create -quiet -volname "Insomnia $version" -srcfolder "$volume" -fs HFS+ -format UDZO "$out"
shasum -a 256 "$out" | tee "$out.sha256"
echo "$out"
