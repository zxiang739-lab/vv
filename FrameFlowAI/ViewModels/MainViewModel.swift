import Foundation
import Combine

/// 主界面 ViewModel：
/// - 引擎切换（系统 VTFrameProcessor / 用户导入 CoreML）；
/// - 5 种业务模式选择；
/// - 能力检测（VT 硬件是否支持 / CoreML 模型是否导入）；
/// - 离线任务队列管理（创建 / 取消 / 状态）。
@MainActor
final class MainViewModel: ObservableObject {

    // MARK: - 已发布状态

    /// 当前选择的引擎
    @Published var selectedEngine: EngineKind = .systemVT

    /// 当前选择的业务模式
    @Published var selectedMode: ProcessingMode = .realtimeInterpolation

    /// 离线任务队列
    @Published var offlineJobs: [OfflineJob] = []

    // MARK: - 能力检测

    /// 查询「引擎 × 模式」的能力：
    /// - 系统 VT：检测对应配置类的 isSupported（不支持则按钮置灰）；
    /// - 导入 CoreML：iOS 26/27 全可用，isReady 取决于所需模型是否已导入。
    func capability(for engine: EngineKind, mode: ProcessingMode) -> EngineCapability {
        switch engine {
        case .systemVT:
            let effects = VTFrameProcessorConfigFactory.makeEffects(
                mode: mode,
                configuration: EngineFactory.sampleConfiguration(for: mode)
            )
            let supported = effects.allSatisfy {
                VTFrameProcessorConfigFactory.isSupported(effect: $0)
            }
            return EngineCapability(
                engineKind: engine, mode: mode,
                isSupported: supported,
                unavailableReason: supported
                    ? nil
                    : "当前设备 / 系统不支持该模式（系统 VTFrameProcessor 需要 iOS 26+ 与对应芯片能力）。",
                isReady: true
            )
        case .importedCoreML:
            let needsInterp = mode.usesFrameInterpolation
            let needsSR = mode.usesSuperResolution
            let interpOK = !needsInterp || CoreMLModelStore.shared.latestModel(kind: .frameInterpolation) != nil
            let srOK = !needsSR || CoreMLModelStore.shared.latestModel(kind: .superResolution) != nil
            let ready = interpOK && srOK
            return EngineCapability(
                engineKind: engine, mode: mode,
                isSupported: true,
                unavailableReason: nil,
                isReady: ready
            )
        }
    }

    /// 当前选择对应的能力（供 UI 置灰判断）。
    var currentCapability: EngineCapability {
        capability(for: selectedEngine, mode: selectedMode)
    }

    /// 引擎模型状态（VT：系统权重由系统管理，启动会话时自动下载；CoreML：显示导入情况）。
    func modelStatusText(for engine: EngineKind, mode: ProcessingMode) -> String {
        switch engine {
        case .systemVT:
            if mode.usesSuperResolution, !mode.isRealtime {
                // 离线高质量超分：启动时检查 configurationModelStatus 并驱动下载
                return "系统模型（离线高质量超分启动时按需下载）"
            }
            return "系统内置权重，无需下载"
        case .importedCoreML:
            var parts: [String] = []
            if mode.usesFrameInterpolation {
                parts.append(CoreMLModelStore.shared.latestModel(kind: .frameInterpolation) != nil ? "补帧✓" : "补帧✗")
            }
            if mode.usesSuperResolution {
                parts.append(CoreMLModelStore.shared.latestModel(kind: .superResolution) != nil ? "超分✓" : "超分✗")
            }
            return parts.isEmpty ? "无需模型" : parts.joined(separator: " ")
        }
    }

    // MARK: - 离线任务

    /// 追加离线任务到队列（任务执行由 OfflineViewModel 驱动）。
    func enqueue(job: OfflineJob) {
        offlineJobs.append(job)
    }

    /// 移除已完成 / 失败 / 已取消任务。
    func removeJob(_ job: OfflineJob) {
        offlineJobs.removeAll { $0.id == job.id }
    }
}
