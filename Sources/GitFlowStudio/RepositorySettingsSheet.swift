import SwiftUI
import GitCore

struct RepositorySettingsSheet: View {
    let repository: GitRepository
    let onRefresh: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var email = ""
    @ViewState private var ignoreText = ""
    @ViewState private var identitySnapshot: GitIdentity?
    @ViewState private var ignoreSnapshot: GitIgnoreSnapshot?
    @ViewState private var busy = true
    @ViewState private var message: String?
    @ViewState private var error: String?
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("Repository Settings").font(.title2.bold()); Text(repository.url.lastPathComponent).foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TabView {
                Form {
                    Text("Commit identity").font(.headline)
                    Text("Use a local identity for this repository. Existing global Git settings are used until you save an override.").font(.callout).foregroundStyle(.secondary)
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    TextField("Email", text: $email).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Use Global Identity") { saveIdentity(inherit: true) }.disabled(identitySnapshot == nil || busy)
                        Spacer()
                        Button("Save Repository Identity") { saveIdentity(inherit: false) }.buttonStyle(.borderedProminent).disabled(identitySnapshot == nil || busy || name.isEmpty || email.isEmpty)
                    }
                    Divider()
                    Text("Signing, hooks, credential helpers, and other Git configuration continue to use your existing Git setup.").font(.caption).foregroundStyle(.secondary)
                }.padding(20).tabItem { Label("Git", systemImage: "person.crop.circle") }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Edit the root .gitignore. Patterns affect untracked files; tracked files remain tracked.").font(.callout).foregroundStyle(.secondary)
                    NativeCodeEditor(text: $ignoreText, editable: true, accessibilityName: "Git ignore patterns").border(.quaternary)
                    HStack {
                        Text("External edits are checked before saving.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save .gitignore") { saveIgnore() }.buttonStyle(.borderedProminent).disabled(busy || ignoreSnapshot == nil)
                    }
                }.padding(20).tabItem { Label("Ignored Files", systemImage: "doc.badge.minus") }
            }
            HStack { if busy { ProgressView().controlSize(.small) }; Text(message ?? "Changes apply only to this repository.").font(.caption).foregroundStyle(.secondary); Spacer() }
        }.padding(24).frame(width: 650, height: 520)
            .task { await load() }
            .alert("Settings could not be saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
    }
    private func load() async {
        busy = true
        defer { busy = false }
        do {
            let identity = try await repository.identity()
            identitySnapshot = identity; name = identity.name; email = identity.email
            let ignore = try await repository.readIgnore()
            ignoreSnapshot = ignore; ignoreText = ignore.text
        } catch { self.error = error.localizedDescription }
    }
    private func saveIdentity(inherit: Bool) {
        guard let expected = identitySnapshot else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await repository.setIdentity(inherit ? nil : GitIdentity(name: name, email: email), expected: expected)
                let identity = try await repository.identity()
                identitySnapshot = identity; name = identity.name; email = identity.email
                message = inherit ? "Using inherited Git identity." : "Repository identity saved."
            } catch { self.error = error.localizedDescription }
        }
    }
    private func saveIgnore() {
        guard let expected = ignoreSnapshot else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await repository.saveIgnore(ignoreText, expected: expected)
                ignoreSnapshot = try await repository.readIgnore()
                message = ".gitignore saved. Review and commit it in Changes."; onRefresh()
            } catch { self.error = error.localizedDescription }
        }
    }
}
