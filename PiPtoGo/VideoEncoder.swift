import UIKit
import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox

/// 把一张图片编码成一段“带静音音轨”的循环视频（H.264 + AAC）。
/// 带静音音轨是为了让 AVPlayer 在后台仍被视为“正在播放音频”，
/// 从而让苹果画中画在切到后台后能持续运行。
enum VideoEncoder {

    enum EncoderError: LocalizedError {
        case invalidImage
        case cannotStartWriter
        case cannotAppend
        case cannotFinish

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法读取图片数据"
            case .cannotStartWriter: return "无法启动视频编码器"
            case .cannotAppend: return "视频帧写入失败"
            case .cannotFinish: return "视频封装失败"
            }
        }
    }

    static func makeLoopedVideo(from imageData: Data, seconds: Double = 6.0) async throws -> URL {
        guard let image = UIImage(data: imageData), let cg = image.cgImage else {
            throw EncoderError.invalidImage
        }

        // 统一缩放到合理尺寸（最长边 1280），保证 H.264 编码稳定
        let fitted = fittedSize(for: cg, maxDimension: 1280)
        guard let scaled = draw(cg, to: fitted) else { throw EncoderError.invalidImage }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // 视频轨道
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(fitted.width),
            AVVideoHeightKey: Int(fitted.height),
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )

        // 静音音轨
        let audioInput = makeSilentAudioInput()

        guard writer.canAdd(videoInput) else { throw EncoderError.cannotStartWriter }
        writer.add(videoInput)
        if let audioInput, writer.canAdd(audioInput) {
            writer.add(audioInput)
        }

        guard writer.startWriting() else { throw EncoderError.cannotStartWriter }
        writer.startSession(atSourceTime: .zero)

        // 逐帧写入
        let fps = 30
        let totalFrames = max(1, Int(seconds * Double(fps)))
        for index in 0..<totalFrames {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let buffer = makePixelBuffer(from: scaled, size: fitted) else {
                throw EncoderError.cannotAppend
            }
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            if !adaptor.append(buffer, withPresentationTime: time) {
                if writer.status == .failed {
                    throw writer.error ?? EncoderError.cannotAppend
                }
                throw EncoderError.cannotAppend
            }
        }
        videoInput.markAsFinished()

        // 写入一段静音
        if let audioInput {
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if let silence = makeSilenceSampleBuffer(duration: seconds) {
                audioInput.append(silence)
            }
            audioInput.markAsFinished()
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? EncoderError.cannotFinish
        }
        return url
    }

    // MARK: - 内部工具

    private static func makeSilentAudioInput() -> AVAssetWriterInput? {
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    /// 生成一段 PCM 静音，交给 AAC 编码器
    private static func makeSilenceSampleBuffer(duration: Double) -> CMSampleBuffer? {
        let sampleRate = 44_100.0
        let channels: UInt32 = 2
        let bytesPerSample: UInt32 = 2 // 16-bit 小端 PCM
        let numSamples = UInt32(duration * sampleRate)
        let blockLength = Int(numSamples) * Int(channels) * Int(bytesPerSample)
        guard blockLength > 0 else { return nil }

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

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerSample * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(numSamples), timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        let sampleSize: [Int] = [blockLength]
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        return sampleBuffer
    }

    private static func fittedSize(for cg: CGImage, maxDimension: CGFloat) -> CGSize {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxDimension / max(w, h))
        let tw = max(2, (w * scale).rounded()), th = max(2, (h * scale).rounded())
        return CGSize(width: tw, height: th)
    }

    private static func draw(_ cg: CGImage, to size: CGSize) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    private static func makePixelBuffer(from cg: CGImage, size: CGSize) -> CVPixelBuffer? {
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
