import AppIntents
import Combine
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Network
import Photos
import UIKit
import RGCxrClient

@available(iOS 16.0, *)
struct GlassesParallelPhotoTestIntent: AppIntent {
    static var title: LocalizedStringResource = "眼镜原声拍照传回手机"
    static var description = IntentDescription("立即触发原生快门，并并行传输原片到相册。")
    static var openAppWhenRun = false
    static var isDiscoverable = true

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await ShortcutPhotoCapture.transfer()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

@available(iOS 16.0, *)
struct GlassesPhotoSpeedTestIntent: AppIntent {
    static var title: LocalizedStringResource = "眼镜传输速度测试"
    static var description = IntentDescription("使用模拟数据比较并发传输速度，不拍照。")
    static var openAppWhenRun = false
    static var isDiscoverable = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !ShortcutPhotoCapture.running else { return .result(dialog: "其他拍照任务正在运行。") }
        ShortcutPhotoCapture.running = true
        defer { ShortcutPhotoCapture.running = false }
        let task = UIApplication.shared.beginBackgroundTask(withName: "PhotoBenchmark") { NSLog("[传输测试] 后台运行时间到期") }
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        GlassesSDK.configure(); let client = CxrClient.shared
        guard client.auth.isAuthenticated() && RGCxrClientBLE.shared.isConnected else { return .result(dialog: "请先打开乐奇助手连接眼镜。") }
        for count in [1, 2, 4, 8] {
            NSLog("[传输测试] 开始 %d 路", count)
            let test = NativePhotoParallelTest(client: client, parts: count, benchmark: true)
            switch await test.run() {
            case .success: NSLog("[传输测试] %d 路完成", count)
            case .empty: return .result(dialog: "传输测试没有收到数据。")
            case .failure(let error): NSLog("[传输测试] %d 路失败: %@", count, error); return .result(dialog: "传输测试未完成，请重试。")
            }
        }
        return .result(dialog: "传输速度测试完成。")
    }
}

@MainActor final class NativePhotoParallelTest {
    enum Outcome { case success(Data), failure(String), empty }
    private let client: any RGCxrClient
    private let parts: Int
    private let benchmark: Bool
    private let albumAfter: Int64?
    private let albumThrough: Int64?
    private let openCompanion: Bool
    private(set) var albumPhotoID: Int64?
    private var transferStartedAt: Date?
    private let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let key = SymmetricKey(size: .bits256)
    private let startedAt = Date()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var subscriptions: [AnyCancellable] = []
    private var fragments: [Int: Data] = [:]
    private var totalBytes: Int?
    private var finished = false
    private var accepted = false
    init(client: any RGCxrClient, parts: Int = 4, benchmark: Bool = false, albumAfter: Int64? = nil,
         albumThrough: Int64? = nil, openCompanion: Bool = true) {
        self.client = client
        self.parts = parts
        self.benchmark = benchmark
        self.albumAfter = albumAfter
        self.albumThrough = albumThrough
        self.openCompanion = openCompanion
    }

