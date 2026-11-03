import SwiftUI
import UIKit

final class BoraMinAppDelegate: NSObject, UIApplicationDelegate {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
    func applicationDidBecomeActive(_ application: UIApplication) {
        TopShelfPublisher.refresh(force: true)
        ICloudSync.shared.schedule(delay:0,urgent:true)
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        TopShelfPublisher.refresh()
        guard ICloudSync.shared.enabled, backgroundTask == .invalid else { return }
        backgroundTask=application.beginBackgroundTask(withName:"iCloud Sync") { [weak self] in
            self?.finishBackgroundTask(application)
        }
        Task { @MainActor in
            await ICloudSync.shared.synchronize()
            TopShelfPublisher.refresh()
            finishBackgroundTask(application)
        }
    }
    private func finishBackgroundTask(_ application: UIApplication) {
        if backgroundTask != .invalid { application.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    func application(_ application: UIApplication,didReceiveRemoteNotification userInfo:[AnyHashable:Any],fetchCompletionHandler completionHandler:@escaping(UIBackgroundFetchResult)->Void) {
        Task { @MainActor in
            await ICloudSync.shared.synchronize()
            TopShelfPublisher.refresh()
            completionHandler(.newData)
        }
    }
}

@main struct BoraMinApp: App {
    @UIApplicationDelegateAdaptor(BoraMinAppDelegate.self) private var delegate
    init() {
        // tvOS throws at runtime for UINavigationBarAppearance setters even though
        // the SDK accepts them. Customize the native title through the legacy API.
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.white]
        // Scope the list backdrop to the browser's public hosting-controller type.
        // Presented players have their own controller hierarchy and keep AVKit styling.
        UICollectionView.appearance(whenContainedInInstancesOf: [UIHostingController<BrowserScreen>.self]).backgroundColor = .black
        _ = VP9Support.registered
    }
    var body: some Scene {
        WindowGroup {
            BrowserHost().ignoresSafeArea()
                .onOpenURL { url in
                    NotificationCenter.default.post(name: .topShelfOpenItem, object: url)
                }
        }
    }
}

// Public SwiftUI/UIKit containment gives UIAppearance a browser-only scope.
private struct BrowserHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIHostingController<BrowserScreen> {
        let controller = UIHostingController(rootView: BrowserScreen())
        controller.view.backgroundColor = .black
        return controller
    }
    func updateUIViewController(_ controller: UIHostingController<BrowserScreen>, context: Context) { }
}
