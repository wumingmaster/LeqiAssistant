import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

nonisolated enum CameraLabFailure: LocalizedError {
    case noVideo, standardRate(Float), encoding, needPhotos, alignment

    var errorDescription: String? {
        switch self {
        case .noVideo: return "读不到这段视频，请选择相机原片。"
        case .standardRate(let fps):
            return "这段视频的轨道约为 \(Int(fps.rounded())) fps。请选 60 或 120 fps 原片；已经由相册慢放导出的视频也可能只剩 30 fps。"
        case .encoding: return "生成文件失败，请重试。"
        case .needPhotos: return "请至少选择两张同一机位拍摄的照片。"
        case .alignment: return "照片没能可靠对齐。请固定眼镜，用同一方向和构图重拍。"
        }
    }
}

nonisolated enum SlowMotionVideo {
    struct Result: Sendable {
        let url: URL
        let sourceFPS: Float
        let speed: Double
    }

    static func make(from url: URL, to output: URL) async throws -> Result {
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw CameraLabFailure.noVideo }
        let fps = try await source.load(.nominalFrameRate)
        guard fps.isFinite, fps >= 0 else { throw CameraLabFailure.noVideo }
        guard fps >= 45 else { throw CameraLabFailure.standardRate(fps) }

        let range = try await source.load(.timeRange)
        guard range.duration.seconds.isFinite, range.duration.seconds > 0 else { throw CameraLabFailure.noVideo }
        let size = try await source.load(.naturalSize)
        let orientation = try await source.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(orientation).standardized
        guard bounds.width >= 2, bounds.height >= 2 else { throw CameraLabFailure.noVideo }

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CameraLabFailure.encoding
        }
        try video.insertTimeRange(range, of: source, at: .zero)

        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let intersection = range.intersection(try await audio.load(.timeRange))
            if intersection.duration.seconds > 0,
               let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try target.insertTimeRange(intersection, of: audio, at: intersection.start - range.start)
            }
        }

        let outputFPS: Int32 = 30
        let ratio = Double(fps) / Double(outputFPS)
        let sourceRange = CMTimeRange(start: .zero, duration: range.duration)
        let duration = CMTimeMultiplyByFloat64(range.duration, multiplier: ratio)
        composition.scaleTimeRange(sourceRange, toDuration: duration)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layer.setTransform(orientation.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: outputFPS)
        videoComposition.renderSize = CGSize(width: (bounds.width / 2).rounded(.down) * 2,
                                             height: (bounds.height / 2).rounded(.down) * 2)
        videoComposition.instructions = [instruction]

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CameraLabFailure.encoding
        }
        exporter.videoComposition = videoComposition
        exporter.audioTimePitchAlgorithm = .spectral
        exporter.shouldOptimizeForNetworkUse = true
        if #available(iOS 18.0, macOS 15.0, *) {
            try await exporter.export(to: output, as: .mp4)
        } else {
            exporter.outputURL = output
            exporter.outputFileType = .mp4
            await exporter.export()
            guard exporter.status == .completed else { throw exporter.error ?? CameraLabFailure.encoding }
        }
        return Result(url: output, sourceFPS: fps, speed: 1 / ratio)
    }
}

nonisolated struct NightPhotoStack {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case night = "夜景降噪"
        case trails = "星轨"
        var id: Self { self }
    }

    struct Result: Sendable {
        let jpeg: Data
        let included: Int
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var reference: CGImage?
    private var composite: CGImage?
    private var area = CGRect.null
    private var included = 0

    mutating func append(_ data: Data, mode: Mode) throws {
        try Task.checkCancellation()
        try autoreleasepool {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }

            guard let reference, let composite else {
                self.reference = image
                composite = image
                area = CIImage(cgImage: image).extent
                included = 1
                return
            }
            guard image.width == reference.width, image.height == reference.height else { return }

            let original = CIImage(cgImage: image)
            let frame: CIImage
            if mode == .night {
                let registration = VNTranslationalImageRegistrationRequest(targetedCGImage: image)
                let handler = VNImageRequestHandler(cgImage: reference)
                guard (try? handler.perform([registration])) != nil,
                      let shift = registration.results?.first?.alignmentTransform,
                      shift.tx.isFinite, shift.ty.isFinite,
                      abs(shift.tx) <= Double(image.width) * 0.045,
                      abs(shift.ty) <= Double(image.height) * 0.045 else { return }
                frame = original.transformed(by: shift)
            } else {
                frame = original
            }

            let overlap = area.intersection(frame.extent)
            guard !overlap.isEmpty, !overlap.isNull else { return }
            // Round inwards so translated photos never introduce a transparent edge.
            let width = floor(overlap.maxX) - ceil(overlap.minX)
            let height = floor(overlap.maxY) - ceil(overlap.minY)
            let crop = CGRect(x: ceil(overlap.minX), y: ceil(overlap.minY), width: width, height: height)
            guard width > 1, height > 1 else { return }
            let background = CIImage(cgImage: composite).transformed(by: CGAffineTransform(translationX: area.minX, y: area.minY))
            let mixed: CIImage
            switch mode {
            case .night:
                mixed = background.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: frame, kCIInputTimeKey: 1.0 / Double(included + 1)
                ])
            case .trails:
                mixed = frame.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: background])
            }
            guard let baked = context.createCGImage(mixed, from: crop, format: .RGBAh, colorSpace: linear) else {
                throw CameraLabFailure.encoding
            }
            self.composite = baked
            area = crop
            included += 1
        }
    }

    func finish() throws -> Result {
        guard let composite, included >= 2 else { throw CameraLabFailure.alignment }
        let image = CIImage(cgImage: composite)
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: sRGB, options: [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.94
        ]) else { throw CameraLabFailure.encoding }
        return Result(jpeg: jpeg, included: included)
    }
}
