import Foundation
import Combine

/// 离线模式 ViewModel：管理离线任务队列（创建 / 执行 / 取消 / 保存相册）。
///
/// 执行模型：任务主体在后台执行（Task.detached + nonisolated run），
/// 任务模型（OfflineJob，@MainActor）的所有更新都通过 MainActor.run 回到主线程，
/// 保证 UI 不阻塞、状态线程安全。
@MainActor
final class OfflineViewModel: ObservableObject {

    // MARK: - 已发布状态

    @Published var jobs: [OfflineJob] = []
    @Published var errorMessage: String?

    // MARK: - 内部

    private var tasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - 文件选择

    /// 导入用户选中的视频到沙盒（返回本地 URL）。
    func importVideo(from url: URL) async throws -> URL {
        try VideoImportService.shared.importVideo(from: url)
    }

    /// 读取视频信息（用于创建任务前回填源帧率 / 尺寸）。
    func inspectVideo(at url: URL) throws -> OfflinePipelineService.VideoInfo {
        try OfflinePipelineService().inspectVideo(at: url)
    }

    // MARK: - 任务管理

    /// 创建并启动一个离线任务。
    func startJob(
        sourceURL: URL,
        engineKind: EngineKind,
        mode: ProcessingMode,
        configuration: EngineConfiguration
    ) {
        let job = OfflineJob(
            mode: mode,
            sourceURL: sourceURL,
            sourceFileName: sourceURL.lastPathComponent
        )
        jobs.append(job)

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run(
                job: job,
                sourceURL: sourceURL,
                engineKind: engineKind,
                mode: mode,
                configuration: configuration
            )
        }
        tasks[job.id] = task
    }

    /// 取消任务（管线会检测 Task.isCancelled 并中断写入）。
    func cancelJob(_ job: OfflineJob) {
        tasks[job.id]?.cancel()
        job.state = .cancelled
        tasks[job.id] = nil
    }

    /// 移除任务（仅允许非进行中任务）。
    func removeJob(_ job: OfflineJob) {
        guard job.state != .processing else { return }
        jobs.removeAll { $0.id == job.id }
        tasks[job.id] = nil
    }

    /// 把已完成任务输出保存到相册。
    func saveToLibrary(job: OfflineJob) async {
        guard let outputURL = job.outputURL else { return }
        do {
            try await PhotoLibraryService.shared.saveVideo(from: outputURL)
            job.savedToLibrary = true
        } catch {
            job.errorMessage = error.localizedDescription
        }
    }

    // MARK: - 任务执行（后台）

    /// 非 MainActor 隔离的任务主体：重活全部在后台执行。
    nonisolated private func run(
        job: OfflineJob,
        sourceURL: URL,
        engineKind: EngineKind,
        mode: ProcessingMode,
        configuration: EngineConfiguration
    ) async {
        await MainActor.run { job.state = .processing }

        // 在非隔离上下文内使用局部管线实例，避免跨 actor 访问 VM 存储属性
        let pipelineService = OfflinePipelineService()

        do {
            // 1. 建引擎并预热（模型加载在后台，不阻塞 UI）
            let engine = EngineFactory.make(kind: engineKind)
            try await engine.prepare(mode: mode, configuration: configuration)
            try await engine.start()

            // 2. 执行离线管线（可取消）
            let outputURL = try await pipelineService.process(
                sourceURL: sourceURL,
                engine: engine,
                configuration: configuration
            ) { progress in
                Task { @MainActor in
                    job.progress = progress
                }
            }

            engine.stop()

            await MainActor.run {
                job.outputURL = outputURL
                job.progress = 1.0
                job.state = .completed
            }
        } catch {
            if Task.isCancelled {
                await MainActor.run { job.state = .cancelled }
            } else {
                await MainActor.run {
                    job.errorMessage = error.localizedDescription
                    job.state = .failed(error.localizedDescription)
                }
            }
        }

        await MainActor.run { [weak self] in
            self?.tasks[job.id] = nil
        }
    }
}
