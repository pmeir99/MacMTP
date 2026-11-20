import AppKit
import USB

enum USBRecoveryPolicy {
    // Exact bundle identifiers only. Finder, Photos, Android Studio, and
    // unrecognized processes are never included in automatic recovery.
    // Media apps are only requested to quit by the explicitly labeled recovery action.
    static let transferApps: Set<String> = [
        "com.google.android.mtpviewer",
        "com.google.android.mtpagent",
        "io.ganeshrvel.openmtp"
    ]

    static let mediaApps: Set<String> = ["com.apple.Photos", "com.apple.Image_Capture"]

    static func canQuit(_ identifier: String?, includingMediaApps: Bool = false) -> Bool {
        guard let identifier else { return false }
        return transferApps.contains(identifier) || (includingMediaApps && mediaApps.contains(identifier))
    }
}

actor USBRecovery {
    func recover(includingMediaApps: Bool = false) async -> [String] {
        var messages = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> String? in
                guard USBRecoveryPolicy.canQuit(app.bundleIdentifier, includingMediaApps: includingMediaApps),
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
                let name = app.localizedName ?? "Android transfer app"
                return app.terminate()
                    ? "Requested that \(name) quit to release Android USB."
                    : "Close \(name) manually to release Android USB."
            }
        }
        switch mac_adb_stop_server() {
        case 1:
            messages.append("Stopped the local ADB server to release Android USB.")
        case -1:
            messages.append("The local ADB server could not be stopped. Close debugging apps and retry.")
        default:
            break
        }
        if !messages.isEmpty {
            // Let graceful app termination and the ADB server release their handles.
            try? await Task.sleep(for: .seconds(1))
        }
        return messages
    }
}
