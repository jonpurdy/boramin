import SwiftUI
import AppKit

@main struct BoraMinMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @StateObject private var library = MacLibrary()
    var body: some Scene {
        Window("BoraMin", id: "library") {
            MacLibraryView(library: library)
                .frame(minWidth: 760, minHeight: 480)
                .task { ICloudSync.shared.activate() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Connections…") { library.showConnection = true }.keyboardShortcut("k")
            }

        }
        Settings { MacSettingsView(browser: library.files).frame(width: 480) }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.registerForRemoteNotifications()
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        ICloudSync.shared.schedule(delay: 0, urgent: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        MacPlaybackWindow.current?.stop()
        #if canImport(AetherEngine)
        MacSoftwarePlaybackWindow.current?.stop()
        #endif
        NotificationCenter.default.post(name: Notification.Name("BoraMinPlaybackSync"), object: nil)
    }
}

@MainActor final class MacLibrary: ObservableObject {
    let files = Browser()
    let favoritesBrowser = Browser()
    let watchingBrowser = Browser()
    @Published var showConnection = false
}
