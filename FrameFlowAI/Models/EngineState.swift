import Foundation

/// 引擎运行状态机。
enum EngineState: Equatable, Sendable {
    case idle          // 未配置
    case preparing     // 正在加载模型 / 创建会话（可能耗时较长）
    case ready         // 已就绪，等待 start
    case running       // 运行中
    case stopped       // 已停止
    case failed(String) // 失败（携带面向用户的错误描述）

    var isRunning: Bool { self == .running }

    var displayText: String {
        switch self {
        case .idle:       return "未配置"
        case .preparing:  return "引擎加载中…"
        case .ready:      return "已就绪"
        case .running:    return "运行中"
        case .stopped:    return "已停止"
        case .failed(let m): return "引擎错误：\(m)"
        }
    }
}
