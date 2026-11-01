#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${CONFIGURATION:-release}"
build_arguments=(--build-system native --configuration "$configuration")
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  build_arguments+=(--arch arm64 --arch x86_64)
fi
swift build "${build_arguments[@]}" --product GitFlowStudio
binary_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"
app_directory="$project_root/build/GitFlow Studio.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$binary_directory/GitFlowStudio" "$app_directory/Contents/MacOS/GitFlowStudio"
cp "$project_root/Resources/Info.plist" "$app_directory/Contents/Info.plist"
cp "$project_root/Resources/PrivacyInfo.xcprivacy" "$app_directory/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$project_root/Resources/AppIcon.icns" "$app_directory/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --timestamp=none "$app_directory"
/usr/bin/codesign --verify --strict "$app_directory"
printf 'Built %s\n' "$app_directory"
if [[ "${1:-}" == "--open" ]]; then
  open "$app_directory"
fi
