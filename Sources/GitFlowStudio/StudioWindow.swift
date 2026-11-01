import SwiftUI
import AppKit
import GitCore

struct StudioWindow: View {
    @ViewState private var model = StudioModel()
    @ViewState private var nativeWindow: NSWindow?
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let repo = model.repository {
                    if !model.status.conflicts.isEmpty && model.section != .conflicts {
                        conflictBanner
                    }
                    switch model.section {
                    case .changes: ChangesWorkspace(model: model)
                    case .conflicts: ConflictWorkspace(repository: repo, model: model.conflictModel, onRefresh: { model.refresh() }).id(repo.url)
                    default: RepositoryToolsWorkspace(model: model)
                    }
                } else { welcome }
                Divider()
                statusBar
            }
            .navigationTitle(model.repository?.url.lastPathComponent ?? "GitFlow Studio")
            .navigationSubtitle(model.repository == nil ? "A clearer view of your work" : model.status.branch)
            .toolbar { toolbar }
        }
        .background(WindowSessionReader(window: $nativeWindow, model: model,
                                         edited: model.hasUnsavedDraft))
        .alert("Git needs your attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert(model.confirmation?.title ?? "Confirm", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })) {
            if let pending = model.confirmation {
                Button(pending.title, role: pending.destructive ? .destructive : nil) { pending.action() }
                Button("Cancel", role: .cancel) {}
            }
        } message: { Text(model.confirmation?.message ?? "") }
        .sheet(isPresented: $model.showClone) { CloneSheet(model: model) }
        .sheet(isPresented: $model.showCommands) { CommandPalette(model: model) }
        .sheet(isPresented: $model.showRepositorySettings) {
            if let repo = model.repository { RepositorySettingsSheet(repository: repo, onRefresh: model.refresh) }
        }
        .sheet(isPresented: $model.showPreview) {
            VStack(spacing: 0) {
                HStack { Text(model.previewTitle).font(.headline).lineLimit(1); Spacer(); Button("Done") { model.showPreview = false }.keyboardShortcut(.cancelAction) }.padding(16)
                Divider()
                DiffTextView(text: model.previewText.isEmpty ? "No differences." : model.previewText)
            }.frame(minWidth: 760, minHeight: 540)
        }
        .onReceive(NotificationCenter.default.publisher(for: .studioOpen)) { _ in if nativeWindow?.isKeyWindow == true { model.openPanel() } }
        .onReceive(NotificationCenter.default.publisher(for: .studioOpenURL)) { note in
            if nativeWindow?.isKeyWindow == true, let url = note.object as? URL { model.open(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .studioRefresh)) { _ in if nativeWindow?.isKeyWindow == true { model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .studioCommands)) { _ in if nativeWindow?.isKeyWindow == true { model.showCommands = true } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            model.open(url); return true
        }
        .task {
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--repo"), args.indices.contains(index + 1) {
                model.open(URL(fileURLWithPath: args[index + 1]))
            } else if UserDefaults.standard.object(forKey: "restoreRepository") as? Bool != false, let path = model.recentPaths.first {
                model.open(URL(fileURLWithPath: path))
            }
        }
        .onChange(of: model.section) { _, _ in
            model.search = ""
            Task { await model.loadSection() }
        }
    }

    private var sidebar: some View {
        List(selection: $model.section) {
            Section {
                ForEach(WorkspaceSection.allCases.filter { $0 != .conflicts }) { section in
                    Label { HStack {
                        Text(section.rawValue)
                        Spacer()
                        if section == .changes && !model.status.files.isEmpty {
                            Text("\(model.status.files.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } } icon: { Image(systemName: section.icon) }.tag(section)
                }
            } header: { Text("Workspace") }
            if model.repository != nil {
                Section {
                    Label("Resolve Conflicts", systemImage: "arrow.triangle.merge").tag(WorkspaceSection.conflicts)
                        .foregroundStyle(model.status.conflicts.isEmpty ? Color.secondary : Color.orange)
                }
            }
            Section("Repositories") {
                ForEach(model.recentPaths, id: \.self) { path in
                    Button { model.open(URL(fileURLWithPath: path)) } label: {
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                            .lineLimit(1).foregroundStyle(model.repository?.url.path == path ? Color.accentColor : Color.primary)
                    }.buttonStyle(.plain).help(path)
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
                            Button("Remove from Recents") {
                                model.recentPaths.removeAll { $0 == path }
                                UserDefaults.standard.set(model.recentPaths, forKey: "recentRepositories")
                            }
                        }
                }
                Button(action: model.openPanel) { Label("Open Repository…", systemImage: "plus") }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitFlow Studio").font(.headline)
                    Text("Local. Native. In your control.").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(14)
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 54, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Make room for your next idea.").font(.largeTitle.weight(.semibold))
                Text("Your repositories, changes, and conflicts—clearly in view.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Repository…", action: model.openPanel).buttonStyle(.borderedProminent)
                Button("Clone…") { model.showClone = true }
                Button("Initialize…", action: model.initialize)
            }.controlSize(.large)
            Text("Or drop a repository folder into this window").font(.caption).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conflictBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(model.status.conflicts.count) files need resolution").font(.callout.weight(.medium))
            Spacer()
            Button("Open Conflict Workspace") { model.section = .conflicts }.buttonStyle(.bordered)
        }.padding(12).background(Color.orange.opacity(0.08))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let busy = model.busy {
                ProgressView().controlSize(.mini)
                Text(busy)
                Spacer()
                Button("Cancel", action: model.cancel).buttonStyle(.plain)
            } else {
                Image(systemName: model.status.conflicts.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(model.status.conflicts.isEmpty ? Color.secondary : Color.orange)
                Text(model.notice ?? (model.repository == nil ? "Ready" : "\(model.status.files.count) changed · \(model.status.files.filter(\.isStaged).count) staged"))
                    .lineLimit(1).help(model.notice ?? "")
                Spacer()
                if model.status.upstream != nil { Text("↑ \(model.status.ahead)  ↓ \(model.status.behind)").monospacedDigit() }
            }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 30)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: model.openPanel) { Label("Open Repository", systemImage: "folder.badge.plus") }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.repository != nil {
                Button { model.section = .branches } label: { Label(model.status.branch, systemImage: "arrow.triangle.branch") }
                Divider()
                Button { model.perform("Fetching…", ["fetch", "--all", "--prune"]) } label: { Label("Fetch", systemImage: "arrow.down.to.line") }
                Menu {
                    Button("Pull (Fast-forward Only)") { model.pull() }
                    Button("Pull and Merge…") { model.confirm("Pull and Merge", "Fetch and merge the upstream branch? Conflicts will open in the resolver.") { model.pull(.merge) } }
                    Button("Pull and Rebase…") { model.confirm("Pull and Rebase", "Fetch and replay your local commits on the upstream branch? This rewrites local commit history.") { model.pull(.rebase) } }
                } label: { Label("Pull", systemImage: "arrow.down") } primaryAction: { model.pull() }
                Button(action: model.push) { Label("Push", systemImage: "arrow.up") }
                Button(action: model.refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                Menu {
                    Button("Repository Settings…") { model.showRepositorySettings = true }
                    Button("Undo Latest Commit…", action: model.undoCommit)
                    Button("Reveal in Finder", action: model.reveal)
                    Button("Open in Editor", action: model.externalEditor)
                    Button("Clone Repository…") { model.showClone = true }
                    Button("Initialize Repository…", action: model.initialize)
                } label: { Label("Repository Actions", systemImage: "ellipsis.circle") }
            }
        }
    }
}

