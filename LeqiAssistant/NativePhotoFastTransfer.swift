import AppIntents
import Combine
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Network
import Photos
import RGCxrClient
import UIKit

@available(iOS 16.0, *)
struct GlassesFastNativePhotoTestIntent: AppIntent {
    static var title: LocalizedStringResource = "眼镜快速高清拍照测试"
    static var description = IntentDescription("通过原生快门拍照，并尝试通过本地网络保存原图到相册。")
    static var openAppWhenRun = false
    static var isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !ShortcutPhotoCapture.running else { return .result(dialog: "其他眼镜操作仍在处理中。") }
        ShortcutPhotoCapture.running = true
        defer { ShortcutPhotoCapture.running = false }
        let task = UIApplication.shared.beginBackgroundTask(withName: "GlassesFastPhoto")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else { return .result(dialog: "请先允许乐奇助手将照片添加到相册。") }
        GlassesSDK.configure()
        let client = CxrClient.shared
        let deadline = Date().addingTimeInterval(15)
        while !client.auth.isAuthenticated() || !RGCxrClientBLE.shared.isConnected {
            guard Date() < deadline else { return .result(dialog: "眼镜未连接或未授权，请打开乐奇助手重连。") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let transfer = NativePhotoFastTransfer(client: client)
        switch await transfer.run() {
        case .failure(let message): return .result(dialog: IntentDialog(stringLiteral: message))
        case .success(let image):
            let saved = await withCheckedContinuation { continuation in
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: image, options: nil)
                }) { success, _ in continuation.resume(returning: success) }
            }
            return .result(dialog: saved ? "原生高清照片已保存到相册。" : "照片已传到手机，但保存相册失败。")
        }
    }
}

@MainActor final class NativePhotoFastTransfer {
    enum Outcome { case success(Data), failure(String) }
    private let client: any RGCxrClient
    private let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let key = SymmetricKey(size: .bits256)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var subscription: AnyCancellable?
    private var bleSubscription: AnyCancellable?
    private var buffer = Data()
    private var armed = false
    private var networkReady = false
    private var finished = false
    private(set) var shutterSent = false
    private let startedAt = Date()
    init(client: any RGCxrClient) { self.client = client }

