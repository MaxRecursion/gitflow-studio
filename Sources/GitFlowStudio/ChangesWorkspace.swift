import SwiftUI
import AppKit
import GitCore

struct ChangesWorkspace: View {
    @Bindable var model: StudioModel
    @ViewState private var sideBySide = false
    @ViewState private var selectedHunk: Int = 0
    @ViewState private var lineSelection: LineSelectionRequest?
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Working Changes").font(.headline)
                    Spacer()
                    Menu {
                        Button("Stage All") { model.stageAll(true) }
                        Button("Unstage All") { model.stageAll(false) }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
                }.padding(14)
                TextField("Filter changed files", text: $model.search).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 10)
                Divider()
                List(model.filteredFiles, selection: $model.selectedFile) { file in
                    HStack(spacing: 9) {
                        Button { model.stage(file, staged: !file.isStaged) } label: {
                            Image(systemName: file.isConflicted ? "exclamationmark.triangle" : file.isStaged ? "checkmark.square.fill" : "square")
                                .foregroundStyle(file.isConflicted ? Color.orange : file.isStaged ? Color.accentColor : Color.secondary)
                        }.buttonStyle(.plain).disabled(file.isConflicted || model.busy != nil)
                            .help(file.isStaged ? "Unstage file" : "Stage file").accessibilityLabel("\(file.isStaged ? "Unstage" : "Stage") \(file.path)")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(URL(fileURLWithPath: file.path).lastPathComponent).lineLimit(1)
                            Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Text(file.isConflicted ? "!" : file.isUntracked ? "+" : file.statusLabel.prefix(1).uppercased())
                            .font(.caption.bold()).foregroundStyle(file.isConflicted ? .orange : .secondary)
                    }.padding(.vertical, 4).tag(file.path)
                        .contextMenu {
                            if !file.isConflicted {
                                Button("Stage File") { model.stage(file, staged: true) }
                                Button("Unstage File") { model.stage(file, staged: false) }.disabled(!file.isStaged)
                                if !file.isUntracked {
                                    Button("Discard Unstaged Changes…", role: .destructive) {
                                        model.discard(file)
                                    }
                                }
                            }
                            Button("Reveal in Finder") {
                                if let repo = model.repository { NSWorkspace.shared.activateFileViewerSelecting([repo.url.appendingPathComponent(file.path)]) }
                            }
                        }
                }.listStyle(.inset)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Commit to \(model.status.branch)").font(.callout.weight(.semibold))
                    TextField("Describe your changes", text: $model.commitMessage, axis: .vertical)
                        .lineLimit(3...6).textFieldStyle(.roundedBorder).accessibilityIdentifier("commit-message")
                    DisclosureGroup("Add a co-author") {
                        TextField("Name", text: $model.coauthorName).textFieldStyle(.roundedBorder)
                        TextField("Email", text: $model.coauthorEmail).textFieldStyle(.roundedBorder)
                    }.font(.caption)
                    HStack {
                        Button("Commit Staged") { model.commit() }.accessibilityIdentifier("commit-staged").buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.status.files.contains(where: \.isStaged) || !model.status.conflicts.isEmpty || model.busy != nil)
                        Menu {
                            Button("Undo Latest Commit…", action: model.undoCommit).disabled(model.status.head == nil || !model.status.conflicts.isEmpty)
                            Button("Amend Latest Commit…") {
                                model.confirm("Amend Commit", "Replace the latest commit using the staged changes and this message? This rewrites its history. Avoid amending shared commits.") { model.commit(amend: true) }
                            }.disabled(model.status.head == nil || model.commitMessage.isEmpty || !model.status.conflicts.isEmpty)
                        } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).frame(width: 24)
                    }
                    Text("Only staged changes are included.").font(.caption).foregroundStyle(.secondary)
                }.padding(14)
            }.frame(minWidth: 260, idealWidth: 310, maxWidth: 410)
            VStack(spacing: 0) {
                if let file = model.selectedChange {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.path).font(.headline).lineLimit(1).truncationMode(.middle)
                            Text(file.statusLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Changes", selection: $model.stagedDiff) { Text("Unstaged").tag(false); Text("Staged").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 172)
                        Toggle(isOn: $sideBySide) { Image(systemName: "rectangle.split.2x1") }.toggleStyle(.button).help("Side-by-side diff")
                    }.padding(14)
                    Divider()
                    if file.isConflicted {
                        ContentUnavailableView {
                            Label("Resolve this file visually", systemImage: "arrow.triangle.merge")
                        } description: { Text("Compare the versions and compose a result in the conflict workspace.") } actions: {
                            Button("Open Conflict Workspace") { model.section = .conflicts }.buttonStyle(.borderedProminent)
                        }
                    } else if model.diffLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if model.diffText.isEmpty { ContentUnavailableView("No changes in this view", systemImage: "checkmark.circle", description: Text("Try the \(model.stagedDiff ? "unstaged" : "staged") view.")) }
                    else {
                        if sideBySide { SideBySideDiff(text: model.diffText) } else { DiffTextView(text: model.diffText) }
                        hunkBar(file)
                    }
                } else {
                    ContentUnavailableView(model.status.files.isEmpty ? "Your working tree is clean" : "Select a file to review", systemImage: model.status.files.isEmpty ? "checkmark.seal" : "doc.text.magnifyingglass", description: Text(model.status.files.isEmpty ? "You’re ready for your next change." : "Inspect changes, stage what belongs together, and commit."))
                }
            }.frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.selectedFile) { _, _ in
            if let file = model.selectedChange { model.stagedDiff = file.isStaged && !file.isUnstaged }
            selectedHunk = 0; model.loadDiff()
        }
        .onChange(of: model.stagedDiff) { _, _ in selectedHunk = 0; model.loadDiff() }
        .sheet(item: $lineSelection) { request in LineStagingSheet(model: model, request: request) }
    }

    @ViewBuilder private func hunkBar(_ file: GitFileChange) -> some View {
        let patch = GitPatch(diff: model.diffText)
        if patch.canApplyHunks && file.originalPath == nil && !file.isUntracked {
            Divider()
            HStack {
                Picker("Hunk", selection: $selectedHunk) {
                    ForEach(patch.hunks.indices, id: \.self) { index in Text("\(index + 1): \(patch.hunks[index].title)").tag(index) }
                }.frame(maxWidth: 400)
                Spacer()
                Button("Select Lines…") {
                    lineSelection = LineSelectionRequest(path: file.path, staged: model.stagedDiff, diff: model.diffText)
                }.disabled(model.busy != nil || !patch.canApplyLines)
                    .help(patch.canApplyLines ? "Choose additions and deletions individually" : "Individual-line staging is available for ordinary text patches with final newlines")
                Button(model.stagedDiff ? "Unstage Hunk" : "Stage Hunk") { applyHunk(patch) }.disabled(model.busy != nil)
            }.padding(10)
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
        editor.textContainerInset = NSSize(width: 14, height: 12)
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 100000, height: CGFloat.greatestFiniteMagnitude)
        editor.usesFindBar = true; editor.allowsUndo = false
        editor.setAccessibilityLabel("File diff")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        let visible = String(text.prefix(1_000_000))
        let content = visible + (text.count > visible.count ? "\n[Preview limited to 1 million characters]" : "")
        let attributed = NSMutableAttributedString(string: content, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor])
        (content as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (content as NSString).length), options: [.byLines]) { line, range, _, _ in
            let color: NSColor?
            if line?.hasPrefix("+") == true { color = .systemGreen }
            else if line?.hasPrefix("-") == true { color = .systemRed }
            else if line?.hasPrefix("@@") == true { color = .systemBlue }
            else { color = nil }
            if let color { attributed.addAttribute(.foregroundColor, value: color, range: range) }
        }
        editor.textStorage?.setAttributedString(attributed)
        editor.scrollToBeginningOfDocument(nil)
    }
}

struct SideBySideDiff: View {
    let text: String
    var body: some View {
        HSplitView {
            VStack(spacing: 0) { Text("Before").font(.caption).padding(7); Divider(); DiffTextView(text: column(old: true)) }
            VStack(spacing: 0) { Text("After").font(.caption).padding(7); Divider(); DiffTextView(text: column(old: false)) }
        }
    }
    private func column(old: Bool) -> String {
        text.components(separatedBy: "\n").map { line in
            if line.hasPrefix(old ? "+" : "-") { return "" }
            return line
        }.joined(separator: "\n")
    }
}
