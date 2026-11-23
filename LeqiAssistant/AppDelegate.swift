import AppIntents
import RGCxrClient
import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        GlassesSDK.configure()
        LeqiShortcuts.updateAppShortcutParameters()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: session.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var connection: GlassesConnection?
    private let photo = PhotoActions()
    private let timelapse = GlassesTimelapse()
    private let recorder = GlassesRecorder()
    private let organizer = GlassesOrganizer()
    private let calendar = SystemCalendar()
    private var pendingTransfer: Bool?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let connection = GlassesConnection()
        self.connection = connection
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: AssistantView(connection: connection, photo: photo, timelapse: timelapse, recorder: recorder, organizer: organizer, calendar: calendar))
        self.window = window
        window.makeKeyAndVisible()
        for context in options.urlContexts { handle(context.url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        connection?.activate()
        calendar.refresh()
        runPendingAction()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        timelapse.appDidEnterBackground()
        recorder.stop()
        connection?.deactivate()
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for context in contexts { handle(context.url) }
    }

    private func handle(_ url: URL) {
        if url.scheme?.lowercased() == "cxrlleqiassistant" {
            _ = CxrClient.shared.handleOpenURL(url)
            return
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "leqiassistant",
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
              parts.user == nil, parts.password == nil, parts.port == nil else { return }
        switch parts.host?.lowercased() {
        case "capture": pendingTransfer = false
        case "photo": pendingTransfer = true
        case "memos": organizer.destination = .memos; return
        case "schedule": organizer.destination = .schedule; return
        default: return
        }
        if UIApplication.shared.applicationState == .active { runPendingAction() }
    }

    private func runPendingAction() {
        guard let transfer = pendingTransfer else { return }
        pendingTransfer = nil
        photo.capture(transfer: transfer)
    }
}
