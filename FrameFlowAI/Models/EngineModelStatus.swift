import Foundation

/// 引擎所需「模型 / 权重」的状态。
///
/// - VT 引擎：高质量离线配置（VTSuperResolutionScalerConfiguration 等）可能需要在
///   系统层面按需下载 AI 权重（configurationModelStatus / downloadConfigurationModel）；
///   低延迟实时配置的系统模型通常随系统预置。
/// - CoreML 引擎：需要用户导入补帧 / 超分 mlpackage。
enum EngineModelStatus: Equatable, Sendable {
    /// 该引擎 / 模式不需要模型（例如低延迟实时配置，系统权重已预置）
    case notApplicable

    /// 尚未配置（CoreML：模型未导入）
    case notConfigured

    /// 系统模型正在下载，progress ∈ [0, 1]
    case downloading(progress: Float)

    /// 系统模型下载失败
    case downloadFailed

    /// 已就绪（系统权重就绪 / 模型已导入并通过校验）
    case ready

    /// UI 展示文案
    var displayText: String {
        switch self {
        case .notApplicable:      return "无需模型"
        case .notConfigured:      return "未导入模型"
        case .downloading(let p): return String(format: "模型下载中 %.0f%%", p * 100)
        case .downloadFailed:     return "模型下载失败"
        case .ready:              return "模型就绪"
        }
    }

    var isReady: Bool {
        switch self {
        case .ready, .notApplicable: return true
        default: return false
        }
    }
}
