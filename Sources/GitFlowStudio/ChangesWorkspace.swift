import SwiftUI
import AppKit
import GitCore

struct ChangesWorkspace: View {
    @Bindable var model: StudioModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("studioAnimationsEnabled") private var animationsEnabled = true
    @ViewState private var sideBySide = false
    @ViewState private var selectedHunk = 0
    @ViewState private var lineSelection: LineSelectionRequest?

    private var motion: Animation? { StudioTheme.animation(reduceMotion: reduceMotion || !animationsEnabled) }
    private var stagedFiles: [GitFileChange] { model.status.files.filter(\.isStaged) }
    private var canCommit: Bool {
        !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !stagedFiles.isEmpty && model.status.conflicts.isEmpty && model.busy == nil
    }

    var body: some View {
        GeometryReader { geometry in
            let inspectorVisible = geometry.size.width >= 1_040
            VStack(alignment: .leading, spacing: 16) {
                workspaceHeader
                HSplitView {
                    fileColumn(showComposer: !inspectorVisible)
                        .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
                    diffColumn
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    if inspectorVisible {
                        ScrollView {
                            checkpointComposer
                        }
                        .frame(minWidth: 245, idealWidth: 260, maxWidth: 290)
                    }
                }
            }
            .padding(18)
            .background(StudioTheme.canvas)
        }
        .onChange(of: model.selectedFile) { _, _ in
            if let file = model.selectedChange { model.stagedDiff = file.isStaged && !file.isUnstaged }
            selectedHunk = 0; model.loadDiff()
        }
        .onChange(of: model.stagedDiff) { _, _ in selectedHunk = 0; model.loadDiff() }
        .sheet(item: $lineSelection) { request in LineStagingSheet(model: model, request: request) }
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Make your next idea real.").font(.title2.weight(.semibold))
                    Text("Review your changes. Save a version to come back to.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                StudioBadge(model.status.branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1).help(model.status.branch)
            }
            HStack(spacing: 10) {
                workflowStep("Review", number: "1", active: stagedFiles.isEmpty && !model.status.files.isEmpty)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                workflowStep("Stage", number: "2", active: !stagedFiles.isEmpty)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                workflowStep("Commit locally", number: "3", active: canCommit)
                Spacer(minLength: 0)
                Text("\(model.status.files.count) changed · \(stagedFiles.count) staged")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(motion, value: stagedFiles.count)
            }
        }
    }

    private func workflowStep(_ title: String, number: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text(number).font(.system(size: 10, weight: .semibold, design: .rounded))
                .frame(width: 19, height: 19)
                .background(active ? StudioTheme.accent.opacity(0.16) : Color.primary.opacity(0.05), in: Circle())
            Text(title).font(.caption.weight(active ? .semibold : .regular))
        }
        .foregroundStyle(active ? StudioTheme.accent : .secondary)
        .animation(motion, value: active)
    }

    private func fileColumn(showComposer: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Label("Working changes", systemImage: "square.stack.3d.up")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Menu {
                        Button("Stage All") { model.stageAll(true) }
                        Button("Unstage All") { model.stageAll(false) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).frame(width: 24).disabled(model.busy != nil)
                        .accessibilityLabel("Change actions")
                }.padding(14)
                TextField("Filter changed files", text: $model.search)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 12)
                Divider()
                if model.filteredFiles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: model.status.files.isEmpty ? "checkmark.circle" : "line.3.horizontal.decrease.circle")
                            .font(.title2).foregroundStyle(model.status.files.isEmpty ? StudioTheme.success : .secondary)
                        Text(model.status.files.isEmpty ? "All clear" : "No matching files")
                            .font(.callout.weight(.medium))
                        Text(model.status.files.isEmpty ? "Your next idea starts here." : "Try a different file name.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(16)
                } else {
                    List(selection: $model.selectedFile) {
                        ForEach(model.filteredFiles) { file in
                            fileRow(file).tag(file.path)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .animation(motion, value: model.status.files)
                }
            }
            .frame(minHeight: 170, maxHeight: .infinity)
            .background(StudioTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.border))
            if showComposer {
                ScrollView { checkpointComposer }
                    .frame(minHeight: 250, idealHeight: model.lastCheckpoint == nil ? 330 : 390, maxHeight: 440)
                    .padding(.top, 12)
            }
        }
        .padding(.trailing, 8)
    }

    private func fileRow(_ file: GitFileChange) -> some View {
        HStack(spacing: 9) {
            Button { model.stage(file, staged: !file.isStaged) } label: {
                Image(systemName: file.isConflicted ? "exclamationmark.triangle.fill" : file.isStaged ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(file.isConflicted ? Color.orange : file.isStaged ? StudioTheme.accent : Color.secondary)
                    .contentTransition(.opacity)
                    .animation(motion, value: file.isStaged)
            }
            .buttonStyle(.plain).disabled(file.isConflicted || model.busy != nil)
            .help(file.isStaged ? "Unstage file" : "Stage file")
            .accessibilityLabel("\(file.isStaged ? "Unstage" : "Stage") \(file.path)")
            StudioFileIcon(path: file.path).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text((file.path as NSString).lastPathComponent)
                    .font(.callout.weight(.medium)).lineLimit(1)
                Text(file.isStaged && file.isUnstaged ? "Staged + unstaged changes" : file.path)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: file.isConflicted ? "exclamationmark.circle" : file.isUntracked ? "plus.circle" : file.isStaged ? "checkmark.circle.fill" : "pencil.circle")
                .font(.caption).foregroundStyle(file.isConflicted ? Color.orange : file.isStaged ? StudioTheme.success : .secondary)
                .accessibilityLabel(file.isConflicted ? "Conflict" : file.isStaged ? "Has staged changes" : file.statusLabel)
        }
        .padding(.vertical, 6)
        .contextMenu {
            if !file.isConflicted {
                Button("Stage File") { model.stage(file, staged: true) }
                if file.isUntracked { Button("Ignore This File") { model.ignore(file) } }
                Button("Unstage File") { model.stage(file, staged: false) }.disabled(!file.isStaged)
                if !file.isUntracked {
                    Button("Discard Unstaged Changes…", role: .destructive) { model.discard(file) }
                }
            }
            Button("Reveal in Finder") {
                if let repo = model.repository { NSWorkspace.shared.activateFileViewerSelecting([repo.url.appendingPathComponent(file.path)]) }
            }
        }
    }

    private var checkpointComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title3).foregroundStyle(StudioTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(StudioTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Save a checkpoint").font(.headline)
                    Text("A local Git commit").font(.caption).foregroundStyle(.secondary)
                }
            }
            stagedSummary
            TextField("Describe your changes", text: $model.commitMessage, axis: .vertical)
                .lineLimit(3...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("commit-message")
                .accessibilityLabel("Commit message")
            DisclosureGroup("Add a co-author") {
                VStack(spacing: 7) {
                    TextField("Name", text: $model.coauthorName).textFieldStyle(.roundedBorder)
                    TextField("Email", text: $model.coauthorEmail).textFieldStyle(.roundedBorder)
                }.padding(.top, 6)
            }.font(.caption)
            HStack(spacing: 7) {
                Button(action: { model.commit() }) {
                    Label("Commit checkpoint", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("commit-staged")
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command).disabled(!canCommit)
                Menu {
                    Button("Undo Latest Commit…", action: model.undoCommit)
                        .disabled(model.status.head == nil || !model.status.conflicts.isEmpty)
                    Button("Amend Latest Commit…") {
                        model.confirm("Amend Commit", "Replace the latest commit using the staged changes and this message? This rewrites its history. Avoid amending shared commits.") { model.commit(amend: true) }
                    }.disabled(model.status.head == nil || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.status.conflicts.isEmpty)
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).frame(width: 20).disabled(model.busy != nil)
                    .accessibilityLabel("More commit actions")
            }
            Label("Only staged changes. Push when you’re ready.", systemImage: "lock.shield")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.status.conflicts.isEmpty {
                Label("Resolve conflicts before committing.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let checkpoint = model.lastCheckpoint {
                VStack(alignment: .leading, spacing: 6) {
                    Label(checkpoint.amended ? "Amended locally" : "Committed locally", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(StudioTheme.success)
                    Text(checkpoint.subject).font(.callout).lineLimit(2)
                    Button("Open history") { model.section = .history }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(StudioTheme.accent)
                }
                .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioTheme.success.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .id(checkpoint.id)
                .transition(.opacity.combined(with: .offset(y: 5)))
                .accessibilityIdentifier("checkpoint-success")
            }
        }
        .padding(14)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.border))
        .animation(motion, value: model.lastCheckpoint?.id)
    }

    private var stagedSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Staged for commit").font(.caption.weight(.medium))
                Spacer()
                Text("\(stagedFiles.count)").font(.caption.monospacedDigit()).foregroundStyle(StudioTheme.accent)
                    .contentTransition(.numericText()).animation(motion, value: stagedFiles.count)
            }
            if stagedFiles.isEmpty {
                Label("Stage a file to include its changes.", systemImage: "tray")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                ForEach(stagedFiles.prefix(4)) { file in
                    Button {
                        model.selectedFile = file.path
                        model.stagedDiff = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(StudioTheme.success)
                            Text((file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if file.isUnstaged { Text("Partial").foregroundStyle(.secondary) }
                        }.font(.caption)
                    }.buttonStyle(.plain).help("Review the staged version of \(file.path)")
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }
                if stagedFiles.count > 4 {
                    Text("And \(stagedFiles.count - 4) more files").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .background(StudioTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
        .animation(motion, value: stagedFiles.map(\.path))
    }

    private var diffColumn: some View {
        VStack(spacing: 0) {
            if let file = model.selectedChange {
                diffHeader(file)
                Divider()
                if file.isConflicted {
                    ContentUnavailableView {
                        Label("Resolve this file visually", systemImage: "arrow.triangle.merge")
                    } description: { Text("Compare the versions and compose a result in the conflict workspace.") } actions: {
                        Button("Open Conflict Workspace") { model.section = .conflicts }.buttonStyle(.borderedProminent)
                    }
                } else if model.diffLoading {
                    ProgressView("Loading changes…").font(.caption)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.diffText.isEmpty {
                    ContentUnavailableView("No changes in this view", systemImage: "checkmark.circle", description: Text("Try the \(model.stagedDiff ? "unstaged" : "staged") view."))
                } else {
                    if sideBySide { SideBySideDiff(text: model.diffText) } else { DiffTextView(text: model.diffText) }
                    hunkBar(file)
                }
            } else {
                emptyReview
            }
        }
        .background(StudioTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.border))
        .padding(.leading, 8)
    }

    private func diffHeader(_ file: GitFileChange) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StudioFileIcon(path: file.path).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text((file.path as NSString).lastPathComponent).font(.headline).lineLimit(1)
                    Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                StudioBadge(file.statusLabel, tint: file.isConflicted ? .orange : .secondary)
            }
            HStack(spacing: 8) {
                Picker("Changes", selection: $model.stagedDiff) {
                    Text("Unstaged").tag(false); Text("Staged").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 168)
                Toggle(isOn: $sideBySide) { Image(systemName: "rectangle.split.2x1") }
                    .toggleStyle(.button).help("Side-by-side diff").accessibilityLabel("Side-by-side diff")
                Spacer(minLength: 0)
                if !file.isConflicted {
                    Button(model.stagedDiff ? "Unstage file" : "Stage file") {
                        model.stage(file, staged: !model.stagedDiff)
                    }.disabled(model.busy != nil)
                }
            }
        }.padding(14)
    }

    private var emptyReview: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(StudioTheme.accent.opacity(0.045)).frame(width: 134, height: 134)
                Circle().strokeBorder(StudioTheme.accent.opacity(0.13), lineWidth: 1).frame(width: 106, height: 106)
                Image(systemName: model.status.files.isEmpty ? "checkmark.seal" : "doc.text.magnifyingglass")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(model.status.files.isEmpty ? StudioTheme.success : StudioTheme.accent)
            }.accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(model.status.files.isEmpty ? "Your working tree is clean" : "Select a file to review")
                    .font(.title3.weight(.semibold))
                Text(model.status.files.isEmpty ? "You’re ready for your next idea." : "See what changed, then stage what belongs together.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if model.status.files.isEmpty {
                Button("Explore history") { model.section = .history }.buttonStyle(.bordered)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func hunkBar(_ file: GitFileChange) -> some View {
        let patch = GitPatch(diff: model.diffText)
        if patch.canApplyHunks && file.originalPath == nil && !file.isUntracked {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { hunkPicker(patch); Spacer(minLength: 0); hunkActions(patch) }
                VStack(alignment: .leading, spacing: 9) { hunkPicker(patch); HStack { Spacer(); hunkActions(patch) } }
            }.padding(12).background(StudioTheme.elevated)
        }
    }

    private func hunkPicker(_ patch: GitPatch) -> some View {
        Picker("Hunk", selection: $selectedHunk) {
            ForEach(patch.hunks.indices, id: \.self) { index in Text("\(index + 1): \(patch.hunks[index].title)").tag(index) }
        }.frame(maxWidth: 400)
    }

    private func hunkActions(_ patch: GitPatch) -> some View {
        Group {
            Button("Select Lines…") {
                guard let path = model.selectedFile else { return }
                lineSelection = LineSelectionRequest(path: path, staged: model.stagedDiff, diff: model.diffText)
            }.disabled(model.busy != nil || !patch.canApplyLines)
                .help(patch.canApplyLines ? "Choose additions and deletions individually" : "Individual-line staging is available for ordinary text edits")
            Button(model.stagedDiff ? "Unstage Hunk" : "Stage Hunk") { applyHunk(patch) }.disabled(model.busy != nil)
        }
    }

    private func applyHunk(_ patch: GitPatch) {
        guard patch.hunks.indices.contains(selectedHunk), let repo = model.repository, let path = model.selectedFile else { return }
        let expected = model.diffText
        let staged = model.stagedDiff
        let hunkID = selectedHunk
        model.execute(staged ? "Unstaging hunk…" : "Staging hunk…") {
            try await repo.applyHunk(path: path, staged: staged, hunkID: hunkID, expectedDiff: expected)
        }
    }
}

