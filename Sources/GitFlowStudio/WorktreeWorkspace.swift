import SwiftUI
import AppKit
import GitCore

struct WorktreeWorkspace: View {
    @Bindable var model: StudioModel
    @ViewState private var sheet: WorktreeSheet?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("studioAnimationsEnabled") private var animationsEnabled = true
    private var motion: Animation? { StudioTheme.animation(reduceMotion: reduceMotion || !animationsEnabled) }
    private enum WorktreeSheet: Identifiable {
        case create, move(GitWorktree), lock(GitWorktree), prune(GitWorktreePrunePreview)
        var id: String {
            switch self {
            case .create: "create"
            case .move(let tree): "move:" + tree.path
            case .lock(let tree): "lock:" + tree.path
            case .prune: "prune"
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "square.stack.3d.up")
                    .font(.title2).foregroundStyle(StudioTheme.accent)
                    .frame(width: 44, height: 44).background(StudioTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Worktrees").font(.title2.weight(.semibold))
                    Text("A separate folder for every idea. Keep branches side by side.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Prune Missing…") {
                    guard let repo = model.repository else { return }
                    model.execute("Checking missing worktrees…", refreshAfter: false) { sheet = .prune(try await repo.previewWorktreePrune()) }
                }
                Button { sheet = .create } label: { Label("New Worktree…", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }.padding(20).disabled(model.operationInProgress)
            Divider()
            if model.worktrees.isEmpty {
                ContentUnavailableView("Make room for another approach", systemImage: "square.stack.3d.up", description: Text("Create a worktree to try a branch in its own folder."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 480), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(model.worktrees) { tree in worktreeCard(tree) }
                    }
                    .padding(20)
                }
            }
        }.background(StudioTheme.canvas).sheet(item: $sheet) { selected in
            switch selected {
            case .create: CreateWorktreeSheet(model: model)
            case .move(let tree): MoveWorktreeSheet(model: model, worktree: tree)
            case .lock(let tree): LockWorktreeSheet(model: model, worktree: tree)
            case .prune(let preview): PruneWorktreeSheet(model: model, preview: preview)
            }
        }
    }
    private func isActive(_ tree: GitWorktree) -> Bool {
        URL(fileURLWithPath: tree.path).standardizedFileURL.resolvingSymlinksInPath() == model.repository?.url
    }

    private func worktreeCard(_ tree: GitWorktree) -> some View {
        let active = isActive(tree)
        let branch = tree.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "Detached at \(tree.head.prefix(8))"
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: tree.isMain ? "folder.fill" : "square.stack.3d.up.fill")
                    .font(.title3).foregroundStyle(active ? StudioTheme.accent : Color.secondary)
                    .frame(width: 38, height: 38).background((active ? StudioTheme.accent : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(URL(fileURLWithPath: tree.path).lastPathComponent).font(.headline).lineLimit(1)
                    Text(tree.isMain ? "Main checkout" : "Linked worktree").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(StudioTheme.accent).accessibilityLabel("Open in this window") }
            }
            Label(branch, systemImage: "arrow.triangle.branch")
                .font(.callout.weight(.medium)).foregroundStyle(active ? StudioTheme.accent : Color.primary)
                .lineLimit(2).textSelection(.enabled)
            Text(tree.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled).help(tree.path)
            HStack(spacing: 7) {
                if active { StudioBadge("This window", systemImage: "macwindow") }
                if tree.isLocked { StudioBadge("Locked", systemImage: "lock.fill", tint: .orange).help(tree.lockReason ?? "Locked in Git") }
                if tree.isPrunable { StudioBadge("Folder missing", systemImage: "folder.badge.questionmark", tint: .orange) }
                if !active && !tree.isLocked && !tree.isPrunable { StudioBadge("Separate checkout", systemImage: "folder", tint: .secondary) }
                Spacer(minLength: 0)
            }
            if tree.isPrunable, let reason = tree.pruneReason {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Divider()
            HStack(spacing: 8) {
                Button { model.open(URL(fileURLWithPath: tree.path)) } label: {
                    Label(active ? "Current" : "Open", systemImage: active ? "checkmark" : "arrow.up.forward.app")
                }.disabled(tree.isPrunable || active)
                Button { openInEditor(tree) } label: { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
                    .disabled(tree.isPrunable).help("Open this worktree in your configured editor")
                Spacer(minLength: 0)
                Menu {
                    Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: tree.path) }.disabled(tree.isPrunable)
                    if !tree.isMain {
                        Divider()
                        if tree.isLocked {
                            Button("Unlock Worktree") {
                                if let repo = model.repository { model.execute("Unlocking worktree…") { try await repo.unlockWorktree(tree) } }
                            }
                        } else {
                            Button("Lock Worktree…") { sheet = .lock(tree) }
                        }
                        Button("Move Worktree…") { sheet = .move(tree) }.disabled(active || tree.isLocked || tree.isPrunable)
                        Divider()
                        Button("Remove Worktree…", role: .destructive) {
                            model.confirm("Remove Worktree", "Remove the folder at \(tree.path)? Git will refuse if it contains uncommitted changes. Its branch and commits are retained.", destructive: true) {
                                if let repo = model.repository { model.execute("Removing worktree…") { try await repo.removeWorktree(tree) } }
                            }
                        }.disabled(active || tree.isLocked || tree.isPrunable)
                    }
                } label: { Label("Worktree Actions", systemImage: "ellipsis") }
                    .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? StudioTheme.elevated : StudioTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(active ? StudioTheme.accent.opacity(0.4) : StudioTheme.border, lineWidth: 1))
        .animation(motion, value: active)
        .disabled(model.operationInProgress)
    }

