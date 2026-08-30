import Foundation
import os

/// 极简日志封装（基于 os.Logger）。
/// 生产环境可通过统一的 Logger 观测引擎生命周期、帧处理耗时与错误。
enum AppLogger {
    private static let subsystem = "com.example.FrameFlowAI"

    private static let engines = Logger(subsystem: subsystem, category: "AIEngines")
    private static let services = Logger(subsystem: subsystem, category: "Services")
    private static let ui = Logger(subsystem: subsystem, category: "UI")

    static func engine(_ message: String) { engines.info("\(message, privacy: .public)") }
    static func engineError(_ message: String) { engines.error("\(message, privacy: .public)") }

    static func service(_ message: String) { services.info("\(message, privacy: .public)") }
    static func serviceError(_ message: String) { services.error("\(message, privacy: .public)") }

    static func ui(_ message: String) { ui.info("\(message, privacy: .public)") }
}
