import Combine
import SwiftUI

@MainActor
final class PhotoActions: ObservableObject {
    @Published private(set) var message = ""
    @Published private(set) var active = false

    func syncAlbum() {
        perform("正在同步眼镜相册…") { try await ShortcutPhotoCapture.syncAlbum() }
    }

    func capture(transfer: Bool) {
        perform(transfer ? "正在准备拍照和传输…" : "正在准备拍照…") {
            if transfer { return try await ShortcutPhotoCapture.transfer(requestPermission: true) }
            return try await ShortcutPhotoCapture.native()
        }
    }

    private func perform(_ pending: String, action: @escaping () async throws -> String) {
        guard !active else { return }
        active = true
        message = pending
        Task {
            defer { active = false }
            do {
                message = try await action()
            } catch {
                message = "眼镜操作已取消。"
            }
        }
    }
}

struct AssistantView: View {
    @ObservedObject var connection: GlassesConnection
    @ObservedObject var photo: PhotoActions
    @ObservedObject var recorder: GlassesRecorder
    @ObservedObject var organizer: GlassesOrganizer
    @ObservedObject var calendar: SystemCalendar

    var body: some View {
        NavigationStack {
            List {
                Section("眼镜连接") {
                    Label(connection.status, systemImage: "eyeglasses")
                        .accessibilityIdentifier("glassesStatus")
                    LabeledContent("蓝牙", value: connection.bluetoothConnected ? "已连接" : "未连接")
                    LabeledContent("Hi Rokid 授权", value: connection.authorized ? "已授权" : "未授权")
                    Button("连接 / 授权眼镜", action: connection.connectFromButton)
                }
                Section {
                    Button {
                        photo.capture(transfer: false)
                    } label: {
                        Label("原生拍照", systemImage: "camera")
                    }
                    .disabled(photo.active || recorder.active)
                    Button {
                        photo.capture(transfer: true)
                    } label: {
                        Label("拍照并传到相册", systemImage: "photo.badge.arrow.down")
                    }
                    .disabled(photo.active || recorder.active)
                    Button(action: photo.syncAlbum) {
                        Label("同步眼镜相册", systemImage: "arrow.clockwise")
                    }
                    .disabled(photo.active || recorder.active)
                    if !photo.message.isEmpty {
                        Text(photo.message)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("captureStatus")
                    }
                } header: {
                    Text("拍照")
                } footer: {
                    Text("原片传输和相册同步需要同一 Wi-Fi。相册同步需要更新眼镜端配套程序。")
                }
                Section("眼镜便签与日程") {
                    NavigationLink(value: OrganizerView.Kind.memos) {
                        Label("眼镜便签", systemImage: "note.text")
                    }
                    NavigationLink(value: OrganizerView.Kind.schedule) {
                        Label("眼镜日程", systemImage: "calendar")
                    }
                }
                Section("眼镜录音") {
                    Button {
                        if recorder.active { recorder.stop() }
                        else { recorder.start() }
                    } label: {
                        Label(recorder.active ? "停止并保存录音" : "开始录音",
                              systemImage: recorder.active ? "stop.circle" : "mic")
                    }
                    .disabled(photo.active)
                    if !recorder.status.isEmpty {
                        Text(recorder.status).foregroundStyle(.secondary)
                    }
                    if let file = recorder.latestRecording {
                        ShareLink(item: file) { Label("分享最近的录音", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle("乐奇助手")
            .navigationDestination(for: OrganizerView.Kind.self) { kind in
                OrganizerView(kind: kind, organizer: organizer, calendar: calendar)
            }
            .navigationDestination(item: $organizer.destination) { kind in
                OrganizerView(kind: kind, organizer: organizer, calendar: calendar)
            }
        }
    }
}
