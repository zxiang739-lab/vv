import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import VideoToolbox
import Dispatch

/// 单个 VTFrameProcessor 会话封装。
///
/// 一个会话 = 一个 `VTFrameProcessor` + 一个 `VTFrameProcessorConfiguration`，
/// 对应一种「效果」（低延迟插值 / 低延迟超分 / 高质量超分 / 高质量帧率转换）。
/// 实时「补帧+超分」由上层引擎串联两个会话。
///
/// 关键职责：
/// 1. `startSession(configuration:)` 建立处理器管线（模型加载可能超过单帧时间，须后台调用）；
/// 2. 依据 `destinationPixelBufferAttributes` 创建输出 `CVPixelBufferPool`，供每帧分配目标缓冲；
/// 3. 通过 `process(parameters:completionHandler:)` 以「信号量同步」方式处理帧，
///    保证帧顺序并保持源缓冲在回调前不被释放（VTFrameProcessor 约束）；
/// 4. 处理系统模型下载（`configurationModelStatus` / `downloadConfigurationModel`）。
@available(iOS 26.0, *)
final class VTFrameProcessorSession {

    // MARK: - 属性

    // 效果类型统一复用 VTFrameProcessorConfigFactory.Effect，
    // 避免在 Session / Factory 各定义一份同名枚举导致类型不一致。
    private let processor = VTFrameProcessor()
    private let effect: VTFrameProcessorConfigFactory.Effect
    private let sourceSize: CGSize

    /// 当前会话配置（构建后缓存）
    private(set) var configuration: (any VTFrameProcessorConfiguration)?

    /// 输出像素格式（从 destinationPixelBufferAttributes 解析）
    private(set) var outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// 输出尺寸（插值=源尺寸；超分=源×倍率）
    private(set) var outputSize: CGSize = .zero

    /// 输出目标缓冲池（帧级复用，降低内存分配压力）
    private var destinationPool: CVPixelBufferPool?

    // MARK: 时序上下文（插值 / 帧率转换 / 视频型超分需要）

    private var previousFrame: VTFrameProcessorFrame?
    private var previousOutputFrame: VTFrameProcessorFrame?

    // MARK: - 初始化

    init(effect: VTFrameProcessorConfigFactory.Effect, sourceSize: CGSize) {
        self.effect = effect
        self.sourceSize = sourceSize
    }

    deinit {
        // 确保退出时结束会话、释放池
        if configuration != nil {
            processor.endSession()
        }
    }

    // MARK: - 生命周期

    /// 建立会话：创建配置 → 校验支持 → （按需下载系统模型）→ startSession → 创建输出池。
    /// 需在后台任务中调用（模型加载可能超过单帧时间，Apple 官方建议勿阻塞 UI 线程）。
    func startSession() async throws {
        // 运行时硬件能力检测：.isSupported 不通过则禁用并抛出友好错误
        guard VTFrameProcessorConfigFactory.isSupported(effect: effect) else {
            throw AppError.engineUnsupported(reason: "当前设备 / 系统不支持该 VideoToolbox 处理器（isSupported = false）。")
        }
        let config = try VTFrameProcessorConfigFactory.makeConfiguration(for: effect, sourceSize: sourceSize)
        self.configuration = config

        // 高质量离线配置可能需要系统模型：startSession 前确认就绪并驱动下载
        // （Apple 文档 Best Practice：model availability + user awareness）
        try await Self.ensureModelAvailable(config)

        // 输出像素格式与尺寸
        self.outputPixelFormat = Self.resolvePixelFormat(from: config.destinationPixelBufferAttributes)
        self.outputSize = resolveOutputSize()

        // 关键：模型加载等初始化应在非主线程执行（WWDC25 官方建议）
        try processor.startSession(configuration: config)

        // 依据处理器要求的目标缓冲属性创建池
        self.destinationPool = try Self.makeDestinationPool(config: config, outputSize: outputSize)
    }

