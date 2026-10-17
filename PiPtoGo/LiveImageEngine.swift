import UIKit
import SwiftUI
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import AudioToolbox

/// 图片「直播化」画中画引擎（iOS 15 兼容）。
///
/// 不再把图片重编码成 MP4（那是主要耗时来源），而是：
/// 1. 把图片绘制进 CVPixelBuffer，按帧率包装成 CMSampleBuffer；
/// 2. 直接 enqueue 给 `AVSampleBufferDisplayLayer`（iOS 15 的 sample-buffer 画中画管道），
///    让系统把它当作一路实时的视频/直播内容；
/// 3. 同时用 `AVSampleBufferAudioRenderer` 持续播放静音，让系统认为有音频在播，
///    从而画中画切到后台后依然持续。
///
/// 结果：选完图片 <1 秒即可开始画中画。
final class LiveImageEngine: NSObject {

    enum EngineError: LocalizedError {
        case invalidImage
        case cannotCreateFrame

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法读取图片数据"
            case .cannotCreateFrame: return "无法生成视频帧"
            }
        }
    }

    /// 上屏用的显示层（加入视图层级，同时作为画中画内容源）
    let displayLayer = AVSampleBufferDisplayLayer()

    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let videoQueue = DispatchQueue(label: "com.piptogo.live.video")
    private var audioTimer: Timer?

    private var pipController: AVPictureInPictureController?
    private var possibilityObservation: NSKeyValueObservation?
    private var activeObservation: NSKeyValueObservation?

    // 视频帧
    private var pixelBuffer: CVPixelBuffer?
    private var formatDescription: CMVideoFormatDescription?
    private var framePTS: CMTime = .zero
    private let frameInterval = CMTime(value: 1, timescale: 30)

    // 静音音频
    private var silenceFormat: CMAudioFormatDescription?
    private var audioPTS: CMTime = .zero
    private let silenceInterval = CMTime(value: 1, timescale: 1) // 1 秒一段

    var onPiPActive: ((Bool) -> Void)?
    var onPossibleChanged: ((Bool) -> Void)?

    var isActive: Bool { pipController?.isPictureInPictureActive ?? false }

    override init() {
        displayLayer.videoGravity = .resizeAspect
    }

    deinit {
        teardown()
    }

    // MARK: - 装载图片（同步、快速、无重编码）

    func attach(imageData: Data) throws {
        teardown()

        guard let image = UIImage(data: imageData), let cg = image.cgImage else {
            throw EngineError.invalidImage
        }

        let fitted = fittedSize(for: cg, maxDimension: 1280)
        guard let pb = makePixelBuffer(from: cg, size: fitted) else {
            throw EngineError.cannotCreateFrame
        }
        pixelBuffer = pb

        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescriptionOut: &fd
        ) == noErr, let fd else {
            throw EngineError.cannotCreateFrame
        }
        formatDescription = fd

        setupAudioSession()
        makeSilenceFormat()
        audioPTS = .zero

        // 渲染第一帧
        displayLayer.flush()
        if let first = makeFrame(at: .zero) {
            displayLayer.enqueue(first)
        }
        framePTS = frameInterval

        // 视频：持续供数（requestMediaDataWhenReady 模式）
        displayLayer.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
            self?.supplyVideoFrames()
        }

        // 音频：先预填 3 秒静音，再每秒补 1 秒
        for _ in 0..<3 {
            enqueueSilence()
        }
        audioTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.enqueueSilence()
        }

        // 尽早创建 PiP 控制器，让 isPictureInPicturePossible 状态立即可用（否则开始按钮一直不可点）
        ensureController()
    }

    // MARK: - 画中画

    func startPIP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        ensureController()

        guard let pipController, pipController.isPictureInPicturePossible else { return }
        pipController.startPictureInPicture()
    }

    private func ensureController() {
        guard pipController == nil else { return }
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        pipController = controller

        possibilityObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            self?.onPossibleChanged?(controller.isPictureInPicturePossible)
        }
        activeObservation = controller.observe(
            \.isPictureInPictureActive,
            options: [.new]
        ) { [weak self] controller, _ in
            self?.onPiPActive?(controller.isPictureInPictureActive)
        }
    }

    func stopPIP() {
        pipController?.stopPictureInPicture()
    }

    // MARK: - 供数循环

    private func supplyVideoFrames() {
        while displayLayer.isReadyForMoreMediaData {
            guard let buffer = makeFrame(at: framePTS) else { break }
            displayLayer.enqueue(buffer)
            framePTS = framePTS + frameInterval
        }
    }

    private func enqueueSilence() {
        guard audioRenderer.status != .failed else { return }
        guard let buffer = makeSilence(at: audioPTS) else { return }
        audioRenderer.enqueue(buffer)
        audioPTS = audioPTS + silenceInterval
    }

    private func teardown() {
        displayLayer.stopRequestingMediaData()
        displayLayer.flush()
        audioTimer?.invalidate()
        audioTimer = nil
        audioRenderer.flush()

        pipController?.stopPictureInPicture()
        pipController = nil
        possibilityObservation = nil
        activeObservation = nil
        pixelBuffer = nil
        formatDescription = nil
        silenceFormat = nil
    }

    // MARK: - 帧构造

    private func makeFrame(at pts: CMTime) -> CMSampleBuffer? {
        guard let pixelBuffer, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: frameInterval,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sb
        ) == noErr, let sb else { return nil }
        return sb
    }

    private func makeSilenceFormat() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var fd: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fd
        ) == noErr else { return }
        silenceFormat = fd
    }

    private func makeSilence(at pts: CMTime) -> CMSampleBuffer? {
        guard let silenceFormat else { return nil }
        let sampleRate = 44_100.0
        let channels: UInt32 = 2
        let bytesPerSample: UInt32 = 2
        let numSamples = UInt32(sampleRate) // 1 秒
        let blockLength = Int(numSamples) * Int(channels) * Int(bytesPerSample)

        let zeroData = calloc(blockLength, 1)
        var block: CMBlockBuffer?
        var source = CMBlockBufferCustomBlockSource(
            version: 0,
            AllocateBlock: nil,
            FreeBlock: { _, ptr, _ in free(ptr) },
            refCon: nil
        )
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: zeroData,
            blockLength: blockLength,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &source,
            offsetToData: 0,
            dataLength: blockLength,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(numSamples), timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let sampleSize: [Int] = [blockLength]
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: silenceFormat,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSize,
            sampleBufferOut: &sb
        ) == noErr, let sb else { return nil }
        return sb
    }

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    // MARK: - 图像工具

    private func fittedSize(for cg: CGImage, maxDimension: CGFloat) -> CGSize {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxDimension / max(w, h))
        return CGSize(width: max(2, (w * scale).rounded()), height: max(2, (h * scale).rounded()))
    }

    private func makePixelBuffer(from cg: CGImage, size: CGSize) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}

