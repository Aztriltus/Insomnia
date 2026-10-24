#!/bin/bash
# Gives GitHub Actions what scripts/release.sh needs to publish a release,
# as secrets of a "release" environment that only main may use. Run it once
# from this Mac, and again when a key changes:
#
#   scripts/setup-release-secrets.sh path/to/AuthKey_XXXXXXXXXX.p8 KEY_ID ISSUER_ID
#
# The .p8 file, key ID and issuer ID come from an App Store Connect API key
# (App Store Connect > Users and Access > Integrations > Team Keys, access
# "Developer"), which notarytool uses in place of your Apple ID.
#
# It reads, from the login keychain, the "Developer ID Application" identity
# and Sparkle's EdDSA private key; macOS asks you to allow each export. They
# go straight to GitHub and are deleted from disk when it finishes. Nothing
# is printed.
set -euo pipefail

key_file="${1:?usage: scripts/setup-release-secrets.sh <AuthKey.p8> <key ID> <issuer ID>}"
key_id="${2:?missing the key ID}"
issuer="${3:?missing the issuer ID}"
repo="Aztriltus/Insomnia"
env="release"
root="$(cd "$(dirname "$0")/.." && pwd)"
tools="$root/.build/artifacts/sparkle/Sparkle/bin"

[[ -r "$key_file" ]] || { echo "Can't read $key_file." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login" >&2; exit 1; }
identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
[[ -n "$identity" ]] || { echo "No Developer ID Application identity in the keychain." >&2; exit 1; }
[[ -x "$tools/generate_keys" ]] || (cd "$root" && swift package resolve >/dev/null)

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "1/4 Creating the \"$env\" environment, limited to main"
gh api -X PUT "repos/$repo/environments/$env" --input - >/dev/null <<'EOF'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
gh api -X POST "repos/$repo/environments/$env/deployment-branch-policies" -f name=main -f type=branch >/dev/null 2>&1 || true

echo "2/4 Exporting \"$identity\" (macOS asks you to allow it)"
cat > "$work/export.swift" <<'EOF'
import Foundation
import Security

// Exports the one identity whose certificate is named argv[1] as PKCS#12,
// protected by the passphrase in P12_PASSWORD, to argv[2].
let name = CommandLine.arguments[1]
let passphrase = ProcessInfo.processInfo.environment["P12_PASSWORD"]! as CFString
var found: CFTypeRef?
let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let identities = found as? [SecIdentity] else { exit(1) }
let identity = identities.first { identity in
    var certificate: SecCertificate?
    SecIdentityCopyCertificate(identity, &certificate)
    return certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } == name
}
guard let identity else { exit(2) }
var parameters = SecItemImportExportKeyParameters(
    version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION), flags: [], passphrase: Unmanaged.passUnretained(passphrase),
    alertTitle: nil, alertPrompt: nil, accessRef: nil, keyUsage: nil, keyAttributes: nil)
var data: CFData?
guard SecItemExport(identity, .formatPKCS12, [], &parameters, &data) == errSecSuccess, let data else { exit(3) }
try (data as Data).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
EOF
p12_password="$(openssl rand -base64 24)"
P12_PASSWORD="$p12_password" swift "$work/export.swift" "$identity" "$work/id.p12"

echo "3/4 Exporting Sparkle's update-signing key (macOS asks you to allow it)"
"$tools/generate_keys" -x "$work/sparkle.key" >/dev/null

echo "4/4 Saving the secrets to $repo ($env)"
set_secret() { gh secret set "$1" --repo "$repo" --env "$env" >/dev/null; }
base64 -i "$work/id.p12" | set_secret DEVELOPER_ID_P12
printf '%s' "$p12_password" | set_secret DEVELOPER_ID_P12_PASSWORD
set_secret NOTARY_KEY < "$key_file"
printf '%s' "$key_id" | set_secret NOTARY_KEY_ID
printf '%s' "$issuer" | set_secret NOTARY_ISSUER_ID
set_secret SPARKLE_PRIVATE_KEY < "$work/sparkle.key"
gh secret list --repo "$repo" --env "$env"
echo "Done. Merging a version bump into main now publishes a release."
