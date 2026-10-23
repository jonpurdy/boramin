import SwiftUI

struct SyncTestScreen: View {
    @StateObject private var cloud = CloudSyncProbe()
    @State private var runID = UserDefaults.standard.string(forKey: "testRun") ?? "demo"
    @Environment(\.scenePhase) private var scenePhase

    private func run(_ work: @escaping @MainActor () async throws -> Void) { cloud.perform(work) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Synthetic test data only. This app does not access your saved NAS credentials, favorites or playback history.")
                    LabeledContent("Status", value: cloud.status)
                    if !cloud.account.isEmpty { LabeledContent("Account fingerprint", value: cloud.account) }
                    LabeledContent("Queued changes", value: "\(cloud.pending)")
                    TextField("Test run", text: $runID).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Test controls") {
                    Toggle("Work offline", isOn: $cloud.offline)
                    Button("Create test data") { run { try cloud.seed(runID); try await cloud.synchronize() } }
                    Button("Sync now") { run { try await cloud.synchronize() } }
                    Button("Set playback to 90 seconds") { run { try cloud.advance(runID); try await cloud.synchronize() } }
                    Button("Reset playback") { run { try cloud.reset(runID); try await cloud.synchronize() } }
                    Button("Add favorite from this device") {
                        run {
                            #if os(tvOS)
                            let name = "manual-tv-favorite"
                            #else
                            let name = "manual-phone-favorite"
                            #endif
                            try cloud.edit(run: runID, name: name, kind: "favorite", fields: ["path":"Movies/\(name)"])
                            try await cloud.synchronize()
                        }
                    }
                    Button("Delete this run’s test data", role: .destructive) {
                        run { try cloud.cleanup(runID); try await cloud.synchronize() }
                    }
                }
                Section("Synced test records") {
                    ForEach(cloud.values.filter { $0.fields["testRun"] == runID }) { value in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(value.kind.capitalized + " · " + value.state)
                            if let path = value.fields["path"] { Text(path).font(.caption) }
                            if let host = value.fields["host"] { Text(host).font(.caption) }
                            if let seconds = value.fields["seconds"] { Text("Position: \(seconds) / \(value.fields["duration"] ?? "?") seconds").font(.caption) }
                            if let all = value.fields["displayAllFiles"] { Text("Display all files: \(all)").font(.caption) }
                            if value.kind == "server" { Text("Password stored locally in Keychain; cloud fields encrypted.").font(.caption) }
                        }
                    }
                }
                Section("Verification log") {
                    ForEach(Array(cloud.log.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("BoraMin Sync Test")
            .disabled(cloud.busy)
            .overlay { if cloud.busy { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .preferredColorScheme(.dark)
        .onChange(of: runID) { _, value in UserDefaults.standard.set(value, forKey: "testRun") }
        .task {
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--run-id"), args.count > index + 1 { runID = args[index + 1] }
            cloud.perform {
                try await cloud.start()
                if let index = args.firstIndex(of: "--cloud-action"), args.count > index + 1 {
                    try await cloud.exercise(run: runID, action: args[index + 1])
                }
            }
        }
    }
}
