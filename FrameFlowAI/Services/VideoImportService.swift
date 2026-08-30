import Foundation

/// 视频导入服务：把用户通过系统文件选择器选中的视频复制到 App 沙盒。
///
/// 说明：离线处理使用沙盒内副本，避免对源文件（尤其 iCloud / 外部盘）的持续访问依赖；
/// 导入由用户主动触发的文件选择器驱动，无需额外隐私权限键。
final class VideoImportService {
    static let shared = VideoImportService()

    private let fileManager = FileManager.default

    /// 沙盒内导入视频目录
    private var importDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ImportedVideos", isDirectory: true)
    }

    /// 复制选中的视频到沙盒，返回本地 URL。
    func importVideo(from sourceURL: URL) throws -> URL {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destination = importDirectory
            .appendingPathComponent("import_\(UUID().uuidString).\(ext)")

        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// 清理沙盒内导入视频（可选，避免长期占用空间）。
    func deleteImportedVideo(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}
