# Distribution readiness

Assessment: November 1, 2026. **Engineering preview; not App Store ready.** The user selected local Developer ID preparation first and confirmed that no Apple Developer team is currently available.

## Two independent release paths

Apple's [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) describes Developer ID distribution outside the store. App Store submission has equivalent security checks and does not require a separately notarized Developer ID archive. A successful notarization is not App Review approval.

Current native SPM packaging produces a locally runnable, ad hoc signed `.app`. Developer ID signing requires a valid Developer ID Application identity with its private key; `security find-identity -v -p codesigning` found none. The prepared pipeline does not claim a notarization ticket without an Accepted response and a verified staple.

## Mac App Store engineering gate

[Review guideline 2.4.5](https://developer.apple.com/app-store/review/guidelines/) requires sandboxing and a self-contained app installation. The current build deliberately uses installed Git and is unsandboxed. Turning on an entitlement alone would not preserve its working behavior.

| Area | Current behavior | Required verification/change |
| --- | --- | --- |
| Git availability | Homebrew/local/system Git discovery; system Git may require CLT | Decide how the store build supplies a compliant, maintained Git runtime while honoring the original installed-Git requirement. Test a clean Mac without CLT. |
| Repository access | Open panel, drag/drop, recent absolute paths | Security-scoped bookmark persistence and balanced access lifetimes; handle moved/deleted/revoked grants. |
| Linked worktrees | Git common directory may be outside selected worktree | Explicit grants for repository metadata and linked directories; no implicit broad home access. |
| Authentication | Existing credential helpers and SSH configuration | Test Keychain access, SSH agent/sockets/keys/config, HTTPS helpers, failures and user recovery inside the sandbox. |
| Hooks, filters, signing | Existing Git programs and configuration | Verify executable access and sandbox inheritance; clearly expose unsupported integrations. |
| Clone/init | Writes to chosen destinations | Maintain parent-folder grant through Git child execution. |
| External editor/Finder | Native open/reveal | Verify supported system APIs in sandbox without privileged helpers. |
| Package/signing | Ad hoc app | Xcode archive, appropriate App Store signing/provisioning, App Store Connect validation and clean installation. |

Apple documents [sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) and [embedded command-line tools](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app). A tool launched through `Process` inherits sandbox restrictions; an external executable does not bypass them. No privileged helper or broad sandbox exception has been introduced.

## Privacy inventory

The bundled `PrivacyInfo.xcprivacy` declares no tracking or developer data collection. `UserDefaults` stores app-owned preferences (`CA92.1`). File metadata APIs validate user-selected repository files (`3B52.1`) and app-owned recovery storage (`C617.1`). The app uses `fstat` for safe regular-file validation even though it does not use timestamps for fingerprinting. Reasons are from Apple's [required-reason definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons).

Re-audit the exact store binary, any bundled Git/dependencies, final sandbox storage, and App Store privacy report before submission. The manifest is an engineering declaration, not evidence that Apple accepted it. No encryption/export-compliance response is inferred: SSH/HTTPS use and any future bundled crypto dependencies need an owner-reviewed answer.

## Release acceptance gates

- [x] Hosted Xcode 16.4 native project build on macOS 15.8.2. Local full Xcode remains absent.
- [ ] Native XCUITest execution on supported macOS; test source exists but is not yet executed.
- [ ] macOS 14 and Intel runtime verification (cross-compilation is not execution).
- [ ] Instruments traces for CPU/allocations, startup, editor scrolling, history and idle behavior.
- [ ] Remaining parity and conflict edge cases in `DESKTOP_PARITY.md` and `ROADMAP.md`.
- [x] Two real-hook cancellation/timeout tests verify ordinary descendants in the isolated process group stop before return. Detached/escaped jobs remain a limitation; abrupt cancellation can leave Git locks.
- [ ] Developer ID certificate, hardened-runtime signature, accepted notarization, verified staple, Gatekeeper and clean-machine installation.
- [ ] Sandbox/runtime feasibility gates above for a separate store build.
- [ ] Registered bundle identifier, App Store Connect record, developer identity and support/privacy URLs.
- [ ] Final icon/screenshots, privacy answers, export compliance, age rating, pricing/territories, review contact and release choice.
- [ ] App Store validation and review approval.

Do not upload the current unsandboxed preview as a store candidate. The metadata under `Distribution/AppStore` intentionally leaves account and business facts blank.
