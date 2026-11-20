import AppKit
import Foundation

public enum UpdateRelaunch {
    /// AppKit can refuse termination while a sheet is attached, before asking the delegate.
    /// Call only after the update helper is ready and the device session has closed.
    @MainActor
    public static func quit() {
        let application = NSApplication.shared
        for window in application.windows {
            if let sheet = window.attachedSheet {
                sheet.preventsApplicationTerminationWhenModal = false
                window.endSheet(sheet)
                sheet.orderOut(nil)
            }
        }
        if let modal = application.modalWindow {
            modal.preventsApplicationTerminationWhenModal = false
            application.abortModal()
        }
        application.terminate(nil)
    }

    /// A successful quit ends this process. If it stays alive, never leave a permanent spinner.
    @MainActor
    public static func watchForFailedQuit(helper: Process, workspace: URL,
                                         timeout: TimeInterval = 8) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard helper.isRunning else {
                let message = try? String(contentsOf: UpdateFiles.root.appendingPathComponent("last-error"), encoding: .utf8)
                throw UpdateError.tool(message ?? "The update helper stopped before MacMTP could quit. Your installed app has not been replaced.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw UpdateError.tool("MacMTP could not quit to finish the update. Close any open dialogs and try again. Your installed app has not been replaced.")
    }

    public static func requestCancellation(in workspace: URL) {
        try? Data("cancel".utf8).write(to: workspace.appendingPathComponent("cancel"), options: .atomic)
    }
}
