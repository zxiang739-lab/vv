import Foundation
import CoreMedia
import CoreVideo

/// 双 AI 引擎统一抽象协议。
///
/// 架构要求（分层解耦）：
/// - UI / ViewModel / Service 只依赖本协议，不感知具体引擎；
/// - `VTFrameProcessorEngine`（系统引擎）与 `CoreMLFrameProcessingEngine`（用户导入引擎）
///   都实现本协议，上层业务代码无需关心底层是哪套引擎；
/// - UI 不直接调用推理，一律经由 ViewModel → Service → Engine。
protocol AIFrameProcessingEngine: AnyObject {

    /// 引擎类型（系统 VT / 用户 CoreML）
    var kind: EngineKind { get }

    /// 当前模式下的能力（是否支持、是否就绪、不可用原因）
    var capability: EngineCapability { get }

    /// 模型 / 系统权重状态
    var modelStatus: EngineModelStatus { get }

    /// 运行状态机
    var state: EngineState { get }

    /// 是否运行中
    var isRunning: Bool { get }

    /// 最近一帧端到端推理耗时（秒）。用于 UI「硬件占用」展示与延迟评估。
    var lastFrameProcessingTime: TimeInterval { get }

    /// 引擎输出像素格式（供 AVSampleBufferDisplayLayer 预览、AVAssetWriter 适配器对齐）
    var outputPixelFormat: OSType { get }

    // MARK: - 生命周期

    /// 配置并预热引擎（加载模型 / 创建 VTFrameProcessor 会话），可能耗时较长，应后台调用。
    func prepare(mode: ProcessingMode, configuration: EngineConfiguration) async throws

    /// 启动引擎（开始接收帧）。
    func start() async throws

    /// 停止并释放资源（会话 / 模型）。
    func stop()

    // MARK: - 帧处理

    /// 处理一帧。实时与离线链路共用同一入口。
    /// - 返回 0..N 帧：补帧模式可能返回多帧（插值帧 + 当前帧），非补帧返回单帧。
    /// - 输入 CMSampleBuffer 在返回 / 回调完成前不得修改（VTFrameProcessor 约束）。
    func process(frame: CMSampleBuffer) async throws -> [CMSampleBuffer]

    /// 触发系统模型下载（仅 VT 高质量离线配置需要；CoreML 引擎为空实现）。
    func downloadConfigurationModelIfNeeded() async throws

    /// 所有输入帧处理完后调用：刷新引擎内部缓冲的尾帧（离线补帧等「前向缓冲」模式需要）。
    /// 无尾帧语义的引擎返回空数组即可。
    func flushEndOfStream() async throws -> [CMSampleBuffer]
}

// MARK: - 默认实现

extension AIFrameProcessingEngine {
    /// 默认无尾帧缓冲：返回空数组（CoreML 引擎无需改动）。
    func flushEndOfStream() async throws -> [CMSampleBuffer] {
        []
    }
}
