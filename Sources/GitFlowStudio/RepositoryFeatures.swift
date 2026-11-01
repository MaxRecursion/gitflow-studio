import SwiftUI
import AppKit
import GitCore

struct RepositoryToolsWorkspace: View {
    @Bindable var model: StudioModel
    @ViewState private var form: RepositoryForm?
    var body: some View {
        Group {
            switch model.section {
            case .history: HistoryWorkspace(model: model)
            case .branches: branches
            case .remotes: remotes
            case .stashes: stashes
            case .tags: tags
            case .worktrees: WorktreeWorkspace(model: model)
            default: EmptyView()
            }
        }
        .sheet(item: $form) { value in RepositoryFormSheet(model: model, form: value) }
    }

    private func header(_ title: String, subtitle: String, action: String, kind: RepositoryForm.Kind) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.title2.weight(.semibold)); Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            Spacer()
            Button(action) { form = RepositoryForm(kind: kind) }.buttonStyle(.borderedProminent).disabled(model.busy != nil)
        }.padding(20)
    }

    private var branches: some View {
        VStack(spacing: 0) {
            header("Branches", subtitle: "A place for every line of work.", action: "New Branch…", kind: .branch)
            Divider()
            List {
                ForEach([false, true], id: \.self) { remote in
                    Section(remote ? "Remote branches" : "Local branches") {
                        ForEach(model.branches.filter { $0.isRemote == remote }) { branch in
                            HStack(spacing: 12) {
                                Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch").foregroundStyle(branch.isCurrent ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(branch.name).font(.headline)
                                    Text(branch.isCurrent ? "Current branch" + (branch.tracking.isEmpty ? "" : " · " + branch.tracking) : branch.upstream ?? String(branch.sha.prefix(8))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if remote {
                                    Button("Track…") { form = RepositoryForm(kind: .track, target: branch.name, initial: branch.name.components(separatedBy: "/").dropFirst().joined(separator: "/")) }
                                } else { Button(branch.isCurrent ? "Current" : "Switch") { if let repo = model.repository { model.execute("Switching branch…") { try await repo.switchBranch(branch.name) } } }.disabled(branch.isCurrent || model.busy != nil) }
                                Menu {
                                    Button("Compare with HEAD") { model.compare(branch.name, to: "HEAD") }
                                    Button("Merge into \(model.status.branch)…") { integrate(.merge, branch.name) }.disabled(branch.isCurrent)
                                    Button("Rebase \(model.status.branch) onto This Branch…") { integrate(.rebase, branch.name) }.disabled(branch.isCurrent)
                                    if !remote {
                                        Divider()
                                        Button("Rename…") { form = RepositoryForm(kind: .renameBranch, target: branch.name, initial: branch.name) }
                                        Button("Delete…", role: .destructive) {
                                            model.confirm("Delete Branch", "Delete \(branch.name)? Git will refuse if it contains unmerged work.", destructive: true) {
                                                if let repo = model.repository { model.execute("Deleting branch…") { try await repo.deleteBranch(branch.name) } }
                                            }
                                        }.disabled(branch.isCurrent)
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 26)
                            }.padding(.vertical, 8)
                        }
                    }
                }
            }.listStyle(.inset)
        }
    }

    private func integrate(_ operation: GitOperation, _ revision: String) {
        let message = operation == .rebase ? "Replay \(model.status.branch) on \(revision)? This rewrites local commits. Commit or stash working changes first." : "Merge \(revision) into \(model.status.branch)? Conflicts will open in the visual resolver. A clean merge may create a commit."
        model.confirm(operation == .rebase ? "Rebase Branch" : "Merge Branch", message) { model.integrate(operation, revision: revision) }
    }

    private var remotes: some View {
        VStack(spacing: 0) {
            header("Remotes", subtitle: "Connect your local work to its shared home.", action: "Add Remote…", kind: .remote)
            Divider()
            if model.remotes.isEmpty { ContentUnavailableView("No remotes configured", systemImage: "network", description: Text("Add a remote URL to fetch and publish branches.")) }
            else {
                List(model.remotes) { remote in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(remote.name, systemImage: "network").font(.headline)
                            Spacer()
                            Button("Fetch") { model.perform("Fetching \(remote.name)…", ["fetch", "--prune", "--", remote.name]) }
                            Button("Publish Current Branch…") {
                                model.confirm("Publish Branch", "Push \(model.status.branch) to \(remote.name) and set its upstream? Existing remote commits will not be overwritten.") {
                                    if let repo = model.repository { model.execute("Publishing branch…") { try await repo.publishBranch(remote: remote.name, branch: model.status.branch) } }
                                }
                            }.disabled(model.status.isUnborn || model.status.branch == "(detached)")
                            Menu {
                                Button("Change URL…") { form = RepositoryForm(kind: .remoteURL, target: remote.name) }
                                Button("Remove Remote…", role: .destructive) {
                                    model.confirm("Remove Remote", "Remove the local configuration and tracking references for \(remote.name)? The remote repository is unchanged.", destructive: true) { model.perform("Removing remote…", ["remote", "remove", "--", remote.name]) }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 26)
                        }
                        Text(remote.fetchURL).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        if remote.fetchURL != remote.pushURL { Text("Push: " + remote.pushURL).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 10)
                }.listStyle(.inset)
            }
        }
    }

    private var stashes: some View {
        VStack(spacing: 0) {
            header("Stashes", subtitle: "Set work aside and pick it up when you’re ready.", action: "Stash Changes…", kind: .stash)
            Divider()
            if model.stashes.isEmpty { ContentUnavailableView("No stashed changes", systemImage: "archivebox", description: Text("Stash tracked and untracked changes to keep your working tree clear.")) }
            else { List(model.stashes) { stash in
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text(stash.subject).font(.headline); Text(stash.reference).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Inspect") { model.preview("Stash · \(stash.reference)", arguments: ["stash", "show", "--patch", "--include-untracked", "--no-ext-diff", stash.sha]) }
                    Button("Apply") { model.applyStash(stash) }
                    Button("Pop…") {
                        model.confirm("Pop Stash", "Apply these changes and remove the stash if application succeeds? A conflicting stash is kept.") { model.applyStash(stash, pop: true) }
                    }
                    Button { model.confirm("Drop Stash", "Permanently remove \(stash.reference)? These saved changes may be lost.", destructive: true) {
                        if let repo = model.repository { model.execute("Dropping stash…") { try await repo.dropStash(stash) } }
                    } } label: { Image(systemName: "trash") }.help("Drop stash")
                }.padding(.vertical, 10)
            }.listStyle(.inset) }
        }
    }

    private var tags: some View {
        VStack(spacing: 0) {
            header("Tags", subtitle: "Give important moments a name.", action: "Create Tag…", kind: .tag)
            Divider()
            if model.tags.isEmpty { ContentUnavailableView("No tags yet", systemImage: "tag", description: Text("Create an annotated tag at a commit or branch.")) }
            else { List(model.tags) { tag in
                HStack {
                    Image(systemName: "tag").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 5) { Text(tag.name).font(.headline); Text(tag.subject).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Push…") { form = RepositoryForm(kind: .pushTag, target: tag.name, initial: "origin", expectedSHA: tag.sha) }
                    Button("Inspect") { model.preview("Tag · \(tag.name)", arguments: ["show", "--no-ext-diff", "--no-textconv", "refs/tags/" + tag.name, "--"]) }
                    Button { model.confirm("Delete Tag", "Delete the local tag \(tag.name)? Any published remote tag remains.", destructive: true) { model.perform("Deleting tag…", ["tag", "-d", "--", tag.name]) } } label: { Image(systemName: "trash") }.help("Delete local tag")
                }.padding(.vertical, 10)
            }.listStyle(.inset) }
        }
    }
}

