import Foundation

/// 离线处理任务的完整状态模型（贯穿 ViewModel / Service / View）。
@MainActor
final class OfflineJob: ObservableObject, Identifiable {
    let id: UUID
    let mode: ProcessingMode
    let sourceURL: URL
    let sourceFileName: String

    /// 任务创建时间
    let createdAt: Date

    // MARK: - 运行时状态（@Published 供 Liquid Glass UI 刷新）

    @Published var state: State = .queued
    @Published var progress: Double = 0        // 0...1
    @Published var processedFrameCount: Int = 0
    @Published var totalFrameCount: Int = 0
    @Published var errorMessage: String?
    @Published var outputURL: URL?             // 处理完成的临时输出文件（用于预览 / 保存）
    @Published var savedToLibrary = false      // 是否已保存到相册

    // MARK: - 任务状态枚举

    enum State: Equatable {
        case queued
        case processing
        case paused
        case cancelled
        case completed
        case failed(String)
    }

    init(mode: ProcessingMode, sourceURL: URL, sourceFileName: String) {
        self.id = UUID()
        self.mode = mode
        self.sourceURL = sourceURL
        self.sourceFileName = sourceFileName
        self.createdAt = Date()
    }

    // MARK: - 便捷 UI 属性

    var isFinished: Bool {
        switch state {
        case .completed, .cancelled, .failed: return true
        default: return false
        }
    }

    var stateText: String {
        switch state {
        case .queued:      return "排队中"
        case .processing:  return String(format: "处理中 %.0f%%", progress * 100)
        case .paused:      return "已暂停"
        case .cancelled:   return "已取消"
        case .completed:   return "已完成"
        case .failed(let m): return "失败：\(m)"
        }
    }
}
