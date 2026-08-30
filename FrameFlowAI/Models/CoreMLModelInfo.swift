import Foundation
import CoreML

/// 用户导入的 CoreML 模型信息（校验结果）。
///
/// 校验维度（见 `CoreMLModelValidator`）：
/// - 是否为图像输入 / 输出（MLImageConstraint）或张量（MLMultiArray）
/// - 输入输出张量维度是否满足 App 约定的规格
struct CoreMLModelInfo: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case frameInterpolation   // 补帧模型
        case superResolution      // 超分模型
    }

    let id: UUID
    let kind: Kind
    let name: String
    let url: URL                    // 沙盒内存储路径
    let fileSize: Int64

    // MARK: 输入描述（以最常用输入为准）

    /// 是否图像类型输入（MLImageConstraint）
    let isImageInput: Bool
    /// 输入张量形状（MultiArray 时）：例如 [1, 3, 256, 256]
    let inputShape: [Int]?
    /// 输入特征名
    let inputFeatureNames: [String]

    /// 是否图像类型输出（MLImageConstraint）
    let isImageOutput: Bool
    /// 输出张量形状：例如 [1, 3, 512, 512]
    let outputShape: [Int]?
    /// 输出特征名
    let outputFeatureName: String

    /// 输入像素格式要求（图像输入时），例如 kCVPixelFormatType_32BGRA / 32ARGB
    let inputPixelFormat: OSType?
    /// 输出像素格式要求（图像输出时）
    let outputPixelFormat: OSType?

    /// 期望输入尺寸（由 shape 推断，nil 表示任意 / 需按模型约束）
    var expectedInputSize: CGSize? {
        guard let shape = inputShape, shape.count >= 2 else { return nil }
        let h = shape[shape.count - 2]
        let w = shape[shape.count - 1]
        guard h > 0, w > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    var kindText: String {
        switch kind {
        case .frameInterpolation: return "补帧模型"
        case .superResolution:    return "超分模型"
        }
    }

    var shapeText: String {
        let inputText = inputShape.map { $0.map(String.init).joined(separator: "×") } ?? "图像"
        let outputText = outputShape.map { $0.map(String.init).joined(separator: "×") } ?? "图像"
        return "\(inputText) → \(outputText)"
    }
}
