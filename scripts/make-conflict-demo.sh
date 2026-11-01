#!/bin/bash
set -euo pipefail

# Every operation is confined to a newly created temporary directory.
demo_directory="$(mktemp -d "${TMPDIR:-/tmp}/gitflow-demo.XXXXXX")"
git -C "$demo_directory" init -b main --quiet
git -C "$demo_directory" config user.name "GitFlow Demo"
git -C "$demo_directory" config user.email "demo@example.invalid"
git -C "$demo_directory" config commit.gpgSign false
git -C "$demo_directory" config core.hooksPath /dev/null
cat > "$demo_directory/Settings.swift" <<'SWIFT'
struct Settings {
    let timeout = 30
    let retries = 3
    let environment = "development"
}
SWIFT
git -C "$demo_directory" add -- Settings.swift
git -C "$demo_directory" commit -qm "Add connection settings"
git -C "$demo_directory" switch -qc incoming
cat > "$demo_directory/Settings.swift" <<'SWIFT'
struct Settings {
    let timeout = 60
    let retries = 3
    let environment = "production"
}
SWIFT
git -C "$demo_directory" commit -qam "Prepare production settings"
git -C "$demo_directory" switch -q main
cat > "$demo_directory/Settings.swift" <<'SWIFT'
struct Settings {
    let timeout = 15
    let retries = 5
    let environment = "development"
}
SWIFT
git -C "$demo_directory" commit -qam "Tune local connection settings"
if git -C "$demo_directory" merge --no-edit incoming > /dev/null 2>&1; then
  printf 'Expected a conflict but merge succeeded. Fixture: %s\n' "$demo_directory" >&2
  exit 1
fi
if [[ -z "$(git -C "$demo_directory" ls-files -u)" ]]; then
  printf 'Merge failed without a conflict. Fixture: %s\n' "$demo_directory" >&2
  exit 1
fi
printf '%s\n' "$demo_directory"
