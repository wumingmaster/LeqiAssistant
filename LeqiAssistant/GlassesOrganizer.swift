import Combine
import Foundation
import RGCxrClient
import SwiftUI
import WidgetKit

struct GlassesMemo: Decodable, Identifiable {
    let id: String
    let title: String
    let content: String

    var displayTitle: String { title.isEmpty ? "便签" : title }
}

struct GlassesScheduleItem: Decodable, Identifiable {
    let id: String
    let title: String
    let scheduleTime: Int64

    var date: Date { Date(timeIntervalSince1970: Double(scheduleTime) / 1000) }
}

struct GlassesOrganizerSnapshot: Decodable {
    let memos: [GlassesMemo]?
    let events: [GlassesScheduleItem]?
}

@MainActor
final class GlassesOrganizer: ObservableObject {
    @Published var destination: OrganizerView.Kind?
    @Published private(set) var snapshot: GlassesOrganizerSnapshot?
    @Published private(set) var status = ""
    @Published private(set) var updating = false

    private let maxSnapshotSize = 192 * 1024
    private let chunkSize = 240
    private var subscriptions = Set<AnyCancellable>()
    private var responseTimeout: Task<Void, Never>?
    private var transferId: String?
    private var data = Data()
    private var expectedLength: Int?
    private var attempts = 0
    private var deadline: ContinuousClock.Instant?

    func refresh() {
        guard !updating else { return }
        guard GlassesSDK.isConnected else {
            status = "请先在乐奇助手连接并授权眼镜。"
            return
        }

        let client = CxrClient.shared
        client.setNotifyEventListenCmds(["rk_custom_key", RGCxrCmd.Schedule.rawValue])
        client.notifyEventPublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                for payload in [event.payload, event.payloadEx].compactMap({ $0 }) {
                    if let text = String(data: payload, encoding: .utf8) { self?.receive(text) }
                }
            }.store(in: &subscriptions)
        RGCxrClientBLE.shared.notifyPublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.receive($0) }.store(in: &subscriptions)
        RGCxrClientBLE.shared.connectionStatePublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                if !connected { self?.cancel("眼镜已断开，重新连接后可刷新。") }
            }.store(in: &subscriptions)

        transferId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        data = Data()
        expectedLength = nil
        attempts = 0
        deadline = ContinuousClock.now + .seconds(45)
        updating = true
        status = "正在建立眼镜同步会话…"
        guard let request = transferId else { return }
        responseTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.transferId == request else { return }
            self.cancel("眼镜端应用启动超时，请保持眼镜亮屏后重试。")
        }
        client.openApp(activityName: GlassesSDK.glassesActivity, url: "") { [weak self] opened in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.transferId == request else { return }
                guard opened else {
                    self.cancel("未能打开眼镜端配套，请确认已安装并保持亮屏。")
                    return
                }
                self.status = "正在读取眼镜同步记录…"
                self.requestChunk()
            }
        }
    }

    func cancel(_ message: String = "") {
        guard updating else { return }
        responseTimeout?.cancel()
        responseTimeout = nil
        subscriptions.removeAll()
        transferId = nil
        deadline = nil
        data = Data()
        expectedLength = nil
        updating = false
        status = message
    }

    private func requestChunk() {
        guard let transferId, let deadline else { return }
        guard ContinuousClock.now < deadline else { cancel("同步超时，请重新刷新。"); return }
        let offset = data.count
        attempts += 1
        CxrClient.shared.sendCustomCmd(cmd: "rk_custom_client", payload: Data(
            "LEQI_SYSTEM_READ:\(transferId):\(offset):\(chunkSize)".utf8
        )) { [weak self] success, _, code, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.transferId == transferId, self.data.count == offset else { return }
                if !success { NSLog("[乐奇同步] CXR 发送反馈失败 code=%@", code.map(String.init) ?? "unknown") }
            }
        }
        responseTimeout?.cancel()
        responseTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, self.transferId == transferId, self.data.count == offset else { return }
            if self.attempts < 3 { self.requestChunk() }
            else { self.cancel("眼镜端未响应，请确认配套 App 已打开并支持同步。") }
        }
    }

    private func receive(_ message: String) {
        guard let transferId else { return }
        if message.contains("LEQI_SYSTEM_ERROR:\(transferId)") {
            cancel("眼镜同步已中断，请重新刷新。")
            return
        }
        let marker = "LEQI_SYSTEM_DATA:\(transferId):"
        guard let range = message.range(of: marker) else { return }
        let response = message[range.upperBound...].prefix(340)
        let parts = response.split(separator: ":", maxSplits: 2)
        guard parts.count == 3, let offset = Int(parts[0]), offset == data.count,
              let length = Int(parts[1]), (2...maxSnapshotSize).contains(length), offset < length,
              expectedLength == nil || length == expectedLength else { return }
        let byteCount = min(length - offset, chunkSize)
        let encodedCount = (byteCount + 2) / 3 * 4
        guard let bytes = Data(base64Encoded: String(parts[2].prefix(encodedCount))),
              bytes.count == byteCount else { return }
        expectedLength = length
        responseTimeout?.cancel()
        data.append(bytes)
        if data.count < length {
            attempts = 0
            requestChunk()
        } else if let decoded = try? JSONDecoder().decode(GlassesOrganizerSnapshot.self, from: data) {
            snapshot = decoded
            publishWidgets(decoded)
        } else {
            cancel("收到的同步数据格式不兼容。")
        }
    }

    private func publishWidgets(_ snapshot: GlassesOrganizerSnapshot) {
        let data = OrganizerWidgetData(
            memos: snapshot.memos.map { records in
                records.prefix(2).map {
                    .init(id: $0.id, title: String($0.displayTitle.prefix(80)),
                          preview: String($0.content.prefix(180)), date: nil)
                }
            },
            events: snapshot.events.map { records in
                records.filter { $0.date >= .now }.sorted { $0.date < $1.date }.prefix(100).map {
                    .init(id: $0.id, title: $0.title, preview: nil, date: $0.date)
                }
            },
            systemEvents: OrganizerWidgetData.read()?.systemEvents
        )
        do {
            if try data.write() { WidgetCenter.shared.reloadAllTimelines() }
            cancel("眼镜同步记录已刷新。")
        } catch {
            cancel("眼镜同步记录已刷新。手机小组件暂无法读取共享数据。")
        }
    }

}

