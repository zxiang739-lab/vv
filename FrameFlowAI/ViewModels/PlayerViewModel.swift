import Foundation
import AVFoundation
import Combine

/// 自定义 AVPlayer 播放器 ViewModel（离线任务预览用）。
///
/// 交互能力：
/// - 拖拽进度（seek 跳转）；
/// - 点击画面显隐控制面板；
/// - 长按画面临时高速（松手恢复原速率）；
/// - 0.5x / 1.0x / 1.5x / 2.0x 档位倍速（AVPlayer.rate）。
@MainActor
final class PlayerViewModel: ObservableObject {

    /// 底层播放器
    let player = AVPlayer()

    // MARK: - 已发布状态

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var selectedRate: Float = 1.0
    @Published var isControlsVisible = true
    @Published var isBoosting = false
    @Published var isLoading = true

    /// 长按临时加速倍数
    let boostRate: Float = 3.0

    // MARK: - 内部

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isSeeking = false

    // MARK: - 加载

    func load(url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        isLoading = true
        currentTime = 0
        duration = 0
        isPlaying = false
        isBoosting = false

        // 观察播放结束
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }

        // 周期时间观察
        removeTimeObserver()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            guard let self, !self.isSeeking else { return }
            self.currentTime = time.seconds
        }

        // 异步读取时长
        Task { [weak self] in
            guard let self else { return }
            do {
                let loadedDuration = try await item.asset.load(.duration)
                self.duration = loadedDuration.seconds.isFinite ? loadedDuration.seconds : 0
                self.isLoading = false
            } catch {
                self.isLoading = false
            }
        }
    }

    // MARK: - 播放控制

    func playPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration, duration > 0 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        }
    }

    /// 跳转（拖拽 / 点击进度条）。
    func seek(to seconds: Double) {
        isSeeking = true
        let clamped = min(max(0, seconds), max(0, duration))
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = clamped
                self?.isSeeking = false
            }
        }
    }

    /// 拖拽进度时的「内存内预览」：仅更新显示时间，不真正跳转（松手才 seek）。
    func updateDragPreview(_ seconds: Double) {
        isSeeking = true
        currentTime = min(max(0, seconds), max(0, duration))
    }

    /// 档位倍速（0.5 / 1.0 / 1.5 / 2.0）。
    func setRate(_ rate: Float) {
        selectedRate = rate
        if !isBoosting {
            player.rate = rate
        }
    }

    // MARK: - 长按加速

    /// 长按开始：临时高速（仅播放中生效）。
    func beginBoost() {
        guard isPlaying else { return }
        player.rate = boostRate
        isBoosting = true
    }

    /// 长按结束：恢复所选档位速率。
    func endBoost() {
        guard isBoosting else { return }
        player.rate = selectedRate
        isBoosting = false
    }

    // MARK: - 控制面板显隐

    func toggleControls() {
        isControlsVisible.toggle()
    }

    // MARK: - 清理

    func tearDown() {
        removeTimeObserver()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }
}
