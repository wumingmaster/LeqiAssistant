import Photos
import PhotosUI
import SwiftUI

struct VideoPanoramaView: View {
    @AppStorage("panorama.watermark") private var showsWatermark = true
    @State private var selection: PhotosPickerItem?
    @State private var result: VideoPanorama.Result?
    @State private var busy = false
    @State private var saving = false
    @State private var saved = false
    @State private var progress = 0.0
    @State private var status = ""

    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $selection, matching: .videos, preferredItemEncoding: .current) {
                    Label(result == nil ? "从相册选择视频" : "选择另一段视频", systemImage: "film")
                }
                .disabled(saving)
                if busy {
                    ProgressView(progress == 0 ? "正在读取视频…" : "正在挑帧并拼接…", value: progress)
                    Button("取消", role: .cancel) { selection = nil }
                }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            } footer: {
                Text("用眼镜朝同一方向慢慢扫拍，再把视频同步到手机相册。App 会从头到尾寻找能对齐的画面。")
            }

            if let result {
                Section {
                    let jpeg = (showsWatermark ? result.watermarkedJPEG : nil) ?? result.jpeg
                    if let preview = UIImage(data: jpeg) {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .accessibilityLabel(result.frames > 1 ? "全景照片预览" : "宽幅单帧预览")
                    }
                    Text("\(result.width) × \(result.height) · \(result.frames > 1 ? "拼接 \(result.frames) 帧" : "宽幅单帧")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let range = result.matchedRange {
                        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
                        Text("拼接帧来自 \(range.lowerBound.formatted(format))–\(range.upperBound.formatted(format)) 秒，共 \(result.sourceDuration.formatted(format)) 秒")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Rokid Glasses 2 水印", isOn: $showsWatermark)
                        .disabled(saving || result.watermarkedJPEG == nil)
                        .onChange(of: showsWatermark) { _, _ in saved = false }
                    Button {
                        Task { await save(jpeg) }
                    } label: {
                        Label(saved ? "已保存到相册" : saving ? "正在保存…" : "保存到相册",
                              systemImage: saved ? "checkmark" : "square.and.arrow.down")
                    }
                    .disabled(saving || saved)
                }
            }
        }
        .navigationTitle("从视频生成全景")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selection) {
            guard let item = selection else {
                busy = false
                return
            }
            await process(item)
        }
    }

    private func process(_ item: PhotosPickerItem) async {
        busy = true
        status = ""
        result = nil
        saved = false
        progress = 0
        defer { if selection == item { busy = false } }

        do {
            guard let movie = try await item.loadTransferable(type: ImportedCameraMovie.self) else {
                if !Task.isCancelled && selection == item { status = "无法导入这段视频。" }
                return
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            try Task.checkCancellation()
            let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            let canReadPhotoInfo = access == .authorized || access == .limited
            let capturedAt = canReadPhotoInfo ? item.itemIdentifier.flatMap {
                PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject?.creationDate
            } : nil
            let work = Task.detached(priority: .userInitiated) {
                try await VideoPanorama().make(from: movie.url, capturedAt: capturedAt) { value in
                    await MainActor.run { if selection == item { progress = value } }
                }
            }
            let image = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            try Task.checkCancellation()
            result = image
            if image.frames == 1 { status = "这段视频的画面没能可靠拼接。可以保存较清晰的一帧宽幅照，或重新扫拍。" }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled && selection == item { status = error.localizedDescription }
        }
    }

    private func save(_ jpeg: Data) async {
        guard !saving, !saved else { return }
        saving = true
        defer { saving = false }
        var permission = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if permission == .notDetermined { permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard permission == .authorized || permission == .limited else {
            status = "请在系统设置中允许乐奇助手添加照片。"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: nil)
            }
            status = ""
            saved = true
        } catch {
            status = "保存到相册失败，可以重试。"
        }
    }
}
