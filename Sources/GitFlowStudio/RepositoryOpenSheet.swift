import SwiftUI
import GitCore

/// This view does not construct NSOpenPanel or touch the filesystem. Opening a
/// repository stays available even when the system's picker service is slow.
struct RepositoryOpenSheet: View {
    @Bindable var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var location = ""
    @ViewState private var validationError: String?
    @FocusState private var locationFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Open Repository", systemImage: "folder.badge.plus").font(.title2.bold())
            Text("Paste a folder path, drop a folder here, or open a recent repository.")
                .foregroundStyle(.secondary)
            TextField("~/Projects/Repository", text: $location)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Repository folder path")
                .accessibilityIdentifier("repository-location")
                .focused($locationFocused)
                .onSubmit(openLocation)
                .onChange(of: location) { _, _ in validationError = nil }
            Text("In Finder, select a folder and press ⌥⌘C to copy its path.")
                .font(.caption).foregroundStyle(.secondary)
            if let validationError {
                Text(validationError).font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("repository-location-error")
            }
            if !model.recentPaths.isEmpty {
                Text("Recent repositories").font(.headline)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.recentPaths.prefix(8), id: \.self) { path in
                            Button { model.chooseRepository(URL(fileURLWithPath: path, isDirectory: true)) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text((path as NSString).lastPathComponent).font(.callout.weight(.medium))
                                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                }.padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(path)
                        }
                    }
                }.frame(maxHeight: 150)
            }
            Divider()
            HStack {
                Button("Choose Folder…", action: model.browseForRepository)
                    .accessibilityIdentifier("browse-repository")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", action: openLocation)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(location.isEmpty).accessibilityIdentifier("open-repository-location")
            }
        }
        .padding(24).frame(width: 540)
        .onAppear { locationFocused = true }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            model.chooseRepository(url); return true
        }
    }

    private func openLocation() {
        do { model.chooseRepository(try RepositoryLocation.url(from: location)) }
        catch { validationError = error.localizedDescription }
    }
}
