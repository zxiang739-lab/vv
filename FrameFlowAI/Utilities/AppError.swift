import Foundation

/// 统一的 App 错误类型。
/// 所有 Cocoa / VideoToolbox / CoreML 错误都在边界处转换为 `AppError`，
/// 向 UI 提供「友好、可读」的错误信息（Cocoa Error 捕获要求）。
enum AppError: LocalizedError {
    case engineUnsupported(reason: String)
    case engineNotConfigured
    case modelMissing
    case modelInvalid(reason: String)
    case modelLoadFailed(underlying: Error)
    case cameraUnavailable(reason: String)
    case permissionDenied(reason: String)
    case pixelBufferMissing
    case formatDescriptionCreationFailed
    case sampleBufferCreationFailed
    case parameterCreationFailed
    case processingFailed(underlying: Error)
    case assetReaderFailed(underlying: Error)
    case assetWriterFailed(underlying: Error)
    case taskCancelled
    case photoLibrarySaveFailed(underlying: Error)
    case unknown(reason: String)

    var errorDescription: String? {
        switch self {
        case .engineUnsupported(let r):
            return "当前设备 / 系统不支持该引擎：\(r)"
        case .engineNotConfigured:
            return "引擎尚未配置，请先选择业务模式并准备模型。"
        case .modelMissing:
            return "未找到所需模型，请先导入补帧 / 超分 mlpackage。"
        case .modelInvalid(let r):
            return "模型校验失败：\(r)"
        case .modelLoadFailed(let e):
            return "模型加载失败：\(e.localizedDescription)"
        case .cameraUnavailable(let r):
            return "摄像头不可用：\(r)"
        case .permissionDenied(let r):
            return "权限被拒绝：\(r)"
        case .pixelBufferMissing:
            return "当前帧缺少像素缓冲（Pixel Buffer）。"
        case .formatDescriptionCreationFailed:
            return "无法创建视频格式描述。"
        case .sampleBufferCreationFailed:
            return "无法创建采样缓冲（SampleBuffer）。"
        case .parameterCreationFailed:
            return "创建帧处理器参数失败。"
        case .processingFailed(let e):
            return "帧处理失败：\(e.localizedDescription)"
        case .assetReaderFailed(let e):
            return "视频读取失败：\(e.localizedDescription)"
        case .assetWriterFailed(let e):
            return "视频写入失败：\(e.localizedDescription)"
        case .taskCancelled:
            return "任务已取消。"
        case .photoLibrarySaveFailed(let e):
            return "保存到相册失败：\(e.localizedDescription)"
        case .unknown(let r):
            return r
        }
    }
}
