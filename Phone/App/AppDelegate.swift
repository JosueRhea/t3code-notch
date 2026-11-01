import ActivityKit
import UIKit

// The iPhone app only pairs with the Mac. The Live Activity it shows is started and updated by
// the Mac through Apple's push service, so after pairing this app never has to be opened again.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // The address the Mac uses to start a Live Activity here. iOS hands it out (and rotates it)
        // through this stream; the latest one goes to the Mac when pairing.
        Task {
            for await data in Activity<NotchActivityAttributes>.pushToStartTokenUpdates {
                PhoneState.pushToStartToken = data.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { NotificationCenter.default.post(name: PhoneState.didChange, object: nil) }
            }
        }
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = PairingViewController()
        window?.makeKeyAndVisible()
        return true
    }

    /// A tap on the Live Activity that iOS gave to us (t3code://threads/<env>/<thread>, or the older
    /// t3notch://open?env=…&thread=…): open that thread in T3 Code.
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        Self.handOff(url)
        return true
    }

    private static func handOff(_ url: URL) {
        let env: String, thread: String
        if url.scheme == "t3notch", url.host == "open",
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let e = items.first(where: { $0.name == "env" })?.value, let t = items.first(where: { $0.name == "thread" })?.value {
            (env, thread) = (e, t)
        } else if url.scheme?.hasPrefix("t3code") == true, url.host == "threads", url.pathComponents.count >= 3 {
            (env, thread) = (url.pathComponents[1], url.pathComponents[2])
        } else {
            return
        }
        // T3 Code's release, preview and dev builds each have their own scheme: first one that opens wins.
        let targets = ["t3code", "t3code-preview", "t3code-dev"].compactMap { URL(string: "\($0)://threads/\(env)/\(thread)") }
        func attempt(_ i: Int) {
            guard i < targets.count else { return }
            UIApplication.shared.open(targets[i]) { opened in if !opened { attempt(i + 1) } }
        }
        attempt(0)
    }
}

/// What the app remembers between launches.
enum PhoneState {
    static let didChange = Notification.Name("PhoneStateDidChange")

    static var pushToStartToken: String? {
        get { UserDefaults.standard.string(forKey: "pushToStartToken") }
        set { UserDefaults.standard.set(newValue, forKey: "pushToStartToken") }
    }

    /// Mac name and the token it was paired with (a rotated token means pairing again).
    static var pairedMac: String? {
        get { UserDefaults.standard.string(forKey: "pairedMac") }
        set { UserDefaults.standard.set(newValue, forKey: "pairedMac") }
    }

    static var pairedToken: String? {
        get { UserDefaults.standard.string(forKey: "pairedToken") }
        set { UserDefaults.standard.set(newValue, forKey: "pairedToken") }
    }
}
