import Foundation

/// 某个引擎在某个业务模式下的可用性描述。
///
/// 上层（ViewModel / View）据此决定：
/// - 该模式按钮是否置灰（isSupported == false）
/// - 点击时提示的原因（unavailableReason）
struct EngineCapability: Equatable, Sendable {
    let engineKind: EngineKind
    let mode: ProcessingMode

    /// 引擎硬件 / 系统是否支持该模式（例如 VT 引擎在 iOS 26 以下或部分硬件上不支持）
    var isSupported: Bool

    /// 不可用原因（用于弹窗 / 置灰提示文案），nil 表示可用
    var unavailableReason: String?

    /// 该模式下引擎是否就绪（模型已就绪 / 无需模型）
    var isReady: Bool

    /// 供 UI 使用的「是否可以启动」组合判断
    var canStart: Bool { isSupported && isReady }
}
