import SwiftUI
import AppKit
import GitCore

// SDK 27 adds a State macro; an alias selects the deployment-compatible property wrapper.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct GitFlowStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("GitFlow Studio", id: "repository") {
            StudioWindow()
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: min(1340, max(960, (NSScreen.main?.visibleFrame.width ?? 1364) - 24)),
                     height: min(860, max(640, (NSScreen.main?.visibleFrame.height ?? 940) - 80)))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { NotificationCenter.default.post(name: .studioOpen, object: nil) }
                    .keyboardShortcut("o")
            }
            RepositoryWindowCommands()
            CommandMenu("Repository") {
                Button("Refresh") { NotificationCenter.default.post(name: .studioRefresh, object: nil) }.keyboardShortcut("r")
                Button("Find Command…") { NotificationCenter.default.post(name: .studioCommands, object: nil) }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        Settings { StudioSettings() }
    }
}

struct RepositoryWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Repository Window") { openWindow(id: "repository") }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowSessionRegistry.shared.requestQuit()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for name in filenames {
            NotificationCenter.default.post(name: .studioOpenURL, object: URL(fileURLWithPath: name))
        }
        sender.reply(toOpenOrPrint: .success)
    }
}

extension Notification.Name {
    static let studioOpen = Notification.Name("studio.open")
    static let studioOpenURL = Notification.Name("studio.openURL")
    static let studioRefresh = Notification.Name("studio.refresh")
    static let studioCommands = Notification.Name("studio.commands")
}

struct StudioSettings: View {
    @AppStorage("editorBundleID") var editor = "com.microsoft.VSCode"
    @AppStorage("restoreRepository") var restore = true
    var body: some View {
        Form {
            Toggle("Reopen the last repository on launch", isOn: $restore)
            TextField("External editor bundle identifier", text: $editor)
            Text("GitFlow Studio uses your installed Git, credential helpers, SSH configuration, identity, and hooks. No account or telemetry is required.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Requires macOS 14 or later. Repository access is not sandboxed; open only repositories you trust, as Git hooks may run during operations.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 510)
    }
}
