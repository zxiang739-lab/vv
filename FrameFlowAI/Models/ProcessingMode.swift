import Foundation

/// 全部 5 种业务模式。
///
/// 注意：按要求「不做离线补帧+超分」组合模式，仅实现列出的 5 种。
enum ProcessingMode: String, CaseIterable, Identifiable, Codable, Sendable {

    // MARK: - 实时模式（摄像头 AVCaptureSession 实时流，CMSampleBuffer 流转）

    /// 1. 实时补帧：仅 AI 帧插值补帧，不放大分辨率；摄像头输入实时预览
    case realtimeInterpolation = "realtimeInterpolation"

    /// 2. 实时超分：仅 AI 超分辨率，不做帧插值补帧；摄像头输入实时预览
    case realtimeSuperResolution = "realtimeSuperResolution"

    /// 3. 实时补帧 + 超分：串联补帧 + 超分流水线，实时预览输出
    case realtimeInterpolationAndSuperResolution = "realtimeInterpolationAndSuperResolution"

    // MARK: - 离线模式（本地导入视频文件，AVAssetReader / AVAssetWriter 输出视频文件）

    /// 4. 离线补帧：AI 帧插值补帧输出新视频，分辨率不变
    case offlineInterpolation = "offlineInterpolation"

    /// 5. 离线超分：AI 超分放大输出新视频，不做补帧
    case offlineSuperResolution = "offlineSuperResolution"

    var id: String { rawValue }

    /// 是否为实时模式
    var isRealtime: Bool {
        switch self {
        case .realtimeInterpolation, .realtimeSuperResolution,
             .realtimeInterpolationAndSuperResolution:
            return true
        case .offlineInterpolation, .offlineSuperResolution:
            return false
        }
    }

    /// 是否离线模式
    var isOffline: Bool { !isRealtime }

    /// 该模式是否涉及补帧
    var usesFrameInterpolation: Bool {
        switch self {
        case .realtimeInterpolation, .realtimeInterpolationAndSuperResolution,
             .offlineInterpolation:
            return true
        case .realtimeSuperResolution, .offlineSuperResolution:
            return false
        }
    }

    /// 该模式是否涉及超分
    var usesSuperResolution: Bool {
        switch self {
        case .realtimeSuperResolution, .realtimeInterpolationAndSuperResolution,
             .offlineSuperResolution:
            return true
        case .realtimeInterpolation, .offlineInterpolation:
            return false
        }
    }

    /// 展示标题
    var title: String {
        switch self {
        case .realtimeInterpolation:                    return "实时补帧"
        case .realtimeSuperResolution:                  return "实时超分"
        case .realtimeInterpolationAndSuperResolution:  return "实时补帧 + 超分"
        case .offlineInterpolation:                     return "离线补帧"
        case .offlineSuperResolution:                   return "离线超分"
        }
    }

    /// 副标题
    var subtitle: String {
        switch self {
        case .realtimeInterpolation:
            return "摄像头实时预览，AI 帧插值，分辨率不变"
        case .realtimeSuperResolution:
            return "摄像头实时预览，AI 超分放大，不插帧"
        case .realtimeInterpolationAndSuperResolution:
            return "串联 补帧 → 超分 流水线，实时预览输出"
        case .offlineInterpolation:
            return "导入视频，补帧输出新视频，分辨率不变"
        case .offlineSuperResolution:
            return "导入视频，超分放大输出新视频，不补帧"
        }
    }
}
