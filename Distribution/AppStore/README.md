# App Store submission material — draft

The user chose Developer ID preparation first on November 1, 2026. No Apple Developer team is configured. These files are **preparation artifacts, not an uploadable App Store release**.

- `en-US/metadata.json`: editable listing draft; missing publisher-controlled fields are `null`, never invented.
- `PRIVACY_POLICY_DRAFT.md`: product behavior statement to review and publish at the owner's URL.
- `../../Resources/AppIcon-1024.png`: original icon master. The packaged app uses `AppIcon.icns`.
- `../../Documentation/STORE_READINESS.md`: engineering and account gates.
- `../../Tests/GitFlowStudioUITests/RepositoryUITests.swift`: disposable local review flows and screenshot attachments, pending execution with full Xcode.

The draft description describes the current direct-distribution architecture. Revise it after implementing and testing an App Store-compatible Git runtime. Do not advertise full GitHub Desktop parity or measured startup/scrolling performance; neither is verified.

Screenshots must show the final signed store build on supported hardware, with no private repository data. Capture the conflict resolver, working changes, commit history, and branch/worktree management. Screenshots attached by UI tests are QA evidence; they still need final App Store sizing and review. See Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
