import SwiftUI
import AppKit
import Observation
import GitCore

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case changes = "Changes", history = "History", branches = "Branches", remotes = "Remotes", stashes = "Stashes", tags = "Tags", worktrees = "Worktrees", conflicts = "Resolve Conflicts"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .changes: "square.and.pencil"
        case .history: "clock.arrow.circlepath"
        case .branches: "arrow.triangle.branch"
        case .remotes: "network"
        case .stashes: "archivebox"
        case .tags: "tag"
        case .worktrees: "rectangle.split.2x2"
        case .conflicts: "arrow.triangle.merge"
        }
    }
}

struct StudioConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let destructive: Bool
    let action: @MainActor () -> Void
}

/// A successful local commit made in this window, rather than a predicted outcome.
struct StudioCheckpoint: Identifiable {
    let id = UUID()
    let subject: String
    let amended: Bool
}

@MainActor @Observable
final class StudioModel {
    var repository: GitRepository?
    var conflictModel: ConflictViewModel?
    var status = GitStatus(branch: "No repository")
    var section: WorkspaceSection = .changes
    var selectedFile: String?
    var stagedDiff = false
    var diffText = ""
    var diffLoading = false
    var search = ""
    var commitMessage = ""
    var coauthorName = ""
    var coauthorEmail = ""
    var commits: [GitCommit] = []
    var selectedCommit: String?
    var commitDetail = ""
    var branches: [GitBranch] = []
    var remotes: [GitRemote] = []
    var stashes: [GitStash] = []
    var tags: [GitTag] = []
    var worktrees: [GitWorktree] = []
    var showRepositorySettings = false
    var historyHasMore = true
    var busy: String?
    var error: String?
    var notice: String?
    var lastCheckpoint: StudioCheckpoint?
    var confirmation: StudioConfirmation?
    var recentPaths = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
    var showClone = false
    var showCommands = false
    var previewTitle = ""
    var previewText = ""
    var showPreview = false
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: RepositoryMonitor?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored weak var presentationWindow: NSWindow?
    @ObservationIgnored private var repositoryPanel: NSOpenPanel?
    @ObservationIgnored private var repositoryPickerScheduled = false

