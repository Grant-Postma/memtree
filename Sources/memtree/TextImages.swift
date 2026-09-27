import AppKit
import CoreText
import SwiftUI

/// Labels rendered once into bitmaps with CoreText.
///
/// Canvas rasterizes text on the CPU every frame it is drawn, while an image
/// is a texture the GPU composites for free. Tiles move every frame but their
/// labels change about once a second, so a label is drawn as an image of
/// itself. A label wider than its tile is truncated with an ellipsis instead
/// of clipped, which would cost a layer per tile.
final class TextImages {
    struct Entry {
        let image: Image
        let size: CGSize
    }

    enum Style: Hashable {
        case name, groupName, value, groupValue

        var font: NSFont {
            switch self {
            case .name: return .systemFont(ofSize: 10, weight: .medium)
            case .groupName: return .systemFont(ofSize: 11, weight: .semibold)
            case .value: return .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            case .groupValue: return .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            }
        }

        var alpha: CGFloat {
            switch self {
            case .name, .groupName: return 0.92
            case .value, .groupValue: return 0.6
            }
        }
    }

    private struct Key: Hashable {
        let text: String
        let style: Style
        /// Truncation width in steps of `step` points; -1 for the whole text.
        let width: Int
    }

    private struct WidthKey: Hashable {
        let text: String
        let style: Style
    }

    private struct FormatKey: Hashable {
        let bits: UInt64
        let metric: Metric
    }

    private static let step: CGFloat = 8
    private var images: [Key: Entry?] = [:]
    private var widths: [WidthKey: CGFloat] = [:]
    private var formatted: [FormatKey: String] = [:]
    private let scale = NSScreen.main?.backingScaleFactor ?? 2

    /// `nil` when not even an ellipsis fits.
    func label(_ text: String, style: Style, maxWidth: CGFloat) -> Entry? {
        let natural = width(of: text, style: style)
        let bucket: Int
        if natural <= maxWidth {
            bucket = -1
        } else {
            // Rounded down so the truncated text always fits the tile.
            bucket = Int(maxWidth / Self.step)
            if CGFloat(bucket) * Self.step < 18 { return nil }
        }
        let key = Key(text: text, style: style, width: bucket)
        if let hit = images[key] { return hit }
        if images.count > 3000 { images.removeAll(keepingCapacity: true) }
        let entry = render(text, style: style, maxWidth: bucket < 0 ? nil : CGFloat(bucket) * Self.step)
        images[key] = entry
        return entry
    }

    func format(_ value: Double, metric: Metric, with format: (Double) -> String) -> String {
        let key = FormatKey(bits: value.bitPattern, metric: metric)
        if let hit = formatted[key] { return hit }
        if formatted.count > 4000 { formatted.removeAll(keepingCapacity: true) }
        let text = format(value)
        formatted[key] = text
        return text
    }

    private func width(of text: String, style: Style) -> CGFloat {
        let key = WidthKey(text: text, style: style)
        if let hit = widths[key] { return hit }
        if widths.count > 4000 { widths.removeAll(keepingCapacity: true) }
        let width = CGFloat(CTLineGetTypographicBounds(line(text, style: style), nil, nil, nil))
        widths[key] = width
        return width
    }

    private func line(_ text: String, style: Style) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 1, alpha: style.alpha),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private func render(_ text: String, style: Style, maxWidth: CGFloat?) -> Entry? {
        var line = line(text, style: style)
        if let maxWidth {
            let token = self.line("…", style: style)
            guard let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token) else { return nil }
            line = truncated
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let height = ceil(ascent + descent)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: Int(ceil(width * scale)), height: Int(ceil(height * scale)),
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        return Entry(image: Image(decorative: image, scale: scale), size: CGSize(width: width, height: height))
    }
}
