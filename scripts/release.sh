#!/bin/bash
# Local preparation never submits. Only the explicit submit/resume commands contact Apple.
set +x
set -euo pipefail
umask 077

project_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-help}"
[[ $# -gt 0 ]] && shift
identity="${GITFLOW_SIGNING_IDENTITY:-}"
profile="${GITFLOW_NOTARY_PROFILE:-}"
output=""
release_dir=""
existing_app=""
universal=1
usage() {
  cat <<'USAGE'
Usage:
  release.sh preview [--app EXISTING_APP] [--output NEW_DIRECTORY] [--arm64-only]
  release.sh prepare --identity PUBLIC_CERTIFICATE_SHA1 [--output NEW_DIRECTORY] [--arm64-only]
  release.sh submit --release-dir DIRECTORY --keychain-profile PROFILE_NAME
  release.sh resume --release-dir DIRECTORY --keychain-profile PROFILE_NAME
  release.sh verify --release-dir DIRECTORY

preview: local ad hoc app/ZIP, manifest, checksums, and signing-readiness evidence; never notarized.
prepare: run tests, build, Developer ID sign with hardened runtime/timestamp, prepare a submission ZIP.
submit: explicitly upload the prepared ZIP to Apple, wait, staple, verify, and package final deliverables.
resume: wait for the recorded submission without re-uploading; finish accepted artifacts.
verify: verify the final ZIP, ticket, signature, and Gatekeeper assessment.

Identity fingerprints and profile names are public identifiers, not passwords.
GITFLOW_SIGNING_IDENTITY / GITFLOW_NOTARY_PROFILE can supply these identifiers.
No Apple ID, password, API private key, or credential flags are accepted.
USAGE
}
fail() { printf 'Release stopped: %s\n' "$1" >&2; exit 1; }
[[ "$mode" == help || "$mode" == --help || "$mode" == -h ]] && { usage; exit 0; }
case "$mode" in preview|prepare|submit|resume|verify) ;; *) usage >&2; exit 64 ;; esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) [[ $# -ge 2 ]] || exit 64; identity="$2"; shift 2 ;;
    --keychain-profile) [[ $# -ge 2 ]] || exit 64; profile="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || exit 64; output="$2"; shift 2 ;;
    --release-dir) [[ $# -ge 2 ]] || exit 64; release_dir="$2"; shift 2 ;;
    --app) [[ $# -ge 2 ]] || exit 64; existing_app="$2"; shift 2 ;;
    --arm64-only) universal=0; shift ;;
    *) printf 'Unsupported option. Use --help.\n' >&2; exit 64 ;;
  esac
done
[[ "$mode" == preview || -z "$existing_app" ]] || fail '--app is allowed only for local preview packaging.'
if [[ "$mode" == submit || "$mode" == resume || "$mode" == verify ]]; then
  [[ -n "$release_dir" && -d "$release_dir" ]] || fail 'Select an existing release directory.'
  [[ -z "$output" && -z "$existing_app" ]] || fail 'Submission/verification accepts a release directory and profile, not preparation inputs.'
  release_dir="$(cd "$release_dir" && pwd)"
else
  [[ -z "$release_dir" ]] || fail '--release-dir is only for submit/resume/verify.'
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/gitflow-release.XXXXXX")"
pending_final=""
trap 'rm -rf "$scratch"; if [[ -n "$pending_final" ]]; then rm -rf "$pending_final"; fi' EXIT
get() { /usr/bin/plutil -extract "$2" raw -o - "$1"; }
sha() { /usr/bin/shasum -a 256 "$1" | awk '{ print $1 }'; }
new_manifest() { /usr/bin/plutil -create xml1 "$scratch/manifest.plist"; }
field() { /usr/bin/plutil -insert "$1" "$2" "$3" "$scratch/manifest.plist"; }
write_manifest() { /usr/bin/plutil -convert json -o "$release_dir/manifest.json" "$scratch/manifest.plist"; }
verify_developer_signature() {
  local app="$1"
  /usr/bin/codesign --verify --strict --all-architectures --verbose=2 "$app"
  /usr/bin/codesign --verify --test-requirement 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
  /usr/bin/codesign -dv --verbose=4 "$app" 2> "$scratch/signature.txt"
  /usr/bin/grep -q '^Authority=Developer ID Application:' "$scratch/signature.txt" || fail 'The app is not signed with Developer ID Application.'
  /usr/bin/grep -Eq '^flags=.*runtime|^CodeDirectory .*flags=.*runtime' "$scratch/signature.txt" || fail 'Hardened runtime is missing.'
  /usr/bin/grep -q '^Timestamp=' "$scratch/signature.txt" || fail 'A secure signing timestamp is missing.'
  /usr/bin/codesign -d --entitlements :- "$app" > "$scratch/entitlements.plist" 2>/dev/null
  if [[ -s "$scratch/entitlements.plist" ]]; then
    local debug_entitlement
    debug_entitlement="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$scratch/entitlements.plist" 2>/dev/null || true)"
    [[ "$debug_entitlement" != true ]] || fail 'Debug get-task-allow entitlement is prohibited in a release.'
  fi
}
validate_single_app() {
  local app="$1"
  [[ -d "$app" && -f "$app/Contents/Info.plist" ]] || fail 'Expected a native app bundle.'
  [[ "$(get "$app/Contents/Info.plist" CFBundleIdentifier)" == studio.gitflow.mac ]] || fail 'Unexpected app bundle identifier.'
  [[ "$(get "$app/Contents/Info.plist" CFBundleExecutable)" == GitFlowStudio ]] || fail 'Unexpected app executable.'
  [[ -x "$app/Contents/MacOS/GitFlowStudio" ]] || fail 'App executable is missing.'
  # Fail closed if future changes add nested code requiring a dedicated inside-out signing plan.
  local nested file_kind
  nested="$(find "$app/Contents" -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' \) -print -quit)"
  [[ -z "$nested" ]] || fail 'Nested code detected; extend the release signing plan before shipping.'
  while IFS= read -r -d '' item; do
    [[ "$item" == "$app/Contents/MacOS/GitFlowStudio" ]] && continue
    file_kind="$(/usr/bin/file -b "$item")"
    [[ "$file_kind" != *Mach-O* ]] || fail 'Additional Mach-O code detected; extend the release signing plan before shipping.'
  done < <(find "$app/Contents" -type f -print0)
}
verify_final() {
  local final_directory="${1:-$release_dir/final}"
  [[ -f "$final_directory/manifest.json" ]] || fail 'No completed notarized release exists here.'
  [[ "$(get "$final_directory/manifest.json" state)" == notarized ]] || fail 'Final manifest does not record notarization.'
  local final_zip archive_name extract_root
  archive_name="$(get "$final_directory/manifest.json" archive)"
  [[ "$archive_name" =~ ^GitFlowStudio-[0-9.]+-[0-9.]+\.zip$ ]] || fail 'Unexpected final archive name.'
  final_zip="$final_directory/$archive_name"
  [[ -f "$final_zip" && "$(sha "$final_zip")" == "$(get "$final_directory/manifest.json" sha256)" ]] || fail 'Final archive checksum does not match.'
  extract_root="$(mktemp -d "$scratch/verified.XXXXXX")"
  /usr/bin/ditto -x -k "$final_zip" "$extract_root"
  local app="$extract_root/GitFlow Studio.app"
  validate_single_app "$app"
  verify_developer_signature "$app"
  /usr/bin/xcrun stapler validate "$app"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
  printf 'Verified notarized archive: %s\n' "$final_zip"
}
finish_accepted() {
  [[ "$(get "$1" status)" == Accepted ]] || fail 'Apple has not accepted this submission; no distributable artifact was produced.'
  [[ ! -e "$release_dir/final" ]] || { verify_final; return; }
  # Extract the exact checksum-validated submission, not a potentially edited loose app.
  mkdir "$scratch/notarized"
  pending_final="$(mktemp -d "$release_dir/.final-staging.XXXXXX")"
  /usr/bin/ditto -x -k "$release_dir/submission.zip" "$scratch/notarized"
  local app="$scratch/notarized/GitFlow Studio.app"
  validate_single_app "$app"
  verify_developer_signature "$app"
  /usr/bin/xcrun stapler staple "$app"
  /usr/bin/xcrun stapler validate "$app"
  /usr/bin/codesign --verify --strict --all-architectures "$app"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
  local name="GitFlowStudio-$(get "$release_dir/manifest.json" version)-$(get "$release_dir/manifest.json" build).zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$pending_final/$name"
  /usr/bin/plutil -create xml1 "$pending_final/manifest.plist"
  /usr/bin/plutil -insert state -string notarized "$pending_final/manifest.plist"
  /usr/bin/plutil -insert archive -string "$name" "$pending_final/manifest.plist"
  /usr/bin/plutil -insert sha256 -string "$(sha "$pending_final/$name")" "$pending_final/manifest.plist"
  /usr/bin/plutil -insert submission_id -string "$(get "$1" id)" "$pending_final/manifest.plist"
  /usr/bin/plutil -insert completed_at_utc -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$pending_final/manifest.plist"
  /usr/bin/plutil -convert json -o "$pending_final/manifest.json" "$pending_final/manifest.plist"
  rm "$pending_final/manifest.plist"
  (cd "$pending_final" && /usr/bin/shasum -a 256 "$name" > SHA256SUMS)
  verify_final "$pending_final"
  mv "$pending_final" "$release_dir/final"
  pending_final=""
  printf 'Only files in %s/final are intended for direct distribution. Nothing has been published.\n' "$release_dir"
}

if [[ "$mode" == verify ]]; then verify_final; exit 0; fi
if [[ "$mode" == submit || "$mode" == resume ]]; then
  [[ -n "$profile" ]] || fail 'Supply an existing Keychain profile name; credential values are not accepted.'
  /usr/bin/xcrun --find notarytool >/dev/null 2>&1 || fail 'notarytool is unavailable.'
  /usr/bin/xcrun --find stapler >/dev/null 2>&1 || fail 'stapler is unavailable.'
  [[ -f "$release_dir/manifest.json" ]] || fail 'Preparation manifest is missing.'
  [[ "$(get "$release_dir/manifest.json" state)" == developer_id_prepared ]] || fail 'Only Developer ID prepared releases may be submitted. Preview archives cannot be notarized by this pipeline.'
  [[ -f "$release_dir/submission.zip" && "$(sha "$release_dir/submission.zip")" == "$(get "$release_dir/manifest.json" submission_sha256)" ]] || fail 'Submission archive checksum does not match.'
  if [[ "$mode" == submit ]]; then
    [[ ! -e "$release_dir/submission.started" ]] || fail 'A submission was already attempted. Use resume; do not upload again.'
    mkdir "$scratch/pre-submit"
    /usr/bin/ditto -x -k "$release_dir/submission.zip" "$scratch/pre-submit"
    validate_single_app "$scratch/pre-submit/GitFlow Studio.app"
    verify_developer_signature "$scratch/pre-submit/GitFlow Studio.app"
    (set -o noclobber; date -u '+%Y-%m-%dT%H:%M:%SZ' > "$release_dir/submission.started")
    # The explicit submit command is the upload boundary. No --force or credential flags.
    if ! /usr/bin/xcrun notarytool submit "$release_dir/submission.zip" --keychain-profile "$profile" --wait --timeout 30m --output-format json > "$release_dir/submission.json"; then
      fail 'Notarization did not complete. The attempt is recorded; inspect its receipt and use resume if an ID was returned. Do not delete the attempt marker or blindly resubmit.'
    fi
    finish_accepted "$release_dir/submission.json"
  else
    [[ -s "$release_dir/submission.json" ]] || fail 'No submission receipt exists. Recover the exact submission from Apple before retrying; the pipeline will not guess or upload a duplicate.'
    submission_id="$(get "$release_dir/submission.json" id)"
    [[ "$submission_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || fail 'Submission receipt has no valid ID.'
    if ! /usr/bin/xcrun notarytool wait "$submission_id" --keychain-profile "$profile" --timeout 30m --output-format json > "$release_dir/submission-resumed.json"; then
      fail 'The recorded submission has not completed successfully. No duplicate upload was made.'
    fi
    finish_accepted "$release_dir/submission-resumed.json"
  fi
  exit 0
fi

[[ -n "$output" ]] || output="$project_root/build/releases/$(date -u '+%Y%m%dT%H%M%SZ')-$mode"
[[ ! -e "$output" ]] || fail 'Output directory already exists. Choose a new directory; releases are never overwritten.'
mkdir -p "$output"
release_dir="$(cd "$output" && pwd)"
preflight_result=0
"$project_root/scripts/release-preflight.sh" --identity "$identity" --keychain-profile "$profile" > "$release_dir/preflight.json" || preflight_result=$?
[[ "$preflight_result" == 0 || "$preflight_result" == 2 ]] || fail 'Preflight could not run; no artifact was prepared.'
if [[ "$mode" == prepare ]]; then
  [[ "$preflight_result" == 0 ]] || fail 'Developer ID signing prerequisites are not ready. Read preflight.json; no build or upload occurred.'
  "$project_root/scripts/test.sh"
fi
if [[ -z "$existing_app" ]]; then
  CONFIGURATION=release UNIVERSAL="$universal" "$project_root/scripts/build-app.sh"
  existing_app="$project_root/build/GitFlow Studio.app"
fi
[[ -d "$existing_app" ]] || fail 'The requested app bundle does not exist.'
validate_single_app "$existing_app"
app="$release_dir/GitFlow Studio.app"
/usr/bin/ditto "$existing_app" "$app"
version="$(get "$app/Contents/Info.plist" CFBundleShortVersionString)"
build="$(get "$app/Contents/Info.plist" CFBundleVersion)"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ && "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail 'Release version/build must be numeric dotted versions.'
architectures="$(/usr/bin/lipo -archs "$app/Contents/MacOS/GitFlowStudio")"
if [[ "$mode" == prepare && "$universal" == 1 ]]; then
  [[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] || fail 'Universal release requested, but both architectures are not present.'
fi
new_manifest
field schema_version -integer 1
field created_at_utc -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
field bundle_identifier -string studio.gitflow.mac
field version -string "$version"
field build -string "$build"
field architectures -string "$architectures"
field host_os -string "$(sw_vers -productVersion)"
field source_revision -string "$(git -C "$project_root" rev-parse HEAD 2>/dev/null || printf 'unversioned-workspace')"
field notarized -bool false
field published -bool false
field app_store_ready -bool false
if [[ "$mode" == preview ]]; then
  /usr/bin/codesign --force --sign - --timestamp=none "$app"
  /usr/bin/codesign --verify --strict --all-architectures "$app"
  archive="GitFlowStudio-$version-$build-preview.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$release_dir/$archive"
  field state -string local_preview
  field signature -string ad_hoc
  field archive -string "$archive"
  field sha256 -string "$(sha "$release_dir/$archive")"
  field tests_run_by_this_invocation -bool false
  write_manifest
  (cd "$release_dir" && /usr/bin/shasum -a 256 "$archive" > SHA256SUMS)
  printf 'Local preview prepared: %s\nAd hoc signed only; NOT Developer ID signed, notarized, or App Store ready.\n' "$release_dir/$archive"
else
  /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp "$app"
  verify_developer_signature "$app"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$release_dir/submission.zip"
  field state -string developer_id_prepared
  field signature -string developer_id_application
  field public_certificate_sha1 -string "$identity"
  field submission_sha256 -string "$(sha "$release_dir/submission.zip")"
  field tests_run_by_this_invocation -bool true
  write_manifest
  (cd "$release_dir" && /usr/bin/shasum -a 256 submission.zip > SHA256SUMS)
  printf 'Developer ID preparation complete: %s\nNotarization has NOT been submitted. Use the separate submit command only when explicitly authorized.\n' "$release_dir"
fi