    var selectedChange: GitFileChange? { status.files.first { $0.path == selectedFile } }
    var hasUnsavedDraft: Bool { conflictModel?.dirty == true || !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var operationInProgress: Bool { busy != nil || conflictModel?.busy == true }
    var filteredFiles: [GitFileChange] {
        status.files.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) }
    }

    func openPanel() {
        chooseRepositoryFolder(prompt: "Open Repository", canCreate: false) { [weak self] in self?.open($0) }
    }

    private func chooseRepositoryFolder(prompt: String, canCreate: Bool, selection: @escaping @MainActor (URL) -> Void) {
        guard repositoryPanel == nil, !repositoryPickerScheduled else { repositoryPanel?.makeKeyAndOrderFront(nil); return }
        repositoryPickerScheduled = true
        // Return from the SwiftUI action before even constructing AppKit's panel.
        // Its first construction can initialize the system picker service.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            repositoryPickerScheduled = false
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false; panel.canCreateDirectories = canCreate
            panel.title = prompt; panel.prompt = prompt
            repositoryPanel = panel
            let completion: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
                let url = response == .OK ? panel?.url : nil
                self?.repositoryPanel = nil
                if let url { selection(url) }
            }
            if let window = presentationWindow, window.attachedSheet == nil {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }

    func open(_ url: URL) {
        guard !operationInProgress else {
            error = "Wait for the current Git operation to finish, or cancel it before opening another repository."
            return
        }
        afterDraftConfirmation { [self] in
            execute("Opening repository…", refreshAfter: false) { [self] in try await loadRepository(url) }
        }
    }

    private func afterDraftConfirmation(_ action: @escaping @MainActor () -> Void) {
        if hasUnsavedDraft {
            confirm("Discard Unsaved Draft", "Opening another repository discards unsaved conflict edits and the current commit message. Files already written to the repository are retained.", destructive: true) { [weak self] in
                Task { @MainActor in
                    guard let self, await self.discardUnsavedDrafts() else { return }
                    action()
                }
            }
        } else { action() }
    }

    /// Complete removal before closing/switching so an autosave cannot resurrect
    /// an explicitly discarded resolution on the next launch.
    func discardUnsavedDrafts() async -> Bool {
        guard !operationInProgress else { return false }
        busy = "Discarding drafts…"
        defer { busy = nil }
        if let conflictModel, !(await conflictModel.discardDraft()) {
            error = conflictModel.error ?? "The saved conflict draft could not be removed."
            return false
        }
        commitMessage = ""; coauthorName = ""; coauthorEmail = ""
        return true
    }

    private func loadRepository(_ url: URL) async throws {
        let interval = GitPerformance.signposter.beginInterval("Repository Presentation", id: GitPerformance.signposter.makeSignpostID())
        defer { GitPerformance.signposter.endInterval("Repository Presentation", interval) }
        let repo = try await GitRepository.open(url)
        let nextStatus = try await repo.status()
        try Task.checkCancellation()
        refreshTask?.cancel(); diffTask?.cancel(); monitorTask?.cancel(); debounceTask?.cancel(); monitor = nil
        repository = repo; status = nextStatus; selectedFile = nil; diffText = ""
        conflictModel = ConflictViewModel(repository: repo)
        commits = []; branches = []; remotes = []; stashes = []; tags = []; worktrees = []; search = ""
        commitMessage = ""; coauthorName = ""; coauthorEmail = ""; selectedCommit = nil; commitDetail = ""
        lastCheckpoint = nil
        stagedDiff = false; diffLoading = false
        section = nextStatus.conflicts.isEmpty ? .changes : .conflicts
        recentPaths.removeAll { $0 == repo.url.path }
        recentPaths.insert(repo.url.path, at: 0); recentPaths = Array(recentPaths.prefix(12))
        UserDefaults.standard.set(recentPaths, forKey: "recentRepositories")
        startMonitoring(repo)
    }

    private func startMonitoring(_ repo: GitRepository) {
        monitorTask = Task { [weak self] in
            do {
                var paths = [repo.url.path]
                for name in ["--absolute-git-dir", "--git-common-dir"] {
                    try Task.checkCancellation()
                    if let out = try? await repo.run(["rev-parse", name]) {
                        var path = try out.strictText(context: "Repository monitoring path")
                        if path.utf8.last == 10 { path = String(decoding: path.utf8.dropLast(), as: UTF8.self) }
                        paths.append(URL(fileURLWithPath: path, relativeTo: repo.url).standardizedFileURL.path)
                    }
                }
                try Task.checkCancellation()
                let nextMonitor = await RepositoryMonitor.start(paths: paths) { [weak self] in
                    Task { @MainActor [weak self] in self?.scheduleRefresh() }
                }
                guard !Task.isCancelled, let self, self.repository === repo else { return }
                monitor = nextMonitor
                // Close the gap between the initial status and watcher registration.
                scheduleRefresh()
            } catch is CancellationError {} catch {
                if !Task.isCancelled, let self, self.repository === repo { self.error = error.localizedDescription }
            }
        }
    }

    func clone(remote: String, destination: URL) {
        afterDraftConfirmation { [self] in
            execute("Cloning repository…", refreshAfter: false) { [self] in
                _ = try await GitRepository.clone(remote: remote, to: destination)
                try await loadRepository(destination)
            }
        }
    }

    func initialize() {
        chooseRepositoryFolder(prompt: "Initialize Repository", canCreate: true) { [weak self] url in
            guard let self else { return }
            afterDraftConfirmation { [self] in
                execute("Initializing…", refreshAfter: false) { [self] in
                    _ = try await GitRepository.initialize(at: url)
                    try await loadRepository(url)
                }
            }
        }
    }

    func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, busy == nil else { return }
            refresh()
        }
    }

    func refresh() {
        guard let repo = repository else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do {
                let next = try await repo.status()
                guard !Task.isCancelled, let self, repository?.url == repo.url else { return }
                let newConflicts = status.conflicts.isEmpty && !next.conflicts.isEmpty
                status = next
                if newConflicts { section = .conflicts }
                if let selectedFile, !status.files.contains(where: { $0.path == selectedFile }) {
                    self.selectedFile = nil; diffText = ""
                } else if section == .changes { loadDiff() }
                await loadSection()
            } catch is CancellationError {} catch {
                if !Task.isCancelled { self?.error = error.localizedDescription }
            }
        }
    }

    func loadSection() async {
        guard let repo = repository else { return }
        do {
            switch section {
            case .history:
                let result = try await repo.history(limit: 100, skip: 0, search: search)
                if !Task.isCancelled { commits = result; historyHasMore = result.count == 100 }
            case .branches: branches = try await repo.branches()
            case .remotes: remotes = try await repo.remotes()
            case .stashes: stashes = try await repo.stashes()
            case .tags: tags = try await repo.tags()
            case .worktrees: worktrees = try await repo.worktrees()
            default: break
            }
        } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    func loadMoreHistory() {
        guard let repo = repository else { return }
        execute("Loading commits…", refreshAfter: false) { [self] in
            let more = try await repo.history(limit: 100, skip: commits.count, search: search)
            commits.append(contentsOf: more); historyHasMore = more.count == 100
        }
    }

    func loadDiff() {
        diffTask?.cancel()
        guard let repo = repository, let path = selectedFile else { diffText = ""; return }
        let staged = stagedDiff
        diffText = ""
        diffLoading = true
        diffTask = Task { [weak self] in
            do {
                let text = try await repo.diff(path: path, staged: staged)
                guard !Task.isCancelled, let self else { return }
                diffText = text; diffLoading = false
            } catch is CancellationError {} catch {
                if !Task.isCancelled { self?.error = error.localizedDescription; self?.diffLoading = false }
            }
        }
    }

    func loadCommit() {
        diffTask?.cancel()
        guard let repo = repository, let sha = selectedCommit else { return }
        diffTask = Task { [weak self] in
            do {
                let output = try await repo.run(["show", "--no-ext-diff", "--no-textconv", "--format=fuller", "--stat", "--patch", sha, "--"])
                if !Task.isCancelled { self?.commitDetail = output.text }
            } catch is CancellationError {} catch { if !Task.isCancelled { self?.error = error.localizedDescription } }
        }
    }

    func stage(_ file: GitFileChange, staged: Bool) {
        guard let repo = repository else { return }
        execute(staged ? "Staging…" : "Unstaging…") { [self] in
            let paths = [file.path] + (file.originalPath.map { [$0] } ?? [])
            if staged { try await repo.stage(paths: paths) } else { try await repo.unstage(paths: paths) }
            let name = URL(fileURLWithPath: file.path).lastPathComponent
            notice = staged ? "\(name) staged for a local commit" : "\(name) unstaged; working file preserved"
        }
    }

    func stageAll(_ staged: Bool) {
        guard let repo = repository else { return }
        let files = status.files.filter { !$0.isConflicted }
        let paths = Array(Set(files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }))
        guard !paths.isEmpty else { return }
        execute(staged ? "Staging changes…" : "Unstaging changes…") { [self] in
            if staged { try await repo.stage(paths: paths) } else { try await repo.unstage(paths: paths) }
            notice = staged ? "Changes staged for a local commit" : "Changes unstaged; working files preserved"
        }
    }

    func commit(amend: Bool = false) {
        guard let repo = repository else { return }
        let message = commitMessage
        let coauthors = coauthorName.isEmpty && coauthorEmail.isEmpty ? [] : [GitIdentity(name: coauthorName, email: coauthorEmail)]
        execute(amend ? "Amending commit…" : "Creating commit…") { [self] in
            try await repo.commit(message: message, amend: amend, coauthors: coauthors)
            lastCheckpoint = StudioCheckpoint(subject: String(message.split(whereSeparator: \.isNewline).first ?? "Commit"), amended: amend)
            commitMessage = ""; notice = amend ? "Commit amended locally · not pushed" : "Checkpoint committed locally · not pushed"
        }
    }

    func perform(_ title: String, _ arguments: [String]) {
        guard let repo = repository else { return }
        execute(title) { [self] in
            let result = try await repo.perform(arguments)
            notice = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Completed" : String(result.text.prefix(1200))
        }
    }

    func integrate(_ operation: GitOperation, revision: String) {
        guard let repo = repository else { return }
        execute("\(operation.title)…") { [self] in
            accept(try await repo.integrate(operation, revision: revision))
        }
    }

    func applyStash(_ stash: GitStash, pop: Bool = false) {
        guard let repo = repository else { return }
        execute("Applying stash…") { [self] in accept(try await repo.applyStash(stash, pop: pop)) }
    }

    func pull(_ strategy: GitRepository.PullStrategy = .fastForward) {
        guard let repo = repository else { return }
        execute("Pulling…") { [self] in accept(try await repo.pull(strategy)) }
    }

    func push() {
        guard let repo = repository else { return }
        execute("Pushing…") { try await repo.pushCurrentBranch() }
    }

    func discard(_ file: GitFileChange) {
        guard let repo = repository else { return }
        execute("Preparing discard…", refreshAfter: false) { [self] in
            let expected = try await repo.diff(path: file.path, staged: false)
            confirm("Discard Changes", "Restore \(file.path) from the index? Unstaged edits will be permanently lost. Staged changes are retained.", destructive: true) { [self] in
                execute("Discarding unstaged changes…") { try await repo.discardUnstaged(path: file.path, expectedDiff: expected) }
            }
        }
    }

    func undoCommit() {
        guard let repo = repository, let head = status.head else { return }
        confirm("Undo Latest Commit", "Move the current branch back one commit while keeping all files and staged changes? Published commits are protected; GitFlow Studio will refuse if a remote-tracking branch contains this commit.") { [self] in
            execute("Undoing latest commit…") { [self] in
                commitMessage = try await repo.undoLatestCommit(expectedHead: head)
                section = .changes
            }
        }
    }

    private func accept(_ result: GitOperationResult) {
        switch result {
        case .completed(let text): notice = String(text.prefix(1000))
        case .conflicts: section = .conflicts; notice = "Choose a resolution for each conflicted file."
        }
    }

    func compare(_ from: String, to: String) {
        guard let repo = repository else { return }
        execute("Comparing…", refreshAfter: false) { [self] in
            previewText = try await repo.compare(from, to: to)
            previewTitle = "\(from) → \(to)"; showPreview = true
        }
    }

    func preview(_ title: String, arguments: [String]) {
        guard let repo = repository else { return }
        execute("Loading preview…", refreshAfter: false) { [self] in
            previewText = try await repo.run(arguments).text
            previewTitle = title; showPreview = true
        }
    }

    func execute(_ title: String, refreshAfter: Bool = true, action: @escaping @MainActor () async throws -> Void) {
        guard busy == nil else { return }
        busy = title; error = nil; notice = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            do { try await action() }
            catch is CancellationError { notice = "Operation stopped." }
            catch { self.error = error.localizedDescription }
            busy = nil
            if refreshAfter { refresh() }
        }
    }

    func confirm(_ title: String, _ message: String, destructive: Bool = false, action: @escaping @MainActor () -> Void) {
        confirmation = StudioConfirmation(title: title, message: message, destructive: destructive, action: action)
    }

    func cancel() { operationTask?.cancel() }
    func reveal() { if let repository { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repository.url.path) } }
    func openTerminal() {
        guard let repository else { return }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { error = "Terminal is not available."; return }
        NSWorkspace.shared.open([repository.url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
    func ignore(_ file: GitFileChange) {
        guard let repo = repository, file.isUntracked else { return }
        execute("Adding ignore rule…") { try await repo.ignoreUntrackedPath(file.path) }
    }
    func externalEditor() {
        guard let repository else { return }
        let id = UserDefaults.standard.string(forKey: "editorBundleID") ?? "com.microsoft.VSCode"
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            error = "The selected editor is not installed. Set its bundle identifier in Settings."; return
        }
        NSWorkspace.shared.open([repository.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
