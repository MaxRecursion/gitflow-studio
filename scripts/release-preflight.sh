#!/bin/bash
# Read-only readiness check. Does not unlock keychains, contact Apple, or build.
set +x
set -euo pipefail

identity="${GITFLOW_SIGNING_IDENTITY:-}"
profile="${GITFLOW_NOTARY_PROFILE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) [[ $# -ge 2 ]] || exit 64; identity="$2"; shift 2 ;;
    --keychain-profile) [[ $# -ge 2 ]] || exit 64; profile="$2"; shift 2 ;;
    --help|-h)
      printf 'Usage: %s [--identity PUBLIC_CERTIFICATE_SHA1] [--keychain-profile PROFILE_NAME]\n' "$0"
      printf 'JSON on stdout. Exit 0: signing prerequisites selected; 2: not ready; 64: invalid usage. Credentials are never read or validated.\n'
      exit 0 ;;
    *) printf 'Unsupported option. Use --help.\n' >&2; exit 64 ;;
  esac
done
if [[ -n "$identity" && ! "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  printf 'Signing identity must be the public 40-character certificate SHA-1 from security find-identity.\n' >&2
  exit 64
fi
identity="$(printf '%s' "$identity" | tr '[:lower:]' '[:upper:]')"

temporary="$(mktemp -d "${TMPDIR:-/tmp}/gitflow-preflight.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
report="$temporary/report.plist"
/usr/bin/plutil -create xml1 "$report"
add() { /usr/bin/plutil -insert "$1" "$2" "$3" "$report"; }
add schema_version -integer 1
add checked_at_utc -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
add host_os -string "$(sw_vers -productVersion)"
developer_dir="$(xcode-select -p 2>/dev/null || true)"
add developer_directory -string "$developer_dir"
full_xcode=false
[[ "$developer_dir" == */Xcode*.app/Contents/Developer && -d "$developer_dir" ]] && full_xcode=true
add full_xcode_selected -bool "$full_xcode"
swift_available=false
/usr/bin/xcrun --find swift >/dev/null 2>&1 && swift_available=true
notary_available=false
/usr/bin/xcrun --find notarytool >/dev/null 2>&1 && notary_available=true
stapler_available=false
/usr/bin/xcrun --find stapler >/dev/null 2>&1 && stapler_available=true
add swift_available -bool "$swift_available"
add notarytool_available -bool "$notary_available"
add stapler_available -bool "$stapler_available"

# Certificate fingerprints and display names are public metadata. Never query private-key data.
identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
candidates="$(printf '%s\n' "$identities" | awk '/"Developer ID Application:/ { print toupper($2) }')"
count="$(printf '%s\n' "$candidates" | awk 'NF { n++ } END { print n+0 }')"
selected=false
if [[ -n "$identity" ]] && printf '%s\n' "$candidates" | /usr/bin/grep -Fxq "$identity"; then selected=true; fi
add developer_id_application_count -integer "$count"
add selected_identity_available -bool "$selected"
add selected_public_certificate_sha1 -string "$identity"
profile_provided=false
[[ -n "$profile" ]] && profile_provided=true
add keychain_profile_provided -bool "$profile_provided"
add credentials_validated -bool false
add contacted_apple -bool false
ready=false
[[ "$swift_available" == true && "$selected" == true && "$notary_available" == true && "$stapler_available" == true ]] && ready=true
add ready_to_prepare_developer_id -bool "$ready"
add app_store_ready -bool false
add app_store_blocker -string 'Current application is unsandboxed and depends on installed Git and external repository/authentication infrastructure. A separate reviewed sandbox architecture, team, provisioning, and App Store Connect submission are required.'
add readiness_scope -string 'Local tool and certificate selection only. No private-key access/signing test, credential validation, Apple account action, notarization, or App Store verification was performed.'
/usr/bin/plutil -insert blockers -array "$report"
index=0
blocker() { /usr/bin/plutil -insert "blockers.$index" -string "$1" "$report"; index=$((index + 1)); }
[[ "$swift_available" == true ]] || blocker 'Swift toolchain unavailable.'
[[ "$notary_available" == true ]] || blocker 'notarytool unavailable.'
[[ "$stapler_available" == true ]] || blocker 'stapler unavailable.'
if [[ "$count" == 0 ]]; then blocker 'No valid Developer ID Application signing identity is installed.'
elif [[ "$selected" != true ]]; then blocker 'Select an installed Developer ID Application identity by its public certificate SHA-1.'; fi
[[ "$profile_provided" == true ]] || blocker 'No Keychain notarization profile selected; required only for explicit submit/resume.'
/usr/bin/plutil -convert json -o - "$report"
printf '\n'
[[ "$ready" == true ]] || exit 2
