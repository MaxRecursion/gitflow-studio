import SwiftUI
import AppKit
import GitCore

struct WorktreeWorkspace: View {
    @Bindable var model: StudioModel
    @ViewState private var sheet: WorktreeSheet?
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
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Worktrees").font(.title2.weight(.semibold))
                    Text("Work on multiple branches in separate folders.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Prune Missing…") {
                    guard let repo = model.repository else { return }
                    model.execute("Checking missing worktrees…", refreshAfter: false) { sheet = .prune(try await repo.previewWorktreePrune()) }
                }
                Button("New Worktree…") { sheet = .create }.buttonStyle(.borderedProminent)
            }.padding(20).disabled(model.operationInProgress)
            Divider()
            List(model.worktrees) { tree in
                HStack(spacing: 14) {
                    Image(systemName: tree.isMain ? "folder.fill" : "folder.badge.plus").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(tree.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "Detached at \(tree.head.prefix(8))").font(.headline)
                        Text(tree.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if tree.isLocked { Label(tree.lockReason ?? "Locked in Git", systemImage: "lock.fill").font(.caption).foregroundStyle(.orange) }
                        if tree.isPrunable { Text("Folder is missing · \(tree.pruneReason ?? "Registration can be pruned")").font(.caption).foregroundStyle(.secondary) }
                        if isActive(tree) { Text("Open in this window").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Open") { model.open(URL(fileURLWithPath: tree.path)) }.disabled(tree.isPrunable)
                    Button("Reveal") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: tree.path) }.disabled(tree.isPrunable)
                    if !tree.isMain {
                        Menu {
                            if tree.isLocked {
                                Button("Unlock Worktree") {
                                    if let repo = model.repository { model.execute("Unlocking worktree…") { try await repo.unlockWorktree(tree) } }
                                }
                            } else {
                                Button("Lock Worktree…") { sheet = .lock(tree) }
                            }
                            Button("Move Worktree…") { sheet = .move(tree) }.disabled(isActive(tree) || tree.isLocked || tree.isPrunable)
                            Divider()
                            Button("Remove Worktree…", role: .destructive) {
                                model.confirm("Remove Worktree", "Remove the folder at \(tree.path)? Git will refuse if it contains uncommitted changes. Its branch and commits are retained.", destructive: true) {
                                    if let repo = model.repository { model.execute("Removing worktree…") { try await repo.removeWorktree(tree) } }
                                }
                            }.disabled(isActive(tree) || tree.isLocked || tree.isPrunable)
                        } label: { Label("Worktree Actions", systemImage: "ellipsis.circle") }
                            .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
                    }
                }.padding(.vertical, 10).disabled(model.operationInProgress)
            }.listStyle(.inset)
        }.sheet(item: $sheet) { selected in
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
}

private struct CreateWorktreeSheet: View {
    @Bindable var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var useExisting = false
    @ViewState private var name = ""
    @ViewState private var existingBranch = ""
    @ViewState private var branches: [GitBranch] = []
    @ViewState private var branchError: String?
    @ViewState private var revision = "HEAD"
    @ViewState private var destination: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Worktree").font(.title2.bold())
            Picker("Branch", selection: $useExisting) {
                Text("Create New Branch").tag(false)
                Text("Use Existing Branch").tag(true)
            }.pickerStyle(.segmented)
            if useExisting {
                Picker("Existing local branch", selection: $existingBranch) {
                    Text("Choose a branch").tag("")
                    ForEach(branches) { branch in Text(branch.name).tag(branch.name) }
                }
                Text(branchError ?? (branches.isEmpty ? "No unused local branches are available. Create a new branch instead." : "Branches already checked out in a worktree are unavailable.")).font(.caption).foregroundStyle(.secondary)
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
                    let existing = useExisting, branch = existing ? existingBranch : name, startPoint = revision
                    dismiss()
                    model.execute("Creating worktree…") {
                        if existing { try await repo.addExistingBranchWorktree(at: destination, branch: branch) }
                        else { try await repo.addWorktree(at: destination, branch: branch, from: startPoint) }
                    }
                }.buttonStyle(.borderedProminent).disabled(destination == nil || (useExisting ? existingBranch.isEmpty : name.isEmpty || revision.isEmpty)).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
            .task {
                guard let repo = model.repository else { return }
                do {
                    let checkedOut = Set(try await repo.worktrees().compactMap(\.branch))
                    branches = try await repo.branches().filter { !$0.isRemote && !checkedOut.contains("refs/heads/" + $0.name) }
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
