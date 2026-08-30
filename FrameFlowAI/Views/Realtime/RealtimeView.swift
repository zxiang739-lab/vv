import SwiftUI
import AVFoundation

/// 实时模式主视图：3 种实时业务模式（实时补帧 / 实时超分 / 实时补帧+超分）。
///
/// - 引擎切换（系统 VTFrameProcessor / 导入 CoreML）分段控件；
/// - 模式选择开关（Liquid Glass 卡片）；
/// - 实时预览（AVSampleBufferDisplayLayer）；
/// - FPS / 端到端延迟 / 引擎状态监控面板；
/// - 不支持（硬件 / 模型缺失）时按钮置灰并提示。
struct RealtimeView: View {

    @ObservedObject var mainViewModel: MainViewModel
    @ObservedObject var realtimeViewModel: RealtimeViewModel

    /// 实时业务模式
    private let realtimeModes: [ProcessingMode] = [
        .realtimeInterpolation,
        .realtimeSuperResolution,
        .realtimeInterpolationAndSuperResolution
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // 实时预览
                    previewSection

                    // 引擎切换
                    engineSection

                    // 模式选择
                    modeSection

                    // 能力提示（硬件不支持 / 模型缺失）
                    capabilityNotice

                    // 启动 / 停止
                    startStopButton
                }
                .padding()
            }
            .navigationTitle("实时处理")
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { realtimeViewModel.errorMessage != nil },
                set: { if !$0 { realtimeViewModel.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(realtimeViewModel.errorMessage ?? "")
        }
    }

    // MARK: - 预览

    private var previewSection: some View {
        ZStack {
            RealtimePreviewView(layer: realtimeViewModel.previewLayer)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )

            // 监控面板
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    MetricBadge(title: "FPS", value: String(format: "%.1f", realtimeViewModel.fps))
                    MetricBadge(title: "延迟 ms", value: String(format: "%.0f", realtimeViewModel.latency * 1000))
                    MetricBadge(title: "引擎", value: realtimeViewModel.engineKind.shortName)
                }
                .padding(10)
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

                // 引擎模型状态
                HStack {
                    Image(systemName: "brain.head.profile")
                    Text(mainViewModel.modelStatusText(for: mainViewModel.selectedEngine, mode: mainViewModel.selectedMode))
                        .font(.caption)
                }
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
            Text("实时业务模式")
                .font(.headline)

            ForEach(realtimeModes) { mode in
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
                Image(systemName: modeIcon(mode))
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

    private func modeIcon(_ mode: ProcessingMode) -> String {
        switch mode {
        case .realtimeInterpolation:                    return "wand.and.stars"
        case .realtimeSuperResolution:                  return "magnifyingglass"
        case .realtimeInterpolationAndSuperResolution:  return "sparkles.rectangle.stack"
        default:                                        return "rectangle"
        }
    }

    // MARK: - 能力提示

    private var capabilityNotice: some View {
        let capability = mainViewModel.capability(
            for: mainViewModel.selectedEngine,
            mode: mainViewModel.selectedMode
        )
        guard !capability.canStart, let reason = capability.unavailableReason ?? capabilityReason else {
            return AnyView(EmptyView())
        }
        return AnyView(
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
    }

    private var capabilityReason: String? {
        let cap = mainViewModel.capability(for: mainViewModel.selectedEngine, mode: mainViewModel.selectedMode)
        if !cap.isSupported { return cap.unavailableReason }
        if !cap.isReady {
            return mainViewModel.selectedEngine == .importedCoreML
                ? "缺少所需模型，请到「设置」导入补帧 / 超分 mlpackage。"
                : nil
        }
        return nil
    }

    // MARK: - 启动按钮

    private var startStopButton: some View {
        let capability = mainViewModel.capability(
            for: mainViewModel.selectedEngine,
            mode: mainViewModel.selectedMode
        )
        let isEnabled = capability.canStart

        return VStack(spacing: 10) {
            GlassPrimaryButton(
                title: realtimeViewModel.isRunning ? "停止" : "启动实时预览",
                systemImage: realtimeViewModel.isRunning ? "stop.fill" : "play.fill",
                isEnabled: isEnabled,
                tint: .orange
            ) {
                Task {
                    await realtimeViewModel.toggle(
                        engine: mainViewModel.selectedEngine,
                        mode: mainViewModel.selectedMode,
                        configuration: realtimeConfiguration(for: mainViewModel.selectedMode)
                    )
                }
            }

            Text(realtimeViewModel.lastEngineState)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 实时模式配置（摄像头 720p；补帧 2x → 60fps；超分 2x）。
    private func realtimeConfiguration(for mode: ProcessingMode) -> EngineConfiguration {
        EngineConfiguration(
            mode: mode,
            sourceWidth: 1280,
            sourceHeight: 720,
            numberOfInterpolatedFrames: 1,
            superResolutionScaleFactor: 2.0,
            sourceFrameRate: 30,
            targetFrameRate: mode.usesFrameInterpolation ? 60 : nil,
            fallbackFrameRate: 30
        )
    }
}
