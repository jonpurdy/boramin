import SwiftUI

struct MacSettingsView: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var cloud = ICloudSync.shared
    @AppStorage("displayAllFiles") private var allFiles = false
    @AppStorage("showDebugInfo") private var debug = false
    @State private var showingLicences = false
    var body: some View {
        Form {
            Section {
                Toggle("Display all files", isOn: $allFiles)
                Text("When disabled, show folders and supported media file types.").font(.body).foregroundStyle(.secondary)
            }
            Section {
                SubtitleSizeSetting()
                Text("For external and ASS/SSA subtitles. Native captions use system settings. Saved on this device.").font(.body).foregroundStyle(.secondary)
                Toggle("Show Debug Info", isOn: $debug)
            }
            Section {
                Toggle("Sync via iCloud", isOn: Binding(get: { cloud.enabled }, set: { cloud.setEnabled($0) }))
                Text(cloud.statusAndLastSync).font(.body).foregroundStyle(.secondary)
                Button("Sync Now") { Task { await cloud.synchronize() } }.disabled(!cloud.enabled || cloud.syncing)
            }
            Section {
                Button("Licences") { showingLicences = true }
            }
        }
        .font(.body)
        .formStyle(.grouped)
        .sheet(isPresented: $showingLicences) {
            NavigationStack {
                LicencesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingLicences = false }
                        }
                    }
            }
            .frame(width: 640, height: 520)
        }
    }
}
