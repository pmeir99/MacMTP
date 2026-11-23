import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("showHiddenFiles") private var showHiddenFiles = false

    var body: some View {
        Form {
            Toggle("Show hidden files and folders", isOn: $showHiddenFiles)
                .help("Show dot-prefixed items exposed by the phone in every browsing mode.")
            Text("Shows items whose names begin with a period. This does not change which files Android makes available over USB.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 180)
    }
}
