import SwiftUI

// MARK: - 液态玻璃卡片

/// 液态玻璃卡片容器：材质背景 + 系统玻璃背景效果。
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 24
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - 玻璃按钮

/// 玻璃主按钮（如「启动 / 停止」）。
struct GlassPrimaryButton: View {
    let title: String
    let systemImage: String?
    let isEnabled: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .background(.thinMaterial, in: Capsule())
            .glassEffect(.regular)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
    }
}

// MARK: - 玻璃分段选择器（引擎切换）

/// 液态玻璃分段选择器（引擎切换 / 模式分组）。
struct GlassSegmentPicker: View {
    let title: String
    let options: [String]
    @Binding var selection: Int
    var disabledIndexes: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button {
                        selection = index
                    } label: {
                        Text(option)
                            .font(.subheadline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(selection == index ? Color.white : .primary)
                            .background(selection == index ? Color.accentColor.opacity(0.85) : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(disabledIndexes.contains(index))
                    .opacity(disabledIndexes.contains(index) ? 0.35 : 1)
                }
            }
            .padding(4)
            .background(.thinMaterial, in: Capsule())
            .glassEffect(.regular)
        }
    }
}

// MARK: - 指标徽章（FPS / 延迟 / 内存）

/// 实时监控指标徽章。
struct MetricBadge: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - 玻璃进度条

/// 液态玻璃进度条。
struct GlassProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(8, proxy.size.width * min(1, progress)))
            }
        }
        .frame(height: 8)
        .glassEffect(.regular)
    }
}
