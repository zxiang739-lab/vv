import Foundation
import CoreML
import CoreVideo
import CoreImage

/// 单个 CoreML 推理阶段：封装一个已加载的 mlpackage 模型。
///
/// 支持两种模型：
/// - 超分（superResolution）：单帧输入 → 放大帧输出；
/// - 补帧（frameInterpolation）：相邻两帧（frameA / frameB）+ 可选标量 timestep → 插值帧输出。
///
/// 输入 / 输出同时支持「图像（MLImageConstraint）」与「张量（MLMultiArray）」两种形态，
/// 张量布局支持 NCHW / NHWC，见 `CoreMLPixelBufferUtility.TensorLayout`。
final class CoreMLInferenceStage {

    enum Kind {
        case superResolution
        case frameInterpolation
    }

    // MARK: - 属性

    private let model: MLModel
    private let kind: Kind

    /// 帧输入特征名（补帧为两帧：frameA、frameB）
    private let inputNames: [String]

    /// 标量 timestep 输入名（若模型提供）
    private let timestepInputName: String?

    /// 输出特征名
    private let outputName: String

    /// 模型是否支持 timestep 标量输入（决定补帧倍率可调性）
    var supportsTimestep: Bool { timestepInputName != nil }

    // MARK: 输入形态描述

    private let isImageInput: Bool
    private let inputPixelFormat: OSType?
    private let inputWidth: Int?
    private let inputHeight: Int?
    private let inputLayout: CoreMLPixelBufferUtility.TensorLayout

    // MARK: 输出形态描述

    private let outputIsImage: Bool
    private let outputWidth: Int?
    private let outputHeight: Int?

    private static let ciContext = CIContext()

    // MARK: - 初始化

    init(model: MLModel, info: CoreMLModelInfo, kind: Kind) throws {
        self.model = model
        self.kind = kind

        // 帧输入名（图像 / 张量输入，按名字排序保证确定性；补帧取前两个）
        let frameInputs = info.inputFeatureNames.sorted()
        self.inputNames = Array(frameInputs.prefix(kind == .frameInterpolation ? 2 : 1))

        // 标量输入（double）且名字包含 timestep 语义 → 识别为插值相位输入
        let description = model.modelDescription
        var timestepName: String?
        for (name, feature) in description.inputDescriptionsByName {
            if feature.type == .double || feature.type == .int64 {
                let lower = name.lowercased()
                if lower.contains("timestep") || lower.contains("phase") || lower == "t" || lower == "interp" {
                    timestepName = name
                    break
                }
            }
        }
        self.timestepInputName = timestepName

        guard let output = description.outputDescriptionsByName.keys.first else {
            throw AppError.modelInvalid(reason: "模型没有输出特征。")
        }
        self.outputName = output

        // 输入形态
        self.isImageInput = info.isImageInput
        self.inputPixelFormat = info.inputPixelFormat
        if let size = info.expectedInputSize {
            self.inputWidth = Int(size.width)
            self.inputHeight = Int(size.height)
        } else if isImageInput, let name = inputNames.first,
                  let constraint = description.inputDescriptionsByName[name]?.imageConstraint {
            self.inputWidth = constraint.width > 0 ? constraint.width : nil
            self.inputHeight = constraint.height > 0 ? constraint.height : nil
        } else {
            self.inputWidth = nil
            self.inputHeight = nil
        }

        // 输出形态
        self.outputIsImage = info.isImageOutput
        let outSize = CoreMLModelValidator.expectedOutputSize(info)
        self.outputWidth = outSize.map { Int($0.width) }
        self.outputHeight = outSize.map { Int($0.height) }

        // 张量布局（从输入 shape 推断）
        if let shape = info.inputShape {
            self.inputLayout = CoreMLPixelBufferUtility.TensorLayout.parse(
                shape: shape,
                width: inputWidth ?? 0,
                height: inputHeight ?? 0
            )
        } else {
            self.inputLayout = .nchw
        }
    }

    // MARK: - 推理

