import Foundation
import CoreML
import CoreVideo

/// CoreML mlpackage 模型校验器。
///
/// 校验维度（满足需求「校验 mlpackage 输入输出张量维度」）：
/// 1. 可被 CoreML 加载；
/// 2. 输入 / 输出特征类型符合预期（图像 MLImageConstraint 或张量 MLMultiArray）；
/// 3. 张量维度满足 App 约定的规格（见 README「用户 mlpackage 模型张量规格要求」）；
/// 4. 输出尺寸大于输入尺寸（超分模型）。
///
/// 约定的模型规格（README 有完整版）：
/// - 超分模型：1 个图像/张量输入（[1,3,H,W] 或图像）→ 1 个图像/张量输出，输出分辨率大于输入。
/// - 补帧模型：2 个图像/张量输入（相邻两帧 frameA / frameB，或 input0 / input1）
///   → 1 个图像/张量输出（中间插值帧），可选 1 个标量 timestep 输入。
enum CoreMLModelValidator {

    /// 完整校验（导入时使用）：加载模型并读取输入输出描述。
    static func validate(url: URL, kind: CoreMLModelInfo.Kind) throws -> CoreMLModelInfo {
        let model: MLModel
        do {
            model = try MLModel(contentsOf: url)
        } catch {
            throw AppError.modelLoadFailed(underlying: error)
        }
        return try validate(loadedModel: model, url: url, kind: kind)
    }

    /// 轻量检查（列清单时使用）：仅读取描述，不参与运行时约束。
    /// - Parameter kind: 模型类型（从导入时的文件命名前缀推断）。
    static func inspect(url: URL, kind: CoreMLModelInfo.Kind) throws -> CoreMLModelInfo {
        let model = try MLModel(contentsOf: url)
        let info = try buildInfo(loadedModel: model, url: url, kind: kind)
        return info
    }

    /// 核心校验逻辑
    private static func validate(loadedModel model: MLModel, url: URL, kind: CoreMLModelInfo.Kind) throws -> CoreMLModelInfo {
        let info = try buildInfo(loadedModel: model, url: url, kind: kind)

        switch kind {
        case .superResolution:
            // 输出必须比输入大（放大）
            guard let inputSize = info.expectedInputSize, let outputSize = expectedOutputSize(info) else {
                // 输入输出至少有一个维度未知时，仍允许通过（模型可能支持动态尺寸），
                // 但给出宽松校验；README 建议提供固定尺寸模型以获得确定性。
                return info
            }
            guard outputSize.width > inputSize.width || outputSize.height > inputSize.height else {
                throw AppError.modelInvalid(reason: "超分模型输出尺寸必须大于输入尺寸（当前 \(info.shapeText)）。")
            }

        case .frameInterpolation:
            // 补帧模型：输入应为两帧，且两帧尺寸一致，输出尺寸与输入一致
            guard info.inputFeatureNames.count >= 2 else {
                throw AppError.modelInvalid(reason: "补帧模型需要至少 2 个图像/张量输入（frameA / frameB）。")
            }
            // 若都是固定尺寸张量，检查输出尺寸
            if let outputSize = expectedOutputSize(info),
               let inputSize = info.expectedInputSize {
                guard abs(outputSize.width - inputSize.width) <= 1,
                      abs(outputSize.height - inputSize.height) <= 1 else {
                    throw AppError.modelInvalid(reason: "补帧模型输出分辨率应保持与输入一致（当前 \(info.shapeText)）。")
                }
            }
        }
        return info
    }

    // MARK: - 描述解析

    /// 从加载好的模型构建结构化信息
    private static func buildInfo(loadedModel model: MLModel, url: URL, kind: CoreMLModelInfo.Kind) throws -> CoreMLModelInfo {
        let description = model.modelDescription

        // 输入：优先图像输入，其次张量输入
        var inputNames: [String] = []
        var imageInputName: String?
        var multiArrayInputName: String?
        var firstInputShape: [Int]?

        for (name, feature) in description.inputDescriptionsByName {
            switch feature.type {
            case .image:
                if imageInputName == nil { imageInputName = name }
                inputNames.append(name)
            case .multiArray:
                if multiArrayInputName == nil { multiArrayInputName = name }
                if firstInputShape == nil, let shape = feature.multiArrayConstraint?.shape {
                    firstInputShape = shape.map { $0.intValue }
                }
                inputNames.append(name)
            default:
                // 标量（如 timestep）不纳入帧输入集合
                break
            }
        }

        // 输出
        let outputName = description.outputDescriptionsByName.keys.first
        var outputShape: [Int]?
        var outputImage = false
        var outputPixelFormat: OSType?
        if let outputName,
           let outputFeature = description.outputDescriptionsByName[outputName] {
            switch outputFeature.type {
            case .image:
                outputImage = true
                // MLImageConstraint.pixelFormatTypes 为 Set<NSNumber>，取首个受支持格式
                outputPixelFormat = outputFeature.imageConstraint?.pixelFormatTypes.first?.uint32Value
            case .multiArray:
                outputShape = outputFeature.multiArrayConstraint?.shape.map { $0.intValue }
            default:
                break
            }
        }

        // 输入像素格式（图像输入）
        var inputPixelFormat: OSType?
        if let imageInputName, let constraint = description.inputDescriptionsByName[imageInputName]?.imageConstraint {
            // MLImageConstraint.pixelFormatTypes 为 Set<NSNumber>，取首个受支持格式
            inputPixelFormat = constraint.pixelFormatTypes.first?.uint32Value
        }

        // 文件大小
        let fileSize: Int64 = (try? FileManager.default.allocatedSizeOfDirectory(at: url)) ?? 0

        let info = CoreMLModelInfo(
            id: UUID(),
            kind: kind,
            name: url.deletingPathExtension().lastPathComponent,
            url: url,
            fileSize: fileSize,
            isImageInput: imageInputName != nil,
            inputShape: firstInputShape,
            inputFeatureNames: inputNames,
            isImageOutput: outputImage,
            outputShape: outputShape,
            outputFeatureName: outputName ?? "",
            inputPixelFormat: inputPixelFormat,
            outputPixelFormat: outputPixelFormat
        )
        return info
    }

    static func expectedOutputSize(_ info: CoreMLModelInfo) -> CGSize? {
        guard let shape = info.outputShape, shape.count >= 2 else { return nil }
        let h = shape[shape.count - 2]
        let w = shape[shape.count - 1]
        guard h > 0, w > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
}

private extension FileManager {
    /// 计算目录内全部文件的累计大小（用于展示模型体积）
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        guard let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