// MARK: - PiP 委托

extension LiveImageEngine: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - Sample Buffer 播放控制（iOS 15 必需）

extension LiveImageEngine: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaybackRate playbackRate: Float
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setCurrentTime time: CMTime,
        fastForwardedTo tolerance: CMTime
    ) {}

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        getSourceTimeWithCompletion completionHandler: @escaping (CMTime) -> Void
    ) {
        completionHandler(framePTS)
    }
}

/// 承载 LiveImageEngine 显示层的 UIView（engine 由外部挂载）
final class LiveImageView: UIView {

    private(set) var engine: LiveImageEngine?

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func attach(engine newEngine: LiveImageEngine) {
        if engine === newEngine { return }
        engine?.displayLayer.removeFromSuperlayer()
        engine = newEngine
        layer.addSublayer(newEngine.displayLayer)
        newEngine.displayLayer.frame = bounds
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        engine?.displayLayer.frame = bounds
    }
}

/// 把 LiveImageView 包进 SwiftUI
struct LiveImageContainer: UIViewRepresentable {

    let engine: LiveImageEngine
    let view: LiveImageView
    let onPiPActive: (Bool) -> Void
    let onPossible: (Bool) -> Void

    func makeUIView(context: Context) -> LiveImageView {
        engine.onPiPActive = { active in onPiPActive(active) }
        engine.onPossibleChanged = { possible in onPossible(possible) }
        view.attach(engine: engine)
        return view
    }

    func updateUIView(_ uiView: LiveImageView, context: Context) {
        engine.onPiPActive = { active in onPiPActive(active) }
        engine.onPossibleChanged = { possible in onPossible(possible) }
        uiView.attach(engine: engine)
    }
}