    /// 执行一次推理。
    /// - Parameters:
    ///   - frame: 当前帧（BGRA 优先）
    ///   - previous: 上一帧（补帧模型需要）
    ///   - timestep: 插值相位 t ∈ [0,1]（模型有 timestep 输入时使用）
    func predict(frame: CVPixelBuffer, previous: CVPixelBuffer?, timestep: Float?) throws -> CVPixelBuffer {
        var features: [String: MLFeatureValue] = [:]

        // 组装帧输入
        switch kind {
        case .superResolution:
            features[inputNames[0]] = try makeInputFeature(pixelBuffer: frame)
        case .frameInterpolation:
            guard let previous else {
                throw AppError.parameterCreationFailed
            }
            guard inputNames.count >= 2 else {
                throw AppError.modelInvalid(reason: "补帧模型需要两个帧输入（frameA / frameB）。")
            }
            features[inputNames[0]] = try makeInputFeature(pixelBuffer: previous)
            features[inputNames[1]] = try makeInputFeature(pixelBuffer: frame)
        }

        // 可选标量输入
        if let timestepInputName, let timestep {
            features[timestepInputName] = MLFeatureValue(double: Double(timestep))
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: features) else {
            throw AppError.parameterCreationFailed
        }

        let result = try model.prediction(from: provider)
        return try extractOutput(from: result)
    }

    // MARK: - 输入 / 输出转换

    /// 把 BGRA（或任意）像素缓冲转成模型要求的输入特征。
    private func makeInputFeature(pixelBuffer: CVPixelBuffer) throws -> MLFeatureValue {
        if isImageInput {
            var buffer = pixelBuffer
            // 图像输入：若像素格式与约束不一致，渲染转换
            if let required = inputPixelFormat,
               CVPixelBufferGetPixelFormatType(buffer) != required {
                buffer = try Self.render(pixelBuffer, toFormat: required,
                                         size: CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                                      height: CVPixelBufferGetHeight(pixelBuffer)))
            }
            guard let value = MLFeatureValue(pixelBuffer: buffer) else {
                throw AppError.parameterCreationFailed
            }
            return value
        } else {
            // 张量输入：统一转 BGRA → 缩放 → RGB float 张量
            let width = inputWidth ?? CVPixelBufferGetWidth(pixelBuffer)
            let height = inputHeight ?? CVPixelBufferGetHeight(pixelBuffer)
            let bgra = try CoreMLPixelBufferUtility.toBGRA(pixelBuffer)
            let array = try CoreMLPixelBufferUtility.makeRGBInputMultiArray(
                from: bgra, width: width, height: height, preferredLayout: inputLayout
            )
            guard let value = MLFeatureValue(multiArray: array) else {
                throw AppError.parameterCreationFailed
            }
            return value
        }
    }

    /// 从预测结果提取输出像素缓冲（统一为 BGRA）。
    private func extractOutput(from result: MLFeatureProvider) throws -> CVPixelBuffer {
        if outputIsImage {
            guard let buffer = result.featureValue(for: outputName)?.imageBufferValue else {
                throw AppError.pixelBufferMissing
            }
            return try CoreMLPixelBufferUtility.toBGRA(buffer)
        } else {
            guard let array = result.featureValue(for: outputName)?.multiArrayValue else {
                throw AppError.pixelBufferMissing
            }
            let width = outputWidth ?? 0
            let height = outputHeight ?? 0
            guard width > 0, height > 0 else {
                throw AppError.modelInvalid(reason: "无法从输出张量推断分辨率（请提供固定尺寸模型）。")
            }
            return try CoreMLPixelBufferUtility.makeBGRAPixelBuffer(from: array, width: width, height: height)
        }
    }

    /// 渲染像素缓冲为指定像素格式（CIContext 兜底转换）。
    private static func render(_ source: CVPixelBuffer, toFormat format: OSType, size: CGSize) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            format, attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw AppError.processingFailed(underlying: NSError(domain: "CVPixelBufferCreate", code: Int(status), userInfo: nil))
        }
        ciContext.render(CIImage(cvPixelBuffer: source), to: buffer)
        return buffer
    }
}