    private func openInEditor(_ tree: GitWorktree) {
        let identifier = UserDefaults.standard.string(forKey: "editorBundleID") ?? "com.microsoft.VSCode"
        guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            model.error = "The selected editor is not installed. Set its bundle identifier in Settings."
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: tree.path)], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct CreateWorktreeSheet: View {
    @Bindable var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var source = "new"
    @ViewState private var remoteBranch = ""
    @ViewState private var remoteBranches: [GitBranch] = []
    @ViewState private var name = ""
    @ViewState private var existingBranch = ""
    @ViewState private var branches: [GitBranch] = []
    @ViewState private var branchError: String?
    @ViewState private var revision = "HEAD"
    @ViewState private var destination: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Worktree").font(.title2.bold())
            Picker("Branch", selection: $source) {
                Text("New branch").tag("new")
                Text("Existing local").tag("existing")
                Text("Remote branch").tag("remote")
            }.pickerStyle(.segmented)
            if source == "existing" {
                Picker("Existing local branch", selection: $existingBranch) {
                    Text("Choose a branch").tag("")
                    ForEach(branches) { branch in Text(branch.name).tag(branch.name) }
                }
                Text(branchError ?? (branches.isEmpty ? "No unused local branches are available. Create a new branch instead." : "Branches already checked out in a worktree are unavailable.")).font(.caption).foregroundStyle(.secondary)
            } else if source == "remote" {
                Picker("Remote branch", selection: $remoteBranch) {
                    Text("Choose a branch").tag("")
                    ForEach(remoteBranches) { branch in Text(branch.name).tag(branch.name) }
                }
                TextField("New local branch name", text: $name).textFieldStyle(.roundedBorder)
            } else {
                TextField("New branch name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Start from branch or commit", text: $revision).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text(destination?.path ?? "Choose a destination folder").font(.callout).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                Button("Choose…") { destination = chooseWorktreeDestination(title: "Worktree Destination", suggested: "Worktree") ?? destination }
            }
            HStack {
                Spacer(); Button("Cancel", role: .cancel) { dismiss() }
                Button("Create Worktree") {
                    guard let repo = model.repository, let destination else { return }
                    let existing = source == "existing", branch = existing ? existingBranch : name, startPoint = revision
                    let tracking = source == "remote" ? remoteBranches.first { $0.name == remoteBranch } : nil
                    dismiss()
                    model.execute("Creating worktree…") {
                        if let tracking { try await repo.addRemoteBranchWorktree(at: destination, localBranch: branch, remoteBranch: tracking) }
                        else if existing { try await repo.addExistingBranchWorktree(at: destination, branch: branch) }
                        else { try await repo.addWorktree(at: destination, branch: branch, from: startPoint) }
                    }
                }.buttonStyle(.borderedProminent).disabled(destination == nil || (source == "existing" ? existingBranch.isEmpty : name.isEmpty) || (source == "remote" && remoteBranch.isEmpty) || (source == "new" && revision.isEmpty)).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
            .task {
                guard let repo = model.repository else { return }
                do {
                    let checkedOut = Set(try await repo.worktrees().compactMap(\.branch))
                    let all = try await repo.branches()
                    branches = all.filter { !$0.isRemote && !checkedOut.contains("refs/heads/" + $0.name) }
                    remoteBranches = all.filter { $0.isRemote && !$0.name.hasSuffix("/HEAD") }
                } catch { branchError = error.localizedDescription }
            }
    }
}

