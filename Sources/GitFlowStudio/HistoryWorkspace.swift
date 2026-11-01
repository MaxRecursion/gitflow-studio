import SwiftUI
import AppKit
import GitCore

struct HistoryWorkspace: View {
    @Bindable var model: StudioModel
    @ViewState private var compareRevision = "HEAD"
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack { Text("History").font(.title2.weight(.semibold)); Spacer(); Text("\(model.commits.count) loaded").font(.caption).foregroundStyle(.secondary) }.padding(16)
                TextField("Search commit messages", text: $model.search).textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.bottom, 12)
                    .onSubmit { Task { await model.loadSection() } }
                Divider()
                let graph = CommitGraph.layout(model.commits)
                List(selection: $model.selectedCommit) {
                    ForEach(Array(model.commits.enumerated()), id: \.element.sha) { index, commit in
                        HStack(spacing: 10) {
                            GraphLane(row: graph[index]).frame(width: CGFloat(graph[index].width) * 14 + 16, height: 60).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(commit.subject).font(.callout.weight(.medium)).lineLimit(2)
                                if !commit.decorations.isEmpty { Text(commit.decorations).font(.caption2.weight(.semibold)).foregroundStyle(.tint).lineLimit(1) }
                                HStack { Text(commit.author).lineLimit(1); Text(commit.date, style: .date); Spacer(); Text(commit.shortSHA).monospaced() }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.tag(commit.sha).accessibilityIdentifier("history-commit-" + commit.sha).contextMenu {
                            Button("Copy Commit SHA") { copy(commit.sha) }
                            Button("Check Out Commit…") { checkout(commit) }
                            Button("Reset Here, Keep Staged…") { reset(commit, mode: .soft) }
                            Button("Reset Here, Unstage All…") { reset(commit, mode: .mixed) }
                            Button("Compare with HEAD") { model.compare(commit.sha, to: "HEAD") }
                            Button("Cherry-pick…") { confirm(.cherryPick, commit) }.disabled(commit.parents.count > 1)
                            Button("Revert…") { confirm(.revert, commit) }.disabled(commit.parents.count > 1)
                        }
                    }
                    if model.historyHasMore { Button("Load 100 More Commits", action: model.loadMoreHistory).disabled(model.busy != nil) }
                }.listStyle(.inset)
            }.frame(minWidth: 340, idealWidth: 470, maxWidth: 700)
            VStack(spacing: 0) {
                if let commit = model.commits.first(where: { $0.sha == model.selectedCommit }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(commit.subject).font(.title3.weight(.semibold)).textSelection(.enabled)
                        HStack {
                            Text(commit.author).foregroundStyle(.secondary)
                            Spacer()
                            Button(commit.shortSHA) { copy(commit.sha) }.font(.system(.caption, design: .monospaced)).help("Copy full SHA")
                            Menu("Actions") {
                                Button("Check Out Commit…") { checkout(commit) }
                                Button("Reset Here, Keep Staged…") { reset(commit, mode: .soft) }
                                Button("Reset Here, Unstage All…") { reset(commit, mode: .mixed) }
                                Button("Cherry-pick…") { confirm(.cherryPick, commit) }.disabled(commit.parents.count > 1)
                                Button("Revert…") { confirm(.revert, commit) }.disabled(commit.parents.count > 1)
                            }
                        }
                        if !commit.parents.isEmpty {
                            HStack { Text("Parents").foregroundStyle(.secondary); ForEach(commit.parents, id: \.self) { sha in Button(String(sha.prefix(8))) { model.preview("Parent " + String(sha.prefix(8)), arguments: ["show", "--no-ext-diff", "--no-textconv", sha, "--"]) }.font(.caption.monospaced()) } }
                        }
                        HStack { TextField("Compare to branch or SHA", text: $compareRevision).textFieldStyle(.roundedBorder); Button("Compare") { model.compare(commit.sha, to: compareRevision) }.disabled(compareRevision.isEmpty) }
                    }.padding(16)
                    Divider()
                    DiffTextView(text: model.commitDetail)
                } else { ContentUnavailableView("Every change has a story", systemImage: "clock.arrow.circlepath", description: Text("Select a commit to inspect its details and changes.")) }
            }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }.onChange(of: model.selectedCommit) { _, _ in model.loadCommit() }
    }
    private func checkout(_ commit: GitCommit) {
        guard let repo = model.repository, let head = model.status.head else { return }
        model.confirm("Check Out Commit", "Open \(commit.shortSHA) in detached HEAD mode? Commit or stash pending work first. Create a branch before making new commits.") {
            model.execute("Checking out commit…") { try await repo.checkoutDetached(commit.sha, expectedHead: head) }
        }
    }
    private func reset(_ commit: GitCommit, mode: GitResetMode) {
        guard let repo = model.repository, let head = model.status.head else { return }
        let effect = mode == .soft ? "The index will remain staged." : "All staged changes will become unstaged."
        model.confirm("Reset History", "Move HEAD to \(commit.shortSHA)? \(effect) Working files are preserved. Known published commits and non-ancestor targets are refused. This rewrites local history.", destructive: true) {
            model.execute("Resetting local history…") { try await repo.resetHistory(to: commit.sha, mode: mode, expectedHead: head) }
        }
    }
    private func copy(_ sha: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sha, forType: .string) }
    private func confirm(_ operation: GitOperation, _ commit: GitCommit) {
        model.confirm(operation == .revert ? "Revert Commit" : "Cherry-pick Commit", "Apply \(operation == .revert ? "the inverse of" : "the changes from") \(commit.shortSHA) to \(model.status.branch)? This creates a commit when successful; conflicts open in the resolver.") {
            model.integrate(operation, revision: commit.sha)
        }
    }
}

struct CommitGraph {
    struct Edge { let from: Int; let to: Int }
    struct Row { let lane: Int; let before: [Int]; let edges: [Edge]; let width: Int; let merge: Bool }
    static func layout(_ commits: [GitCommit]) -> [Row] {
        var lanes: [String] = [], rows: [Row] = []
        for commit in commits {
            if !lanes.contains(commit.sha) { lanes.append(commit.sha) }
            let before = lanes
            let lane = lanes.firstIndex(of: commit.sha)!
            lanes.remove(at: lane)
            for parent in commit.parents.reversed() where !lanes.contains(parent) { lanes.insert(parent, at: min(lane, lanes.count)) }
            var edges: [Edge] = []
            for (index, sha) in before.enumerated() where sha != commit.sha {
                if let target = lanes.firstIndex(of: sha) { edges.append(Edge(from: index, to: target)) }
            }
            for parent in commit.parents { if let target = lanes.firstIndex(of: parent) { edges.append(Edge(from: lane, to: target)) } }
            rows.append(Row(lane: lane, before: Array(before.indices), edges: edges, width: max(before.count, lanes.count), merge: commit.parents.count > 1))
        }
        return rows
    }
}

struct GraphLane: View {
    let row: CommitGraph.Row
    private let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .green]
    var body: some View {
        NativeCommitGraph(row: row, colors: colors, nodeOutline: row.merge ? .primary : nil)
    }
}