    /// 确保系统模型就绪：若为「需下载」状态则驱动下载。
    private static func ensureModelAvailable(_ config: any VTFrameProcessorConfiguration) async throws {
        guard let srConfig = config as? VTSuperResolutionScalerConfiguration else { return }
        guard srConfig.configurationModelStatus == .downloadRequired else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            srConfig.downloadConfigurationModel { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    /// 结束会话（flush 未完成处理）。
    func endSession() {
        if configuration != nil {
            processor.endSession()
            configuration = nil
        }
        destinationPool = nil
        previousFrame = nil
        previousOutputFrame = nil
    }

    /// 处理单帧，返回输出帧数组。
    func process(_ source: CMSampleBuffer) throws -> [CMSampleBuffer] {
        // 源缓冲格式适配：若处理器要求的源格式与输入不一致，则转换（见 prepareSourceBuffer）
        guard let pixelBuffer = try prepareSourceBuffer(source) else {
            throw AppError.pixelBufferMissing
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(source)

        switch effect {
        case .lowLatencyInterpolation(let n):
            return try processInterpolation(pixelBuffer: pixelBuffer, pts: pts, numberOfInterpolatedFrames: n)

        case .lowLatencySuperResolution:
            return try processLowLatencySuperResolution(pixelBuffer: pixelBuffer, pts: pts)

        case .highQualitySuperResolution:
            return try processHighQualitySuperResolution(pixelBuffer: pixelBuffer, pts: pts)

        case .highQualityFrameRateConversion(let srcFps, let convFps):
            return try processFrameRateConversion(pixelBuffer: pixelBuffer, pts: pts, sourceFPS: srcFps, conversionFPS: convFps)
        }
    }

    // MARK: - 模型状态 / 下载

    /// 系统模型状态上报（映射为统一的 EngineModelStatus）。
    func reportModelStatus() -> EngineModelStatus {
        switch effect {
        case .highQualitySuperResolution:
            guard let config = configuration as? VTSuperResolutionScalerConfiguration else {
                return .notApplicable
            }
            switch config.configurationModelStatus {
            case .ready:
                return .ready
            case .downloading:
                return .downloading(progress: config.configurationModelPercentageAvailable)
            case .downloadRequired:
                return .notConfigured
            @unknown default:
                return .ready
            }
        default:
            // 低延迟实时配置的系统权重随系统预置；帧率转换配置如暴露
            // configurationModelStatus，可参照高质量超分分支同样处理。
            return .notApplicable
        }
    }

    /// 触发系统模型下载（仅高质量超分配置需要）。
    func downloadConfigurationModelIfNeeded() async throws {
        switch effect {
        case .highQualitySuperResolution:
            guard let config = configuration as? VTSuperResolutionScalerConfiguration,
                  config.configurationModelStatus == .downloadRequired else { return }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                config.downloadConfigurationModel { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: ())
                    }
                }
            }
        default:
            break
        }
    }

    // MARK: - 各效果处理实现

    /// 低延迟帧插值：相邻两帧之间生成 N 个插值帧 + 输出当前帧。
    private func processInterpolation(pixelBuffer: CVPixelBuffer, pts: CMTime, numberOfInterpolatedFrames n: Int) throws -> [CMSampleBuffer] {
        guard let current = VTFrameProcessorFrame(buffer: pixelBuffer, presentationTimeStamp: pts) else {
            throw AppError.parameterCreationFailed
        }

        // 首帧：尚无上一帧，直接输出本身，保证输出流完整
        guard let previous = previousFrame else {
            previousFrame = current
            return [try makeSampleBuffer(pixelBuffer: pixelBuffer, pts: pts)]
        }

        // 分配目标缓冲（N 个插值帧）
        let destinationFrames = try makeDestinationFrames(count: n, pts: pts)

        // 插值相位：均匀分布在 (0,1) 区间
        let phases: [Float] = (1...n).map { Float($0) / Float(n + 1) }

        guard let params = VTLowLatencyFrameInterpolationParameters(
            sourceFrame: current,
            previousFrame: previous,
            interpolationPhase: phases,
            destinationFrames: destinationFrames
        ) else {
            throw AppError.parameterCreationFailed
        }

        try runProcessing(params)

        // 组装输出：插值帧（时间戳按相位内插）+ 当前帧
        let dt = CMTimeSubtract(pts, previous.presentationTimeStamp)
        var outputs: [CMSampleBuffer] = []
        for (index, frame) in destinationFrames.enumerated() {
            let phase = Double(phases[index])
            let interpolatedPTS = CMTimeAdd(
                previous.presentationTimeStamp,
                CMTimeMultiplyByFloat64(dt, multiplier: phase)
            )
            outputs.append(try makeSampleBuffer(pixelBuffer: frame.buffer, pts: interpolatedPTS))
        }
        outputs.append(try makeSampleBuffer(pixelBuffer: pixelBuffer, pts: pts))

        previousFrame = current
        return outputs
    }

