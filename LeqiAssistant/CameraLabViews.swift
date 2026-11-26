import AVKit
import CoreTransferable
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ImportedCameraMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext.isEmpty ? "mov" : ext)
            try FileManager.default.copyItem(at: received.file, to: url)
            return ImportedCameraMovie(url: url)
        }
    }
}

private struct ImportedCameraPhoto: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { ImportedCameraPhoto(data: $0) }
    }
}

private enum CameraLabExport {
    static func save(photo: Data? = nil, video: URL? = nil) async -> String {
        var permission = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if permission == .notDetermined { permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard permission == .authorized || permission == .limited else {
            return "请在系统设置中允许乐奇助手添加照片和视频。"
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if let photo { request.addResource(with: .photo, data: photo, options: nil) }
                if let video { request.addResource(with: .video, fileURL: video, options: nil) }
            }
            return "已保存到相册。"
        } catch {
            return "保存到相册失败，可以重试。"
        }
    }
}

struct SlowMotionView: View {
    @State private var selection: PhotosPickerItem?
    @State private var result: SlowMotionVideo.Result?
    @State private var player: AVPlayer?
    @State private var busy = false
    @State private var saving = false
    @State private var message = ""

    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $selection, matching: .videos, preferredItemEncoding: .current) {
                    Label("从相册选择视频", systemImage: "film")
                }
                .disabled(busy || saving)
                if busy { ProgressView("正在生成慢镜头…") }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            } footer: {
                Text("请选择眼镜录制的 60 或 120 fps 原视频。以 30 fps 输出并保留原构图。")
            }
            if let result, let player {
                Section {
                    VideoPlayer(player: player)
                        .frame(height: 265)
                        .accessibilityLabel("慢镜头预览")
                    Text("\(result.sourceFPS.formatted(.number.precision(.fractionLength(0...2)))) fps → 30 fps · \(result.speed.formatted(.number.precision(.fractionLength(0...2))))× 速度")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("保存到相册", systemImage: "square.and.arrow.down") {
                        Task {
                            saving = true
                            message = await CameraLabExport.save(video: result.url)
                            saving = false
                        }
                    }
                    .disabled(saving)
                    ShareLink(item: result.url) { Label("分享视频", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("从视频生成慢镜头")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selection) {
            guard let item = selection else { return }
            await generate(item)
        }
        .onDisappear { player?.pause() }
    }

    private func generate(_ item: PhotosPickerItem) async {
        busy = true
        message = ""
        player?.pause()
        player = nil
        if let result { try? FileManager.default.removeItem(at: result.url) }
        result = nil
        defer {
            busy = false
            selection = nil
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("慢镜头-\(UUID().uuidString).mp4")
        defer { if result == nil { try? FileManager.default.removeItem(at: output) } }
        do {
            guard let movie = try await item.loadTransferable(type: ImportedCameraMovie.self) else { throw CameraLabFailure.noVideo }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            try Task.checkCancellation()
            let finished = try await SlowMotionVideo.make(from: movie.url, to: output)
            try Task.checkCancellation()
            result = finished
            player = AVPlayer(url: finished.url)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
    }
}

struct NightPhotoStackView: View {
    @State private var picks: [PhotosPickerItem] = []
    @State private var mode: NightPhotoStack.Mode = .night
    @State private var result: NightPhotoStack.Result?
    @State private var busy = false
    @State private var saving = false
    @State private var progress = 0
    @State private var message = ""
    @State private var job: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Picker("合成方式", selection: $mode) {
                    ForEach(NightPhotoStack.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                PhotosPicker(selection: $picks, maxSelectionCount: 16, matching: .images, preferredItemEncoding: .current) {
                    Label("从相册选择照片", systemImage: "photo.on.rectangle.angled")
                }
                if !picks.isEmpty { Text("已选 \(picks.count) 张").foregroundStyle(.secondary) }
                Button("合成照片", systemImage: "sparkles", action: start)
                    .disabled(picks.count < 2)
            } footer: {
                Text(mode == .night
                     ? "选择 2–16 张同一构图的夜景原片。手机对齐后平均叠加，用于降低噪点。"
                     : "固定眼镜，选 2–16 张能看到星点的照片。合成保留每个位置最亮的画面，星点移动越明显，轨迹越长。")
            }
            .disabled(busy || saving)
            if busy {
                ProgressView("正在处理 \(progress) / \(picks.count) 张…",
                             value: Double(progress), total: Double(max(1, picks.count)))
            }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            if let result {
                Section {
                    if let image = UIImage(data: result.jpeg) {
                        Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("合成照片预览")
                    }
                    Button("保存到相册", systemImage: "square.and.arrow.down") {
                        Task {
                            saving = true
                            message = await CameraLabExport.save(photo: result.jpeg)
                            saving = false
                        }
                    }
                    .disabled(saving)
                }
            }
        }
        .navigationTitle("夜景与星轨合成")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { job?.cancel() }
    }

    private func start() {
        let selected = picks
        let selectedMode = mode
        result = nil
        message = ""
        progress = 0
        busy = true
        job = Task {
            defer { busy = false; job = nil }
            let worker = Task.detached(priority: .userInitiated) {
                var stack = NightPhotoStack()
                for (index, photo) in selected.enumerated() {
                    try Task.checkCancellation()
                    if let imported = try? await photo.loadTransferable(type: ImportedCameraPhoto.self) {
                        try stack.append(imported.data, mode: selectedMode)
                    }
                    await MainActor.run { progress = index + 1 }
                }
                try Task.checkCancellation()
                return try stack.finish()
            }
            do {
                let image = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                result = image
                message = "已合成 \(image.included) / \(selected.count) 张。"
            } catch is CancellationError {
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
