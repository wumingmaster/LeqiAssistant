import Combine
import Foundation
import RGCxrClient

@MainActor
enum TimelapsePhotoMark {
    struct Snapshot {
        let lastID: Int64
        let count: Int
    }

    enum Outcome {
        case snapshot(Snapshot)
        case failure(String)
    }

    static func read(after: Int64? = nil, expected: Int = 0) async -> Outcome {
        let client = CxrClient.shared
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let window = after.map { ":\($0):\(expected)" } ?? ""
        let command = Data("PHOTO_TIMELAPSE_MARK:\(id)\(window)".utf8)
        client.setNotifyEventListenCmds(["rk_custom_key", RGCxrCmd.Schedule.rawValue])

        return await withCheckedContinuation { continuation in
            var subscriptions = Set<AnyCancellable>()
            var retry: Task<Void, Never>?
            var finished = false

            func finish(_ outcome: Outcome) {
                guard !finished else { return }
                finished = true
                retry?.cancel()
                subscriptions.removeAll()
                continuation.resume(returning: outcome)
            }

            func receive(_ text: String) {
                if let match = text.range(of: "TIMELAPSE_MARK_OK:\(id):") {
                    let fields = text[match.upperBound...].prefix { $0 == ":" || ($0.isASCII && $0.isNumber) }
                        .split(separator: ":", omittingEmptySubsequences: false)
                    guard fields.count == 2, let lastID = Int64(fields[0]), let count = Int(fields[1]),
                          lastID >= (after ?? 0), count >= 0 else { return }
                    finish(.snapshot(Snapshot(lastID: lastID, count: count)))
                } else if text.contains("TIMELAPSE_MARK_ERROR:\(id):permission") {
                    finish(.failure("请在眼镜上允许配套 App 访问照片，再重试。"))
                } else if text.contains("TIMELAPSE_MARK_ERROR:\(id):") {
                    finish(.failure("眼镜无法读取相册。"))
                }
            }

            client.notifyEventPublisher.receive(on: DispatchQueue.main).sink { event in
                for payload in [event.payload, event.payloadEx].compactMap({ $0 }) {
                    if let text = String(data: payload, encoding: .utf8) { receive(text) }
                }
            }.store(in: &subscriptions)
            RGCxrClientBLE.shared.notifyPublisher.receive(on: DispatchQueue.main)
                .sink { receive($0) }.store(in: &subscriptions)

            retry = Task {
                do {
                    // A running companion can answer without opening its UI. The
                    // closing mark may need up to 4.5 seconds to flush new JPEGs.
                    let openAttempt = after == nil ? 1 : 3
                    for attempt in 0..<6 {
                        guard GlassesSDK.isConnected else {
                            finish(.failure("眼镜已断开连接。"))
                            return
                        }
                        if attempt == openAttempt {
                            client.openApp(activityName: GlassesSDK.glassesActivity, url: "") { _ in }
                        }
                        client.sendCustomCmd(cmd: "rk_custom_client", payload: command)
                        try await Task.sleep(for: .seconds(2))
                    }
                    finish(.failure("眼镜配套未响应。请确认已安装 0.56 或更新版本。"))
                } catch {
                    // A response arrived and cancelled the retry timer.
                }
            }
        }
    }
}
