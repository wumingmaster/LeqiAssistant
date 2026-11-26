import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision
import simd

nonisolated struct VideoPanorama {
    struct Result: Sendable {
        let jpeg: Data
        let watermarkedJPEG: Data?
        let width: Int
        let height: Int
        let frames: Int
        let sourceDuration: Double
        let matchedRange: ClosedRange<Double>?
    }

    enum Failure: LocalizedError {
        case noFrames, rendering

        var errorDescription: String? {
            switch self {
            case .noFrames: return "无法从这段视频读取画面，请选择另一段录像。"
            case .rendering: return "生成照片失败，请重试。"
            }
        }
    }

    private struct Frame {
        let image: CGImage
        let time: CMTime
        let luma: Luma
    }

    private struct Placement {
        let time: CMTime
        let transform: simd_float3x3
        let offset: SIMD2<Float>
    }

    private struct Luma {
        let width = 80
        let height: Int
        let pixels: [UInt8]
        let sharpness: Double
        let deviation: Double

        init?(_ image: CGImage) {
            let height = max(12, Int(80 * Double(image.height) / Double(image.width)))
            var pixels = [UInt8](repeating: 0, count: 80 * height)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: 80, height: height,
                    bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 80, height: height))
                return true
            }
            guard drawn else { return nil }
            var edges = 0
            for y in 1 ..< height - 1 {
                for x in 1 ..< 79 {
                    let i = y * 80 + x
                    edges += abs(4 * Int(pixels[i]) - Int(pixels[i - 1]) - Int(pixels[i + 1])
                        - Int(pixels[i - 80]) - Int(pixels[i + 80]))
                }
            }
            let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
            deviation = sqrt(pixels.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(pixels.count))
            sharpness = Double(edges) / Double(pixels.count)
            self.height = height
            self.pixels = pixels
        }
    }

    private let context = CIContext(options: [.cacheIntermediates: false])

    func make(from url: URL, capturedAt: Date? = nil,
              progress: @Sendable (Double) async -> Void = { _ in }) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure.noFrames }
        var date = capturedAt
        if date == nil, let metadata = try? await asset.load(.creationDate) {
            date = try? await metadata.load(.dateValue)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // Cover the whole timeline. Batching bounds decoded-frame memory for long clips.
        let count = Int(min(12_000, max(2, ceil(duration * 6))))
        let spacing = duration / Double(count)
        var sequence: [Placement] = []
        var best: [Placement] = []
        var bestSize = CGSize.zero
        var reference: Frame?
        var sharpest: Frame?
        var trailing: Placement?
        var matchesThrough = 0.0
        func keepBest() {
            let candidate = sequence + [trailing].compactMap { $0 }
            if let reference, abs(candidate.last?.offset.x ?? 0) > abs(best.last?.offset.x ?? 0) {
                best = candidate
                bestSize = CGSize(width: reference.image.width, height: reference.image.height)
            }
        }

        for start in stride(from: 0, to: count, by: 24) {
            let times = (start ..< min(start + 24, count)).map {
                CMTime(seconds: spacing * (Double($0) + 0.35), preferredTimescale: 600)
            }
            var decoded: [(time: CMTime, image: CGImage)] = []
            for await sample in generator.images(for: times) {
                try Task.checkCancellation()
                if case .success(_, let image, let actualTime) = sample {
                    decoded.append((actualTime, image))
                }
            }
            for (time, image) in decoded.sorted(by: { $0.time < $1.time }) {
                try Task.checkCancellation()
                guard let luma = autoreleasepool(invoking: { Luma(image) }) else { continue }
                let frame = Frame(image: image, time: time, luma: luma)
                if luma.sharpness > (sharpest?.luma.sharpness ?? -1) { sharpest = frame }
                guard luma.deviation >= 8, luma.sharpness >= 2.5 else { continue }

                let center = SIMD2(Float(image.width) / 2, Float(image.height) / 2)
                if let previous = reference, let last = sequence.last,
                   luma.sharpness >= previous.luma.sharpness * 0.35,
                   let alignment = autoreleasepool(invoking: { align(frame, to: previous) }),
                   let moved = project(alignment, center) {
                    matchesThrough = time.seconds
                    let delta = moved - center
                    let width = Float(image.width)
                    guard last.offset.x == 0 || delta.x * last.offset.x > 0 else { continue }
                    let placement = Placement(time: time, transform: last.transform * alignment, offset: last.offset + delta)
                    if abs(delta.x) >= width * 0.12 {
                        sequence.append(placement)
                        reference = frame
                        trailing = nil
                    } else if abs(delta.x) >= width * 0.035, time > last.time {
                        trailing = placement
                    }
                } else if reference == nil || time.seconds - matchesThrough > max(1.5, spacing * 4) {
                    keepBest()
                    sequence = [Placement(time: time, transform: matrix_identity_float3x3, offset: .zero)]
                    reference = frame
                    trailing = nil
                    matchesThrough = time.seconds
                }
            }
            await progress(0.78 * Double(min(start + 24, count)) / Double(count))
        }
        keepBest()

        try Task.checkCancellation()
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        await progress(0.8)
        if let first = best.first, let last = best.last,
           let panorama = try await stitch(best, basis: bestSize, generator: generator, progress: progress) {
            let result = try encode(panorama, frames: best.count, date: date, duration: duration,
                                    matched: first.time.seconds ... last.time.seconds)
            await progress(1)
            return result
        }

        guard let sharpest else { throw Failure.noFrames }
        let image = (try? await generator.image(at: sharpest.time).image) ?? sharpest.image
        try Task.checkCancellation()
        let width = image.width
        let height = min(image.height, Int(Double(width) * 9 / 16))
        let bounds = CGRect(x: 0, y: (image.height - height) / 2, width: width, height: height)
        guard let cropped = image.cropping(to: bounds) else { throw Failure.rendering }
        let result = try encode(cropped, frames: 1, date: date, duration: duration)
        await progress(1)
        return result
    }

    private func align(_ next: Frame, to previous: Frame) -> simd_float3x3? {
        guard next.image.width == previous.image.width, next.image.height == previous.image.height else { return nil }
        let width = Float(next.image.width)
        let height = Float(next.image.height)
        let handler = VNImageRequestHandler(cgImage: previous.image)
        let translation = VNTranslationalImageRegistrationRequest(targetedCGImage: next.image)
        try? handler.perform([translation])
        let shift = translation.results?.first?.alignmentTransform
        if let shift, abs(shift.tx) < CGFloat(width * 0.11), abs(shift.ty) < CGFloat(height * 0.08) {
            let matrix = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(Float(shift.tx), Float(shift.ty), 1))
            if let similarity = overlap(previous, next, using: matrix), similarity > 0.87 { return matrix }
        }
        let perspective = VNHomographicImageRegistrationRequest(targetedCGImage: next.image)
        try? handler.perform([perspective])
        var candidates: [simd_float3x3] = []
        if let warp = perspective.results?.first?.warpTransform { candidates.append(warp) }
        if let shift {
            candidates.append(simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(Float(shift.tx), Float(shift.ty), 1)))
        }
        var best: simd_float3x3?
        var bestScore = 0.80
        for candidate in candidates {
            let center = SIMD2(width / 2, height / 2)
            guard let moved = project(candidate, center),
                  abs(moved.x - center.x) <= width * 0.62,
                  abs(moved.y - center.y) <= height * 0.23,
                  let quad = corners(candidate, width: width, height: height),
                  quad.enumerated().allSatisfy({ i, p in
                      let next = quad[(i + 1) % quad.count]
                      let edge = next - p
                      let horizontal = i.isMultiple(of: 2)
                      let expected = horizontal ? width : height
                      let signedLength = i < 2 ? (horizontal ? edge.x : edge.y) : (horizontal ? -edge.x : -edge.y)
                      return signedLength > expected * 0.64 && signedLength < expected * 1.5
                          && abs(horizontal ? edge.y : edge.x) < expected * 0.35
                  }),
                  let score = overlap(previous, next, using: candidate), score > bestScore else { continue }
            bestScore = score
            best = candidate
        }
        return best
    }

    private func overlap(_ previous: Frame, _ next: Frame, using transform: simd_float3x3) -> Double? {
        let a = previous.luma, b = next.luma
        let dx = Float(next.image.width) / Float(b.width)
        let dy = Float(next.image.height) / Float(b.height)
        var n = 0.0, sa = 0.0, sb = 0.0, aa = 0.0, bb = 0.0, ab = 0.0
        for row in stride(from: 2, to: b.height - 2, by: 3) {
            for col in stride(from: 2, to: b.width - 2, by: 3) {
                let coordinate = SIMD2((Float(col) + 0.5) * dx, (Float(b.height - row) - 0.5) * dy)
                guard let p = project(transform, coordinate) else { continue }
                let x = p.x / dx, y = Float(a.height) - p.y / dy
                guard x >= 2, y >= 2, x < Float(a.width - 2), y < Float(a.height - 2) else { continue }
                let ap = Double(a.pixels[Int(y) * a.width + Int(x)])
                let bp = Double(b.pixels[row * b.width + col])
                n += 1; sa += ap; sb += bp; aa += ap * ap; bb += bp * bp; ab += ap * bp
            }
        }
        guard n >= Double(b.width * b.height) / 30 else { return nil }
        let variance = (aa - sa * sa / n) * (bb - sb * sb / n)
        guard variance > 0 else { return nil }
        return (ab - sa * sb / n) / sqrt(variance)
    }

    private func project(_ m: simd_float3x3, _ p: SIMD2<Float>) -> SIMD2<Float>? {
        let q = m * SIMD3(p.x, p.y, 1)
        guard q.z.isFinite, abs(q.z) > 0.001 else { return nil }
        let r = SIMD2(q.x / q.z, q.y / q.z)
        return r.x.isFinite && r.y.isFinite ? r : nil
    }

    private func corners(_ m: simd_float3x3, width: Float, height: Float) -> [SIMD2<Float>]? {
        let points: [SIMD2<Float>] = [.zero, SIMD2(width, 0), SIMD2(width, height), SIMD2(0, height)]
        let transformed = points.compactMap { project(m, $0) }
        return transformed.count == 4 ? transformed : nil
    }

    private struct Layer {
        let time: CMTime
        let corners: [SIMD2<Float>]
        let center: Float
    }

    private struct Layout {
        let layers: [Layer]
        let origin: SIMD2<Float>
        let width: Float
        let height: Float
    }

    private func layout(_ frames: [Placement], basis: CGSize, perspective: Bool) -> Layout? {
        guard frames.count >= 2 else { return nil }
        let width = Float(basis.width), height = Float(basis.height)
        let middle = frames[frames.count / 2]
        let reference = simd_inverse(middle.transform)
        let layers = frames.compactMap { frame -> Layer? in
            let offset = frame.offset - middle.offset
            let matrix = perspective ? reference * frame.transform
                : simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(offset.x, offset.y, 1))
            guard let quad = corners(matrix, width: width, height: height),
                  let center = project(matrix, SIMD2(width / 2, height / 2)),
                  quad[0].x < quad[1].x, quad[3].x < quad[2].x,
                  quad[0].y < quad[3].y, quad[1].y < quad[2].y else { return nil }
            if perspective {
                let left = max(quad[0].x, quad[3].x)
                let right = min(quad[1].x, quad[2].x)
                guard right - left >= width * 0.55, right - left <= width * 2.75,
                      quad.allSatisfy({ abs($0.y) < height * 3 }) else { return nil }
            }
            return Layer(time: frame.time, corners: quad, center: center.x)
        }.sorted { $0.center < $1.center }

        guard layers.count == frames.count, let left = layers.first, let right = layers.last else { return nil }
        let minX = ceil(max(left.corners[0].x, left.corners[3].x)) + 2
        let maxX = floor(min(right.corners[1].x, right.corners[2].x)) - 2
        let bottom = ceil(layers.map { max($0.corners[0].y, $0.corners[1].y) }.max() ?? height) + 2
        let maxY = floor(layers.map { min($0.corners[2].y, $0.corners[3].y) }.min() ?? 0) - 2
        guard maxX - minX >= width * 1.22, maxY - bottom >= height * 0.48 else { return nil }
        let outputHeight = min(maxY - bottom, (maxX - minX) * 9 / 16)
        let minY = bottom + (maxY - bottom - outputHeight) / 2
        var coveredThrough = -Float.infinity
        for (index, layer) in layers.enumerated() {
            let near = max(layer.corners[0].x, layer.corners[3].x)
            let far = min(layer.corners[1].x, layer.corners[2].x)
            if index > 0 && coveredThrough - near < width * 0.1 { return nil }
            coveredThrough = max(coveredThrough, far)
        }
        return Layout(layers: layers, origin: SIMD2(minX, minY), width: maxX - minX, height: outputHeight)
    }

    private func stitch(_ frames: [Placement], basis: CGSize, generator: AVAssetImageGenerator,
                        progress: @Sendable (Double) async -> Void) async throws -> CGImage? {
        // A single perspective plane stretches the ends of a wide sweep. Keep the
        // same verified matches in a translation layout if that projection fails.
        guard let plan = layout(frames, basis: basis, perspective: true) ?? layout(frames, basis: basis, perspective: false),
              let firstLayer = plan.layers.first else { return nil }
        let firstImage = try await generator.image(at: firstLayer.time).image
        let scale = min(Float(firstImage.width) / Float(basis.width), 6500 / plan.width)
        let rect = CGRect(x: 0, y: 0, width: CGFloat(floor(plan.width * scale)),
                          height: CGFloat(floor(plan.height * scale)))
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        let empty = CIImage(color: .clear).cropped(to: rect)
        var combined = empty
        var coveredThrough = Float(0)
        for (index, layer) in plan.layers.enumerated() {
            try Task.checkCancellation()
            let image = index == 0 ? firstImage : try await generator.image(at: layer.time).image
            let points = layer.corners.map {
                CGPoint(x: CGFloat(($0.x - plan.origin.x) * scale), y: CGFloat(($0.y - plan.origin.y) * scale))
            }
            let near = Float(max(points[0].x, points[3].x))
            let far = Float(min(points[1].x, points[2].x))
            let warp = CIFilter.perspectiveTransform()
            warp.inputImage = CIImage(cgImage: image)
            warp.bottomLeft = points[0]
            warp.bottomRight = points[1]
            warp.topRight = points[2]
            warp.topLeft = points[3]
            guard let warped = warp.outputImage else { return nil }
            let layerImage = warped.cropped(to: rect)
            if index == 0 {
                combined = layerImage.composited(over: empty)
            } else {
                let transition = CGFloat(min(Float(basis.width) * scale * 0.14, (coveredThrough - near) * 0.45))
                let gradient = CIFilter.linearGradient()
                gradient.point0 = CGPoint(x: CGFloat(near), y: 0)
                gradient.point1 = CGPoint(x: CGFloat(near) + transition, y: 0)
                gradient.color0 = .black
                gradient.color1 = .white
                guard let mask = gradient.outputImage else { return nil }
                let blend = CIFilter.blendWithMask()
                blend.inputImage = layerImage
                blend.backgroundImage = empty
                blend.maskImage = mask.cropped(to: rect)
                guard let feathered = blend.outputImage else { return nil }
                combined = feathered.composited(over: combined)
            }
            coveredThrough = max(coveredThrough, far)
            if (index + 1).isMultiple(of: 5) {
                guard let baked = context.createCGImage(combined, from: rect) else { throw Failure.rendering }
                combined = CIImage(cgImage: baked)
            }
            await progress(0.8 + 0.17 * Double(index + 1) / Double(plan.layers.count))
        }
        guard let image = context.createCGImage(combined, from: rect) else { throw Failure.rendering }
        return image
    }

    private func encode(_ image: CGImage, frames: Int, date: Date?, duration: Double,
                        matched: ClosedRange<Double>? = nil) throws -> Result {
        let clean = try jpeg(image)
        let marked = CaptureWatermark.apply(to: image, date: date).flatMap { try? jpeg($0) }
        return Result(jpeg: clean, watermarkedJPEG: marked, width: image.width, height: image.height,
                      frames: frames, sourceDuration: duration, matchedRange: matched)
    }

    private func jpeg(_ image: CGImage) throws -> Data {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.rendering
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.93] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.rendering }
        return buffer as Data
    }
}
