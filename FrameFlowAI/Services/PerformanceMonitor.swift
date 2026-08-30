import Foundation
import QuartzCore

/// 实时链路性能监控：FPS（输出帧率）与端到端延迟（帧到达 → 处理完成）。
///
/// 线程安全：内部使用 NSLock，可在相机回调队列 / 处理队列并发调用。
final class PerformanceMonitor {

    /// 帧时间戳窗口（秒），用于计算 FPS
    private let fpsWindow: TimeInterval = 1.0

    private let lock = NSLock()
    private var frameTimestamps: [TimeInterval] = []
    private var latencyAccumulator: TimeInterval = 0
    private var latencyCount: Int = 0

    /// 当前输出 FPS
    private(set) var fps: Double = 0

    /// 平均端到端延迟（秒）
    private(set) var averageLatency: TimeInterval = 0

    /// 记录一次输出帧（刷新 FPS）
    func recordOutput(at time: TimeInterval = CACurrentMediaTime()) {
        lock.lock()
        defer { lock.unlock() }

        frameTimestamps.append(time)
        while let first = frameTimestamps.first, time - first > fpsWindow {
            frameTimestamps.removeFirst()
        }
        fps = Double(frameTimestamps.count)
    }

    /// 记录一次端到端延迟（滑动平均）
    func recordLatency(_ latency: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        latencyAccumulator += latency
        latencyCount += 1
        averageLatency = latencyCount > 0 ? latencyAccumulator / Double(latencyCount) : 0
    }

    /// 重置
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        frameTimestamps.removeAll()
        latencyAccumulator = 0
        latencyCount = 0
        fps = 0
        averageLatency = 0
    }
}