struct RepositoryForm: Identifiable {
    enum Kind { case branch, track, renameBranch, remote, remoteURL, stash, tag, pushTag }
    let id = UUID()
    let kind: Kind
    var target = ""
    var initial = ""
    var expectedSHA = ""
    var title: String {
        switch kind {
        case .branch: "Create Branch"
        case .track: "Track Remote Branch"
        case .renameBranch: "Rename Branch"
        case .remote: "Add Remote"
        case .remoteURL: "Change Remote URL"
        case .stash: "Stash Changes"
        case .pushTag: "Push Tag"
        case .tag: "Create Tag"
        }
    }
}

struct RepositoryFormSheet: View {
    @Bindable var model: StudioModel
    let form: RepositoryForm
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var second = ""
    @ViewState private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(form.title).font(.title2.bold())
            if !form.target.isEmpty { Text(form.target).foregroundStyle(.secondary) }
            TextField(form.kind == .stash ? "Stash message" : form.kind == .remoteURL ? "Remote URL" : form.kind == .pushTag ? "Remote name" : "Name", text: $name).textFieldStyle(.roundedBorder)
            if form.kind == .branch || form.kind == .tag { TextField("Starting revision (HEAD)", text: $second).textFieldStyle(.roundedBorder) }
            if form.kind == .remote { TextField("HTTPS, SSH, or local URL", text: $second).textFieldStyle(.roundedBorder) }
            if form.kind == .tag { TextField("Tag message", text: $message).textFieldStyle(.roundedBorder) }
            if form.kind == .pushTag { Text("Push only this tag. An existing remote tag will not be replaced.").font(.callout).foregroundStyle(.secondary) }
            if form.kind == .stash { Text("Tracked and untracked changes will be saved and removed from the working tree. Ignored files are retained.").font(.callout).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }; Button(form.title) { submit() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || form.kind == .remote && second.isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480).onAppear { name = form.initial }
    }

    private func submit() {
        guard let repo = model.repository else { return }
        dismiss()
        model.execute(form.title + "…") {
            switch form.kind {
            case .branch: try await repo.createBranch(name: name, startPoint: second.isEmpty ? "HEAD" : second)
            case .track: try await repo.createBranch(name: name, startPoint: form.target, tracking: true)
            case .renameBranch: try await repo.renameBranch(form.target, to: name)
            case .remote: try await repo.addRemote(name: name, url: second)
            case .remoteURL: try await repo.updateRemote(name: form.target, url: name)
            case .stash: _ = try await repo.perform(["stash", "push", "--include-untracked", "-m", name])
            case .pushTag: try await repo.pushTag(GitTag(name: form.target, sha: form.expectedSHA, subject: ""), remote: name)
            case .tag: try await repo.createTag(name, revision: second.isEmpty ? "HEAD" : second, message: message)
            }
        }
    }
}
