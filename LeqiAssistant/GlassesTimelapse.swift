import Combine
import Foundation
import Photos
import RGCxrClient
import UIKit

struct TimelapsePlan {
    let interval: Int
    let duration: Int
    let showsWatermark: Bool

    init?(interval: Int, duration: Int, showsWatermark: Bool = true) {
        guard (3...3600).contains(interval), (interval + 1...86400).contains(duration) else { return nil }
        self.interval = interval
        self.duration = duration
        self.showsWatermark = showsWatermark
    }

    var frameCount: Int { (duration - 1) / interval + 1 }

    // The first frame is at t = 0. A frame is never started at or after the deadline.
    func nextSlot(after slot: Int, elapsedSeconds: Int64) -> Int {
        max(slot + 1, Int((elapsedSeconds + Int64(interval) - 1) / Int64(interval)))
    }
}

@MainActor
final class GlassesTimelapse: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, capturing, stopping, importing, exporting
    }

    struct CaptureResult: Codable {
        let interval: Int
        let duration: Int
        let planned: Int
        let requested: Int
        let missed: Int
        let stored: Int?
        let imported: Int
        let videoFrames: Int?
        let message: String
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var frames = 0
    @Published private(set) var skipped = 0
    @Published private(set) var shutterCount = 0
    @Published private(set) var availableFrames = 0
    @Published private(set) var endDate: Date?
    @Published private(set) var status = ""
    @Published private(set) var latestVideo: URL?
    @Published private(set) var saving = false
    @Published private(set) var lastResult: CaptureResult?

    private static let lastResultKey = "timelapse.lastResult"
    private var lastSnapshotCount: Int?
    private var downloadedFrames = 0
    private var videoFrames: Int?
    private var stopReason: String?
    private var finishImportRequested = false
    private var delay: Task<Void, Error>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var active: Bool { phase != .idle }
    var canStop: Bool { phase == .preparing || phase == .capturing }
    var canFinishImport: Bool { phase == .importing && frames > 0 && !finishImportRequested }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.lastResultKey) {
            lastResult = try? JSONDecoder().decode(CaptureResult.self, from: data)
        }
        if let video = try? Self.videoDirectory().appendingPathComponent("眼镜延时摄影.mp4"),
           FileManager.default.fileExists(atPath: video.path) {
            latestVideo = video
        }
    }

    func start(_ plan: TimelapsePlan) {
        guard !active, !saving else { return }
        guard !ShortcutPhotoCapture.running else {
            status = "眼镜正在执行其他操作，请稍后再试。"
            return
        }
        ShortcutPhotoCapture.running = true
        phase = .preparing
        frames = 0
        skipped = 0
        shutterCount = 0
        availableFrames = 0
        lastSnapshotCount = nil
        downloadedFrames = 0
        videoFrames = nil
        finishImportRequested = false
        status = "正在连接眼镜…"
        stopReason = nil
        Task { await capture(plan) }
    }

    func stop() {
        requestStop("已提前结束拍摄。")
    }

    func finishImport() {
        guard canFinishImport else { return }
        finishImportRequested = true
        status = "正在结束导入…"
    }

    func glassesDidDisconnect() {
        if phase == .capturing { requestStop("眼镜连接已断开，已结束拍摄。") }
    }

    func appDidEnterBackground() {
        requestStop("乐奇助手进入后台，已结束拍摄。")
        if active, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinishGlassesTimelapse") { [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func requestStop(_ reason: String) {
        guard canStop else { return }
        stopReason = reason
        phase = .stopping
        status = "正在结束拍摄…"
        delay?.cancel()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func saveLatestVideo() {
        guard !active, !saving, let latestVideo else { return }
        saving = true
        Task {
            defer { saving = false }
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard permission == .authorized || permission == .limited else {
                status = "请在系统设置中允许乐奇助手添加照片和视频。"
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: latestVideo, options: nil)
                }
                status = "视频已保存到 iPhone 相册。"
            } catch {
                status = "视频未能保存到相册，可以重新保存或分享。"
            }
        }
    }

    private func capture(_ plan: TimelapsePlan) async {
        let app = UIApplication.shared
        let idleTimerWasDisabled = app.isIdleTimerDisabled
        app.isIdleTimerDisabled = true
        defer {
            recordResult(for: plan)
            app.isIdleTimerDisabled = idleTimerWasDisabled
            ShortcutPhotoCapture.running = false
            endDate = nil
            phase = .idle
            endBackgroundTask()
        }

        do {
            let directory = try Self.videoDirectory()
            let output = directory.appendingPathComponent("眼镜延时摄影.mp4")
            let working = directory.appendingPathComponent("进行中的延时摄影.mp4")
            if FileManager.default.fileExists(atPath: working.path) { try FileManager.default.removeItem(at: working) }
            defer { try? FileManager.default.removeItem(at: working) }
            let encoder = TimelapseVideoWriter(url: working, showsWatermark: plan.showsWatermark)
            let message = await captureAndImport(plan, using: encoder)
            guard frames > 0 else {
                await encoder.discard()
                status = message ?? "没有拍到照片。"
                return
            }

            phase = .exporting
            status = "正在生成视频…"
            do {
                try await encoder.finish()
                if FileManager.default.fileExists(atPath: output.path) {
                    _ = try FileManager.default.replaceItemAt(output, withItemAt: working)
                } else {
                    try FileManager.default.moveItem(at: working, to: output)
                }
                latestVideo = output
                videoFrames = frames
                let result = "已生成延时视频，共 \(frames) 帧。"
                status = [message, result].compactMap { $0 }.joined(separator: "\n")
            } catch {
                await encoder.discard()
                status = "视频生成失败。已拍摄的照片保存在眼镜中。"
                NSLog("[延时摄影] 生成视频失败：%@", String(describing: error))
            }
        } catch {
            status = "无法创建视频文件，请检查 iPhone 存储空间。"
            NSLog("[延时摄影] 无法准备文件：%@", String(describing: error))
        }
    }

    private func captureAndImport(_ plan: TimelapsePlan, using encoder: TimelapseVideoWriter) async -> String? {
        GlassesSDK.configure()
        let clock = ContinuousClock()
        let connectionDeadline = clock.now + .seconds(15)
        while stopReason == nil, !GlassesSDK.isConnected, clock.now < connectionDeadline {
            await wait(until: clock.now + .milliseconds(100), clock: clock)
        }
        if let stopReason { return stopReason }
        guard GlassesSDK.isConnected else { return "眼镜未连接或未授权，请先连接眼镜。" }
        guard NativePhotoParallelTest.wifiAddress() != nil else { return "请让 iPhone 和眼镜连接同一 Wi‑Fi。" }

        status = "正在准备眼镜相册…"
        let firstID: Int64
        switch await TimelapsePhotoMark.read() {
        case .snapshot(let snapshot): firstID = snapshot.lastID
        case .failure(let message): return stopReason ?? message
        }
        if let stopReason { return stopReason }

        if plan.showsWatermark { await encoder.setWatermarkDate(Date()) }
        await takePhotos(plan, clock: clock)
        guard shutterCount > 0 else { return stopReason }
        endDate = nil
        phase = .stopping
        status = "正在等待眼镜写入最后的照片…"

        NSLog("[延时摄影] 发出 %d 次快门，错过 %d 个时点", shutterCount, skipped)
        var snapshot: TimelapsePhotoMark.Snapshot
        switch await TimelapsePhotoMark.read(after: firstID, expected: shutterCount) {
        case .snapshot(let result): snapshot = result
        case .failure(let message): return message + " 已拍摄的原片留在眼镜相册。"
        }
        // A shutter request may return before the camera has published its JPEG to MediaStore.
        if snapshot.count < shutterCount, GlassesSDK.isConnected {
            status = "正在等候眼镜相册写入余下照片…"
            if case .snapshot(let refreshed) = await TimelapsePhotoMark.read(after: firstID, expected: shutterCount),
               refreshed.count >= snapshot.count, refreshed.lastID >= snapshot.lastID {
                snapshot = refreshed
            }
        }
        lastSnapshotCount = snapshot.count
        guard snapshot.count > 0, snapshot.lastID > firstID else { return "眼镜相册没有写入新的照片。" }
        guard snapshot.count <= shutterCount else {
            return "这段时间眼镜相册新增了额外照片，无法确认延时摄影的帧。原片留在眼镜相册。"
        }

        availableFrames = snapshot.count
        phase = .importing
        status = "正在从眼镜导入照片…"
        let result = await importPhotos(after: firstID, through: snapshot.lastID, using: encoder)
        let missing = shutterCount - snapshot.count
        let missingNote = missing > 0 ? "眼镜相册少了 \(missing) 张照片。" : nil
        let notes = [stopReason, missingNote, result].compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    private func takePhotos(_ plan: TimelapsePlan, clock: ContinuousClock) async {
        let start = clock.now
        let deadline = start + .seconds(plan.duration)
        endDate = Date().addingTimeInterval(Double(plan.duration))
        phase = .capturing
        status = "正在拍摄，照片暂存在眼镜中…"
        var slot = 0
        while slot < plan.frameCount {
            let scheduled = start + .seconds(slot * plan.interval)
            if scheduled > clock.now { await wait(until: scheduled, clock: clock) }
            if stopReason != nil { return }
            if UIApplication.shared.applicationState == .background {
                requestStop("乐奇助手进入后台，已结束拍摄。")
                return
            }
            guard clock.now < deadline else {
                skipped += plan.frameCount - slot
                break
            }
            guard GlassesSDK.isConnected else {
                requestStop("眼镜连接已断开，已结束拍摄。")
                return
            }

            CxrClient.shared.takePhoto()
            shutterCount += 1

            let elapsed = start.duration(to: clock.now).components
            let elapsedSeconds = elapsed.seconds + (elapsed.attoseconds > 0 ? 1 : 0)
            let next = min(plan.frameCount, plan.nextSlot(after: slot, elapsedSeconds: elapsedSeconds))
            skipped += next - slot - 1
            slot = next
        }
        if clock.now < deadline, stopReason == nil { await wait(until: deadline, clock: clock) }
    }

    private func importPhotos(after firstID: Int64, through lastID: Int64, using encoder: TimelapseVideoWriter) async -> String? {
        var after = firstID
        while after < lastID, frames < availableFrames {
            if finishImportRequested { return "已提前结束导入，剩余照片留在眼镜相册。" }
            guard GlassesSDK.isConnected else { return "眼镜连接已断开，未导入的照片留在眼镜相册。" }
            guard NativePhotoParallelTest.wifiAddress() != nil else { return "手机 Wi‑Fi 已断开，未导入的照片留在眼镜相册。" }

            let result = await downloadPhoto(after: after, through: lastID)
            switch result.outcome {
            case .success(let photo):
                guard let id = result.id else { return "未收到有效的眼镜相册编号。" }
                downloadedFrames += 1
                do {
                    try await encoder.append(photo)
                    frames += 1
                    after = id
                } catch {
                    NSLog("[延时摄影] 编码帧失败：%@", String(describing: error))
                    return "一张照片未能写入视频，原片留在眼镜相册。"
                }
            case .empty: return "部分照片未能导入，原片可在眼镜相册查看。"
            case .failure(let message):
                return finishImportRequested ? "已提前结束导入，剩余照片留在眼镜相册。" : message
            }
        }
        return frames == availableFrames ? nil : "部分照片未能导入，原片可在眼镜相册查看。"
    }

    private func downloadPhoto(after: Int64, through: Int64) async -> (outcome: NativePhotoParallelTest.Outcome, id: Int64?) {
        let first = NativePhotoParallelTest(client: CxrClient.shared, parts: 1, albumAfter: after,
                                            albumThrough: through, openCompanion: false)
        let outcome = await first.run()
        guard case .failure = outcome else { return (outcome, first.albumPhotoID) }
        try? await Task.sleep(for: .milliseconds(500))
        guard !finishImportRequested, GlassesSDK.isConnected, NativePhotoParallelTest.wifiAddress() != nil else {
            return (outcome, nil)
        }
        status = "正在重试导入第 \(frames + 1) 张照片…"
        let retry = NativePhotoParallelTest(client: CxrClient.shared, parts: 1, albumAfter: after,
                                            albumThrough: through, openCompanion: false)
        let retried = await retry.run()
        if !finishImportRequested { status = "正在从眼镜导入照片…" }
        return (retried, retry.albumPhotoID)
    }

    private func recordResult(for plan: TimelapsePlan) {
        guard shutterCount > 0 else { return }
        let result = CaptureResult(interval: plan.interval, duration: plan.duration, planned: plan.frameCount,
                                   requested: shutterCount, missed: skipped, stored: lastSnapshotCount,
                                   imported: downloadedFrames, videoFrames: videoFrames, message: status)
        lastResult = result
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: Self.lastResultKey)
        }
        NSLog("[延时摄影] 计划 %d，快门 %d，错过 %d，眼镜写入 %@，导入 %d，成片 %@", result.planned,
              result.requested, result.missed, result.stored.map(String.init) ?? "未知", result.imported,
              result.videoFrames.map(String.init) ?? "无")
    }

    private func wait(until next: ContinuousClock.Instant, clock: ContinuousClock) async {
        let timer = Task { try await clock.sleep(until: next) }
        delay = timer
        _ = await timer.result
        delay = nil
    }

    private static func videoDirectory() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("Timelapse", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
