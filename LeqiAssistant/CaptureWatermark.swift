import CoreGraphics
import CoreText
import Foundation

nonisolated enum CaptureWatermark {
    struct Overlay {
        let image: CGImage
        let rect: CGRect

        func draw(in context: CGContext) {
            context.draw(image, in: rect)
        }
    }

    static func overlay(width: Int, height: Int, date: Date?) -> Overlay? {
        let shortSide = CGFloat(min(width, height))
        guard shortSide >= 48 else { return nil }

        let size = shortSide * 0.048
        let title = textLine([("Rokid", "AvenirNext-DemiBold"), (" Glasses 2", "AvenirNext-Regular")], size: size)
        let dateLine = date.map { date in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy.MM.dd HH:mm"
            return textLine([(formatter.string(from: date), "AvenirNext-Medium")], size: size * 0.59)
        }
        let padding = ceil(size * 0.25)
        let dateBaseline = padding + size * 0.15
        let titleBaseline = dateLine == nil ? padding + size * 0.22 : dateBaseline + size * 0.93
        let lines = [title, dateLine].compactMap { $0 }
        let textWidth = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        let overlayWidth = Int(ceil(textWidth + 2 * padding))
        let overlayHeight = Int(ceil(titleBaseline + size + padding))
        guard let context = bitmap(width: overlayWidth, height: overlayHeight) else { return nil }
        context.setShadow(offset: CGSize(width: 0, height: -size * 0.065), blur: size * 0.12,
                          color: CGColor(gray: 0, alpha: 0.58))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: padding, y: titleBaseline)
        CTLineDraw(title, context)
        if let dateLine {
            context.textPosition = CGPoint(x: padding, y: dateBaseline)
            CTLineDraw(dateLine, context)
        }
        guard let image = context.makeImage() else { return nil }
        let inset = round(shortSide * 0.036)
        return Overlay(image: image, rect: CGRect(x: inset - padding, y: inset - padding,
                                                  width: CGFloat(overlayWidth), height: CGFloat(overlayHeight)))
    }

    static func apply(to image: CGImage, date: Date?) -> CGImage? {
        guard let overlay = overlay(width: image.width, height: image.height, date: date),
              let context = bitmap(width: image.width, height: image.height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        overlay.draw(in: context)
        return context.makeImage()
    }

    private static func textLine(_ parts: [(String, String)], size: CGFloat) -> CTLine {
        let content = NSMutableAttributedString(string: "")
        for (text, name) in parts {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            content.append(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ]))
        }
        return CTLineCreateWithAttributedString(content)
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
