import Foundation
import CoreVideo
import CoreImage
import CoreML
import Accelerate

/// CoreML 引擎的像素缓冲格式转换工具。
///
/// 需求：「CoreML 引擎做像素缓冲区格式转换；尽量减少内存拷贝」
/// - 相机 / 读取器统一输出 BGRA → 与图像型模型输入直接复用（零拷贝直通）；
/// - 非 BGRA 输入用 CIContext 渲染转换（兜底）；
/// - 张量（MLMultiArray，NCHW/NHWC）输入输出用手工 + vImage 完成通道重排与缩放。
enum CoreMLPixelBufferUtility {

    /// 共享 CIContext（格式转换兜底用；复用避免重复创建开销）
    private static let ciContext = CIContext()

    // MARK: - 统一转 BGRA

    /// 任意像素缓冲 → BGRA。
    /// 已是 BGRA 则直接返回原缓冲（零拷贝）；否则渲染转换。
    static func toBGRA(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(source)
        if format == kCVPixelFormatType_32BGRA {
            return source
        }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard let bgra = makeBGRAPixelBuffer(width: width, height: height) else {
            throw AppError.processingFailed(underlying: NSError(domain: "CVPixelBufferCreate", code: -1, userInfo: nil))
        }
        let ciImage = CIImage(cvPixelBuffer: source)
        ciContext.render(ciImage, to: bgra)
        return bgra
    }

    /// 创建 BGRA 像素缓冲
    static func makeBGRAPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }

    // MARK: - 缩放（BGRA，vImage 加速，逐通道缩放与通道顺序无关，可直接用于 BGRA）

    /// 将 BGRA 源缓冲缩放到目标尺寸（返回新的 BGRA 缓冲）。
    static func scaledBGRA(_ source: CVPixelBuffer, to size: CGSize) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let targetW = max(1, Int(size.width))
        let targetH = max(1, Int(size.height))

        guard let destination = makeBGRAPixelBuffer(width: targetW, height: targetH) else {
            throw AppError.processingFailed(underlying: NSError(domain: "CVPixelBufferCreate", code: -1, userInfo: nil))
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        var sourceBuffer = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(source),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var destinationBuffer = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(destination),
            height: vImagePixelCount(targetH),
            width: vImagePixelCount(targetW),
            rowBytes: CVPixelBufferGetBytesPerRow(destination)
        )
        vImageScale_ARGB8888(
            &sourceBuffer, &destinationBuffer,
            nil, vImage_Flags(kvImageHighQualityResampling)
        )
        return destination
    }

    // MARK: - 张量 → BGRA

    /// 把模型输出 MLMultiArray（float，[1,3,H,W] NCHW 或 [1,H,W,3] NHWC）转为 BGRA 像素缓冲。
    static func makeBGRAPixelBuffer(from array: MLMultiArray, width: Int, height: Int) throws -> CVPixelBuffer {
        guard let bgra = makeBGRAPixelBuffer(width: width, height: height) else {
            throw AppError.pixelBufferMissing
        }
        let shape = array.shape.map { $0.intValue }

        // 解析布局
        let layout = TensorLayout.parse(shape: shape, width: width, height: height)

        CVPixelBufferLockBaseAddress(bgra, [])
        defer { CVPixelBufferUnlockBaseAddress(bgra, []) }

        guard let base = CVPixelBufferGetBaseAddress(bgra) else { throw AppError.pixelBufferMissing }
        let rowBytes = CVPixelBufferGetBytesPerRow(bgra)
        let dst = base.assumingMemoryBound(to: UInt8.self)
        let src = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)

        for y in 0..<height {
            for x in 0..<width {
                let r = src[layout.index(x: x, y: y, c: 0, w: width, h: height)]
                let g = src[layout.index(x: x, y: y, c: 1, w: width, h: height)]
                let b = src[layout.index(x: x, y: y, c: 2, w: width, h: height)]
                let offset = y * rowBytes + x * 4
                dst[offset]     = UInt8(clamping: Int((b * 255).rounded()))
                dst[offset + 1] = UInt8(clamping: Int((g * 255).rounded()))
                dst[offset + 2] = UInt8(clamping: Int((r * 255).rounded()))
                dst[offset + 3] = 255
            }
        }
        return bgra
    }

    // MARK: - BGRA → 张量

    /// 把 BGRA 像素缓冲转为模型输入 MLMultiArray（float，NCHW/NHWC，自动缩放至模型输入尺寸）。
    /// 先 vImage 缩放到目标尺寸，再手工完成 BGRA → RGB 通道重排。
    static func makeRGBInputMultiArray(
        from bgraSource: CVPixelBuffer,
        width: Int,
        height: Int,
        preferredLayout: TensorLayout
    ) throws -> MLMultiArray {
        // 1. 缩放至模型输入尺寸
        let scaled = try scaledBGRA(bgraSource, to: CGSize(width: width, height: height))

        // 2. 分配张量（按布局生成 shape）
        let shape: [NSNumber] = preferredLayout.shapeArray(width: width, height: height)
        guard let array = try? MLMultiArray(shape: shape, dataType: .float32) else {
            throw AppError.processingFailed(underlying: NSError(domain: "MLMultiArray", code: -1, userInfo: nil))
        }

        CVPixelBufferLockBaseAddress(scaled, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(scaled, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(scaled) else { throw AppError.pixelBufferMissing }
        let rowBytes = CVPixelBufferGetBytesPerRow(scaled)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let dst = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                let b = Float(src[offset]) / 255.0
                let g = Float(src[offset + 1]) / 255.0
                let r = Float(src[offset + 2]) / 255.0
                dst[preferredLayout.index(x: x, y: y, c: 0, w: width, h: height)] = r
                dst[preferredLayout.index(x: x, y: y, c: 1, w: width, h: height)] = g
                dst[preferredLayout.index(x: x, y: y, c: 2, w: width, h: height)] = b
            }
        }
        return array
    }

    // MARK: - 张量布局

    /// 张量布局描述（NCHW / NHWC 与裸 HWC）
    enum TensorLayout {
        case nchw   // [1, 3, H, W]
        case nhwc   // [1, H, W, 3]
        case hwc    // [H, W, 3]
        case chw    // [3, H, W]

        static func parse(shape: [Int], width: Int, height: Int) -> TensorLayout {
            if shape.count == 4 {
                if shape[1] == 3 { return .nchw }        // [1,3,H,W]
                if shape[3] == 3 { return .nhwc }        // [1,H,W,3]
            }
            if shape.count == 3 {
                if shape[0] == 3 { return .chw }         // [3,H,W]
                if shape[2] == 3 { return .hwc }         // [H,W,3]
            }
            // 默认按 NCHW 处理
            return .nchw
        }

        func shapeArray(width: Int, height: Int) -> [NSNumber] {
            switch self {
            case .nchw: return [1, 3, NSNumber(value: height), NSNumber(value: width)]
            case .nhwc: return [1, NSNumber(value: height), NSNumber(value: width), 3]
            case .chw:  return [3, NSNumber(value: height), NSNumber(value: width)]
            case .hwc:  return [NSNumber(value: height), NSNumber(value: width), 3]
            }
        }

        func index(x: Int, y: Int, c: Int, w: Int, h: Int) -> Int {
            switch self {
            case .nchw: return c * h * w + y * w + x
            case .nhwc: return y * w * 3 + x * 3 + c
            case .chw:  return c * h * w + y * w + x
            case .hwc:  return y * w * 3 + x * 3 + c
            }
        }
    }
}
