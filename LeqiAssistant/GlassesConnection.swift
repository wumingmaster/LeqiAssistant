import Combine
import Foundation
import RGCxrClient
import UIKit

@MainActor
enum GlassesSDK {
    static let glassesActivity = "party.xiaoyu.glasses.wakeprobe.MainActivity"
    static let scopes = ["device_control"]
    private static var configured = false

    static func configure() {
        guard !configured else { return }
        CxrClient.initialize(mode: .customApp, options: .init(
            appDisplayName: "乐奇助手", pageName: "party.xiaoyu.glasses.wakeprobe"
        ))
        CxrClient.shared.auth.config.callbackScheme = "cxrlleqiassistant"
        configured = true
    }

    static var isConnected: Bool {
        CxrClient.shared.auth.isAuthenticated() && RGCxrClientBLE.shared.isConnected
    }

    static func waitUntilConnected() async throws -> Bool {
        configure()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while !isConnected {
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}

@MainActor
final class GlassesConnection: ObservableObject {
    @Published private(set) var status = "正在检查连接…"
    @Published private(set) var bluetoothConnected = false
    @Published private(set) var authorized = false

    private let client: any RGCxrClient
    private var subscriptions = Set<AnyCancellable>()
    private var foreground = false
    private var attemptedOpen = false
    private var refreshing = false
    private var triedRefresh = false
    private var openAttempt: UUID?
    private var openTimeout: Task<Void, Never>?
    private let authorizedKey = "didAuthorizeRokid"

    init() {
        GlassesSDK.configure()
        client = CxrClient.shared
        RGCxrClientBLE.shared.connectionStatePublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if !connected && self.bluetoothConnected {
                    self.openTimeout?.cancel()
                    self.openAttempt = nil
                    self.attemptedOpen = false
                }
                self.update()
            }.store(in: &subscriptions)
        client.auth.statePublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
    }

    func activate() {
        if !foreground {
            foreground = true
            attemptedOpen = false
        }
        update()
    }

    func deactivate() {
        foreground = false
        openTimeout?.cancel()
        openAttempt = nil
    }

    func connectFromButton() {
        guard client.isRokidAppInstalled() else {
            status = "请先安装 Hi Rokid 并配对眼镜。"
            return
        }
        if !client.auth.isAuthenticated() {
            guard !refreshing else { return }
            if case .authenticating = client.auth.currentState { return }
            status = "请在 Hi Rokid 中确认授权。"
            client.auth.authenticate(scopes: GlassesSDK.scopes, appName: "乐奇助手") { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.update()
                    case .failure:
                        self.status = "授权未完成，请确认 Hi Rokid 中的眼镜已连接。"
                    }
                }
            }
        } else if !RGCxrClientBLE.shared.isConnected {
            status = "正在等待眼镜连接。请检查 Hi Rokid 中的连接状态。"
            if let url = URL(string: "rokidai://") {
                UIApplication.shared.open(url)
            }
        } else if openAttempt == nil {
            attemptedOpen = false
            update()
        }
    }

    private func update() {
        authorized = client.auth.isAuthenticated()
        bluetoothConnected = RGCxrClientBLE.shared.isConnected
        if authorized { UserDefaults.standard.set(true, forKey: authorizedKey) }
        guard foreground, UIApplication.shared.applicationState == .active else { return }
        guard authorized else {
            guard !refreshing else { return }
            if case .authenticating = client.auth.currentState {
                status = "请在 Hi Rokid 中确认授权。"
                return
            }
            if !triedRefresh, UserDefaults.standard.bool(forKey: authorizedKey), client.isRokidAppInstalled() {
                refreshAuthorization()
            } else {
                status = "请连接并授权眼镜。"
            }
            return
        }
        guard bluetoothConnected else {
            status = "正在等待眼镜连接…"
            return
        }
        if !attemptedOpen { openGlassesApp() }
    }

    private func refreshAuthorization() {
        triedRefresh = true
        refreshing = true
        status = "正在恢复 Hi Rokid 授权…"
        client.auth.refreshToken(scopes: GlassesSDK.scopes) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                switch result {
                case .success:
                    self.update()
                case .failure:
                    self.status = "授权需要更新，请点「连接 / 授权眼镜」。"
                }
            }
        }
    }

    private func openGlassesApp() {
        attemptedOpen = true
        let attempt = UUID()
        openAttempt = attempt
        status = "已连接，正在打开眼镜端应用…"
        openTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            self?.finishOpening(attempt, success: false)
        }
        client.openApp(activityName: GlassesSDK.glassesActivity, url: "") { [weak self] success in
            DispatchQueue.main.async { self?.finishOpening(attempt, success: success) }
        }
    }

    private func finishOpening(_ attempt: UUID, success: Bool) {
        guard openAttempt == attempt else { return }
        openAttempt = nil
        openTimeout?.cancel()
        openTimeout = nil
        status = success
            ? "眼镜已连接，眼镜端应用已打开。"
            : "已连接；打开眼镜端应用失败，请确认眼镜端程序已安装。"
    }
}
