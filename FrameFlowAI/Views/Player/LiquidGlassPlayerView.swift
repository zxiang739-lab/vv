import SwiftUI
import AVFoundation

/// 自定义 AVPlayer 播放器（SwiftUI 液态玻璃 UI，用于离线任务预览）。
///
/// 完整交互：
/// 1. 进度条拖拽：手指拖动滑块实时预览时间点（内存内），松手跳转；
/// 2. 点击画面：显示 / 隐藏液态玻璃控制面板；
/// 3. 长按加速：长按画面临时高速（3x），松手恢复所选档位速率；
/// 4. 档位倍速：0.5x / 1.0x / 1.5x / 2.0x（AVPlayer.rate 原生接口）。
struct LiquidGlassPlayerView: View {

    @ObservedObject var viewModel: PlayerViewModel

    /// 拖拽进度状态
    @State private var isDragging = false
    @State private var draggingTime: Double = 0

    /// 当前显示时间（拖拽时用预览值）
    private var displayTime: Double {
        isDragging ? draggingTime : viewModel.currentTime
    }

    private var displayProgress: Double {
        guard viewModel.duration > 0 else { return 0 }
        return min(max(0, displayTime / viewModel.duration), 1)
    }

    var body: some View {
        ZStack {
            // 视频画面层
            VideoLayerView(player: viewModel.player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                // 点击画面：显隐控制面板
                .onTapGesture { viewModel.toggleControls() }
                // 长按加速（按下加速 / 松开恢复）
                .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 30, pressing: { isPressing in
                    if isPressing {
                        viewModel.beginBoost()
                    } else {
                        viewModel.endBoost()
                    }
                }, perform: {})

            // 控制面板（液态玻璃）
            if viewModel.isControlsVisible {
                controlOverlay
                    .transition(.opacity)
            }

            // 加载指示
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .background(Color.black)
    }

    // MARK: - 控制面板

    private var controlOverlay: some View {
        VStack {
            // 顶栏：加速状态提示
            topBar

            Spacer()

            // 底栏：播放 / 进度 / 倍速
            bottomBar
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.45), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private var topBar: some View {
        HStack {
            if viewModel.isBoosting {
                Label("3x 加速中", systemImage: "forward.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .glassEffect(.regular)
            }
            Spacer()
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            // 进度条（拖拽）
            progressBar

            // 播放控制 + 倍速
            HStack(spacing: 16) {
                Button(action: { viewModel.playPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .foregroundStyle(.white)
                        .background(.thinMaterial, in: Circle())
                        .glassEffect(.regular)
                }
                .buttonStyle(.plain)

                Spacer()

                // 时间
                Text(formatTime(displayTime) + " / " + formatTime(viewModel.duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                // 倍速档位
                HStack(spacing: 8) {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            viewModel.setRate(Float(rate))
                        } label: {
                            Text(rate == 1.0 ? "1x" : String(format: "%.1fx", rate))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .foregroundStyle(viewModel.selectedRate == Float(rate) ? Color.white : .white.opacity(0.7))
                                .background(
                                    viewModel.selectedRate == Float(rate) ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.15),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(.thinMaterial, in: Capsule())
                .glassEffect(.regular)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    // MARK: - 进度条

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 轨道
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 6)
                // 已播放
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(6, geo.size.width * displayProgress), height: 6)
                // 滑块
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(radius: 2)
                    .offset(x: max(0, min(geo.size.width - 16, geo.size.width * displayProgress - 8)))
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging { isDragging = true }
                        let ratio = min(max(0, value.location.x / geo.size.width), 1)
                        draggingTime = ratio * max(0, viewModel.duration)
                        viewModel.updateDragPreview(draggingTime)
                    }
                    .onEnded { _ in
                        viewModel.seek(to: draggingTime)
                        isDragging = false
                    }
            )
        }
        .frame(height: 24)
    }

    // MARK: - 工具

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - AVPlayerLayer 包装

/// 把 AVPlayerLayer 包装为 SwiftUI 视图。
private struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
