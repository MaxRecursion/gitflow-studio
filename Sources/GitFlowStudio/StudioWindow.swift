import SwiftUI
import AppKit
import GitCore

struct StudioWindow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("studioAnimationsEnabled") private var animationsEnabled = true
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
            .background(StudioTheme.canvas)
            .navigationTitle(model.repository?.url.lastPathComponent ?? "GitFlow Studio")
            .navigationSubtitle(model.repository == nil ? "A clearer view of your work" : model.status.branch)
            .toolbar { toolbar }
        }
        .background(StudioTheme.canvas)
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
        .sheet(isPresented: $model.showOpenRepository, onDismiss: model.repositoryChooserDismissed) {
            RepositoryOpenSheet(model: model)
        }
        .sheet(isPresented: $model.showCommands, onDismiss: model.commandsDismissed) { CommandPalette(model: model) }
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
            let defaults = UserDefaults.standard
            let restoreRepository = defaults.object(forKey: "restoreRepository") == nil || defaults.bool(forKey: "restoreRepository")
            if let index = args.firstIndex(of: "--repo"), args.indices.contains(index + 1) {
                model.open(URL(fileURLWithPath: args[index + 1]))
            } else if restoreRepository, let path = model.recentPaths.first {
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
                            Text("\(model.status.files.count)")
                                .font(.caption.monospacedDigit().weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                                .contentTransition(.numericText())
                        }
                    } } icon: {
                        Image(systemName: section.icon)
                            .frame(width: 22, height: 25)
                    }
                    .padding(.vertical, 3)
                    .tag(section).accessibilityIdentifier("workspace-\(section.rawValue)")
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
                        Label((path as NSString).lastPathComponent, systemImage: "folder")
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if let repository = model.repository {
                VStack(alignment: .leading, spacing: 7) {
                    Label(repository.url.lastPathComponent, systemImage: "folder.fill")
                        .font(.headline).lineLimit(1)
                    Label(model.status.branch, systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(StudioTheme.accent.opacity(0.055))
                .overlay(alignment: .bottom) { Rectangle().fill(StudioTheme.border).frame(height: 1) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(StudioTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(StudioTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitFlow Studio").font(.callout.weight(.semibold))
                    Text("A clearer path for your ideas.").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(14)
        }
    }

    private var welcome: some View {
        VStack(spacing: 25) {
            WelcomeFlowIllustration().frame(width: 400, height: 152).accessibilityHidden(true)
            VStack(spacing: 11) {
                Text("Make room for your next idea.").font(.largeTitle.weight(.semibold))
                Text("Review your changes, save a checkpoint, and explore what comes next.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            HStack {
                Button("Open Repository…", action: model.openPanel).buttonStyle(.borderedProminent)
                Button("Clone…") { model.showClone = true }
                Button("Initialize…", action: model.initialize)
            }.controlSize(.large)
            Text("Or drop a repository folder into this window").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RadialGradient(colors: [StudioTheme.accent.opacity(0.075), .clear], center: .center, startRadius: 20, endRadius: 380)
        }
    }

    private var conflictBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(model.status.conflicts.count) files need resolution").font(.callout.weight(.medium))
            Spacer()
            Button("Open Conflict Workspace") { model.section = .conflicts }.buttonStyle(.bordered)
        }.padding(.horizontal, 18).padding(.vertical, 12).background(Color.orange.opacity(0.08))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let busy = model.busy {
                ProgressView().controlSize(.mini)
                Text(busy)
                Spacer()
                Button("Cancel", action: model.cancel).buttonStyle(.plain)
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusTint)
                Text(model.notice ?? (model.repository == nil ? "Ready" : "\(model.status.files.count) changed · \(model.status.files.filter(\.isStaged).count) staged"))
                    .lineLimit(1).help(model.notice ?? "")
                Spacer()
                if model.status.upstream != nil {
                    Text("↑ \(model.status.ahead)  ↓ \(model.status.behind)").monospacedDigit()
                        .help("\(model.status.ahead) commits ahead and \(model.status.behind) behind the upstream branch")
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 38)
        .background(StudioTheme.surface)
        .animation(StudioTheme.animation(reduceMotion: reduceMotion || !animationsEnabled), value: model.busy != nil)
    }

    private var statusSymbol: String {
        if model.error != nil { return "exclamationmark.circle.fill" }
        if !model.status.conflicts.isEmpty { return "exclamationmark.triangle.fill" }
        if model.notice?.hasPrefix("Operation stopped") == true { return "pause.circle" }
        return model.notice == nil ? "checkmark.circle" : "checkmark.circle.fill"
    }

    private var statusTint: Color {
        if model.error != nil || !model.status.conflicts.isEmpty { return .orange }
        if model.notice?.hasPrefix("Operation stopped") == true { return .secondary }
        return model.notice == nil ? .secondary : StudioTheme.success
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: model.openPanel) { Label("Open Repository", systemImage: "folder.badge.plus") }
                .accessibilityIdentifier("open-repository")
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
                    Button("Open in Terminal", action: model.openTerminal)
                    Button("Clone Repository…") { model.showClone = true }
                    Button("Initialize Repository…", action: model.initialize)
                } label: { Label("Repository Actions", systemImage: "ellipsis.circle") }
            }
        }
    }
}

private struct WelcomeFlowIllustration: View {
    var body: some View {
        ZStack {
            Path { main in
                main.move(to: CGPoint(x: 65, y: 83))
                main.addCurve(to: CGPoint(x: 335, y: 83),
                              control1: CGPoint(x: 150, y: 83), control2: CGPoint(x: 250, y: 83))
            }.stroke(StudioTheme.accent.opacity(0.22), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Path { branch in
                branch.move(to: CGPoint(x: 65, y: 83))
                branch.addCurve(to: CGPoint(x: 200, y: 39),
                                control1: CGPoint(x: 128, y: 83), control2: CGPoint(x: 131, y: 39))
                branch.addCurve(to: CGPoint(x: 335, y: 83),
                                control1: CGPoint(x: 269, y: 39), control2: CGPoint(x: 272, y: 83))
            }.stroke(StudioTheme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            stage("Review", symbol: "doc.text.magnifyingglass", tint: StudioTheme.accent).position(x: 65, y: 101)
            stage("Commit", symbol: "checkmark", tint: StudioTheme.success).position(x: 200, y: 57)
            stage("Explore", symbol: "arrow.triangle.branch", tint: .blue).position(x: 335, y: 101)
        }
    }

    private func stage(_ title: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 60, height: 60)
                .background(StudioTheme.elevated, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(StudioTheme.border) }
                .shadow(color: .black.opacity(0.05), radius: 12, y: 5)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(width: 80)
    }
}

