import AppKit
import SwiftUI

/// Each window owns its draft. Keep AppKit's existing SwiftUI delegate behavior,
/// adding only the close decision and forwarding all other delegate messages.
struct WindowSessionReader: NSViewRepresentable {
    @Binding var window: NSWindow?
    let model: StudioModel
    let edited: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let attached = view.window else { return }
            coordinator.attach(to: attached)
            attached.isDocumentEdited = edited
            if window !== attached { window = attached }
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: StudioModel
        weak var window: NSWindow?
        private var approvedClose = false
        // This immutable wrapper is returned only synchronously on the main thread
        // through Objective-C forwarding; the delegate never crosses executors.
        private struct ForwardTarget: @unchecked Sendable { let value: Any? }
        weak var previousDelegate: (any NSWindowDelegate)?
        init(model: StudioModel) { self.model = model }
        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            model.presentationWindow = window
            previousDelegate = window.delegate
            window.delegate = self
            WindowSessionRegistry.shared.add(model)
        }
        func detach() {
            if model.presentationWindow === window { model.presentationWindow = nil }
            if window?.delegate === self { window?.delegate = previousDelegate }
            WindowSessionRegistry.shared.remove(model)
            window = nil; previousDelegate = nil
        }
        override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            // NSWindow delivers its delegate messages on the main thread.
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated { previousDelegate?.responds(to: selector) == true }
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            guard Thread.isMainThread else { return super.forwardingTarget(for: selector) }
            return MainActor.assumeIsolated {
                ForwardTarget(value: previousDelegate?.responds(to: selector) == true ? previousDelegate : super.forwardingTarget(for: selector))
            }.value
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if approvedClose {
                approvedClose = false
                return previousDelegate?.windowShouldClose?(sender) ?? true
            }
            guard WindowSessionRegistry.canClose([model], quitting: false) else { return false }
            if model.hasUnsavedDraft {
                Task { @MainActor [self] in
                    if await model.discardUnsavedDrafts() {
                        approvedClose = true
                        sender.performClose(nil)
                    }
                }
                return false
            }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }
        func windowWillClose(_ notification: Notification) {
            previousDelegate?.windowWillClose?(notification)
            WindowSessionRegistry.shared.remove(model)
        }
    }
}

@MainActor final class WindowSessionRegistry {
    static let shared = WindowSessionRegistry()
    private let models = NSHashTable<StudioModel>.weakObjects()
    func add(_ model: StudioModel) { models.add(model) }
    func remove(_ model: StudioModel) { models.remove(model) }
    func requestQuit() -> NSApplication.TerminateReply {
        let openModels = models.allObjects
        guard Self.canClose(openModels, quitting: true) else { return .terminateCancel }
        let drafts = openModels.filter(\.hasUnsavedDraft)
        guard !drafts.isEmpty else { return .terminateNow }
        Task { @MainActor in
            for model in drafts {
                guard await model.discardUnsavedDrafts() else {
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    static func canClose(_ models: [StudioModel], quitting: Bool) -> Bool {
        if models.contains(where: \.operationInProgress) {
            let alert = NSAlert()
            alert.messageText = "A Git operation is still running"
            alert.informativeText = "Wait for it to finish, or cancel it in the repository window before closing."
            alert.addButton(withTitle: "Keep Working")
            alert.runModal()
            return false
        }
        let drafts = models.filter(\.hasUnsavedDraft)
        guard !drafts.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = quitting ? "Quit with unsaved drafts?" : "Close with an unsaved draft?"
        alert.informativeText = "Conflict edits and commit messages in this window have not been saved. Closing discards these drafts and their matching local recovery copies. Files already written to your repository are retained."
        if quitting && drafts.count > 1 { alert.informativeText = "\(drafts.count) repository windows contain unsaved conflict edits or commit messages. Quitting discards those drafts and their matching local recovery copies. Files already written to your repositories are retained." }
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: quitting ? "Discard Drafts and Quit" : "Discard Draft and Close")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
