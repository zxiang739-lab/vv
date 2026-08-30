import Foundation

/// 引擎运行配置：把「业务模式 + 参数」解耦成一份纯数据，供双引擎 `prepare` 消费。
struct EngineConfiguration: Equatable, Sendable {
    let mode: ProcessingMode

    /// 源帧宽（像素）
    let sourceWidth: Int

    /// 源帧高（像素）
    let sourceHeight: Int

    // MARK: 补帧参数

    /// 相邻两帧之间插入的插值帧数量 N。
    /// 输出帧率 = 源帧率 × (N + 1)。
    /// - 实时低延迟：VTLowLatencyFrameInterpolationConfiguration(frameWidth:height:numberOfInterpolatedFrames:)
    /// - 离线帧率转换：conversionFrameRate = sourceFrameRate × (N + 1)
    var numberOfInterpolatedFrames: Int = 1

    // MARK: 超分参数

    /// 超分倍率（离线高质量使用整数倍率，如 2 / 3 / 4；实时低延迟为 Float）
    var superResolutionScaleFactor: Double = 2.0

    // MARK: 离线帧率参数

    /// 源视频帧率（离线补帧时使用，用于计算目标帧率）
    var sourceFrameRate: Double?

    /// 目标输出帧率（离线补帧：conversionFrameRate；离线超分保持源帧率）
    var targetFrameRate: Double?

    /// 源帧率（用于离线补帧时如果没有显式提供则回退到读取到的 fps）
    var fallbackFrameRate: Double = 30.0

    // MARK: 便捷计算

    /// 输出帧率（补帧 = 源帧率 × (N+1)；非补帧 = 源帧率）
    var resolvedOutputFrameRate: Double {
        if mode.usesFrameInterpolation {
            let base = targetFrameRate ?? (fallbackFrameRate * Double(numberOfInterpolatedFrames + 1))
            return base
        }
        return fallbackFrameRate
    }

    /// 输出宽（超分 = 源宽 × 倍率；否则不变）
    var outputWidth: Int {
        mode.usesSuperResolution
            ? Int((Double(sourceWidth) * superResolutionScaleFactor).rounded())
            : sourceWidth
    }

    /// 输出高
    var outputHeight: Int {
        mode.usesSuperResolution
            ? Int((Double(sourceHeight) * superResolutionScaleFactor).rounded())
            : sourceHeight
    }
}
