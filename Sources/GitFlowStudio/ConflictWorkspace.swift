import AppKit
import SwiftUI
import Observation
import GitCore

@MainActor @Observable final class ConflictViewModel {
    let service: ConflictService
    let scrollGroup = EditorScrollGroup()
    var synchronizeSources = true
    var currentWordRanges: [NSRange] = []
    var incomingWordRanges: [NSRange] = []
    var wordComparisonLimited = false
    @ObservationIgnored private var wordTask: Task<Void, Never>?
    var overview = ConflictOverview(operation: .none, files: [])
    var snapshot: ConflictSnapshot?
    var document: MergeDocument?
    var selectedPath: String?
    var selectedRegion = 0
    var resolvedPaths: Set<String> = []
    var busy = false
    var loaded = false
    var dirty = false
    var error: String?
    var undoDocuments: [MergeDocument] = []
    var showBase = false
    var showWorktree = false
    var showDrafts = false
    var savedDrafts: [ConflictDraftDescriptor] = []
    var reviewDraft: ConflictDraft?
    var recovery: ConflictDraftRecovery?
    var staleDraft = false
    var draftStatus: String?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var draftContext: ConflictDraftContext?
    @ObservationIgnored private let draftStore = ConflictDraftStore.shared
    init(repository: GitRepository) { service = ConflictService(repository: repository) }
    var region: MergeRegion? { document?.regions.first { $0.id == selectedRegion } }
    func refresh() async {
        busy = true
        defer { busy = false }
        do {
            let fresh = try await service.overview()
            overview = fresh; loaded = true
            if dirty, let selectedPath, let snapshot {
                // Never clear a draft because another tool staged, resolved, or
                // aborted its file. Keep the text and disable writes until review.
                if fresh.operation != snapshot.operation || !fresh.files.contains(where: { $0.path == selectedPath && $0 == snapshot.file }) {
                    staleDraft = true
                } else if !staleDraft {
                    let freshSnapshot = try await service.load(path: selectedPath)
                    staleDraft = try await ConflictDraftContext.capture(repository: service.repository, snapshot: freshSnapshot) != draftContext
                }
                if staleDraft { draftStatus = "Git changed outside this draft. Your edits are retained for review and export."; _ = await flushDraft() }
                return
            }
            if let selectedPath, fresh.files.contains(where: { $0.path == selectedPath }) { return }
            if let first = fresh.files.first { await select(first.path) }
            else { snapshot = nil; document = nil; selectedPath = nil; recovery = nil; staleDraft = false; await refreshSavedDrafts() }
        } catch { self.error = error.localizedDescription }
    }
    func select(_ path: String) async {
        busy = true
        defer { busy = false }
        do {
            let loaded = try await service.load(path: path)
            let context = try await ConflictDraftContext.capture(repository: service.repository, snapshot: loaded)
            draftTask?.cancel()
            snapshot = loaded; document = loaded.document; selectedPath = path; draftContext = context
            selectedRegion = 0; dirty = false; undoDocuments = []; staleDraft = false; draftStatus = nil; recovery = nil
            do { recovery = try await draftStore.load(context: context) }
            catch { draftStatus = error.localizedDescription }
            await refreshSavedDrafts()
            updateWordComparison()
        } catch { self.error = error.localizedDescription }
    }
    func refreshSavedDrafts() async {
        do { savedDrafts = try await draftStore.list(repository: service.repository.url) }
        catch { draftStatus = error.localizedDescription }
    }
    func scheduleDraftSave() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            _ = await self.flushDraft()
        }
    }
    /// Call before an orderly repository switch/close when retaining the draft.
    @discardableResult func flushDraft() async -> Bool {
        guard dirty, let document, let context = draftContext else { return true }
        guard recovery == nil else { draftStatus = "Review the saved draft before replacing it."; return false }
        do {
            _ = try await draftStore.save(document: document, context: context)
            if !staleDraft { draftStatus = "Draft saved on this Mac" }
            await refreshSavedDrafts()
            return true
        } catch { draftStatus = error.localizedDescription; return false }
    }
    /// An explicit discard removes only this exact snapshot's recovery copy.
    @discardableResult func discardDraft() async -> Bool {
        draftTask?.cancel()
        do {
            if let context = draftContext { try await draftStore.remove(context: context) }
            dirty = false; staleDraft = false; draftStatus = nil; recovery = nil
            await refreshSavedDrafts()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func restoreDraft() {
        guard case .matching(let saved) = recovery, saved.context == draftContext else { return }
        document = saved.document; dirty = true; selectedRegion = document?.regions.first?.id ?? 0
        recovery = nil; undoDocuments = []; draftStatus = "Recovered local draft — review before staging"
        updateWordComparison()
    }
    func review(_ descriptor: ConflictDraftDescriptor) async {
        showDrafts = true
        do { reviewDraft = try await draftStore.read(descriptor) }
        catch { reviewDraft = nil; self.error = error.localizedDescription }
    }
    func discardSaved(_ descriptor: ConflictDraftDescriptor) async {
        do {
            try await draftStore.remove(descriptor)
            if recovery?.draft.id == descriptor.id { recovery = nil; draftStatus = nil }
            if reviewDraft?.id == descriptor.id { reviewDraft = nil }
            await refreshSavedDrafts()
        } catch { self.error = error.localizedDescription }
    }
    func choose(_ choice: MergeChoice) {
        guard let document else { return }
        undoDocuments.append(document)
        if undoDocuments.count > 40 { undoDocuments.removeFirst() }
        self.document?.choose(choice, region: selectedRegion)
        dirty = true
        scheduleDraftSave()
    }
    func updateWordComparison() {
        wordTask?.cancel()
        currentWordRanges = []; incomingWordRanges = []; wordComparisonLimited = false
        guard let region, let snapshot else { return }
        let current = snapshot.current.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let incoming = snapshot.incoming.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        wordTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let difference = WordDifference.compare(current: region.current, incoming: region.incoming)
                return (WordDifference.locateUnique(region.current, in: current, ranges: difference.current), WordDifference.locateUnique(region.incoming, in: incoming, ranges: difference.incoming), difference.wasLimited)
            }.value
            guard !Task.isCancelled, let self else { return }
            currentWordRanges = result.0; incomingWordRanges = result.1; wordComparisonLimited = result.2
        }
    }
    func edit(_ range: NSRange, replacement: String) {
        // A whole-document decision snapshot must never erase later manual edits.
        undoDocuments.removeAll()
        document?.edit(range: range, replacement: replacement)
        dirty = true
        scheduleDraftSave()
    }
    func useWorktree() {
        guard let data = snapshot?.worktree, let text = String(data: data, encoding: .utf8) else { return }
        undoDocuments.removeAll()
        document = MergeDocument(text: text)
        dirty = true
        scheduleDraftSave()
        updateWordComparison()
    }
    func undoChoice() {
        guard let previous = undoDocuments.popLast() else { return }
        document = previous; dirty = true
        scheduleDraftSave()
    }
    func save(_ resolution: ConflictResolution) async -> Bool {
        guard let snapshot, !staleDraft, recovery == nil else { return false }
        busy = true
        defer { busy = false }
        do {
            try await service.resolve(snapshot: snapshot, resolution: resolution)
            resolvedPaths.insert(snapshot.file.path)
            draftTask?.cancel()
            if let context = draftContext { try? await draftStore.remove(context: context) }
            dirty = false; recovery = nil; staleDraft = false; draftStatus = nil
            self.snapshot = nil; selectedPath = nil; document = nil; undoDocuments = []
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

struct ConflictWorkspace: View {
    let repository: GitRepository
    let onRefresh: () -> Void
    @ViewState<ConflictViewModel> private var model: ConflictViewModel
    @ViewState<Confirmation?> private var confirmation: Confirmation?
    @ViewState<SubmodulePreview?> private var submodulePreview: SubmodulePreview?
    private struct SubmodulePreview: Identifiable { let id = UUID(); let text: String }
    private enum Confirmation: Identifiable {
        case proceed, abort, selection(String), delete, version(ConflictResolution), stageText(String), workingFile, savedDraft(ConflictDraftDescriptor), discardCurrent
        var id: String { switch self { case .proceed: "continue"; case .abort: "abort"; case .selection: "selection"; case .delete: "delete"; case .version: "version"; case .stageText: "stageText"; case .workingFile: "workingFile"; case .savedDraft: "savedDraft"; case .discardCurrent: "discardCurrent" } }
    }
    init(repository: GitRepository, model: ConflictViewModel? = nil, onRefresh: @escaping () -> Void) {
        self.repository = repository
        self.onRefresh = onRefresh
        _model = ViewState(initialValue: model ?? ConflictViewModel(repository: repository))
    }
    var body: some View {
        VStack(spacing: 0) {
            overviewHeader
            Divider()
            recoveryBanner
            if !model.loaded {
                ContentUnavailableView("Checking conflict state", systemImage: "arrow.triangle.merge", description: Text(model.error ?? "Reading Git’s unmerged index…"))
            } else if model.overview.files.isEmpty && !model.dirty {
                completion
            } else {
                HSplitView {
                    fileList.frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                    if let snapshot = model.snapshot {
                        VStack(alignment: .leading, spacing: 0) {
                            fileHeader(snapshot)
                            Divider()
                            if model.document != nil { textWorkspace(snapshot) }
                            else { specializedWorkspace(snapshot) }
                        }.frame(minWidth: 500)
                    } else { ContentUnavailableView("Select a conflicted file", systemImage: "arrow.triangle.branch").frame(maxWidth: .infinity) }
                }
            }
        }
        .background(.background)
        .sheet(item: $submodulePreview) { preview in
            VStack(spacing: 0) {
                HStack { Text("Submodule Commit").font(.headline); Spacer(); Button("Done") { submodulePreview = nil } }.padding(16)
                Divider(); DiffTextView(text: preview.text)
            }.frame(minWidth: 600, minHeight: 440)
        }
        .task { await model.refresh() }
        .onChange(of: model.selectedRegion) { _, _ in model.updateWordComparison() }
        .disabled(model.busy)
        .overlay(alignment: .topTrailing) { if model.busy { ProgressView().controlSize(.small).padding(12) } }
        .alert("Conflict resolution", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            switch confirmation {
            case .proceed:
                Button("Continue \(model.overview.operation.title)") { performContinue() }
            case .abort:
                Button("Abort \(model.overview.operation.title)", role: .destructive) { performAbort() }
            case .selection(let path):
                Button("Discard Unsaved Resolution", role: .destructive) { Task { if await model.discardDraft() { await model.select(path) } } }
            case .delete:
                Button(model.snapshot?.isSubmodule == true ? "Remove Reference and Keep Checkout" : "Delete File and Mark Resolved", role: .destructive) { save(.delete) }
            case .version(let resolution):
                Button(model.snapshot?.isSubmodule == true ? "Stage Commit Reference" : "Use This Version and Mark Resolved") { save(resolution) }
            case .stageText(let text):
                Button("Write Result and Stage File") { save(.text(text)) }.accessibilityIdentifier("conflict-write-stage")
            case .workingFile:
                Button("Use Existing Working File") { model.useWorktree() }
            case .savedDraft(let descriptor):
                Button("Discard Saved Draft", role: .destructive) { Task { await model.discardSaved(descriptor) } }
            case .discardCurrent:
                Button("Discard Draft and Reload", role: .destructive) { Task { if await model.discardDraft() { model.selectedPath = nil; await model.refresh() } } }
            case .none: EmptyView()
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { Text(confirmationMessage) }
        .sheet(isPresented: $model.showDrafts) { SavedConflictDraftsSheet(model: model) }
        .sheet(isPresented: $model.showWorktree) {
            VStack(spacing: 0) {
                HStack { Text("Existing Working File").font(.headline); Spacer(); Button("Done") { model.showWorktree = false } }.padding(16)
                Divider()
                NativeCodeEditor(text: .constant(model.snapshot?.worktree.flatMap { String(data: $0, encoding: .utf8) } ?? "No UTF-8 working file"), accessibilityName: "Existing working file")
            }.frame(width: 800, height: 550)
        }
    }
    private var overviewHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.merge").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(!model.loaded ? "Checking conflict state" : model.staleDraft ? "Draft needs review" : model.overview.files.isEmpty ? "All conflicts resolved" : "\(model.overview.operation.title) requires attention").font(.headline)
                Text("\(model.resolvedPaths.count) resolved this session · \(model.overview.files.count) remaining").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.savedDrafts.isEmpty {
                Button("Saved Drafts (\(model.savedDrafts.count))") { model.showDrafts = true }
            }
            if model.overview.operation != .none {
                Button("Abort…", role: .destructive) { confirmation = .abort }
                Button("Continue…") { confirmation = .proceed }.buttonStyle(.borderedProminent).disabled(!model.overview.files.isEmpty || model.dirty).accessibilityIdentifier("conflict-continue")
            }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh conflicts")
        }.padding(16)
    }
    @ViewBuilder private var recoveryBanner: some View {
        if let recovery = model.recovery {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.timemachine")
                Text(recovery.matches ? "A saved draft matches this exact Git state." : "A saved draft belongs to an earlier Git state. Review or export it before discarding.").font(.callout)
                Spacer()
                if recovery.matches { Button("Restore Draft") { model.restoreDraft() }.buttonStyle(.borderedProminent) }
                Button("Review") { Task { await model.review(recovery.draft.descriptor) } }
                Button("Discard…", role: .destructive) { confirmation = .savedDraft(recovery.draft.descriptor) }
            }.padding(12).background(.orange.opacity(0.10))
        } else if model.staleDraft {
            HStack(spacing: 12) {
                Text("Git changed outside this draft. Your edits are retained; they cannot be staged against the old versions.").font(.callout)
                Spacer()
                Button("Export Draft…") { if let document = model.document { exportConflictDraft(document.text, path: model.selectedPath ?? "resolution.txt", onError: { model.error = $0 }) } }
                Button("Discard and Reload…", role: .destructive) { confirmation = .discardCurrent }
            }.padding(12).background(.orange.opacity(0.10))
        } else if let status = model.draftStatus, status != "Draft saved on this Mac" {
            Text(status).font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var fileList: some View {
        List {
            Section("Needs resolution") {
                ForEach(model.overview.files) { file in
                    Button {
                        guard file.path != model.selectedPath else { return }
                        if model.dirty { confirmation = .selection(file.path) }
                        else { Task { await model.select(file.path) } }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.path).lineLimit(2).font(.system(.body, design: .monospaced))
                                Text(file.category).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .listRowBackground(file.path == model.selectedPath ? Color.accentColor.opacity(0.12) : Color.clear)
                }
            }
            if !model.resolvedPaths.isEmpty {
                Section("Staged resolutions") { ForEach(model.resolvedPaths.sorted(), id: \.self) { path in Label(path, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary).font(.caption) } }
            }
        }.listStyle(.sidebar)
    }
    private func fileHeader(_ snapshot: ConflictSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(snapshot.file.path).font(.headline).textSelection(.enabled)
                Spacer()
                if snapshot.isText { Toggle("Show ancestor", isOn: $model.showBase).toggleStyle(.checkbox).controlSize(.small) }
                if snapshot.isText { Toggle("Sync scrolling", isOn: $model.synchronizeSources).toggleStyle(.checkbox).controlSize(.small)
                    .onChange(of: model.synchronizeSources) { _, value in model.scrollGroup.enabled = value }
                }
            }
            Text(snapshot.operation.explanation).font(.caption).foregroundStyle(.secondary)
            if snapshot.isText {
                HStack {
                    Text("The draft is rebuilt from Git versions. Review any edits already in the working file before replacing it.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Preview Working File") { model.showWorktree = true }
                    Button("Use Working File…") { confirmation = .workingFile }
                }.controlSize(.small)
            }
        }.padding(12)
    }
    private func textWorkspace(_ snapshot: ConflictSnapshot) -> some View {
        VSplitView {
            HSplitView {
                sourcePane(snapshot.operation.currentLabel, data: snapshot.current, color: .blue)
                if model.showBase { sourcePane("Common ancestor", data: snapshot.base, color: .secondary) }
                sourcePane(snapshot.operation.incomingLabel, data: snapshot.incoming, color: .purple)
            }.frame(minHeight: 120, idealHeight: 240)
            VStack(spacing: 0) {
                regionControls.disabled(model.staleDraft || model.recovery != nil)
                Divider()
                HStack {
                    Label("Merged result", systemImage: "pencil.line").font(.headline)
                    if model.dirty { Text(model.draftStatus == "Draft saved on this Mac" ? "Saved locally" : "Unstaged draft").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text("\(model.document?.remaining ?? 0) regions need a decision").font(.caption).foregroundStyle(.secondary)
                    Button("Mark File Resolved") { if let document = model.document { confirmation = .stageText(document.text) } }
                        .buttonStyle(.borderedProminent).disabled((model.document?.remaining ?? 1) != 0 || model.staleDraft || model.recovery != nil)
                }.padding(10)
                NativeCodeEditor(text: Binding(get: { model.document?.text ?? "" }, set: { _ in }), editable: !model.staleDraft && model.recovery == nil, selectedRange: model.region?.range, selectionID: model.selectedRegion,
                                 onEdit: { range, value in model.edit(range, replacement: value) }, accessibilityName: "Editable merged result")
            }.frame(minHeight: 240)
        }
    }
    private var regionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let regions = model.document?.regions, !regions.isEmpty {
                    Button { model.selectedRegion = max(0, model.selectedRegion - 1) } label: { Image(systemName: "chevron.up") }.disabled(model.selectedRegion == 0).help("Previous conflict")
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Text("Conflict \(model.selectedRegion + 1) of \(regions.count)").font(.subheadline.weight(.semibold))
                    Button { model.selectedRegion = min(regions.count - 1, model.selectedRegion + 1) } label: { Image(systemName: "chevron.down") }.disabled(model.selectedRegion == regions.count - 1).help("Next conflict")
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    if let region = model.region { Text(region.choice == .unresolved ? "Choose a version or edit these lines" : "Decision: \(region.choice.rawValue)").font(.caption).foregroundStyle(.secondary) }
                } else { Text("Git combined the text without overlapping regions. Review the result before staging.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Undo Decision") { model.undoChoice() }.disabled(model.undoDocuments.isEmpty || model.dirty && model.undoDocuments.isEmpty)
            }
            if model.region != nil {
                HStack {
                    Button(model.overview.operation == .rebase ? "Use Destination" : "Use Current") { model.choose(.current) }
                        .accessibilityIdentifier("conflict-use-current")
                        .disabled(model.region?.supportsChoices == false)
                    Button(model.overview.operation == .rebase ? "Use Replayed Commit" : "Use Incoming") { model.choose(.incoming) }
                        .accessibilityIdentifier("conflict-use-incoming")
                        .disabled(model.region?.supportsChoices == false)
                    Button("Keep Both") { model.choose(.both) }.accessibilityIdentifier("conflict-keep-both")
                        .disabled(model.region?.supportsChoices == false)
                    Button("Accept Edited Region") { model.choose(.manual) }.help("Explicitly accept the currently edited text for this region")
                    Spacer()
                    Button("Reset Region") { model.choose(.unresolved) }
                        .disabled(model.region?.supportsChoices == false)
                }.controlSize(.small)
                if model.region?.supportsChoices == false {
                    Text("Your manual edit spans this region’s boundary. Continue editing the result to preserve those edits.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.wordComparisonLimited { Text("Word highlights are limited for large regions; full source text remains available.").font(.caption).foregroundStyle(.secondary) }
        }.padding(10).background(.quaternary.opacity(0.3))
    }
    private func sourcePane(_ title: String, data: Data?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color).padding(10)
            Divider()
            NativeCodeEditor(text: .constant(data.flatMap { String(data: $0, encoding: .utf8) } ?? "File absent in this version"), accessibilityName: title, scrollGroup: model.scrollGroup,
                             highlightedRanges: title == model.overview.operation.currentLabel ? model.currentWordRanges : title == model.overview.operation.incomingLabel ? model.incomingWordRanges : [])
        }.frame(minWidth: 160)
    }
    private func specializedWorkspace(_ snapshot: ConflictSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(snapshot.file.category, systemImage: "doc.badge.gearshape").font(.title2)
            Text(snapshot.isSubmodule ? "Choose the commit reference to stage in the parent repository. The submodule checkout and all local edits are kept. Review any remaining submodule working changes before continuing." : "This conflict needs a whole-file decision. The chosen bytes and file mode will be written exactly and staged in Git.").foregroundStyle(.secondary)
            if snapshot.isSubmodule {
                HStack(spacing: 16) {
                    submoduleCard(snapshot.operation.currentLabel, stage: snapshot.file.stage(2), resolution: .current)
                    submoduleCard(snapshot.operation.incomingLabel, stage: snapshot.file.stage(3), resolution: .incoming)
                }
                Text("This action updates the Git index only; it does not download commits or update the child checkout.").font(.caption).foregroundStyle(.secondary)
            } else if snapshot.supportsVersionSelection {
                HStack(spacing: 16) {
                    versionCard(title: snapshot.operation.currentLabel, data: snapshot.current, stage: snapshot.file.stage(2), resolution: .current)
                    versionCard(title: snapshot.operation.incomingLabel, data: snapshot.incoming, stage: snapshot.file.stage(3), resolution: .incoming)
                }
                Button("Delete File…", role: .destructive) { confirmation = .delete }
            } else {
                Text("Submodule conflicts require choosing the submodule commit using Git. This resolver will keep the conflict open until the index is resolved.")
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([repository.url.appendingPathComponent(snapshot.file.path)]) }
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func submoduleCard(_ title: String, stage: ConflictStage?, resolution: ConflictResolution) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let stage {
                Text(stage.objectID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Inspect Commit…") {
                    guard let snapshot = model.snapshot else { return }
                    model.busy = true
                    Task { @MainActor in
                        defer { model.busy = false }
                        do { submodulePreview = SubmodulePreview(text: try await model.service.submoduleCommitDetails(snapshot: snapshot, stage: stage.number)) }
                        catch { model.error = error.localizedDescription }
                    }
                }
                Button("Stage This Commit…") { confirmation = .version(resolution) }
            } else {
                Text("Reference removed in this version").font(.caption)
                Button("Remove Reference…") { confirmation = .delete }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    private func versionCard(title: String, data: Data?, stage: ConflictStage?, resolution: ConflictResolution) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let data, let stage {
                Text("\(data.count.formatted()) bytes · mode \(stage.mode)").font(.caption).foregroundStyle(.secondary)
                if stage.mode == "120000" { Text("Link target: " + String(decoding: data, as: UTF8.self)).textSelection(.enabled) }
                Text(String(stage.objectID.prefix(12))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Button("Use This Version…") { confirmation = .version(resolution) }
            } else { Text("File deleted in this version").font(.caption).foregroundStyle(.secondary); Button("Keep Deletion…") { confirmation = .delete } }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    private var completion: some View {
        ContentUnavailableView {
            Label("All conflicts resolved", systemImage: "checkmark.circle")
        } description: {
            Text(model.overview.operation == .none ? "There are no unmerged files in the Git index." : "Review your staged changes in Changes, then explicitly continue \(model.overview.operation.rawValue).")
        } actions: {
            if model.overview.operation != .none { Button("Continue \(model.overview.operation.title)…") { confirmation = .proceed }.buttonStyle(.borderedProminent) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var confirmationTitle: String {
        switch confirmation {
        case .proceed: "Continue \(model.overview.operation.title)?"
        case .abort: "Abort \(model.overview.operation.title)?"
        case .selection: "Discard unsaved resolution edits?"
        case .delete: model.snapshot?.isSubmodule == true ? "Remove this submodule reference?" : "Delete this conflicted file?"
        case .version: model.snapshot?.isSubmodule == true ? "Stage this submodule commit reference?" : "Stage this whole-file resolution?"
        case .stageText: "Write and stage the merged result?"
        case .workingFile: "Use the existing working file as the result?"
        case .savedDraft: "Discard the saved local draft?"
        case .discardCurrent: "Discard this retained draft?"
        case .none: "Confirm"
        }
    }
    private var confirmationMessage: String {
        switch confirmation {
        case .proceed: "Git will continue the operation and may create commits. Review staged changes first."
        case .abort: "Git will attempt to restore the state before the operation. Conflict-resolution edits may be lost."
        case .selection: "Your in-memory edits have not been written to the repository."
        case .delete: model.snapshot?.isSubmodule == true ? "Remove the parent index reference. The child checkout and all local files are kept on disk." : "The file will be removed from the working tree and the deletion staged."
        case .version: model.snapshot?.isSubmodule == true ? "Stage the selected commit in the parent index. The child checkout and all local edits are preserved. Review any remaining submodule working changes before continuing." : "This replaces the worktree file with the selected Git index version and stages it."
        case .stageText: "The displayed result will replace the working file and be staged. Review any edits made before opening this resolver using Preview Working File. This does not continue the operation."
        case .workingFile: "This replaces the draft with the existing working file, preserving any prior manual edits. Review and remove any remaining conflict markers before explicitly marking the file resolved."
        case .savedDraft: "The local recovery copy will be removed. This does not change repository files or the Git index."
        case .discardCurrent: "The retained text and its matching local recovery copy will be removed. Git will then be reloaded."
        case .none: ""
        }
    }
    private func save(_ resolution: ConflictResolution) { Task { if await model.save(resolution) { onRefresh() } } }
    private func performContinue() {
        Task {
            model.busy = true
            do { try await model.service.continueOperation(); onRefresh() }
            catch { model.error = error.localizedDescription }
            await model.refresh()
        }
    }
    private func performAbort() {
        Task {
            model.busy = true
            do { try await model.service.abortOperation(); _ = await model.discardDraft(); model.selectedPath = nil; onRefresh() }
            catch { model.error = error.localizedDescription }
            await model.refresh()
        }
    }
}


private struct SavedConflictDraftsSheet: View {
    @Bindable var model: ConflictViewModel
    @ViewState private var pendingDiscard: ConflictDraftDescriptor?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Saved Conflict Drafts").font(.headline)
                Spacer()
                Button("Done") { model.showDrafts = false }
            }.padding(16)
            Divider()
            HSplitView {
                List(model.savedDrafts) { descriptor in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { Task { await model.review(descriptor) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(descriptor.path).lineLimit(2)
                                Text(descriptor.savedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button("Discard…", role: .destructive) { pendingDiscard = descriptor }.controlSize(.small)
                    }.padding(.vertical, 4)
                }.frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                if let draft = model.reviewDraft {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(draft.descriptor.path).font(.headline)
                            Spacer()
                            Button("Export…") { exportConflictDraft(draft.document.text, path: draft.descriptor.path, onError: { model.error = $0 }) }
                        }.padding(12)
                        Text("Saved locally. Reviewing or exporting this text does not modify the repository.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 10)
                        Divider()
                        NativeCodeEditor(text: .constant(draft.document.text), accessibilityName: "Saved conflict draft preview")
                    }.frame(minWidth: 420)
                } else { ContentUnavailableView("Select a saved draft", systemImage: "doc.text.magnifyingglass").frame(minWidth: 420) }
            }
        }.frame(width: 850, height: 580)
        .task { await model.refreshSavedDrafts() }
        .confirmationDialog("Discard this saved draft?", isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }), titleVisibility: .visible) {
            if let descriptor = pendingDiscard {
                Button("Discard Saved Draft", role: .destructive) { Task { await model.discardSaved(descriptor) } }
            }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: { Text("Only the local recovery copy will be removed. Repository files and the Git index will not change.") }
    }
}

@MainActor private func exportConflictDraft(_ text: String, path: String, onError: @escaping @MainActor (String) -> Void) {
    let panel = NSSavePanel()
    panel.title = "Export Conflict Draft"
    panel.nameFieldStringValue = (path as NSString).lastPathComponent + ".draft"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
        do { try await Task.detached(priority: .utility) { try Data(text.utf8).write(to: url, options: .atomic) }.value }
        catch { onError(error.localizedDescription) }
    }
}
