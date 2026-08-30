import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import QuartzCore

/// 【系统 VTFrameProcessor 引擎】
///
/// 基于 VideoToolbox 原生 `VTFrameProcessor` 体系：
/// - 实时模式 → `VTLowLatencyFrameInterpolationConfiguration` /
///   `VTLowLatencySuperResolutionScalerConfiguration`（低延迟）
/// - 离线模式 → `VTSuperResolutionScalerConfiguration` /
///   `VTFrameRateConversionConfiguration`（高质量）
/// - 实时「补帧+超分」= 串联「低延迟插值会话 → 低延迟超分会话」流水线
///
/// 遵循统一协议 `AIFrameProcessingEngine`，上层业务代码不感知具体实现。
/// 仅 iOS 26+ 可用；不支持的设备在 `capability` 中标明并置灰（由 UI 层处理）。
@available(iOS 26.0, *)
final class VTFrameProcessorEngine: AIFrameProcessingEngine {

    // MARK: - 协议属性

    let kind: EngineKind = .systemVT
    private(set) var capability: EngineCapability
    private(set) var modelStatus: EngineModelStatus = .notApplicable
    private(set) var state: EngineState = .idle
    private(set) var lastFrameProcessingTime: TimeInterval = 0
    private(set) var outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    var isRunning: Bool { state.isRunning }

    // MARK: - 内部状态

    /// 会话链（实时补帧+超分为两个，其余一个）
    private var sessions: [VTFrameProcessorSession] = []
    private var mode: ProcessingMode = .realtimeInterpolation
    private var engineConfiguration: EngineConfiguration?
    private let processingLock = NSLock()

    // MARK: - 初始化

    init() {
        // 初始能力占位（未选择模式）
        self.capability = EngineCapability(
            engineKind: .systemVT,
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

        let sourceSize = CGSize(width: configuration.sourceWidth, height: configuration.sourceHeight)
        let effects = VTFrameProcessorConfigFactory.makeEffects(mode: mode, configuration: configuration)

        // 1. 硬件能力检测：任何环节不支持即整体置灰
        for effect in effects where !VTFrameProcessorConfigFactory.isSupported(effect: effect) {
            let reason = "当前设备不支持「\(mode.title)」所需的 VideoToolbox 处理器。"
            self.capability = EngineCapability(
                engineKind: .systemVT, mode: mode,
                isSupported: false, unavailableReason: reason, isReady: false
            )
            self.state = .failed(reason)
            throw AppError.engineUnsupported(reason: reason)
        }

        // 2. 构建并启动会话（后台执行，模型加载可能耗时）
        stop() // 先清理旧会话
        var newSessions: [VTFrameProcessorSession] = []
        for effect in effects {
            let session = VTFrameProcessorSession(effect: effect, sourceSize: sourceSize)
            try await session.startSession()
            newSessions.append(session)
        }
        self.sessions = newSessions

        // 3. 模型状态汇总
        self.modelStatus = sessions.first?.reportModelStatus() ?? .ready
        self.outputPixelFormat = sessions.last?.outputPixelFormat ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        self.capability = EngineCapability(
            engineKind: .systemVT, mode: mode,
            isSupported: true, unavailableReason: nil,
            isReady: modelStatus.isReady
        )
        self.state = .ready
        AppLogger.engine("VT 引擎就绪：\(mode.title)，\(sessions.count) 个会话")
    }

    func start() async throws {
        guard !sessions.isEmpty else {
            throw AppError.engineNotConfigured
        }
        state = .running
    }

    func stop() {
        for session in sessions {
            session.endSession()
        }
        sessions.removeAll()
        state = .stopped
        lastFrameProcessingTime = 0
    }

    // MARK: - 协议：帧处理

    func process(frame: CMSampleBuffer) async throws -> [CMSampleBuffer] {
        guard state == .running, !sessions.isEmpty else {
            throw AppError.engineNotConfigured
        }
        // 会话内部维护时序状态（previousFrame 等），必须串行访问
        processingLock.lock()
        defer { processingLock.unlock() }

        let start = CACurrentMediaTime()
        // 串联流水线：前一会话输出依次作为后一会话输入
        var currentInputs: [CMSampleBuffer] = [frame]
        for session in sessions {
            var nextInputs: [CMSampleBuffer] = []
            for input in currentInputs {
                let outputs = try session.process(input)
                nextInputs.append(contentsOf: outputs)
            }
            currentInputs = nextInputs
        }
        lastFrameProcessingTime = CACurrentMediaTime() - start
        return currentInputs
    }

    func downloadConfigurationModelIfNeeded() async throws {
        for session in sessions {
            try await session.downloadConfigurationModelIfNeeded()
        }
        modelStatus = sessions.first?.reportModelStatus() ?? .ready
    }
}