    func run() async -> Outcome {
        // Explicitly take the picture first. Never trigger a second capture if
        // the subsequent transfer fails or the phone lacks Wi-Fi.
        let captureMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let takesPhoto = !benchmark && albumAfter == nil
        if takesPhoto { client.takePhoto() }
        if takesPhoto { NSLog("[即时分片拍照] 已请求原生快门，耗时 %.2f 秒", Date().timeIntervalSince(startedAt)) }
        guard let host = Self.wifiAddress() else { NSLog("[即时分片拍照] 手机没有 Wi-Fi 地址"); return .failure(takesPhoto ? "已触发原生拍照；手机未连接 Wi-Fi，照片留在眼镜中。" : "手机未连接 Wi-Fi，无法同步眼镜相册。") }
        let maxBytes = 16 * 1024 * 1024 + (albumAfter == nil ? 0 : MemoryLayout<Int64>.size)
        return await withCheckedContinuation { continuation in
            let finish: (Outcome) -> Void = { [self] result in
                guard !finished else { return }; finished = true
                subscriptions.removeAll(); connections.forEach { $0.cancel() }; listener?.cancel()
                switch result {
                case .success: NSLog("[即时分片拍照] %d 个分片已校验，总耗时 %.2f 秒，传输 %.2f 秒", parts, Date().timeIntervalSince(startedAt), transferStartedAt.map { Date().timeIntervalSince($0) } ?? -1)
                case .empty: break
                case .failure(let message): NSLog("[即时分片拍照] %@，耗时 %.2f 秒", message, Date().timeIntervalSince(startedAt))
                }
                continuation.resume(returning: result)
            }
            do {
                let socket = try NWListener(using: .tcp, on: .any); listener = socket
                socket.newConnectionHandler = { [self] incoming in
                    MainActor.assumeIsolated {
                        guard !finished, connections.count < parts else { incoming.cancel(); return }
                        if transferStartedAt == nil { transferStartedAt = Date() }
                        connections.append(incoming); incoming.start(queue: .main)
                        var buffer = Data()
                        func receiveMore() {
                            incoming.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
                                MainActor.assumeIsolated {
                                    guard !finished else { return }
                                    if let data { buffer.append(data) }
                                    guard buffer.count <= (maxBytes + parts - 1) / parts + 256 else { finish(.failure("照片分片过大，照片留在眼镜中。")); return }
                                    if complete {
                                        do {
                                            guard let newline = buffer.firstIndex(of: 10), newline < 128,
                                                  let header = String(data: buffer.prefix(upTo: newline), encoding: .ascii) else { throw CocoaError(.fileReadCorruptFile) }
                                            let fields = header.split(separator: ":", omittingEmptySubsequences: false)
                                            guard fields.count == 3, fields[0] == token,
                                                  let index = Int(fields[1]), (0..<parts).contains(index),
                                                  let total = Int(fields[2]), total >= 4, total <= maxBytes,
                                                  totalBytes == nil || totalBytes == total, fragments[index] == nil else { throw CocoaError(.fileReadCorruptFile) }
                                            let box = try AES.GCM.SealedBox(combined: Data(buffer[buffer.index(after: newline)...]))
                                            let part = try AES.GCM.open(box, using: key, authenticating: Data("\(id):\(index):\(total)".utf8))
                                            let chunkSize = (total + parts - 1) / parts
                                            let expected = max(0, min(total, (index+1)*chunkSize) - index*chunkSize)
                                            guard part.count == expected else { throw CocoaError(.fileReadCorruptFile) }
                                            totalBytes = total; fragments[index] = part
                                            if fragments.count == parts {
                                                var image = Data(); for i in 0..<parts { guard let piece = fragments[i] else { throw CocoaError(.fileReadCorruptFile) }; image.append(piece) }
                                                if benchmark {
                                                    guard image.count == 3*1024*1024, image.allSatisfy({ $0 == 65 }) else { throw CocoaError(.fileReadCorruptFile) }
                                                    finish(.success(image)); return
                                                }
                                                guard image.count == total else { throw CocoaError(.fileReadCorruptFile) }
                                                if let albumAfter {
                                                    let prefix = image.prefix(MemoryLayout<Int64>.size)
                                                    guard prefix.count == MemoryLayout<Int64>.size else { throw CocoaError(.fileReadCorruptFile) }
                                                    let receivedID = prefix.reduce(Int64(0)) { ($0 << 8) | Int64($1) }
                                                    guard receivedID > albumAfter, receivedID <= (albumThrough ?? Int64.max) else { throw CocoaError(.fileReadCorruptFile) }
                                                    albumPhotoID = receivedID
                                                    image.removeFirst(prefix.count)
                                                }
                                                guard let source = CGImageSourceCreateWithData(image as CFData, nil),
                                                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                                                      let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                                                      let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                                                      width > 0, height > 0,
                                                      albumAfter != nil || (width >= 2000 && height >= 2000)
                                                else { throw CocoaError(.fileReadCorruptFile) }
                                                finish(.success(image))
                                            }
                                        } catch { finish(.failure("照片分片校验失败，照片留在眼镜中。")) }
                                    } else if error != nil { finish(.failure("照片分片传输中断，照片留在眼镜中。")) }
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
                            NSLog("[即时分片拍照] 手机接收端已就绪")
                            guard let port = socket.port else { finish(.failure("传输未就绪，照片留在眼镜中。")); return }
                            client.setNotifyEventListenCmds(["rk_custom_key", RGCxrCmd.Schedule.rawValue])
                            let inspect: (String) -> Void = { message in
                                if message.contains("PARALLEL_PHOTO_ACCEPTED:\(self.id)") {
                                    if !self.accepted { NSLog("[即时分片拍照] 眼镜已确认传输请求") }; self.accepted = true
                                } else if self.albumAfter != nil && message.contains("PARALLEL_PHOTO_EMPTY:\(self.id)") { finish(.empty)
                                } else if message.contains("PARALLEL_PHOTO_ERROR:\(self.id):permission") { finish(.failure("请在眼镜允许照片访问；本次照片留在眼镜中。")) }
                                else if message.contains("PARALLEL_PHOTO_ERROR:\(self.id):") { finish(.failure("照片定位或传输失败，照片留在眼镜中。")) }
                            }
                            subscriptions.append(client.notifyEventPublisher.receive(on: DispatchQueue.main).sink { event in
                                for data in [event.payload, event.payloadEx].compactMap({ $0 }) { if let s = String(data: data, encoding: .utf8) { inspect(s) } }
                            })
                            subscriptions.append(RGCxrClientBLE.shared.notifyPublisher.receive(on: DispatchQueue.main).sink { inspect($0) })
                            DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { [self] in
                                guard !finished else { return }
                                let k = key.withUnsafeBytes { Data($0).base64EncodedString() }.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                                let commandName = albumThrough != nil ? "PHOTO_TIMELAPSE_NEXT"
                                    : albumAfter != nil ? "PHOTO_ALBUM_NEXT" : benchmark ? "PHOTO_NATIVE_BENCH" : "PHOTO_NATIVE_PARALLEL"
                                let suffix = (albumAfter.map { ":\($0)" } ?? (benchmark ? ":\(parts)" : ""))
                                    + (albumThrough.map { ":\($0)" } ?? "")
                                let command = "\(commandName):\(id):\(host):\(port.rawValue):\(token):\(k):\(captureMillis)\(suffix)"
                                @MainActor func sendIfNeeded(_ remaining: Int) {
                                    guard !finished, remaining > 0,
                                          !accepted || (albumAfter != nil && transferStartedAt == nil) else { return }
                                    client.sendCustomCmd(cmd: "rk_custom_client", payload: Data(command.utf8))
                                    // Let the BLE SDK drain the previous request before enqueuing a retry.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + (benchmark ? 4.5 : 3)) {
                                        sendIfNeeded(remaining - 1)
                                    }
                                }
                                sendIfNeeded(benchmark ? 4 : 6)
                                if openCompanion && (!benchmark || parts == 1) {
                                    NSLog("[即时分片拍照] 请求启动眼镜传输程序")
                                    client.openApp(activityName: GlassesSDK.glassesActivity, url: "") { success in
                                        NSLog("[即时分片拍照] 眼镜启动回调: %@", success ? "成功" : "失败")
                                    }
                                }
                            }
                        case .failed: finish(.failure("手机本地网络不可用，照片留在眼镜中。"))
                        default: break
                        }
                    }
                }
                socket.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now()+24) { finish(.failure("照片传输超时，照片留在眼镜中。")) }
            } catch { finish(.failure("无法建立传输，照片留在眼镜中。")) }
        }
    }
    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }; defer { freeifaddrs(list) }
        var current = list
        while let ptr = current {
            defer { current = ptr.pointee.ifa_next }
            guard String(cString: ptr.pointee.ifa_name) == "en0", let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
}
