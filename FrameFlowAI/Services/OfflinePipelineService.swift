import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// 离线处理管线：AVAssetReader 读帧 → AI 引擎处理 → AVAssetWriter 编码输出。
///
/// 特性：
/// - 异步任务队列（调用方持有 Task，支持取消）；
/// - 逐帧串行 + 每帧局部作用域回收中间缓冲，防范 OOM（autoreleasepool 不支持 async，由 ARC 承担回收）；
/// - 输出帧按目标帧率统一重排时间戳（补帧 / 超分均适用）；
/// - 可选复制音频轨（保持音画同步，时长不变）。
final class OfflinePipelineService {

    // MARK: - 视频信息

    struct VideoInfo {
        let width: Int
        let height: Int
        let frameRate: Double
        let duration: CMTime
        let hasAudio: Bool
        let fileSize: Int64
    }

    /// 读取视频基本信息（选择文件后、创建任务前调用）。
    func inspectVideo(at url: URL) throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw AppError.assetReaderFailed(underlying: NSError(domain: "OfflinePipeline", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件不包含视频轨道。"]))
        }
        let size = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let sizeNumber = attrs[.size] as? NSNumber {
            fileSize = sizeNumber.int64Value
        }
        return VideoInfo(
            width: Int(abs(size.width)),
            height: Int(abs(size.height)),
            frameRate: videoTrack.nominalFrameRate > 0 ? Double(videoTrack.nominalFrameRate) : 30.0,
            duration: asset.duration,
            hasAudio: !asset.tracks(withMediaType: .audio).isEmpty,
            fileSize: Int64(fileSize)
        )
    }

    // MARK: - 处理

