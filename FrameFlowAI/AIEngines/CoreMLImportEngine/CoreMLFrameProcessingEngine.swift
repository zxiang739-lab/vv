import Foundation
import CoreMedia
import CoreVideo
import CoreML
import QuartzCore

/// 【用户导入 CoreML 引擎】
///
/// 遵循统一协议 `AIFrameProcessingEngine`。
/// - 加载用户导入的补帧 / 超分 mlpackage（存储于 App 沙盒，见 `CoreMLModelStore`）；
/// - 实时 / 离线全部走 CoreML + MPS 推理管线（CoreML 自动调度 GPU / ANE / CPU）；
/// - 输入统一为 BGRA 像素缓冲（`CoreMLPixelBufferUtility.toBGRA`，BGRA 时零拷贝直通）；
/// - 校验 mlpackage 输入输出张量维度（见 `CoreMLModelValidator`）。
final class CoreMLFrameProcessingEngine: AIFrameProcessingEngine {

    // MARK: - 协议属性

    let kind: EngineKind = .importedCoreML
    private(set) var capability: EngineCapability
    private(set) var modelStatus: EngineModelStatus = .notConfigured
    private(set) var state: EngineState = .idle
    private(set) var lastFrameProcessingTime: TimeInterval = 0
    private(set) var outputPixelFormat: OSType = kCVPixelFormatType_32BGRA

    var isRunning: Bool { state.isRunning }

    // MARK: - 内部状态

    private var interpolationStage: CoreMLInferenceStage?
    private var superResolutionStage: CoreMLInferenceStage?
    private var previousFrame: CVPixelBuffer?
    private var mode: ProcessingMode = .realtimeInterpolation
    private var engineConfiguration: EngineConfiguration?
    private let lock = NSLock()

    // MARK: - 初始化

    init() {
        self.capability = EngineCapability(
            engineKind: .importedCoreML,
            mode: .realtimeInterpolation,
            isSupported: true,
            unavailableReason: nil,
            isReady: false
        )
    }

    // MARK: - 协议：配置

    func prepare(mode: ProcessingMode, configuration: EngineConfiguration) async throws {
        self.mode = mode
        self.engineConfiguration = configuration
        self.state = .preparing

        let store = CoreMLModelStore.shared

        // 1. 加载所需模型（按模式需求）
        var interp: CoreMLInferenceStage?
        var sr: CoreMLInferenceStage?

        if mode.usesFrameInterpolation {
            guard let info = store.latestModel(kind: .frameInterpolation) else {
                modelStatus = .notConfigured
                capability = .init(engineKind: kind, mode: mode, isSupported: true, unavailableReason: "请先导入补帧 mlpackage。", isReady: false)
                state = .failed("缺少补帧模型")
                throw AppError.modelMissing
            }
            let model = try MLModel(contentsOf: info.url)
            interp = try CoreMLInferenceStage(model: model, info: info, kind: .frameInterpolation)
        }

        if mode.usesSuperResolution {
            guard let info = store.latestModel(kind: .superResolution) else {
                modelStatus = .notConfigured
                capability = .init(engineKind: kind, mode: mode, isSupported: true, unavailableReason: "请先导入超分 mlpackage。", isReady: false)
                state = .failed("缺少超分模型")
                throw AppError.modelMissing
            }
            let model = try MLModel(contentsOf: info.url)
            sr = try CoreMLInferenceStage(model: model, info: info, kind: .superResolution)
        }

        stop()
        interpolationStage = interp
        superResolutionStage = sr
        previousFrame = nil

        modelStatus = .ready
        capability = EngineCapability(
            engineKind: kind, mode: mode,
            isSupported: true, unavailableReason: nil, isReady: true
        )
        state = .ready
        AppLogger.engine("CoreML 引擎就绪：\(mode.title)")
    }

    func start() async throws {
        guard interpolationStage != nil || superResolutionStage != nil else {
            throw AppError.engineNotConfigured
        }
        state = .running
    }

    func stop() {
        interpolationStage = nil
        superResolutionStage = nil
        previousFrame = nil
        state = .stopped
        lastFrameProcessingTime = 0
    }

    // MARK: - 协议：帧处理

    func process(frame: CMSampleBuffer) async throws -> [CMSampleBuffer] {
        guard state == .running else {
            throw AppError.engineNotConfigured
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(frame) else {
            throw AppError.pixelBufferMissing
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(frame)

        lock.lock()
        defer { lock.unlock() }

        let start = CACurrentMediaTime()
        let bgra = try CoreMLPixelBufferUtility.toBGRA(imageBuffer)
        let outputBuffers = try processPipeline(bgra: bgra)
        lastFrameProcessingTime = CACurrentMediaTime() - start

        // 组装 CMSampleBuffer（插值帧时间戳按中点近似，离线管线会按输出帧索引重排）
        let frameDuration = engineConfiguration.map {
            CMTime(value: 1, timescale: Int32(max(1, $0.resolvedOutputFrameRate)))
        } ?? CMTime(value: 1, timescale: 30)

        var result: [CMSampleBuffer] = []
        for (index, buffer) in outputBuffers.enumerated() {
            let outputPTS = index > 0
                ? CMTimeAdd(pts, CMTimeMultiplyByFloat64(frameDuration, multiplier: Double(index) * 0.5))
                : pts
            result.append(try makeSampleBuffer(pixelBuffer: buffer, pts: outputPTS))
        }
        return result
    }

    func downloadConfigurationModelIfNeeded() async throws {
        // CoreML 引擎使用用户导入模型，无需系统模型下载
    }

    // MARK: - 私有：管线

    /// 核心管线：补帧（可选）→ 超分（可选），串联执行。
    private func processPipeline(bgra: CVPixelBuffer) throws -> [CVPixelBuffer] {
        let count = engineConfiguration?.numberOfInterpolatedFrames ?? 1

        // 1) 补帧阶段
        if let interp = interpolationStage {
            guard let previous = previousFrame else {
                // 首帧：无上一帧，直接透传（保证输出流完整）
                previousFrame = bgra
                return [bgra]
            }

            let hasTimestep = interp.supportsTimestep
            let interpolatedCount = hasTimestep ? max(1, count) : 1

            var chain: [CVPixelBuffer] = []
            if hasTimestep {
                for i in 1...interpolatedCount {
                    let t = Float(i) / Float(interpolatedCount + 1)
                    chain.append(try interp.predict(frame: bgra, previous: previous, timestep: t))
                }
            } else {
                // 模型不支持 timestep：仅输出中点插值帧（2 倍补帧）
                chain.append(try interp.predict(frame: bgra, previous: previous, timestep: nil))
            }
            chain.append(bgra)
            previousFrame = bgra

            // 2) 超分阶段（可选）
            if let sr = superResolutionStage {
                return try chain.map { try sr.predict(frame: $0, previous: nil, timestep: nil) }
            }
            return chain
        }

        // 2) 仅超分
        if let sr = superResolutionStage {
            return [try sr.predict(frame: bgra, previous: nil, timestep: nil)]
        }

        // 无任何阶段（理论不会发生，prepare 已保证）
        return [bgra]
    }

    // MARK: - 私有：CMSampleBuffer 组装

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer, pts: CMTime) throws -> CMSampleBuffer {
        var formatDescription: CMFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard fdStatus == noErr, let formatDescription else {
            throw AppError.formatDescriptionCreationFailed
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            throw AppError.sampleBufferCreationFailed
        }
        return sampleBuffer
    }
}