struct DiffTextView: NSViewRepresentable {
    let text: String

    final class Coordinator {
        var renderedText: String?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        let editor = NSTextView(usingTextLayoutManager: true)
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = NSSize(width: 16, height: 14)
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 100000, height: CGFloat.greatestFiniteMagnitude)
        editor.usesFindBar = true; editor.allowsUndo = false
        editor.setAccessibilityLabel("File diff")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView, context.coordinator.renderedText != text else { return }
        context.coordinator.renderedText = text
        let visible = String(text.prefix(1_000_000))
        let content = visible + (text.count > visible.count ? "\n[Preview limited to 1 million characters]" : "")
        let attributed = NSMutableAttributedString(string: content, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor])
        (content as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (content as NSString).length), options: [.byLines]) { line, range, _, _ in
            guard let line else { return }
            let color: NSColor?
            let background: NSColor?
            if line.hasPrefix("+++") || line.hasPrefix("---") { color = .secondaryLabelColor; background = nil }
            else if line.hasPrefix("+") { color = .systemGreen; background = NSColor.systemGreen.withAlphaComponent(0.07) }
            else if line.hasPrefix("-") { color = .systemRed; background = NSColor.systemRed.withAlphaComponent(0.07) }
            else if line.hasPrefix("@@") { color = .systemPurple; background = NSColor.systemPurple.withAlphaComponent(0.06) }
            else { color = nil; background = nil }
            if let color { attributed.addAttribute(.foregroundColor, value: color, range: range) }
            if let background { attributed.addAttribute(.backgroundColor, value: background, range: range) }
        }
        editor.textStorage?.setAttributedString(attributed)
        editor.scrollToBeginningOfDocument(nil)
    }
}

struct SideBySideDiff: View {
    let text: String
    var body: some View {
        HSplitView {
            VStack(spacing: 0) { Text("Before").font(.caption).padding(8); Divider(); DiffTextView(text: column(old: true)) }
            VStack(spacing: 0) { Text("After").font(.caption).padding(8); Divider(); DiffTextView(text: column(old: false)) }
        }
    }
    private func column(old: Bool) -> String {
        text.components(separatedBy: "\n").map { line in
            if line.hasPrefix(old ? "+" : "-") { return "" }
            return line
        }.joined(separator: "\n")
    }
}
