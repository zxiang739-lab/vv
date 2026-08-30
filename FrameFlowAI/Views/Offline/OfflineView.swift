import SwiftUI
import UniformTypeIdentifiers
import CoreMedia

/// 离线模式主视图：2 种离线业务模式（离线补帧 / 离线超分）。
///
/// - 引擎切换 + 模式选择；
/// - 系统文件选择器导入本地视频（复制到沙盒）；
/// - 展示视频信息（分辨率 / 帧率 / 时长）；
/// - 任务队列：进度、取消、预览（自定义 AVPlayer）、保存相册；
/// - 异步任务可取消，分批分帧防 OOM。
struct OfflineView: View {

    @ObservedObject var mainViewModel: MainViewModel
    @ObservedObject var offlineViewModel: OfflineViewModel

    /// 离线业务模式
    private let offlineModes: [ProcessingMode] = [
        .offlineInterpolation,
        .offlineSuperResolution
    ]

    // MARK: - 本地状态

    @State private var isImporting = false
    @State private var importedURL: URL?
    @State private var videoInfo: OfflinePipelineService.VideoInfo?
    @State private var sourceFPS: Double = 30
    @State private var isPreparingJob = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // 引擎切换
                    engineSection

                    // 模式选择
                    modeSection

                    // 文件导入
                    importSection

