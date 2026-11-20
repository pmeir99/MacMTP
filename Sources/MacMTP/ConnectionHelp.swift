import AppKit
import SwiftUI
import USB

struct USBOpenFailure: LocalizedError {
    let status: Int32
    let stage: Int32
    let driverState: Int32
    let vendor: UInt16
    let product: UInt16
    let interface: UInt8

    init(status: Int32, diagnostics: MacUSBDiagnostics) {
        self.status = status
        stage = diagnostics.stage
        driverState = diagnostics.kernel_driver_active
        vendor = diagnostics.vendor
        product = diagnostics.product
        interface = diagnostics.interface_number
    }

    var cause: DeviceError { DeviceError.openingUSB(status, stage: stage, driverActive: driverState == 1) }
    var errorDescription: String? { cause.localizedDescription }
    var details: String {
        let step = ["discovery", "open device", "claim interface", "configure interface"]
        let operation = step.indices.contains(Int(stage)) ? step[Int(stage)] : "unknown"
        return "USB error: \(status)\nOperation: \(operation)\nDevice: \(String(format: "%04x:%04x", Int(vendor), Int(product)))\nInterface: \(interface)\nKernel driver: \(driverState == 1 ? "active" : driverState == 0 ? "not active" : "unknown")"
    }
}

struct ConnectionIssue: Equatable {
    enum Kind: Equatable { case waiting, access, interface, busy, other }
    let kind: Kind
    let title: String
    let message: String
    let details: String

    static let waiting = ConnectionIssue(kind: .waiting, title: "Connect your Android phone",
        message: "Unlock your phone and select File Transfer (MTP) in its USB notification.", details: "No MTP storage is connected.")

    init(error: Error) {
        let usb = error as? USBOpenFailure
        let cause = usb?.cause ?? (error as? DeviceError)
        details = usb?.details ?? error.localizedDescription
        switch cause {
        case .usbAccessDenied:
            kind = .access
            title = "USB access is blocked"
            message = "Unlock your phone, choose File Transfer (MTP), and reconnect the USB cable. If macOS asks to allow this accessory, choose Allow."
        case .interfaceAccessDenied:
            kind = .interface
            title = "File-transfer interface is blocked"
            message = "The device was opened, but macOS blocked its file-transfer interface. Recover USB to release known Android transfer apps, then reconnect the phone."
        case .interfaceBusy:
            kind = .busy
            title = "The USB interface is in use"
            message = "An app or USB driver is holding the file-transfer interface. Recover USB, or close the app that is using your phone."
        case .unavailable:
            kind = .waiting
            title = Self.waiting.title
            message = Self.waiting.message
        default:
            kind = .other
            title = "Connection interrupted"
            message = error.localizedDescription
        }
    }

    private init(kind: Kind, title: String, message: String, details: String) {
        self.kind = kind; self.title = title; self.message = message; self.details = details
    }

    var offersMediaRecovery: Bool { kind == .access || kind == .interface || kind == .busy }
    var report: String {
        "MacMTP \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\(details)"
    }
}

/// Short retries immediately after a failure/action, then a quiet bounded polling interval.
struct ConnectionRetryPolicy {
    private(set) var failures = 0
    mutating func failed() { failures = min(failures + 1, 20) }
    mutating func reset() { failures = 0 }
    var delay: Duration { failures <= 10 ? .seconds(1) : .seconds(3) }
}

struct ConnectionHelpView: View {
    let issue: ConnectionIssue
    let busy: Bool
    let reconnect: () -> Void
    let recover: () -> Void
    let recoverMediaApps: () -> Void
    @State private var showDetails = false

    var body: some View {
        ScrollView {
        VStack(spacing: 16) {
            Image(systemName: issue.kind == .waiting ? "cable.connector" : "exclamationmark.triangle")
                .font(.system(size: 48, weight: .light)).foregroundStyle(.secondary)
            Text(issue.title).font(.title2.weight(.semibold))
            Text(issue.message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button("Reconnect", systemImage: "arrow.clockwise", action: reconnect)
                    .buttonStyle(.borderedProminent)
                    .help("Try connecting now after unlocking or reconnecting your phone")
                Button("Recover USB", systemImage: "cable.connector", action: recover)
                    .help("Gracefully closes known Android transfer apps and stops the local ADB server, then reconnects")
            }.disabled(busy)
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                Text(busy ? "Connecting…" : "MacMTP retries automatically. You can leave this screen open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("More connection help") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Use a USB cable that supports data. If you use a hub, try connecting directly to your Mac.")
                    if issue.offersMediaRecovery {
                        Button("Close Photos & Image Capture", action: recoverMediaApps)
                            .disabled(busy)
                            .help("Asks these two apps to quit normally, then retries. Any save or confirmation dialogs remain under your control.")
                    }
                    Text("On Apple-silicon MacBooks: Privacy & Security → Accessories → Automatically allow when unlocked can reduce repeated approval prompts.")
                    Button("Open Privacy & Security", systemImage: "gearshape") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text("Accessory approval is controlled by macOS. An app cannot grant it automatically.")
                        .foregroundStyle(.secondary)
                }.font(.callout).padding(.top, 10)
            }
            DisclosureGroup("Connection details", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(issue.report).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Copy Details", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(issue.report, forType: .string)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
            }
        }
        .frame(maxWidth: 470)
        .padding(30)
        .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