struct OrganizerView: View {
    enum Kind: String, Hashable {
        case memos = "眼镜便签"
        case schedule = "眼镜日程"
    }

    let kind: Kind
    @ObservedObject var organizer: GlassesOrganizer
    @ObservedObject var calendar: SystemCalendar
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            switch kind {
            case .memos:
                if let memos = organizer.snapshot?.memos {
                    if memos.isEmpty { Text("暂无便签").foregroundStyle(.secondary) }
                    ForEach(memos) { memo in
                        Text(memo.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? memo.displayTitle : memo.content)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("还未收到 Rokid 的便签同步记录。").foregroundStyle(.secondary)
                }
            case .schedule:
                NavigationLink {
                    SystemCalendarView(calendar: calendar)
                } label: {
                    Label("iPhone 系统日历", systemImage: "calendar")
                }
                if let events = organizer.snapshot?.events {
                    if events.isEmpty { Text("暂无日程").foregroundStyle(.secondary) }
                    ForEach(events.sorted { $0.date < $1.date }) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title)
                            Text(event.date, format: .dateTime.month().day().hour().minute())
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("还未收到 Rokid 的日程同步记录。").foregroundStyle(.secondary)
                }
            }
            if !organizer.status.isEmpty {
                Text(organizer.status).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(kind.rawValue)
        .toolbar {
            Button("同步", systemImage: "arrow.clockwise") { organizer.refresh() }
                .disabled(organizer.updating)
        }
        .onAppear { organizer.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { organizer.refresh() }
            else if phase == .background { organizer.cancel() }
        }
        .onDisappear { organizer.cancel() }
    }
}