    private func startShutterIfReady(host: String, port: NWEndpoint.Port) {
        guard armed, networkReady, !shutterSent, !finished else { return }
        shutterSent = true
        NSLog("[快速高清拍照] 请求原生快门，耗时 %.2f 秒", Date().timeIntervalSince(startedAt))
        client.takePhoto()
        let encodedKey = key.withUnsafeBytes { Data($0).base64EncodedString() }
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let cmd = "PHOTO_NATIVE_FETCH:\(id):\(host):\(port.rawValue):\(token):\(encodedKey)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            if !finished { client.sendCustomCmd(cmd: "rk_custom_client", payload: Data(cmd.utf8)) }
        }
    }

    func run() async -> Outcome {
        guard let host = wifiAddress() else { return .failure("手机没有连接 Wi-Fi，无法使用快速传输。") }
        return await withCheckedContinuation { continuation in
            let finish: (Outcome) -> Void = { [self] outcome in
                guard !finished else { return }
                switch outcome {
                case .success: NSLog("[快速高清拍照] 原片已校验，耗时 %.2f 秒", Date().timeIntervalSince(startedAt))
                case .failure(let message): NSLog("[快速高清拍照] %@，耗时 %.2f 秒", message, Date().timeIntervalSince(startedAt))
                }
                finished = true; subscription?.cancel(); bleSubscription?.cancel(); connection?.cancel(); listener?.cancel()
                continuation.resume(returning: outcome)
            }
            do {
                let socket = try NWListener(using: .tcp, on: .any)
                listener = socket
                socket.newConnectionHandler = { [self] incoming in
                    MainActor.assumeIsolated {
                        guard connection == nil, !finished else { incoming.cancel(); return }
                        connection = incoming; incoming.start(queue: .main)
                        func receiveMore() {
                            incoming.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
                                MainActor.assumeIsolated {
                                    if let data { buffer.append(data) }
                                    let header = Data((token + "\n").utf8)
                                    guard buffer.count <= 16 * 1024 * 1024 + 128 else { finish(.failure("照片超过传输大小限制。")); return }
                                    if buffer.count >= header.count && buffer.prefix(header.count) != header {
                                        finish(.failure("传输身份校验失败，照片仍在眼镜中。")); return
                                    }
                                    if complete {
                                        if !networkReady {
                                            guard buffer == header + Data("READY".utf8), let port = socket.port else {
                                                finish(.failure("本地连接校验失败，请重试。")); return
                                            }
                                            incoming.cancel(); connection = nil; buffer.removeAll(keepingCapacity: false)
                                            networkReady = true
                                            startShutterIfReady(host: host, port: port)
                                            return
                                        }
                                        do {
                                            guard buffer.count > header.count else { throw CocoaError(.fileReadCorruptFile) }
                                            let combined = Data(buffer.dropFirst(header.count))
                                            let sealed = try AES.GCM.SealedBox(combined: combined)
                                            let photo = try AES.GCM.open(sealed, using: key, authenticating: Data(id.utf8))
                                            guard let source = CGImageSourceCreateWithData(photo as CFData, nil),
                                                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                                                  (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0 >= 2000,
                                                  (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0 >= 2000 else {
                                                throw CocoaError(.fileReadCorruptFile)
                                            }
                                            finish(.success(photo))
                                        } catch { finish(.failure("照片完整性校验失败，照片仍在眼镜中。")) }
                                    } else if error != nil { finish(.failure("照片传输中断，照片仍在眼镜中。")) }
                                    else { receiveMore() }
                                }
                            }
                        }
                        receiveMore()
                    }
                }
                socket.stateUpdateHandler = { [self] state in
                    MainActor.assumeIsolated {
                        switch state {
                        case .ready:
                            guard let port = socket.port else { finish(.failure("本地传输未就绪。")); return }
                            client.setNotifyEventListenCmds(["rk_custom_key", RGCxrCmd.Schedule.rawValue])
                            let inspect: (String) -> Void = { [self] message in
                                if message.contains("NATIVE_PHOTO_ERROR:\(id):permission") {
                                    finish(.failure("请在眼镜允许照片访问，然后重新运行。"))
                                } else if message.contains("NATIVE_PHOTO_ERROR:\(id):") {
                                    finish(.failure(shutterSent ? "原片传输失败，照片仍在眼镜中。" : "眼镜照片读取准备失败。"))
                                } else if message.contains("NATIVE_PHOTO_ARMED:\(id)") && !armed {
                                    armed = true
                                    startShutterIfReady(host: host, port: port)
                                }
                            }
                            subscription = client.notifyEventPublisher.receive(on: DispatchQueue.main).sink { event in
                                for payload in [event.payload, event.payloadEx].compactMap({ $0 }) {
                                    if let text = String(data: payload, encoding: .utf8) { inspect(text) }
                                }
                            }
                            bleSubscription = RGCxrClientBLE.shared.notifyPublisher.receive(on: DispatchQueue.main).sink { inspect($0) }
                            client.openApp(activityName: GlassesSDK.glassesActivity, url: "") { success in
                                DispatchQueue.main.async {
                                    guard !self.finished else { return }
                                    if success {
                                        let arm = "PHOTO_NATIVE_ARM:\(self.id):\(host):\(port.rawValue):\(self.token)"
                                        self.client.sendCustomCmd(cmd: "rk_custom_client", payload: Data(arm.utf8))
                                    }
                                    else { finish(.failure("眼镜拍照程序未就绪，请重试。")) }
                                }
                            }
                        case .failed: finish(.failure("手机本地网络不可用。"))
                        default: break
                        }
                    }
                }
                socket.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [self] in
                    if !shutterSent { finish(.failure("快速传输未就绪，请检查眼镜照片权限和网络。")) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [self] in
                    finish(.failure(shutterSent ? "传输超时，照片仍在眼镜中。" : "准备拍照超时，请检查连接。"))
                }
            } catch { finish(.failure("无法建立本地传输。")) }
        }
    }

    private func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var current = list
        while let ptr = current {
            defer { current = ptr.pointee.ifa_next }
            guard String(cString: ptr.pointee.ifa_name) == "en0", let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
