import SwiftUI
import GitCore

struct LineSelectionRequest: Identifiable {
    let id = UUID()
    let path: String
    let staged: Bool
    let diff: String
}

struct LineStagingSheet: View {
    @Bindable var model: StudioModel
    let request: LineSelectionRequest
    @Environment(\.dismiss) private var dismiss
    private struct PreparedHunk: Identifiable, Sendable {
        let id: Int
        let title: String
        let lines: [GitDiffLine]
    }
    private struct PreparedPatch: Sendable {
        let canApplyLines: Bool
        let hunks: [PreparedHunk]
    }
    @ViewState private var patch: PreparedPatch?
    @ViewState private var selection: [Int: Set<Int>] = [:]
    private var selectedCount: Int { selection.values.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(request.staged ? "Unstage Individual Lines" : "Stage Individual Lines").font(.title2.bold())
                Text(request.path).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                Text(request.staged
                     ? "Choose additions and deletions to remove from the index. Your working file stays intact."
                     : "Choose additions and deletions independently. Unticked edits remain unstaged.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Select All Changes") { selectAll() }.disabled(patch == nil)
                    Button("Clear Selection") { selection = [:] }.disabled(selectedCount == 0)
                    Spacer()
                    Text("\(selectedCount) \(selectedCount == 1 ? "line" : "lines") selected").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.top, 5)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if let patch {
                if patch.canApplyLines {
                    List {
                        ForEach(patch.hunks) { hunk in
                            Section {
                                ForEach(hunk.lines) { line in lineRow(line, hunkID: hunk.id) }
                            } header: { Text(hunk.title).font(.caption.monospaced()).textCase(nil) }
                        }
                    }.listStyle(.inset)
                } else {
                    ContentUnavailableView("Use file or hunk staging", systemImage: "doc.text",
                                           description: Text("This patch includes metadata or a missing final newline that cannot be split into individual lines here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else { ProgressView("Preparing line selection…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            Divider()
            HStack {
                Text("Git verifies this preview is current before changing the index.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.staged ? "Unstage Selected Lines" : "Stage Selected Lines", action: apply)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(selectedCount == 0 || patch?.canApplyLines != true || model.busy != nil)
            }.padding(16)
        }.frame(minWidth: 760, idealWidth: 900, minHeight: 540, idealHeight: 650)
            .task(id: request.id) {
                let diff = request.diff
                let result = await Task.detached(priority: .userInitiated) {
                    let parsed = GitPatch(diff: diff)
                    return PreparedPatch(canApplyLines: parsed.canApplyLines,
                                         hunks: parsed.hunks.map { PreparedHunk(id: $0.id, title: $0.title, lines: $0.lines) })
                }.value
                if !Task.isCancelled { patch = result }
            }
    }

    private func lineRow(_ line: GitDiffLine, hunkID: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if line.isSelectable {
                Toggle(isOn: Binding(get: { selection[hunkID]?.contains(line.id) == true }, set: { value in
                    if value { selection[hunkID, default: []].insert(line.id) }
                    else { selection[hunkID]?.remove(line.id) }
                })) { EmptyView() }.toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel("Select \(line.kind == .addition ? "addition" : "deletion") at line \(line.newLineNumber ?? line.oldLineNumber ?? 0): \(line.text)")
                    .frame(width: 18)
            } else { Color.clear.frame(width: 18, height: 12) }
            Text(line.oldLineNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.newLineNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ").frame(width: 12)
                .foregroundStyle(line.kind == .addition ? Color.green : line.kind == .deletion ? Color.red : Color.secondary)
            Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12, design: .monospaced)).padding(.vertical, 3)
            .listRowBackground(line.kind == .addition ? Color.green.opacity(0.07) : line.kind == .deletion ? Color.red.opacity(0.07) : Color.clear)
    }
    private func selectAll() {
        guard let patch else { return }
        selection = Dictionary(uniqueKeysWithValues: patch.hunks.map { ($0.id, Set($0.lines.filter(\.isSelectable).map(\.id))) })
    }
    private func apply() {
        guard let repo = model.repository else { return }
        let chosen = selection
        dismiss()
        model.execute(request.staged ? "Unstaging selected lines…" : "Staging selected lines…") {
            try await repo.applyLines(path: request.path, staged: request.staged, selection: chosen, expectedDiff: request.diff)
        }
    }
}
