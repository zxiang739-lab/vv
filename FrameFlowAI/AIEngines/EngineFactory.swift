import Foundation

/// 引擎工厂：按 `EngineKind` 创建对应引擎实例。
/// 上层（ViewModel / Service）通过本工厂 + 统一协议创建引擎，避免散落的 switch。
enum EngineFactory {
    static func make(kind: EngineKind) -> AIFrameProcessingEngine {
        switch kind {
        case .systemVT:
            return VTFrameProcessorEngine()
        case .importedCoreML:
            return CoreMLFrameProcessingEngine()
        }
    }

    /// 供能力检测使用的「样例配置」（仅用于 isSupported 等与尺寸无关的能力判断）。
    static func sampleConfiguration(for mode: ProcessingMode) -> EngineConfiguration {
        EngineConfiguration(
            mode: mode,
            sourceWidth: 1280,
            sourceHeight: 720,
            numberOfInterpolatedFrames: 1,
            superResolutionScaleFactor: 2.0,
            sourceFrameRate: 30,
            targetFrameRate: mode.usesFrameInterpolation ? 60 : nil,
            fallbackFrameRate: 30
        )
    }
}
