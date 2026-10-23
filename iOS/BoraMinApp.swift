import SwiftUI
import UIKit
import AVFoundation

private var cloudProbeRequested: Bool {
    #if BORAMIN_CLOUD_PROBE
    return CommandLine.arguments.contains("--probe") || CommandLine.arguments.contains("--cloud-action")
    #else
    return false
    #endif
}

final class BoraMinIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = VP9Support.registered
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        application.registerForRemoteNotifications()
        return true
    }
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PlaybackOrientation.supported
    }
    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !cloudProbeRequested else { return }
        ICloudSync.shared.schedule(delay:0,urgent:true)
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        guard !cloudProbeRequested, ICloudSync.shared.enabled else { return }
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = application.beginBackgroundTask(withName: "iCloud Sync") {
            if identifier != .invalid { application.endBackgroundTask(identifier); identifier = .invalid }
        }
        Task { @MainActor in
            await ICloudSync.shared.synchronize()
            if identifier != .invalid { application.endBackgroundTask(identifier); identifier = .invalid }
        }
    }
    func application(_ application: UIApplication,didReceiveRemoteNotification userInfo:[AnyHashable:Any],fetchCompletionHandler completionHandler:@escaping(UIBackgroundFetchResult)->Void) {
        guard !cloudProbeRequested else { completionHandler(.noData); return }
        Task { @MainActor in
            await ICloudSync.shared.synchronize()
            completionHandler(.newData)
        }
    }
}

@main struct BoraMinApp: App {
    @UIApplicationDelegateAdaptor(BoraMinIOSAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            #if BORAMIN_CLOUD_PROBE
            if cloudProbeRequested { SyncTestScreen() }
            else { BrowserScreen() }
            #else
            BrowserScreen()
            #endif
        }
    }
}
