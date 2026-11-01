# GitFlow Studio privacy statement — publisher review required

This is a draft, not a published policy. The publisher must add their identity, contact address, effective date, and public policy URL before distribution.

GitFlow Studio works with Git repositories you choose on your Mac. It stores preferences and recent repository locations locally. Conflict recovery drafts may include source code and merged results; they are stored locally in the app's private Application Support directory. They are not uploaded to the developer.

The app does not include analytics, advertising, tracking, an account service, or an automatic crash-report upload service. Local diagnostic messages and performance intervals do not include repository contents, paths, Git command arguments, or credentials.

When you request a Git network operation such as clone, fetch, pull, or push, your installed Git connects to the remote server you configured. Git may use your existing credential helpers, SSH configuration, and hooks. Repository content and authentication data involved in those operations are handled by Git and your configured services under their own policies. The app does not route those operations through a GitFlow Studio server.

You control repository files on disk. Removing a repository from Recent Repositories removes its listing, not its files. Recovery drafts can contain sensitive work; review and discard them in the conflict workspace when no longer needed. Removing local app data does not remove repositories or erase data already sent to a Git remote.

Before publishing, validate this statement against the final signed binary, its dependencies, any support/crash-report workflow, and the final sandboxed architecture. App Store privacy answers must be completed by the publisher from that reviewed behavior.
