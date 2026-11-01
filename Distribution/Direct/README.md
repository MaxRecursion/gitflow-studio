# Direct-distribution release handoff

GitFlow Studio 0.2.0 (build 2), engineering preview. The selected architecture uses **installed Git** and no bundled runtime. The app has no account requirement, telemetry or backend service.

## Local artifacts

`build/releases/0.2.0-preview/` contains the universal native app, ad hoc preview ZIP, source archive, evidence archive, manifest and SHA-256 checksums. The source revision in the manifest identifies the exact committed release source, with the tested runtime revision recorded separately. It is built in an isolated checkout so unrelated workspace styling edits are preserved and excluded.

```sh
cd build/releases/0.2.0-preview
shasum -a 256 -c SHA256SUMS
```

The preview is for engineering review. It has no Developer ID signature or notarization ticket and is not a verified customer download. No upload to Apple or App Store Connect has occurred.

## Requirements and installation acceptance

The deployment target is macOS 14. The binary contains arm64 and x86_64 slices. Actual platform results and remaining GUI gates are recorded in [release status](../../Documentation/RELEASE_STATUS.md); compiled slices do not substitute for runtime acceptance.

Git is discovered at `/opt/homebrew/bin/git`, `/usr/local/bin/git`, then `/usr/bin/git`. Apple's system Git can require Command Line Tools. Install a usable Git before using repository features. Existing hooks, signing programs, SSH agents and credential helpers remain authoritative. Background terminal prompts are disabled; configure noninteractive credentials outside the app and test the intended HTTPS/SSH host.

After Developer ID signing and accepted notarization, validate a downloaded, quarantined copy on a clean supported Mac. Verify Git discovery with and without CLT, permission/error recovery, open/clone, staging/commit, authentication, hooks and the supported conflict continuations. Retain that signed binary's hash and results. Minimum-OS GUI, live-host authentication, broader accessibility and long-session/frame profiling remain release gates.

## Signing handoff

No Apple Developer team, usable Developer ID Application identity/private key or notarization Keychain profile is currently available. Configure those locally; never send secrets in chat or commit them. [RELEASING.md](../../Documentation/RELEASING.md) documents prepare, explicit submit, resume, staple and verification. The pipeline fails before building/uploading without prerequisites and accepts only public certificate fingerprints and a local Keychain profile name.

Only the pipeline's verified `final/` ZIP is a notarized distribution candidate. Publishing still requires the owner's release choice and final clean-machine acceptance. Mac App Store submission is deferred: this unsandboxed installed-Git build is not a store candidate.

## Scope

This update adds safe EOF line selection, root-commit undo, detached checkout, soft/mixed ancestor reset, literal ignore, tag push, remote-tracking worktrees and pure submodule conflict reference choices. The final ARM validation passes 79 core and seven native UI tests; Intel passes 79 core and five critical UI workflows. Native UI tests exercise ordinary commits and merge/rebase/cherry-pick/revert continuation; separate real-Git tests cover the newer operations. Submodule choices alter the parent index reference while preserving child files and HEAD.

Full GitHub Desktop parity is unfinished. Complex rename/file-directory conflicts, mixed submodule/file cases, rich working diffs, advanced history planning and hosted account/PR workflows remain partial or missing. See [the evidence ledger](../../Documentation/DESKTOP_PARITY.md) before making feature claims. No performance target is advertised as guaranteed.
