import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("showHiddenFiles") private var showHiddenFiles = false

    @ObservedObject private var mount = FinderMountController.shared
    @AppStorage("finderMountWritable") private var finderWritable = false

    var body: some View {
        Form {
            Section("Finder") {
                Toggle("Allow changes from Finder", isOn: $finderWritable)
                    .disabled(mount.ownsDevice)
                    .help("Allow Finder to upload, rename, move, and delete phone files. Eject before changing this option.")
                HStack {
                    Toggle("Mount phone in Finder", isOn: Binding(
                        get: { mount.ownsDevice },
                        set: { enabled in Task { if enabled { await mount.mount(writable: finderWritable) } else { await mount.unmount() } } }
                    ))
                    .disabled(mount.changing)
                    if mount.changing { ProgressView().controlSize(.small) }
                    if mount.location != nil { Button("Open in Finder") { mount.open() } }
                }
                Text(mount.message.isEmpty ? "Mount internal shared storage and SD cards over USB. MacMTP must remain running. No ADB or filesystem installation is required." : mount.message)
                    .font(.caption).foregroundStyle(.secondary)
                if let error = mount.failure { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Browsing") {
                Toggle("Show hidden files and folders", isOn: $showHiddenFiles)
                .help("Show dot-prefixed items exposed by the phone in every browsing mode.")
            Text("Shows items whose names begin with a period. This does not change which files Android makes available over USB.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 370)
    }
}
