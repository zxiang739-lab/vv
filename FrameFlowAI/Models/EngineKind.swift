import Foundation

/// 双 AI 处理引擎的类型。
///
/// 架构要求：两种引擎都遵循统一的 `AIFrameProcessingEngine` 协议，
/// 上层业务代码（View / ViewModel / Service）只依赖协议，不感知具体引擎。
enum EngineKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 系统 VTFrameProcessor 引擎：VideoToolbox 原生 API，使用系统内置 AI 权重，
    /// 无需外部模型，仅 iOS 26+ 且硬件支持的设备可用。
    case systemVT = "systemVT"

    /// 用户导入 CoreML 引擎：CoreML + MPS，加载用户通过文件选择器导入的
    /// 补帧 / 超分 mlpackage 模型，全支持 iOS 26 / iOS 27。
    case importedCoreML = "importedCoreML"

    var id: String { rawValue }

    /// 展示名称（Liquid Glass UI 使用）
    var displayName: String {
        switch self {
        case .systemVT:      return "系统 VTFrameProcessor 引擎"
        case .importedCoreML: return "用户导入 CoreML 引擎"
        }
    }

    /// 简短名称（按钮 / 卡片使用）
    var shortName: String {
        switch self {
        case .systemVT:      return "系统引擎"
        case .importedCoreML: return "CoreML"
        }
    }

    /// 简要能力描述
    var summary: String {
        switch self {
        case .systemVT:
            return "VideoToolbox 原生 AI，免模型，实时低延迟；离线高质量。仅 iOS 26+。"
        case .importedCoreML:
            return "加载您导入的补帧 / 超分 mlpackage，CoreML + MPS 推理，iOS 26/27 通用。"
        }
    }

    /// 是否在指定模式下提供该模式所需的两类模型均已就绪（仅 CoreML 引擎需要）
    func requiresImportedModels(for mode: ProcessingMode) -> Bool {
        self == .importedCoreML
    }
}