private struct MoveWorktreeSheet: View {
    @Bindable var model: StudioModel
    let worktree: GitWorktree
    @Environment(\.dismiss) private var dismiss
    @ViewState private var destination: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Move Worktree").font(.title2.bold())
            Text("Move this checkout and its working files to a new folder. Git updates its registration.").foregroundStyle(.secondary)
            Text(worktree.path).font(.caption).textSelection(.enabled)
            HStack {
                Text(destination?.path ?? "Choose a destination that does not exist").font(.callout).lineLimit(3)
                Spacer()
                Button("Choose…") { destination = chooseWorktreeDestination(title: "Move Worktree", suggested: URL(fileURLWithPath: worktree.path).lastPathComponent) ?? destination }
            }
            HStack {
                Spacer(); Button("Cancel", role: .cancel) { dismiss() }
                Button("Move Worktree") {
                    guard let repo = model.repository, let destination else { return }
                    dismiss(); model.execute("Moving worktree…") { try await repo.moveWorktree(worktree, to: destination) }
                }.buttonStyle(.borderedProminent).disabled(destination == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
    }
}

private struct LockWorktreeSheet: View {
    @Bindable var model: StudioModel
    let worktree: GitWorktree
    @Environment(\.dismiss) private var dismiss
    @ViewState private var reason = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Lock Worktree").font(.title2.bold())
            Text("Protect this worktree from moving, removal, and pruning. Lock folders on removable drives before disconnecting them.").foregroundStyle(.secondary)
            Text(worktree.path).font(.caption).textSelection(.enabled)
            TextField("Reason (optional)", text: $reason).textFieldStyle(.roundedBorder)
            HStack {
                Spacer(); Button("Cancel", role: .cancel) { dismiss() }
                Button("Lock Worktree") {
                    guard let repo = model.repository else { return }
                    let savedReason = reason
                    dismiss(); model.execute("Locking worktree…") { try await repo.lockWorktree(worktree, reason: savedReason) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
    }
}

private struct PruneWorktreeSheet: View {
    @Bindable var model: StudioModel
    let preview: GitWorktreePrunePreview
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Prune Missing Worktrees").font(.title2.bold())
            Text(preview.hasChanges ? "Remove the Git registrations listed below. Branches and commits remain. Reconnect removable drives and network folders first if you intend to keep their worktrees." : "There are no missing worktree registrations to prune.").foregroundStyle(.secondary)
            if preview.hasChanges {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(preview.worktrees) { tree in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tree.path).font(.callout)
                                if let reason = tree.pruneReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Text(preview.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
            }
            HStack {
                Spacer(); Button("Cancel", role: .cancel) { dismiss() }
                Button("Prune Listed Registrations", role: .destructive) {
                    guard let repo = model.repository else { return }
                    dismiss(); model.execute("Pruning missing worktrees…") { try await repo.pruneWorktrees(expected: preview) }
                }.disabled(!preview.hasChanges)
            }
        }.padding(24).frame(width: 600)
    }
}

@MainActor
private func chooseWorktreeDestination(title: String, suggested: String) -> URL? {
    let panel = NSSavePanel()
    panel.title = title; panel.nameFieldStringValue = suggested; panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url : nil
}
