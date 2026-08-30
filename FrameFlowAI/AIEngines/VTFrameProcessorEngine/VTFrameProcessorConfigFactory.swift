import Foundation
import VideoToolbox

/// VTFrameProcessor 配置工厂。
///
/// 职责：根据业务模式把 `EngineConfiguration` 转成对应的
/// `VTFrameProcessorConfiguration` 具体类，并做硬件能力（isSupported）检测。
///
/// 映射关系（严格遵循用户要求）：
/// - 实时模式 → VTLowLatencyXXXConfiguration 低延迟配置
///   · 实时补帧     → VTLowLatencyFrameInterpolationConfiguration
///   · 实时超分     → VTLowLatencySuperResolutionScalerConfiguration
///   · 实时补帧+超分 → 串联两个低延迟会话（插值 → 超分）
/// - 离线模式 → VT 高质量配置
///   · 离线补帧     → VTFrameRateConversionConfiguration
///   · 离线超分     → VTSuperResolutionScalerConfiguration
enum VTFrameProcessorConfigFactory {

    /// 会话效果类型（一个效果对应一个 VTFrameProcessor 会话）
    enum Effect {
        case lowLatencyInterpolation(numberOfInterpolatedFrames: Int)
        case lowLatencySuperResolution(scaleFactor: Float)
        case highQualitySuperResolution(scaleFactor: Int)
        case highQualityFrameRateConversion(sourceFrameRate: Double, conversionFrameRate: Double)

        /// 该效果是否需要「上一帧」作为时序上下文
        var needsPreviousFrame: Bool {
            switch self {
            case .lowLatencyInterpolation, .highQualitySuperResolution,
                 .highQualityFrameRateConversion:
                return true
            case .lowLatencySuperResolution:
                return false
            }
        }
    }

    /// 由业务模式 + 引擎配置构造效果链（实时补帧+超分返回两个效果）
    static func makeEffects(mode: ProcessingMode, configuration: EngineConfiguration) -> [Effect] {
        switch mode {
        case .realtimeInterpolation:
            return [.lowLatencyInterpolation(numberOfInterpolatedFrames: configuration.numberOfInterpolatedFrames)]

        case .realtimeSuperResolution:
            return [.lowLatencySuperResolution(scaleFactor: Float(configuration.superResolutionScaleFactor))]

        case .realtimeInterpolationAndSuperResolution:
            // 串联流水线：先补帧（原生分辨率），再超分（对插值后的帧放大）
            return [
                .lowLatencyInterpolation(numberOfInterpolatedFrames: configuration.numberOfInterpolatedFrames),
                .lowLatencySuperResolution(scaleFactor: Float(configuration.superResolutionScaleFactor))
            ]

        case .offlineInterpolation:
            let source = configuration.sourceFrameRate ?? configuration.fallbackFrameRate
            let conversion = configuration.targetFrameRate
                ?? source * Double(configuration.numberOfInterpolatedFrames + 1)
            return [.highQualityFrameRateConversion(sourceFrameRate: source, conversionFrameRate: conversion)]

        case .offlineSuperResolution:
            return [.highQualitySuperResolution(scaleFactor: Int(configuration.superResolutionScaleFactor.rounded()))]
        }
    }

    /// 创建具体配置对象（并校验可用性）。
    ///
    /// 注意：`VTFrameRateConversionConfiguration` 的公开文档页在编写本工程时无法访问，
    /// 属性名 `sourceFrameRate` / `conversionFrameRate` 依据 WWDC25 Session 300
    /// 「Enhance your app with machine learning-based video effects」示例代码编写；
    /// 若安装的 SDK 中属性名有出入，只需修改下方 frameRateConversion 分支一处即可。
    static func makeConfiguration(for effect: Effect, sourceSize: CGSize) throws -> any VTFrameProcessorConfiguration {
        let w = Int(sourceSize.width)
        let h = Int(sourceSize.height)

        switch effect {
        case .lowLatencyInterpolation(let n):
            guard let config = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: w,
                frameHeight: h,
                numberOfInterpolatedFrames: n
            ) else {
                throw AppError.engineUnsupported(reason: "无法创建低延迟帧插值配置（分辨率或插值帧数不受支持）。")
            }
            return config

        case .lowLatencySuperResolution(let f):
            let config = VTLowLatencySuperResolutionScalerConfiguration(
                frameWidth: w,
                frameHeight: h,
                scaleFactor: f
            )
            return config

        case .highQualitySuperResolution(let s):
            guard let config = VTSuperResolutionScalerConfiguration(
                frameWidth: w,
                frameHeight: h,
                scaleFactor: s,
                inputType: .video,        // 视频流时序超分（利用前后帧信息，画质更好）
                usePrecomputedFlow: false, // 不提供预计算光流，由系统内部计算
                qualityPrioritization: .normal,
                revision: .revision1      // Revision.revision1（首个公开修订版本）
            ) else {
                throw AppError.engineUnsupported(reason: "无法创建高质量超分配置（倍率或分辨率不受支持）。")
            }
            return config

        case .highQualityFrameRateConversion(let src, let conv):
            let config = VTFrameRateConversionConfiguration()
            config.sourceFrameRate = src
            config.conversionFrameRate = conv
            return config
        }
    }

    /// 硬件能力检测：当前设备 / 系统是否支持该效果（VTFrameProcessor 的 isSupported）。
    static func isSupported(effect: Effect) -> Bool {
        switch effect {
        case .lowLatencyInterpolation:
            return VTLowLatencyFrameInterpolationConfiguration.isSupported
        case .lowLatencySuperResolution:
            return VTLowLatencySuperResolutionScalerConfiguration.isSupported
        case .highQualitySuperResolution:
            return VTSuperResolutionScalerConfiguration.isSupported
        case .highQualityFrameRateConversion:
            // VTFrameRateConversionConfiguration 未公开单独的 isSupported 时按可用处理；
            // 运行时仍可能因配置不合法而 throw，会在 start 阶段以 AppError 上报。
            return true
        }
    }

    /// 低延迟实时配置的系统 AI 权重随系统预置，无需外部下载。
    /// 离线高质量配置（超分）可能需要在系统层面按需下载权重。
    static func requiresConfigurationModelDownload(effect: Effect) -> Bool {
        switch effect {
        case .highQualitySuperResolution, .highQualityFrameRateConversion:
            return true
        default:
            return false
        }
    }
}
