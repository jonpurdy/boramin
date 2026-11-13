import SwiftUI

struct MacSettingsView: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var cloud = ICloudSync.shared
    @AppStorage("displayAllFiles") private var allFiles = false
    @AppStorage("showDebugInfo") private var debug = false
    @AppStorage(PlaybackRoute.alwaysUseAetherKey) private var alwaysUseAether = PlaybackRoute.defaultAlwaysUseAether
    @State private var showingLicences = false
    var body: some View {
        Form {
            Section {
                Toggle("Sync via iCloud", isOn: Binding(get: { cloud.enabled }, set: { cloud.setEnabled($0) }))
                Text(cloud.statusAndLastSync).font(.body).foregroundStyle(.secondary)
                Button("Sync Now") { Task { await cloud.synchronize() } }.disabled(!cloud.enabled || cloud.syncing)
            }
            Section {
                Toggle("Display all files", isOn: $allFiles)
                Toggle("Use AVPlayer when possible (Experimental)", isOn: Binding(
                    get: { !alwaysUseAether }, set: { alwaysUseAether = !$0 }
                ))
            }
            Section {
                SubtitleSizeSetting()
            }
            Section {
                Toggle("Show Debug Info", isOn: $debug)
            }
            Section {
                Button("Licences") { showingLicences = true }
            } footer: {
                SettingsVersionFooter()
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
