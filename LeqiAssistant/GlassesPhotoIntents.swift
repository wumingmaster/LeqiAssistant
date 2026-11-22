import AppIntents
import CryptoKit
import Photos
import RGCxrClient
import UIKit

@MainActor
enum ShortcutPhotoCapture {
    static var running = false

    static func native() async throws -> String {
        guard !running else { return "上一张照片仍在处理中，请稍后重试。" }
        running = true
        defer { running = false }
        guard try await GlassesSDK.waitUntilConnected() else { return connectionMessage }
        CxrClient.shared.takePhoto()
        return "已发出原生拍照请求，请检查眼镜及官方相册。"
    }

    static func transfer(requestPermission: Bool = false) async throws -> String {
        guard !running else { return "上一张照片仍在处理中，请稍后重试。" }
        running = true
        defer { running = false }
        var permission = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if requestPermission && permission == .notDetermined {
            permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard permission == .authorized || permission == .limited else {
            return "请先在乐奇助手中点「拍照并传到相册」，允许添加照片。"
        }
        let task = UIApplication.shared.beginBackgroundTask(withName: "GlassesPhotoTransfer")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        guard try await GlassesSDK.waitUntilConnected() else { return connectionMessage }
        let transfer = NativePhotoParallelTest(client: CxrClient.shared)
        switch await transfer.run() {
        case .empty:
            return "没有收到照片。"
        case .failure(let message):
            return message
        case .success(let data):
            let saved = await saveToPhotos(data)
            return saved ? "眼镜照片已保存到 iPhone 相册。" : "照片已接收，但相册保存失败。"
        }
    }

    static func syncAlbum() async throws -> String {
        guard !running else { return "其他眼镜操作仍在处理中。" }
        running = true
        defer { running = false }
        var permission = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if permission == .notDetermined { permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard permission == .authorized || permission == .limited else { return "请在系统设置中允许乐奇助手添加照片。" }
        guard try await GlassesSDK.waitUntilConnected() else { return connectionMessage }

        let client = CxrClient.shared
        let device = RGCxrClientBLE.shared.connectedDeviceName ?? "default"
        let cursorKey = "albumCursor.\(device)"
        let defaults = UserDefaults.standard
        var after = Int64(defaults.integer(forKey: cursorKey))
        var savedCount = 0
        for index in 0..<10 {
            try Task.checkCancellation()
            let transfer = NativePhotoParallelTest(client: client, albumAfter: after, openCompanion: index == 0)
            switch await transfer.run() {
            case .empty:
                return savedCount == 0 ? "没有新的眼镜照片。" : "已同步 \(savedCount) 张照片到相册。"
            case .failure(let message):
                let prefix = savedCount == 0 ? "" : "已保存 \(savedCount) 张。"
                return prefix + message
            case .success(let photo):
                guard let id = transfer.albumPhotoID else { return "未收到眼镜相册的照片编号。" }
                if !alreadySaved(photo) {
                    guard await saveToPhotos(photo) else { return "相册保存失败，可重新同步。" }
                    savedCount += 1
                }
                defaults.set(Int(id), forKey: cursorKey)
                after = id
            }
        }
        return "本批已检查 10 张，保存 \(savedCount) 张。可再次同步。"
    }

    private static let receiptsKey = "savedPhotoDigests"

    private static func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func alreadySaved(_ data: Data) -> Bool {
        UserDefaults.standard.stringArray(forKey: receiptsKey)?.contains(digest(data)) == true
    }

    private static func saveToPhotos(_ data: Data) async -> Bool {
        let saved = await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                if success {
                    NSLog("[眼镜照片] 系统相册已确认保存")
                } else if let error = error as NSError? {
                    NSLog("[眼镜照片] 系统相册保存失败 %@ %ld", error.domain, error.code)
                }
                continuation.resume(returning: success)
            }
        }
        if saved {
            let defaults = UserDefaults.standard
            var recent = defaults.stringArray(forKey: receiptsKey) ?? []
            recent.append(digest(data))
            defaults.set(Array(recent.suffix(500)), forKey: receiptsKey)
        }
        return saved
    }

    private static let connectionMessage = "眼镜未连接或未授权，请打开乐奇助手重连。"
}

struct GlassesNativePhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "眼镜原声拍照"
    static var description = IntentDescription("触发眼镜快门，由眼镜和 Hi Rokid 管理照片。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await ShortcutPhotoCapture.native()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct GlassesPhotoIntent: AppIntent {
    static var isDiscoverable = false
    static var title: LocalizedStringResource = "眼镜拍照并传输"
    static var description = IntentDescription("触发眼镜拍照，将原片传输并保存到 iPhone 相册。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await ShortcutPhotoCapture.transfer()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct LeqiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GlassesNativePhotoIntent(),
                    phrases: ["用\(.applicationName)原声拍照", "用\(.applicationName)原生拍照"],
                    shortTitle: "眼镜原声拍照", systemImageName: "camera")
        AppShortcut(intent: GlassesParallelPhotoTestIntent(),
                    phrases: ["用\(.applicationName)拍照传回手机"],
                    shortTitle: "眼镜原声拍照传回手机", systemImageName: "photo.badge.arrow.down")
    }
}
