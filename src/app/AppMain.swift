import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Apply process-level Lockdown Mode exemption BEFORE any UIViewController / WKProcessPool is created!
        let initialConfig = AppConfig.load()
        let overrideMode = JWLockdownHelper.bridgeOverrideMode(for: initialConfig.lockdownPolicy)
        _ = JWBridgeSyncProcessLockdownState(overrideMode)

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.rootViewController = HubViewController(initialConfig: initialConfig)
        win.makeKeyAndVisible()
        self.window = win
        return true
    }
}
