import Foundation

/// CoreML 模型沙盒存储。
///
/// 职责：
/// - 把用户通过文件选择器选中的 mlpackage（目录）复制到 App 沙盒 Documents/ImportedModels；
/// - 维护已导入模型清单（补帧 / 超分各一份）；
/// - 支持删除。
///
/// 约束：模型不打包内置（不放入 Bundle），全部由用户导入，仅存沙盒。
final class CoreMLModelStore {
    static let shared = CoreMLModelStore()

    private let fileManager = FileManager.default

    /// 沙盒内模型根目录
    private var modelsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ImportedModels", isDirectory: true)
    }

    // MARK: - 导入

    /// 导入用户选择的 mlpackage（sourceURL 为安全作用域 URL）。
    /// 流程：复制 → 校验（张量维度）→ 登记。
    func importModel(from sourceURL: URL, kind: CoreMLModelInfo.Kind) throws -> CoreMLModelInfo {
        // 安全作用域资源访问（UIDocumentPicker 返回的 URL）
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        // 唯一命名，避免覆盖
        let destinationURL = modelsDirectory
            .appendingPathComponent("\(kind.rawValue)_\(UUID().uuidString).mlpackage")

        // mlpackage 本质是目录（bundle），整体复制
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        // 张量维度校验：不通过则回滚并抛错
        do {
            let info = try CoreMLModelValidator.validate(url: destinationURL, kind: kind)
            return info
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    // MARK: - 查询 / 删除

    /// 已导入的模型清单（按导入时间排序）
    func listModels(kind: CoreMLModelInfo.Kind) -> [CoreMLModelInfo] {
        let all = allModels()
        return all.filter { $0.kind == kind }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// 获取某类型模型（最新一个，同一类型只保留一个）
    func latestModel(kind: CoreMLModelInfo.Kind) -> CoreMLModelInfo? {
        listModels(kind: kind).last
    }

    func deleteModel(_ info: CoreMLModelInfo) throws {
        try fileManager.removeItem(at: info.url)
    }

    // MARK: - 私有

    private func allModels() -> [CoreMLModelInfo] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        // 尝试解析目录内已登记的清单；无法解析（旧数据）则跳过
        var result: [CoreMLModelInfo] = []
        for url in urls where url.pathExtension == "mlpackage" {
            // 从导入命名前缀推断类型（import_ 时用 kind.rawValue 前缀命名）
            let name = url.deletingPathExtension().lastPathComponent
            let kind: CoreMLModelInfo.Kind = name.hasPrefix(CoreMLModelInfo.Kind.frameInterpolation.rawValue)
                ? .frameInterpolation : .superResolution
            guard let info = try? CoreMLModelValidator.inspect(url: url, kind: kind) else { continue }
            result.append(info)
        }
        return result
    }
}
