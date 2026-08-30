import Foundation
import AVFoundation
import Combine

/// 实时模式 ViewModel：驱动 RealtimePipelineService（3 种实时业务模式共用）。
@MainActor
final class RealtimeViewModel: ObservableObject {

    /// 实时链路服务（内部持有引擎 / 摄像头 / 预览层）
    let pipeline = RealtimePipelineService()

    // MARK: - 已发布状态

    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var fps: Double = 0
    @Published var latency: TimeInterval = 0
    @Published var lastEngineState: String = "未启动"
    @Published var isPreparing = false

    /// 预览层（SwiftUI 用 UIViewRepresentable 包装）
    var previewLayer: AVSampleBufferDisplayLayer { pipeline.previewLayer }

    /// 当前引擎 / 模式（供 UI 文案）
    var engineKind: EngineKind { pipeline.engineKind }
    var processingMode: ProcessingMode { pipeline.processingMode }

    private var metricsTimer: Timer?

    // MARK: - 启动 / 停止

    func start(engine: EngineKind, mode: ProcessingMode, configuration: EngineConfiguration) async {
        guard !isRunning else { return }
        isPreparing = true
        errorMessage = nil
        do {
            pipeline.onError = { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                }
            }
            try await pipeline.start(engineKind: engine, mode: mode, configuration: configuration)
            isRunning = true
            lastEngineState = "运行中"
            startMetricsTimer()
        } catch {
            errorMessage = error.localizedDescription
            lastEngineState = "启动失败"
        }
        isPreparing = false
    }

    func stop() {
        pipeline.stop()
        isRunning = false
        lastEngineState = "已停止"
        stopMetricsTimer()
        fps = 0
        latency = 0
    }

    func toggle(engine: EngineKind, mode: ProcessingMode, configuration: EngineConfiguration) async {
        if isRunning {
            stop()
        } else {
            await start(engine: engine, mode: mode, configuration: configuration)
        }
    }

    // MARK: - 性能刷新

    private func startMetricsTimer() {
        stopMetricsTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fps = self.pipeline.performanceMonitor.fps
                self.latency = self.pipeline.performanceMonitor.averageLatency
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        metricsTimer = timer
    }

    private func stopMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = nil
    }
}
