import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `memtree --record out.mp4`: samples the machine in real time, then renders
/// every frame offscreen through the same painter as the window. No screen
/// recording permission, no dropped frames, and nothing to install: the MP4
/// comes from AVFoundation and the GIF from ImageIO.
struct RecordOptions {
    var video: URL?
    var gif: URL?
    var png: URL?
    var seconds = 12.0
    var fps = 30
    /// GIFs grow fast; 10 fps keeps a 15-second loop small enough for a README.
    var gifFPS = 10.0
    var metric = Metric.memory
    /// Points; rendered at `scale`, so 1280×720 becomes 1920×1080.
    var size = CGSize(width: 1280, height: 720)
    var scale: CGFloat = 1.5

    static let usage = """
    usage: memtree --record out.mp4 [--gif out.gif] [--png out.png]
                   [--seconds 12] [--fps 30] [--gif-fps 10] [--cpu] [--size 1280x720] [--scale 1.5]
    """

    static func parse(_ args: [String]) throws -> RecordOptions {
        var options = RecordOptions()
        var it = args.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw RecordError("\(flag) needs a value") }
            return v
        }
        func number(_ flag: String) throws -> Double {
            guard let n = Double(try value(flag)), n > 0 else { throw RecordError("\(flag) needs a positive number") }
            return n
        }
        while let arg = it.next() {
            switch arg {
            case "--record": options.video = URL(fileURLWithPath: try value(arg))
            case "--gif": options.gif = URL(fileURLWithPath: try value(arg))
            case "--png": options.png = URL(fileURLWithPath: try value(arg))
            case "--seconds": options.seconds = try number(arg)
            case "--fps": options.fps = min(Int(try number(arg)), 60)
            case "--gif-fps": options.gifFPS = try number(arg)
            case "--scale": options.scale = try number(arg)
            case "--size":
                let parts = try value(arg).split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2 else { throw RecordError("--size needs WxH, e.g. 1280x720") }
                options.size = CGSize(width: parts[0], height: parts[1])
            case "--cpu": options.metric = .cpu
            case "--memory": options.metric = .memory
            default: throw RecordError("unknown option \(arg)")
            }
        }
        return options
    }
}

@MainActor
enum Recorder {
    static let headerHeight: CGFloat = 36

    static func run(_ options: RecordOptions) throws {
        _ = NSApplication.shared
        let sampler = Sampler()
        let model = LiveModel()
        model.metric = options.metric

        // Real time first: CPU and memory only mean anything measured live.
        print("sampling for \(Int(options.seconds)) s…")
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let clock = Date()
        var snapshots: [(at: Double, snapshot: Snapshot)] = []
        for tick in 0...Int(ceil(options.seconds)) {
            let wake = clock.addingTimeInterval(Double(tick) * LiveModel.interval)
            Thread.sleep(until: wake)
            snapshots.append((Date().timeIntervalSince(clock), sampler.sample()))
        }

        let pixelWidth = Int((options.size.width * options.scale).rounded()) & ~1
        let pixelHeight = Int((options.size.height * options.scale).rounded()) & ~1
        let video = try options.video.map { try VideoWriter(url: $0, width: pixelWidth, height: pixelHeight, fps: options.fps) }
        let gifEvery = max(Int((Double(options.fps) / options.gifFPS).rounded()), 1)
        let gif = options.gif.map { GIFWriter(url: $0, fps: Double(options.fps) / Double(gifEvery)) }

        let texts = TextImages()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let canvasSize = CGSize(width: options.size.width, height: options.size.height - headerHeight - 1)
        let frames = Int(options.seconds * Double(options.fps))
        var next = 0
        var last: CGImage?
        print("rendering \(frames) frames at \(pixelWidth)×\(pixelHeight)…")
        for frame in 0..<frames {
            let t = Double(frame) / Double(options.fps)
            while next < snapshots.count, snapshots[next].at <= t + 0.001 || next == 0 {
                model.ingest(snapshots[next].snapshot, at: base.addingTimeInterval(snapshots[next].at))
                next += 1
            }
            let groups = model.step(size: canvasSize, now: base.addingTimeInterval(t))
            let view = FrameView(model: model, groups: groups, texts: texts, canvas: canvasSize)
                .frame(width: options.size.width, height: options.size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = options.scale
            guard let image = renderer.cgImage else { throw RecordError("could not render frame \(frame)") }
            try video?.append(image, frame: frame)
            if frame % gifEvery == 0 { gif?.append(image) }
            last = image
        }

        try video?.finish()
        try gif?.finish()
        if let png = options.png, let last { try writePNG(last, to: png) }
        for url in [options.video, options.gif, options.png].compactMap({ $0 }) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("  \(url.path)  \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RecordError("cannot write \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RecordError("cannot write \(url.path)") }
    }
}

private struct FrameView: View {
    @ObservedObject var model: LiveModel
    let groups: [DrawnGroup]
    let texts: TextImages
    let canvas: CGSize

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model, interactive: false).frame(height: Recorder.headerHeight)
            Divider()
            Canvas { context, _ in
                Painter(texts: texts, metric: model.metric, hovered: nil).paint(groups, in: &context)
            }
            .frame(width: canvas.width, height: canvas.height)
            .background(Color(white: 0.07))
        }
        .background(Color(white: 0.1))
        .environment(\.colorScheme, .dark)
    }
}

struct RecordError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class VideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int32
    private let width: Int, height: Int

    init(url: URL, width: Int, height: Int, fps: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        self.width = width
        self.height = height
        self.fps = Int32(fps)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw RecordError("cannot start video: \(writer.error?.localizedDescription ?? "?")") }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage, frame: Int) throws {
        guard let pool = adaptor.pixelBufferPool else { throw RecordError("no pixel buffer pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw RecordError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
            throw RecordError("cannot append frame: \(writer.error?.localizedDescription ?? "?")")
        }
    }

    func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        while done.wait(timeout: .now() + 0.01) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if writer.status != .completed { throw RecordError("video failed: \(writer.error?.localizedDescription ?? "?")") }
    }
}

private final class GIFWriter {
    private let url: URL
    private let delay: Double
    private var frames: [CGImage] = []
    /// A tweet-sized GIF: 800 wide keeps it README- and tweet-sized.
    private let width = 800

    init(url: URL, fps: Double) {
        self.url = url
        delay = 1 / fps
    }

    func append(_ image: CGImage) {
        let height = Int(Double(image.height) * Double(width) / Double(image.width))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let scaled = context.makeImage() { frames.append(scaled) }
    }

    func finish() throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw RecordError("cannot write \(url.path)")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(dest, frame, frameProperties) }
        guard CGImageDestinationFinalize(dest) else { throw RecordError("cannot write \(url.path)") }
    }
}