                    // 任务队列
                    jobsSection
                }
                .padding()
            }
            .navigationTitle("离线处理")
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { offlineViewModel.errorMessage != nil },
                set: { if !$0 { offlineViewModel.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(offlineViewModel.errorMessage ?? "")
        }
        // 任务预览播放器
        .sheet(item: $previewJob) { _ in
            if let playerViewModel {
                LiquidGlassPlayerView(viewModel: playerViewModel)
                    .onDisappear {
                        playerViewModel.tearDown()
                        self.playerViewModel = nil
                    }
            }
        }
    }

    // MARK: - 引擎切换

    private var engineSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI 引擎")
                    .font(.headline)

                GlassSegmentPicker(
                    title: "选择推理引擎",
                    options: EngineKind.allCases.map { $0.shortName },
                    selection: engineSelection
                )

                Text(mainViewModel.selectedEngine.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var engineSelection: Binding<Int> {
        Binding(
            get: { EngineKind.allCases.firstIndex(of: mainViewModel.selectedEngine) ?? 0 },
            set: { index in
                guard EngineKind.allCases.indices.contains(index) else { return }
                mainViewModel.selectedEngine = EngineKind.allCases[index]
            }
        )
    }

    // MARK: - 模式选择

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("离线业务模式")
                .font(.headline)

            ForEach(offlineModes) { mode in
                modeRow(mode)
            }
        }
    }

    private func modeRow(_ mode: ProcessingMode) -> some View {
        let isSelected = mainViewModel.selectedMode == mode
        return Button {
            mainViewModel.selectedMode = mode
        } label: {
            HStack(spacing: 14) {
                Image(systemName: mode == .offlineInterpolation ? "film.stack" : "arrow.up.left.and.arrow.down.right")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(mode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .padding(14)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 文件导入

    private var importSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("源视频")
                        .font(.headline)
                    Spacer()
                    if let videoInfo {
                        Text(String(format: "%.0f FPS", videoInfo.frameRate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GlassPrimaryButton(
                    title: importedURL == nil ? "选择视频文件" : "重新选择视频",
                    systemImage: "folder",
                    isEnabled: true,
                    tint: .orange
                ) {
                    isImporting = true
                }

                if let videoInfo {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("分辨率：\(videoInfo.width) × \(videoInfo.height)", systemImage: "rectangle.ratio.3.to.2")
                        Label("帧率：\(String(format: "%.1f", videoInfo.frameRate)) FPS", systemImage: "timer")
                        Label("时长：\(formattedDuration(videoInfo.duration))", systemImage: "clock")
                        Label("音频：\(videoInfo.hasAudio ? "有" : "无")", systemImage: "waveform")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // 处理参数说明
                    Text(parameterSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    GlassPrimaryButton(
                        title: isPreparingJob ? "处理中…" : "开始处理",
                        systemImage: "play.circle.fill",
                        isEnabled: !isPreparingJob && capability.canStart,
                        tint: .green
                    ) {
                        startProcessing()
                    }
                }
            }
        }
    }

    private var capability: EngineCapability {
        mainViewModel.capability(for: mainViewModel.selectedEngine, mode: mainViewModel.selectedMode)
    }

    private var parameterSummary: String {
        let mode = mainViewModel.selectedMode
        var parts: [String] = []
        if mode.usesFrameInterpolation {
            parts.append("补帧 2x：输出 \(String(format: "%.0f", sourceFPS * 2)) FPS，分辨率不变")
        }
        if mode.usesSuperResolution {
            parts.append("超分 2x：输出 \(videoInfo.map { "\($0.width * 2)×\($0.height * 2)" } ?? "")")
        }
        return parts.joined(separator: "；")
    }

    // MARK: - 任务队列

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("任务队列")
                .font(.headline)

            if offlineViewModel.jobs.isEmpty {
                Text("暂无任务。选择视频并开始处理后，任务将显示在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(offlineViewModel.jobs) { job in
                    OfflineJobRow(
                        job: job,
                        onCancel: { offlineViewModel.cancelJob(job) },
                        onRemove: { offlineViewModel.removeJob(job) },
                        onPreview: { presentPlayer(job) },
                        onSave: {
                            Task { await offlineViewModel.saveToLibrary(job: job) }
                        }
                    )
                }
            }
        }
    }

    /// 任务预览播放器（sheet）
    @State private var previewJob: OfflineJob?
    @State private var playerViewModel: PlayerViewModel?

    private func presentPlayer(_ job: OfflineJob) {
        let vm = PlayerViewModel()
        if let url = job.outputURL {
            vm.load(url: url)
        }
        playerViewModel = vm
        previewJob = job
    }

    // MARK: - 动作

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let localURL = try await offlineViewModel.importVideo(from: url)
                    importedURL = localURL
                    videoInfo = try offlineViewModel.inspectVideo(at: localURL)
                    sourceFPS = videoInfo?.frameRate ?? 30
                } catch {
                    offlineViewModel.errorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            offlineViewModel.errorMessage = error.localizedDescription
        }
    }

    private func startProcessing() {
        guard let importedURL, let videoInfo else { return }
        guard capability.canStart else {
            offlineViewModel.errorMessage = capability.unavailableReason ?? "当前配置无法启动任务。"
            return
        }
        isPreparingJob = true
        let configuration = offlineConfiguration(for: mainViewModel.selectedMode, info: videoInfo)
        offlineViewModel.startJob(
            sourceURL: importedURL,
            engineKind: mainViewModel.selectedEngine,
            mode: mainViewModel.selectedMode,
            configuration: configuration
        )
        isPreparingJob = false
    }

    private func offlineConfiguration(for mode: ProcessingMode, info: OfflinePipelineService.VideoInfo) -> EngineConfiguration {
        EngineConfiguration(
            mode: mode,
            sourceWidth: info.width,
            sourceHeight: info.height,
            numberOfInterpolatedFrames: 1,
            superResolutionScaleFactor: 2.0,
            sourceFrameRate: info.frameRate,
            targetFrameRate: mode.usesFrameInterpolation ? info.frameRate * 2 : nil,
            fallbackFrameRate: info.frameRate
        )
    }

    private func formattedDuration(_ time: CMTime) -> String {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return "--" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 任务行

/// 单个离线任务行：进度、取消、预览（自定义播放器）、保存相册。
private struct OfflineJobRow: View {
    @ObservedObject var job: OfflineJob
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onPreview: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.mode.title)
                        .font(.subheadline.weight(.semibold))
                    Text(job.sourceFileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                Text(job.stateText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(stateColor)
            }

            // 进度
            GlassProgressBar(progress: job.progress)

            // 操作按钮
            HStack(spacing: 8) {
                switch job.state {
                case .processing:
                    Button(action: onCancel) {
                        Label("取消", systemImage: "xmark.circle")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .glassEffect(.regular)
                    }
                    .buttonStyle(.plain)
                case .completed:
                    Button(action: onPreview) {
                        Label("预览", systemImage: "play.circle")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .glassEffect(.regular)
                    }
                    .buttonStyle(.plain)

                    Button(action: onSave) {
                        Label(job.savedToLibrary ? "已保存" : "保存相册", systemImage: job.savedToLibrary ? "checkmark.circle" : "square.and.arrow.down")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .glassEffect(.regular)
                    }
                    .buttonStyle(.plain)
                    .disabled(job.savedToLibrary)
                case .failed, .cancelled:
                    Button(action: onRemove) {
                        Label("移除", systemImage: "trash")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .glassEffect(.regular)
                    }
                    .buttonStyle(.plain)
                default:
                    EmptyView()
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var stateColor: Color {
        switch job.state {
        case .completed: return .green
        case .failed:    return .red
        case .cancelled: return .secondary
        default:         return .orange
        }
    }
}
