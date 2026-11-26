import AVKit
import SwiftUI

struct GlassesTimelapseView: View {
    @ObservedObject var timelapse: GlassesTimelapse
    @ObservedObject var photo: PhotoActions
    @ObservedObject var recorder: GlassesRecorder
    @AppStorage("timelapse.interval") private var interval = "5"
    @AppStorage("timelapse.duration") private var duration = "2"
    @AppStorage("timelapse.durationUnit") private var durationUnit = DurationUnit.minutes
    @AppStorage("timelapse.watermark") private var showsWatermark = true
    @State private var player: AVPlayer?
    @State private var showingPreview = false
    @FocusState private var editing: Field?

    private enum Field: Hashable { case interval, duration }

    private enum DurationUnit: String, CaseIterable {
        case seconds = "秒"
        case minutes = "分钟"
        case hours = "小时"

        var seconds: Int {
            switch self {
            case .seconds: 1
            case .minutes: 60
            case .hours: 3600
            }
        }
    }

    private var plan: TimelapsePlan? {
        guard let interval = Int(interval), let units = Int(duration),
              (1...(86400 / durationUnit.seconds)).contains(units) else { return nil }
        return TimelapsePlan(interval: interval, duration: units * durationUnit.seconds, showsWatermark: showsWatermark)
    }

    var body: some View {
        Form {
            Section {
                numberField("拍摄间隔（秒）", value: $interval, field: .interval)
                numberField("拍摄总时长", value: $duration, field: .duration)
                Picker("时长单位", selection: $durationUnit) {
                    ForEach(DurationUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                Toggle("Rokid Glasses 2 水印", isOn: $showsWatermark)
            } footer: {
                if let plan {
                    let seconds = Double(plan.frameCount) / Double(TimelapseVideoWriter.framesPerSecond)
                    Text("最多 \(plan.frameCount) 帧，成片约 \(seconds.formatted(.number.precision(.fractionLength(0...2)))) 秒（24 fps）。")
                } else {
                    Text("间隔可设为 3–3600 秒，总时长须大于间隔，最长 24 小时。")
                }
            }
            .disabled(timelapse.active)

            Section {
                if timelapse.canStop {
                    Button(action: timelapse.stop) {
                        Label("结束拍摄并生成视频", systemImage: "stop.circle")
                    }
                } else if timelapse.canFinishImport {
                    Button(action: timelapse.finishImport) {
                        Label("结束导入并生成视频", systemImage: "stop.circle")
                    }
                } else if !timelapse.active {
                    Button {
                        guard let plan else { return }
                        editing = nil
                        timelapse.start(plan)
                    } label: {
                        Label("开始拍摄", systemImage: "record.circle")
                    }
                    .disabled(plan == nil || photo.active || recorder.active || timelapse.saving)
                }

                if timelapse.phase == .capturing, let end = timelapse.endDate, let plan {
                    ProgressView(timerInterval: end.addingTimeInterval(-Double(plan.duration))...end) {
                        Text("剩余时间")
                    }
                }
                if timelapse.phase == .capturing {
                    LabeledContent("已发出拍照指令", value: "\(timelapse.shutterCount) 次")
                }
                if timelapse.phase == .importing || timelapse.phase == .exporting {
                    ProgressView(value: Double(timelapse.frames), total: Double(max(1, timelapse.availableFrames))) {
                        Text("已导入 \(timelapse.frames) / \(timelapse.availableFrames) 张")
                    }
                }
                if timelapse.active, timelapse.skipped > 0 {
                    LabeledContent("错过的拍摄时点", value: "\(timelapse.skipped)")
                }
                if !timelapse.status.isEmpty {
                    Text(timelapse.status)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("需要眼镜配套 0.56 或更新版本。拍摄期间请保持乐奇助手在前台，避免用眼镜另行拍照。拍完后通过同一 Wi‑Fi 导入照片。")
            }

            if !timelapse.active, let result = timelapse.lastResult {
                Section("上次拍摄结果") {
                    LabeledContent("拍摄设置", value: "每 \(result.interval) 秒，拍 \(result.duration) 秒")
                    LabeledContent("计划拍摄", value: "\(result.planned) 张")
                    LabeledContent("已发快门指令", value: "\(result.requested) 次")
                    LabeledContent("错过的拍摄时点", value: "\(result.missed)")
                    LabeledContent("眼镜相册写入", value: result.stored.map { "\($0) 张" } ?? "未能读取")
                    LabeledContent("已导入", value: "\(result.imported) 张")
                    LabeledContent("成片", value: result.videoFrames.map { "\($0) 帧" } ?? "未生成")
                    if result.message != timelapse.status {
                        Text(result.message).foregroundStyle(.secondary)
                    }
                }
            }

            if let video = timelapse.latestVideo {
                Section("最近的视频") {
                    Button {
                        player = AVPlayer(url: video)
                        showingPreview = true
                    } label: {
                        Label("预览视频", systemImage: "play.rectangle")
                    }
                    Button(action: timelapse.saveLatestVideo) {
                        Label(timelapse.saving ? "正在保存…" : "保存到相册", systemImage: "square.and.arrow.down")
                    }
                    ShareLink(item: video) {
                        Label("分享视频", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(timelapse.active || timelapse.saving)
            }
        }
        .onAppear {
            if let seconds = Int(interval), (1...2).contains(seconds) { interval = "3" }
        }
        .navigationTitle("眼镜延时摄影")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editing != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { editing = nil }
                }
            }
        }
        .sheet(isPresented: $showingPreview, onDismiss: { player = nil }) {
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            }
        }
    }

    private func numberField(_ label: String, value: Binding<String>, field: Field) -> some View {
        LabeledContent {
            TextField(label, text: value)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .focused($editing, equals: field)
        } label: {
            Text(label)
        }
    }
}
