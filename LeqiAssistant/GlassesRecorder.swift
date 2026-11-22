import Combine
import Foundation
import RGCxrClient

@MainActor
final class GlassesRecorder: ObservableObject {
    enum State { case idle, starting, recording }

    @Published private(set) var state = State.idle
    @Published private(set) var status = ""
    @Published private(set) var latestRecording: URL?

    private let recordType = "home_voice"
    private let sampleRate: UInt32 = 16_000
    private let maxBytes = 16_000 * 2 * 300
    private var samples = Data()
    private var events: AnyCancellable?
    private var link: AnyCancellable?
    private var startTimeout: Task<Void, Never>?
    private var confirmedFormat = false
    private var receivedUnconfirmedData = false

    var active: Bool { state != .idle }

    init() {
        latestRecording = try? FileManager.default.contentsOfDirectory(
            at: recordingDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "wav" }.max { $0.lastPathComponent < $1.lastPathComponent }
    }

    func start() {
        guard !active else { return }
        GlassesSDK.configure()
        guard GlassesSDK.isConnected else {
            status = "请先连接并授权眼镜。"
            return
        }
        guard !ShortcutPhotoCapture.running else {
            status = "请等待当前照片操作完成。"
            return
        }
        ShortcutPhotoCapture.running = true
        let client = CxrClient.shared
        state = .starting
        status = "正在启动眼镜麦克风…"
        samples = Data()
        confirmedFormat = false
        receivedUnconfirmedData = false
        events = client.audioEventPublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.receive(event) }
        link = RGCxrClientBLE.shared.connectionStatePublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                if !connected { self?.stop(reason: "眼镜已断开。") }
            }
        startTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self else { return }
            let message = self.confirmedFormat ? "眼镜确认录音格式，但未发回音频。"
                : self.receivedUnconfirmedData ? "收到眼镜音频，但未收到匹配的录音格式确认。"
                : "未收到眼镜的录音确认或音频，请确认眼镜已唤醒。"
            self.stop(reason: message)
        }
        client.startRecord(recordType, codec: .pcm, mode: .xf)
    }

    func stop() { stop(reason: "") }

    private func receive(_ event: RGCxrClientAudioEvent) {
        guard active else { return }
        switch event {
        case .started(let info):
            let matchesRequest = info.type == recordType
            NSLog("[眼镜录音] 开始回调 matched=%@ codec=%ld channels=%lu",
                  matchesRequest ? "yes" : "no", Int(info.codec), UInt(info.channels))
            guard matchesRequest else { return }
            guard info.codec == Int32(RGCxrAudioCodec.pcm.rawValue), info.channels == 1 else {
                stop(reason: "眼镜返回的录音格式不受支持。")
                return
            }
            confirmedFormat = true
        case .stream(let frame):
            guard !frame.data.isEmpty else { return }
            guard confirmedFormat else {
                receivedUnconfirmedData = true
                return
            }
            let count = min(frame.data.count, maxBytes - samples.count)
            samples.append(contentsOf: frame.data.prefix(count))
            if state == .starting {
                startTimeout?.cancel()
                state = .recording
                status = "正在用眼镜录音…"
            }
            if samples.count == maxBytes { stop(reason: "已达到 5 分钟录音上限。") }
        @unknown default: break
        }
    }

    private func stop(reason: String) {
        guard active else { return }
        state = .idle
        startTimeout?.cancel()
        startTimeout = nil
        events = nil
        link = nil
        CxrClient.shared.stopRecord(recordType)
        ShortcutPhotoCapture.running = false
        if !samples.count.isMultiple(of: 2) { samples.removeLast() }
        defer { samples = Data() }
        guard !samples.isEmpty else {
            status = reason.isEmpty ? "未收到录音数据。" : reason
            return
        }
        do {
            let directory = recordingDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = String(Int64(Date().timeIntervalSince1970 * 1000))
            let url = directory.appendingPathComponent("眼镜录音-\(stamp).wav")
            try waveFile().write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            latestRecording = url
            status = reason + "录音已保存到 iPhone。"
        } catch {
            status = reason + "录音保存失败。"
        }
    }

    private var recordingDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("录音", isDirectory: true)
    }

    private func waveFile() -> Data {
        var file = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ number: T) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { file.append(contentsOf: $0) }
        }
        append(UInt32(samples.count + 36))
        file.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        file.append(contentsOf: "data".utf8)
        append(UInt32(samples.count))
        file.append(samples)
        return file
    }
}
