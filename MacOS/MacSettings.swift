import SwiftUI

struct MacSettingsView: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var cloud = ICloudSync.shared
    @AppStorage("displayAllFiles") private var allFiles = false
    @AppStorage("showDebugInfo") private var debug = false
    @State private var connection = false
    var body: some View {
        Form {
            Section("Browsing") {
                Toggle("Display all files", isOn: $allFiles)
                Text("When disabled, show folders and supported media file types.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Playback") { Toggle("Show Debug Info", isOn: $debug) }
            Section("iCloud") {
                Toggle("Sync via iCloud", isOn: Binding(get: { cloud.enabled }, set: { cloud.setEnabled($0) }))
                Text(cloud.status).font(.caption).foregroundStyle(.secondary)
                if let date = cloud.lastSync { Text("Last synced: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                Button("Sync Now") { Task { await cloud.synchronize() } }.disabled(!cloud.enabled || cloud.syncing)
            }
            Section("Server") {
                Button("Connection Setup…") { connection = true }
                Text("Passwords are stored in Keychain. iCloud sync uses the same account and container as iPhone and Apple TV.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $connection) { MacConnectionView(browser: browser) }
    }
}

struct MacConnectionView: View {
    @ObservedObject var browser: Browser
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var share = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect to Server").font(.title2.bold())
            Form {
                TextField("Server", text: $host, prompt: Text("smb://server or IP address"))
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                TextField("Domain (optional)", text: $domain)
                TextField("Share (optional)", text: $share)
            }
            if let message = browser.error ?? browser.connectionError {
                Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            if browser.playing != nil { Text("Close playback before changing this server connection.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if browser.busy { ProgressView().controlSize(.small); Text(browser.status).font(.caption) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    browser.error = nil
                    browser.connect(host: host, username: username, domain: domain, password: password, directShare: share) { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || browser.busy || browser.playing != nil)
            }
        }
        .padding(24).frame(width: 470)
        .onAppear {
            browser.reloadSavedConnectionIfUnchanged()
            host = browser.host; username = browser.username; password = browser.password
            domain = browser.domain; share = browser.directShare
        }
    }
}
