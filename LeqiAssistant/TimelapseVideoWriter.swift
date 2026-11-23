import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

actor TimelapseVideoWriter {
    static let framesPerSecond: Int32 = 24

    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var width = 0
    private var height = 0
    private var frameCount: Int64 = 0

    enum Failure: Error {
        case invalidPhoto, cannotEncode, encoderTimedOut
    }

    init(url: URL) {
        self.url = url
    }

    func append(_ data: Data) async throws {
        // ImageIO applies the EXIF orientation and downsamples during decode.
        let image = try autoreleasepool {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1920
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  image.width >= 2, image.height >= 2 else { throw Failure.invalidPhoto }
            return image
        }
        if writer == nil { try start(width: image.width, height: image.height) }
        guard let writer, let input, let adaptor else { throw Failure.cannotEncode }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? Failure.cannotEncode }
            guard clock.now < deadline else { throw Failure.encoderTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        let time = CMTime(value: frameCount, timescale: Self.framesPerSecond)
        try autoreleasepool {
            let buffer = try draw(image, using: adaptor)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? Failure.cannotEncode
            }
        }
        frameCount += 1
    }

    func finish() async throws {
        guard let writer, let input, frameCount > 0, writer.status == .writing else {
            throw writer?.error ?? Failure.cannotEncode
        }
        writer.endSession(atSourceTime: CMTime(value: frameCount, timescale: Self.framesPerSecond))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.cannotEncode }
    }

    func discard() {
        if writer?.status == .writing { writer?.cancelWriting() }
    }

    private func start(width: Int, height: Int) throws {
        self.width = width - width % 2
        self.height = height - height % 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: self.width,
            AVVideoHeightKey: self.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: Self.framesPerSecond,
                AVVideoAverageBitRateKey: self.width * self.height * 4
            ]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: self.width,
            kCVPixelBufferHeightKey as String: self.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw Failure.cannotEncode }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.cannotEncode }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    private func draw(_ image: CGImage, using adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer,
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            throw Failure.cannotEncode
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else { throw Failure.cannotEncode }
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(canvas)
        let scale = min(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
        let imageWidth = CGFloat(image.width) * scale
        let imageHeight = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (canvas.width - imageWidth) / 2, y: (canvas.height - imageHeight) / 2,
                                       width: imageWidth, height: imageHeight))
        return pixelBuffer
    }
}
