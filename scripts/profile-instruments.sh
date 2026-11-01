#!/bin/bash
set -euo pipefail
# An explicit attach target avoids launching or changing a user's repository.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 1 || ! "$1" =~ ^[0-9]+$ ]]; then
  echo 'Usage: scripts/profile-instruments.sh PID [Time Profiler|Allocations|Points of Interest] [seconds (1..60)]' >&2
  exit 64
fi
profile_pid="$1"
profile_template="${2:-Time Profiler}"
profile_seconds="${3:-30}"
if [[ ! "$profile_seconds" =~ ^[0-9]+$ ]] || (( profile_seconds < 1 || profile_seconds > 60 )); then
  echo 'Choose a duration from 1 to 60 seconds.' >&2; exit 64
fi
case "$profile_template" in 'Time Profiler'|'Allocations'|'Points of Interest') ;; *) echo 'Unsupported profiling template.' >&2; exit 64;; esac
if ! profile_tool="$(xcrun --find xctrace 2>/dev/null)"; then
  echo 'BLOCKED: xctrace is unavailable. Install full Xcode and select its Developer directory. No Instruments trace was recorded.' >&2
  exit 69
fi
kill -0 "$profile_pid" 2>/dev/null || { echo 'The target process is not running.' >&2; exit 66; }
profile_label="${profile_template// /-}"
profile_directory="$project_root/build/profiles/$(date -u +%Y%m%dT%H%M%SZ)-$profile_pid-$profile_label"
mkdir -p "$profile_directory"
/usr/bin/sw_vers > "$profile_directory/environment.txt"
/usr/bin/uname -m >> "$profile_directory/environment.txt"
/usr/sbin/sysctl hw.model hw.memsize hw.logicalcpu >> "$profile_directory/environment.txt"
xcodebuild -version >> "$profile_directory/environment.txt"
/bin/ps -p "$profile_pid" -o pid=,comm= >> "$profile_directory/environment.txt"
if [[ -f "$project_root/build/GitFlow Studio.app/Contents/MacOS/GitFlowStudio" ]]; then
  shasum -a 256 "$project_root/build/GitFlow Studio.app/Contents/MacOS/GitFlowStudio" > "$profile_directory/build-sha256.txt"
fi
"$profile_tool" record --template "$profile_template" --attach "$profile_pid" --time-limit "${profile_seconds}s" --output "$profile_directory/capture.trace"
"$profile_tool" export --input "$profile_directory/capture.trace" --toc --output "$profile_directory/table-of-contents.xml"
printf 'Recorded %s\nInspect the trace in Instruments; the script does not infer performance acceptance.\n' "$profile_directory"