    /// 低延迟超分：单帧输入 → 放大输出。
    private func processLowLatencySuperResolution(pixelBuffer: CVPixelBuffer, pts: CMTime) throws -> [CMSampleBuffer] {
        guard let current = VTFrameProcessorFrame(buffer: pixelBuffer, presentationTimeStamp: pts) else {
            throw AppError.parameterCreationFailed
        }
        let destBuffer = try makeDestinationBuffer(pts: pts)
        let destFrame = try makeFrame(from: destBuffer, pts: pts)

        let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: current, destinationFrame: destFrame)
        try runProcessing(params)

        return [try makeSampleBuffer(pixelBuffer: destFrame.buffer, pts: pts)]
    }

    /// 高质量超分（离线，视频时序型）：利用前后帧时序信息提升画质。
    private func processHighQualitySuperResolution(pixelBuffer: CVPixelBuffer, pts: CMTime) throws -> [CMSampleBuffer] {
        guard let current = VTFrameProcessorFrame(buffer: pixelBuffer, presentationTimeStamp: pts) else {
            throw AppError.parameterCreationFailed
        }
        let destBuffer = try makeDestinationBuffer(pts: pts)
        let destFrame = try makeFrame(from: destBuffer, pts: pts)

        guard let params = VTSuperResolutionScalerParameters(
            sourceFrame: current,
            previousFrame: previousFrame,
            previousOutputFrame: previousOutputFrame,
            opticalFlow: nil,
            submissionMode: .sequential,   // 逐帧顺序提交，保持时序缓存
            destinationFrame: destFrame
        ) else {
            throw AppError.parameterCreationFailed
        }

        try runProcessing(params)

        // 更新时序上下文
        previousFrame = current
        previousOutputFrame = destFrame

        return [try makeSampleBuffer(pixelBuffer: destFrame.buffer, pts: pts)]
    }

    /// 高质量帧率转换（离线补帧）：在相邻两帧 A(source) 与 B(next) 之间生成插值帧。
    ///
    /// API 语义（iOS 26 SDK）：
    /// `VTFrameRateConversionParameters(sourceFrame:nextFrame:opticalFlow:interpolationPhase:submissionMode:destinationFrames:)`
    /// 的 `sourceFrame` / `nextFrame` 分别为「当前源帧」与「按时间序的下一源帧」，
    /// 插值帧插入两者之间。因此本实现采用「前向缓冲」：
    /// - 帧 A 到达时先缓冲（作为 sourceFrame），不产生输出；
    /// - 帧 B 到达时对 (A, B) 提交一次处理，输出 [A, A..B 之间的插值帧…]；
    /// - 全部输入处理完后由 `flushTail()` 输出最后一帧，保证源帧完整不丢失。
    private func processFrameRateConversion(pixelBuffer: CVPixelBuffer, pts: CMTime, sourceFPS: Double, conversionFPS: Double) throws -> [CMSampleBuffer] {
        guard let current = VTFrameProcessorFrame(buffer: pixelBuffer, presentationTimeStamp: pts) else {
            throw AppError.parameterCreationFailed
        }
        guard sourceFPS > 0 else { throw AppError.engineUnsupported(reason: "源帧率无效。") }

        // 输出倍率（四舍五入取整，要求整数倍率以获得稳定帧率）
        let multiplier = max(1, Int((conversionFPS / sourceFPS).rounded()))
        let interpolatedCount = max(1, multiplier - 1)

        // 首帧：仅缓冲（作为下一处理对的 sourceFrame），不产生输出
        guard let previous = previousFrame else {
            previousFrame = current
            return []
        }

        // 在 previous(A) 与 current(B) 之间插值：sourceFrame = A, nextFrame = B
        let destinationFrames = try makeDestinationFrames(count: interpolatedCount, pts: pts)
        // 插值相位：均匀分布在 (0,1) 区间（0 对应 A，1 对应 B）
        let phases: [Float] = (1...interpolatedCount).map { Float($0) / Float(interpolatedCount + 1) }

        guard let params = VTFrameRateConversionParameters(
            sourceFrame: previous,
            nextFrame: current,
            opticalFlow: nil,
            interpolationPhase: phases,
            submissionMode: .sequential,   // 逐帧顺序提交（A→B→C…），保持时序缓存
            destinationFrames: destinationFrames
        ) else {
            throw AppError.parameterCreationFailed
        }

        try runProcessing(params)

        // 输出顺序：[源帧 A] + A..B 之间的插值帧（时间戳按相位内插）
        let dt = CMTimeSubtract(pts, previous.presentationTimeStamp)
        var outputs: [CMSampleBuffer] = [
            try makeSampleBuffer(pixelBuffer: previous.buffer, pts: previous.presentationTimeStamp)
        ]
        for (index, frame) in destinationFrames.enumerated() {
            let phase = Double(phases[index])
            let interpolatedPTS = CMTimeAdd(
                previous.presentationTimeStamp,
                CMTimeMultiplyByFloat64(dt, multiplier: phase)
            )
            outputs.append(try makeSampleBuffer(pixelBuffer: frame.buffer, pts: interpolatedPTS))
        }

        previousFrame = current
        return outputs
    }

    /// 所有输入帧处理完后调用：输出被缓冲的最后一帧（仅离线帧率转换需要）。
    /// 其它效果（超分等）不缓冲待输出帧，返回空数组。
    func flushTail() throws -> [CMSampleBuffer] {
        switch effect {
        case .highQualityFrameRateConversion:
            guard let last = previousFrame else { return [] }
            previousFrame = nil
            return [try makeSampleBuffer(pixelBuffer: last.buffer, pts: last.presentationTimeStamp)]
        default:
            return []
        }
    }

    // MARK: - 私有工具

    /// 源像素缓冲格式适配：
    /// - 格式已被处理器支持 → 直接返回（零拷贝直通，满足「VT 引擎直接传入」）；
    /// - 不被支持 → 转换为处理器要求的第一个像素格式（离线读取器为 BGRA 时常见）。
    private func prepareSourceBuffer(_ sampleBuffer: CMSampleBuffer) throws -> CVPixelBuffer? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let supported = supportedFormats()
        guard !supported.isEmpty, !supported.contains(format) else {
            return pixelBuffer
        }
        return try Self.render(pixelBuffer, toFormat: supported[0])
    }

    /// 读取处理器支持的源像素格式（按具体配置类查询）。
    private func supportedFormats() -> [OSType] {
        guard let config = configuration else { return [] }
        if let c = config as? VTLowLatencyFrameInterpolationConfiguration {
            return c.supportedPixelFormats
        }
        if let c = config as? VTLowLatencySuperResolutionScalerConfiguration {
            return c.supportedPixelFormats
        }
        if let c = config as? VTSuperResolutionScalerConfiguration {
            return c.supportedPixelFormats
        }
        // VTFrameRateConversionConfiguration 的属性以 SDK 为准，此处不做强类型访问
        return []
    }

    /// 渲染像素缓冲为指定格式（CIContext 兜底转换，共享实例复用）。
    private static func render(_ source: CVPixelBuffer, toFormat format: OSType) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw AppError.processingFailed(underlying: NSError(domain: "CVPixelBufferCreate", code: Int(status), userInfo: nil))
        }
        renderContext.render(CIImage(cvPixelBuffer: source), to: buffer)
        return buffer
    }

    private static let renderContext = CIContext()

    /// 同步执行一次帧处理（信号量等待回调）。
    /// 必须运行在引擎专用串行队列，避免与其它帧交错。
    private func runProcessing(_ parameters: any VTFrameProcessorParameters) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var capturedError: Error?

        processor.process(parameters: parameters) { _, error in
            capturedError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let capturedError {
            throw AppError.processingFailed(underlying: capturedError)
        }
    }

    /// 从池中分配一个输出目标缓冲并包装为 VTFrameProcessorFrame。
    private func makeDestinationBuffer(pts: CMTime) throws -> CVPixelBuffer {
        guard let pool = destinationPool else {
            throw AppError.engineNotConfigured
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw AppError.processingFailed(underlying: NSError(domain: "CVPixelBufferPool", code: Int(status), userInfo: nil))
        }
        return buffer
    }

    private func makeDestinationFrames(count: Int, pts: CMTime) throws -> [VTFrameProcessorFrame] {
        var frames: [VTFrameProcessorFrame] = []
        for _ in 0..<count {
            let buffer = try makeDestinationBuffer(pts: pts)
            frames.append(try makeFrame(from: buffer, pts: pts))
        }
        return frames
    }

    private func makeFrame(from buffer: CVPixelBuffer, pts: CMTime) throws -> VTFrameProcessorFrame {
        guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: pts) else {
            throw AppError.parameterCreationFailed
        }
        return frame
    }

    /// 像素缓冲 → CMSampleBuffer（带时间戳）。
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
            sampleTiming: &timing,   // 该 C API 需要 UnsafePointer<CMSampleTimingInfo>
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            throw AppError.sampleBufferCreationFailed
        }
        return sampleBuffer
    }

    /// 解析目标像素格式。
    private static func resolvePixelFormat(from attributes: [String: any Sendable]) -> OSType {
        if let number = attributes[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber {
            return OSType(number.uint32Value)
        }
        return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    /// 计算输出尺寸。
    private func resolveOutputSize() -> CGSize {
        switch effect {
        case .lowLatencyInterpolation, .highQualityFrameRateConversion:
            return sourceSize
        case .lowLatencySuperResolution(let f):
            // f 为 Float，统一转 CGFloat 后与源尺寸（CGFloat）相乘
            return CGSize(width: sourceSize.width * CGFloat(f),
                          height: sourceSize.height * CGFloat(f))
        case .highQualitySuperResolution(let s):
            // s 为 Int，需显式转 CGFloat（Swift 不允许 CGFloat × Int）
            return CGSize(width: sourceSize.width * CGFloat(s),
                          height: sourceSize.height * CGFloat(s))
        }
    }

    /// 依据处理器目标缓冲属性创建输出池。
    private static func makeDestinationPool(config: any VTFrameProcessorConfiguration, outputSize: CGSize) throws -> CVPixelBufferPool {
        var attributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 6,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height)
        ]
        // 合并处理器要求的属性（像素格式、Metal 兼容等），尺寸以计算值为准
        for (key, value) in config.destinationPixelBufferAttributes {
            attributes[key] = value
        }
        attributes[kCVPixelBufferWidthKey as String] = Int(outputSize.width)
        attributes[kCVPixelBufferHeightKey as String] = Int(outputSize.height)

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw AppError.processingFailed(underlying: NSError(domain: "CVPixelBufferPoolCreate", code: Int(status), userInfo: nil))
        }
        return pool
    }
}
