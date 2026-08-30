import SwiftUI
import UniformTypeIdentifiers

/// 设置视图：
/// - 双引擎架构说明；
/// - 用户导入 CoreML 模型（补帧 mlpackage / 超分 mlpackage）导入 / 校验 / 删除；
/// - 引擎 × 模式能力矩阵；
/// - 隐私权限说明。
struct SettingsView: View {

    @ObservedObject var mainViewModel: MainViewModel

    // MARK: - 本地状态

    @State private var isImporting = false
    @State private var importingKind: CoreMLModelInfo.Kind?
    @State private var errorMessage: String?
    /// 刷新令牌（模型导入 / 删除后自增触发 UI 刷新）
    @State private var refreshToken = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    architectureSection
                    modelImportSection
                    capabilitySection
                    privacySection
                }
                .padding()
            }
            .navigationTitle("设置")
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 架构说明

    private var architectureSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("双 AI 引擎架构", systemImage: "cpu")
                    .font(.headline)

                ForEach(EngineKind.allCases) { engine in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(engine.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(engine.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("两套引擎遵循统一处理协议，上层业务代码不感知底层实现，可随时切换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - CoreML 模型导入

    private var modelImportSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("CoreML 模型管理", systemImage: "square.stack.3d.up")
                    .font(.headline)

                Text("模型不打包内置，由您导入补帧 / 超分 mlpackage 并存于 App 沙盒。导入时自动校验张量维度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                modelCard(kind: .frameInterpolation)
                modelCard(kind: .superResolution)
            }
        }
    }

    private func modelCard(kind: CoreMLModelInfo.Kind) -> some View {
        let model = CoreMLModelStore.shared.latestModel(kind: kind)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind.kindText)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    importingKind = kind
                    isImporting = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .glassEffect(.regular)
                }
                .buttonStyle(.plain)
            }

            if let model {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Text("张量：\(model.shapeText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("大小：\(ByteCountFormatter.string(fromByteCount: model.fileSize, countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button(role: .destructive) {
                    deleteModel(model)
                } label: {
                    Label("删除模型", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            } else {
                Text("未导入。请选择 \(kind == .frameInterpolation ? "补帧" : "超分") mlpackage（目录）导入。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 能力矩阵

    private var capabilitySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("引擎 × 模式 能力矩阵", systemImage: "checklist")
                    .font(.headline)

                VStack(spacing: 6) {
                    ForEach(ProcessingMode.allCases) { mode in
                        HStack {
                            Text(mode.title)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            capabilityDot(engine: .systemVT, mode: mode)
                            capabilityDot(engine: .importedCoreML, mode: mode)
                        }
                    }
                    HStack {
                        Text("")
                            .frame(maxWidth: .infinity)
                        Text("系统")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 56)
                        Text("CoreML")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 56)
                    }
                }
            }
        }
    }

    private func capabilityDot(engine: EngineKind, mode: ProcessingMode) -> some View {
        let cap = mainViewModel.capability(for: engine, mode: mode)
        let color: Color = cap.canStart ? .green : (cap.isSupported ? .yellow : .red)
        return Image(systemName: cap.canStart ? "checkmark.circle.fill" : (cap.isSupported ? "exclamationmark.circle" : "xmark.circle.fill"))
            .foregroundStyle(color)
            .font(.title3)
            .frame(width: 56)
    }

    // MARK: - 隐私权限

    private var privacySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("隐私与权限", systemImage: "lock.shield")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Label("相机：实时模式采集画面", systemImage: "camera")
                    Label("照片：从相册选择视频 / 保存输出", systemImage: "photo.on.rectangle")
                    Label("文件：通过系统文件选择器导入视频与模型", systemImage: "folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("所有处理均在设备本地完成，画面与模型数据不会上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 动作

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let kind = importingKind else { return }
            do {
                _ = try CoreMLModelStore.shared.importModel(from: url, kind: kind)
                refreshToken += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
        importingKind = nil
    }

    private func deleteModel(_ info: CoreMLModelInfo) {
        do {
            try CoreMLModelStore.shared.deleteModel(info)
            refreshToken += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