    /// 执行一次离线任务。
    /// - Parameters:
    ///   - sourceURL: 源视频本地 URL（沙盒内副本）
    ///   - engine: 已 prepare 好的引擎
    ///   - configuration: 引擎配置（含源帧率 / 目标帧率 / 输出尺寸）
    ///   - progress: 进度回调（0...1），可跨线程调用
    /// - Returns: 输出文件 URL（App 临时目录）
    func process(
        sourceURL: URL,
        engine: AIFrameProcessingEngine,
        configuration: EngineConfiguration,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {

        let asset = AVURLAsset(url: sourceURL)

        // 1. 视频轨道与帧率
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw AppError.assetReaderFailed(underlying: NSError(domain: "OfflinePipeline", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件不包含视频轨道。"]))
        }
        let sourceFPS = configuration.sourceFrameRate ?? Double(videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30)
        let outputFPS = configuration.resolvedOutputFrameRate

        // 2. 读取器（BGRA 解压输出；引擎侧负责格式适配）
        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw AppError.assetReaderFailed(underlying: NSError(domain: "OfflinePipeline", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法添加视频读取输出。"]))
        }
        reader.add(readerOutput)

        // 3. 音频读取器（可选复制）
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioSamples: [CMSampleBuffer] = []
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: nil)
            if reader.canAdd(mixOutput) {
                reader.add(mixOutput)
                audioOutput = mixOutput
            }
        }

        // 4. 写入器
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameFlow_\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // 视频输入（H.264；HEVC 可切换）
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.outputWidth,
            AVVideoHeightKey: configuration.outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: estimatedBitrate(width: configuration.outputWidth, height: configuration.outputHeight, fps: outputFPS),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ] as [String: Any]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        // 像素缓冲适配器：像素格式与引擎输出一致，避免编码前二次转换
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: engine.outputPixelFormat,
                kCVPixelBufferWidthKey as String: configuration.outputWidth,
                kCVPixelBufferHeightKey as String: configuration.outputHeight
            ]
        )
        guard writer.canAdd(writerInput) else {
            throw AppError.assetWriterFailed(underlying: NSError(domain: "OfflinePipeline", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法添加视频写入输入。"]))
        }
        writer.add(writerInput)

        // 音频输入
        var audioWriterInput: AVAssetWriterInput?
        if audioOutput != nil {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128_000
            ])
            audioInput.expectsMediaDataInRealTime = false
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                audioWriterInput = audioInput
            }
        }

        // 5. 开始读写
        guard reader.startReading() else {
            throw AppError.assetReaderFailed(underlying: reader.error ?? NSError(domain: "OfflinePipeline", code: -4, userInfo: [NSLocalizedDescriptionKey: "读取器启动失败。"]))
        }
        guard writer.startWriting() else {
            throw AppError.assetWriterFailed(underlying: writer.error ?? NSError(domain: "OfflinePipeline", code: -5, userInfo: [NSLocalizedDescriptionKey: "写入器启动失败。"]))
        }
        writer.startSession(atSourceTime: .zero)

        // 6. 主循环：读帧 → 引擎处理 → 写入
        let timescale = CMTimeScale(max(1, Int32(outputFPS.rounded())))
        var outputFrameIndex: Int64 = 0
        var inputFrameIndex = 0
        var totalFrames = 0

        // 先统计总帧数（用于进度）
        if let track = asset.tracks(withMediaType: .video).first {
            let fps = Double(track.nominalFrameRate > 0 ? track.nominalFrameRate : 30)
            let duration = CMTimeGetSeconds(asset.duration)
            totalFrames = max(1, Int(duration * fps))
        }

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            if Task.isCancelled {
                writer.cancelWriting()
                throw AppError.taskCancelled
            }

            // 逐帧处理：串行循环 + 每帧局部作用域，配合 ARC 及时释放中间缓冲，防范 OOM。
            // （autoreleasepool 内不允许 async 调用，故由串行循环 + 局部作用域承担内存回收）
            let outputs = try await engine.process(frame: sampleBuffer)

            // 写入引擎输出帧，时间戳按输出帧索引重排
            for output in outputs {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(output) else { continue }
                let pts = CMTime(value: outputFrameIndex, timescale: timescale)
                while !writerInput.isReadyForMoreMediaData {
                    if Task.isCancelled { throw AppError.taskCancelled }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                    throw AppError.assetWriterFailed(underlying: writer.error ?? NSError(domain: "OfflinePipeline", code: -6, userInfo: [NSLocalizedDescriptionKey: "写入像素缓冲失败。"]))
                }
                outputFrameIndex += 1
            }

            // 收集音频样本（写入阶段统一按时间顺序追加）
            if let audioOutput {
                while let audioSample = audioOutput.copyNextSampleBuffer() {
                    audioSamples.append(audioSample)
                }
            }

            // 进度（按已读输入帧计数）
            inputFrameIndex += 1
            if totalFrames > 0 {
                progress(min(1, Double(inputFrameIndex) / Double(totalFrames)))
            }
        }

        if Task.isCancelled {
            writer.cancelWriting()
            throw AppError.taskCancelled
        }

        // 6.5 尾帧刷新：补帧等「前向缓冲」引擎可能缓冲了最后一帧，全部输入处理完后刷新一次
        let tail = try await engine.flushEndOfStream()
        for output in tail {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(output) else { continue }
            let pts = CMTime(value: outputFrameIndex, timescale: timescale)
            while !writerInput.isReadyForMoreMediaData {
                if Task.isCancelled { throw AppError.taskCancelled }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw AppError.assetWriterFailed(underlying: writer.error ?? NSError(domain: "OfflinePipeline", code: -6, userInfo: [NSLocalizedDescriptionKey: "写入像素缓冲失败。"]))
            }
            outputFrameIndex += 1
        }

        // 7. 写入音频
        if let audioWriterInput, !audioSamples.isEmpty {
            for sample in audioSamples {
                if Task.isCancelled {
                    writer.cancelWriting()
                    throw AppError.taskCancelled
                }
                while !audioWriterInput.isReadyForMoreMediaData {
                    if Task.isCancelled { throw AppError.taskCancelled }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                audioWriterInput.append(sample)
            }
        }

        // 8. 结束写入
        writerInput.markAsFinished()
        audioWriterInput?.markAsFinished()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                cont.resume()
            }
        }

        guard writer.status == .completed else {
            throw AppError.assetWriterFailed(underlying: writer.error ?? NSError(domain: "OfflinePipeline", code: -7, userInfo: [NSLocalizedDescriptionKey: "写入未完成。"]))
        }

        progress(1.0)
        return outputURL
    }

    // MARK: - 工具

    /// 根据输出分辨率与帧率估算码率（H.264 常规公式）。
    private func estimatedBitrate(width: Int, height: Int, fps: Double) -> Int {
        let pixels = width * height
        // 每像素 0.1 bit × fps 为参考，限制在合理区间
        let bps = Int(Double(pixels) * 0.1 * fps)
        return min(20_000_000, max(2_000_000, bps))
    }
}
