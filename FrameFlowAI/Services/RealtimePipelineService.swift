import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

/// 实时链路编排服务。
///
/// 职责（实时 3 种业务模式共用）：
/// 1. 按 `EngineKind` 创建对应引擎（VTFrameProcessor / CoreML），遵循统一协议；
/// 2. 摄像头 AVCaptureSession → CMSampleBuffer 流转；
/// 3. 背压控制：上一帧处理未完成时丢弃新帧（实时优先，避免队列积压引入延迟）；
/// 4. 处理结果送入 `AVSampleBufferDisplayLayer` 预览；
/// 5. FPS / 端到端延迟监控（供 UI「硬件占用」面板展示）。
final class RealtimePipelineService {

    // MARK: - 输出

    /// 预览显示层（由 SwiftUI 用 UIViewRepresentable 包装）
    let previewLayer = AVSampleBufferDisplayLayer()

    /// 性能监控（线程安全）
    let performanceMonitor = PerformanceMonitor()

    /// 错误回调（供 ViewModel 展示）
    var onError: ((Error) -> Void)?

    // MARK: - 内部

    private let cameraService = CameraService()
    private var engine: AIFrameProcessingEngine?

    private(set) var engineKind: EngineKind = .systemVT
    private(set) var processingMode: ProcessingMode = .realtimeInterpolation

    private let processingQueue = DispatchQueue(label: "realtime.processing", qos: .userInteractive)
    private let stateLock = NSLock()

    /// 是否正在处理上一帧（背压标志）
    private var isFrameInFlight = false

    var isRunning: Bool { engine?.isRunning ?? false }

    // MARK: - 生命周期

    /// 启动实时链路：建引擎 → prepare → 开摄像头 → start。
    func start(engineKind: EngineKind, mode: ProcessingMode, configuration: EngineConfiguration) async throws {
        stop()

        self.engineKind = engineKind
        self.processingMode = mode

        // 1. 创建引擎（统一协议，上层不感知具体实现）
        let engine = EngineFactory.make(kind: engineKind)
        self.engine = engine

        // 2. 配置并预热引擎（模型加载等可能耗时，在后台执行）
        try await engine.prepare(mode: mode, configuration: configuration)

        // 3. 摄像头采集（BGRA 输出）
        cameraService.onSampleBuffer = { [weak self] sampleBuffer in
            self?.handleFrame(sampleBuffer)
        }
        try await cameraService.start()

        // 4. 引擎进入运行态
        try await engine.start()

        performanceMonitor.reset()
        AppLogger.service("实时链路已启动：\(engineKind.shortName) / \(mode.title)")
    }

    func stop() {
        cameraService.onSampleBuffer = nil
        cameraService.stop()
        engine?.stop()
        engine = nil
        previewLayer.flushAndRemoveImage()
        stateLock.lock()
        isFrameInFlight = false
        stateLock.unlock()
    }

    // MARK: - 帧处理（背压 + 引擎调用 + 预览）

    private func handleFrame(_ sampleBuffer: CMSampleBuffer) {
        // 背压：上一帧仍在处理时直接丢弃（实时链路优先低延迟）
        stateLock.lock()
        guard !isFrameInFlight else {
            stateLock.unlock()
            return
        }
        isFrameInFlight = true
        stateLock.unlock()

        let arrivalTime = CACurrentMediaTime()

        processingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.isFrameInFlight = false
                self.stateLock.unlock()
            }
            do {
                let outputs = try await self.engine?.process(frame: sampleBuffer) ?? []
                for output in outputs {
                    self.performanceMonitor.recordOutput()
                    self.enqueueToPreview(output)
                }
                self.performanceMonitor.recordLatency(CACurrentMediaTime() - arrivalTime)
            } catch {
                AppLogger.engineError("实时帧处理失败：\(error.localizedDescription)")
                self.onError?(error)
            }
        }
    }

    /// 送入 AVSampleBufferDisplayLayer（enqueue 线程安全，可在处理队列调用）
    private func enqueueToPreview(_ sampleBuffer: CMSampleBuffer) {
        previewLayer.enqueue(sampleBuffer)
        previewLayer.setNeedsDisplay()
    }
}
