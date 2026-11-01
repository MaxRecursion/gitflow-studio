import SwiftUI
import AppKit
import GitCore

struct CloneSheet: View {
    @Bindable var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var remote = ""
    @ViewState private var destination: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Clone a Repository").font(.title2.bold())
            Text("Use an HTTPS URL, SSH address, or local repository path. Your existing Git authentication is used.").foregroundStyle(.secondary)
            TextField("Repository URL", text: $remote).textFieldStyle(.roundedBorder)
            HStack {
                Text(destination?.path ?? "Choose a new destination folder").lineLimit(2).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") {
                    let panel = NSSavePanel(); panel.title = "Clone Destination"; panel.nameFieldStringValue = "Repository"; panel.canCreateDirectories = true
                    if panel.runModal() == .OK { destination = panel.url }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Clone") {
                    guard let destination else { return }
                    dismiss()
                    model.clone(remote: remote, destination: destination)
                }.buttonStyle(.borderedProminent).disabled(remote.isEmpty || destination == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 500)
    }
}

struct CommandPalette: View {
    @Bindable var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find a Command").font(.headline)
            TextField("Search commands", text: $query).textFieldStyle(.roundedBorder)
            ForEach(WorkspaceSection.allCases.filter { query.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(query) }) { section in
                Button { model.section = section; dismiss() } label: { Label(section.rawValue, systemImage: section.icon).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.borderless)
            }
            Divider()
            Button("Open Repository…") { dismiss(); model.openPanel() }
            Button("Reveal in Finder") { dismiss(); model.reveal() }.disabled(model.repository == nil)
            HStack { Spacer(); Button("Close", role: .cancel) { dismiss() } }
        }.padding(24).frame(width: 420)
    }
}
