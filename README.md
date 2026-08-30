# FrameFlowAI

**iOS 原生 AI 视频补帧 / 超分工具**（纯 iOS，不支持 macOS）

基于 **VideoToolbox `VTFrameProcessor`**（系统 AI，免模型）与 **用户导入 CoreML**（CoreML + MPS）双引擎，
提供 5 种业务模式：3 种实时（摄像头）+ 2 种离线（本地视频文件）。
UI 全部使用 **SwiftUI 原生 Liquid Glass**（`.glassBackgroundEffect()`），无任何第三方 UI 库 / 推理运行时 / FFmpeg / 私有 API。

> 最低部署版本 **iOS 26.0**，同时完整兼容 **iOS 27**。
> 系统 VTFrameProcessor 引擎仅 iOS 26+ 且硬件支持的设备可用；用户导入 CoreML 引擎全 iOS 26/27 通用。

---

## 目录

1. [项目简介](#1-项目简介)
2. [5 种业务模式](#2-5-种业务模式)
3. [双引擎架构与切换](#3-双引擎架构与切换)
4. [VTFrameProcessor 硬件 / 系统要求](#4-vtframeprocessor-硬件--系统要求)
5. [用户 mlpackage 模型张量规格要求](#5-用户-mlpackage-模型张量规格要求)
6. [工程目录结构](#6-工程目录结构)
7. [编译步骤](#7-编译步骤)
8. [使用教程](#8-使用教程)
9. [已知性能限制](#9-已知性能限制)
10. [隐私与合规](#10-隐私与合规)
11. [GitHub Actions 在线编译（无需本地 Mac）](#11-github-actions-在线编译无需本地-mac)

---

## 1. 项目简介

FrameFlowAI 是一个纯 Swift / SwiftUI 的 iOS App，做两件事：

- **补帧（帧插值）**：在相邻两帧之间用 AI 生成中间帧，把 30 FPS 平滑到 60 FPS（或更多）；
- **超分（超分辨率）**：用 AI 把低分辨率画面放大（如 720p → 1440p），补充细节。

支持两条完全独立的数据链路：

| 链路 | 输入 | 输出 | 引擎 |
|---|---|---|---|
| **实时** | AVCaptureSession 摄像头（CMSampleBuffer 流） | 实时预览（AVSampleBufferDisplayLayer） | 低延迟 VT 配置 / CoreML |
| **离线** | 本地视频文件（AVAssetReader 解帧） | 新视频文件（AVAssetWriter 编码，可存相册） | 高质量 VT 配置 / CoreML |

两种引擎遵循**同一套抽象协议** `AIFrameProcessingEngine`，上层 UI / ViewModel / Service 不感知底层实现，
在界面上一个分段控件即可切换。

---

## 2. 5 种业务模式

> 按需求，**不实现「离线补帧 + 超分」组合**，仅下列 5 种。

### 实时模式（摄像头输入，实时预览）

| # | 模式 | 说明 | 引擎效果 |
|---|---|---|---|
| 1 | **实时补帧** | 仅 AI 帧插值，分辨率不变 | `VTLowLatencyFrameInterpolationConfiguration` / CoreML 补帧 |
| 2 | **实时超分** | 仅 AI 超分放大，不插帧 | `VTLowLatencySuperResolutionScalerConfiguration` / CoreML 超分 |
| 3 | **实时补帧 + 超分** | 串联补帧 → 超分流水线 | 低延迟插值会话 → 低延迟超分会话（CoreML 同理串联） |

### 离线模式（本地视频文件，输出新视频）

| # | 模式 | 说明 | 引擎效果 |
|---|---|---|---|
| 4 | **离线补帧** | 补帧输出新视频，分辨率不变 | `VTFrameRateConversionConfiguration` / CoreML 补帧 |
| 5 | **离线超分** | 超分放大输出新视频，不补帧 | `VTSuperResolutionScalerConfiguration` / CoreML 超分 |

> 离线链路细节：AVAssetReader 读帧 → AI 引擎处理 → AVAssetWriter（H.264）编码输出；
> 异步任务队列、可取消、分批分帧防 OOM、输出帧按目标帧率统一重排时间戳、可选复制音频、完成后可保存相册。

---

## 3. 双引擎架构与切换

```
┌──────────────┐   ┌──────────────┐
│  UI (SwiftUI) │   │  Liquid Glass │
└──────┬───────┘   └──────────────┘
       ▼
┌──────────────────────────────────────┐
│  ViewModel（Main / Realtime / Offline）│
└──────────────────┬───────────────────┘
                   ▼
┌──────────────────────────────────────┐
│  Service（Camera / RealtimePipeline / │
│  OfflinePipeline / PhotoLibrary ...）│
└──────────────────┬───────────────────┘
                   ▼
┌─────────────────────────────────────────────────────────┐
│  protocol AIFrameProcessingEngine（统一抽象协议）            │
│  prepare / start / stop / process / downloadModel        │
└───────────┬─────────────────────────┬───────────────────┘
            ▼                         ▼
┌──────────────────┐   ┌──────────────────────────────┐
│ VTFrameProcessor  │   │ CoreMLFrameProcessingEngine │
│ Engine（iOS26+）  │   │ （用户导入 mlpackage）         │
│ VideoToolbox 原生  │   │ CoreML + MPS                 │
└──────────────────┘   └──────────────────────────────┘
```

- **UI 不直接调用推理**：一律 UI → ViewModel → Service → Engine。
- 引擎切换控件位于「实时」「离线」两个页面的顶部（分段选择器）。
- 系统引擎在硬件不支持时**按钮置灰**并弹出友好提示（`isSupported` 运行时检测）。
- CoreML 引擎在缺少对应模型时提示去「设置」导入。

---

## 4. VTFrameProcessor 硬件 / 系统要求

系统引擎基于 iOS 26 引入的 VideoToolbox `VTFrameProcessor` 体系（WWDC25 Session 300
「Enhance your app with machine learning-based video effects」）。要求：

- **系统版本**：iOS 26.0 及以上（工程部署目标即 26.0；iOS 27 完整兼容，无已废弃 API）。
- **硬件**：`VTFrameProcessor` 使用 Apple 神经引擎 / GPU 内置权重，需设备支持对应能力。运行时通过
  `VTLowLatencyFrameInterpolationConfiguration.isSupported`、
  `VTLowLatencySuperResolutionScalerConfiguration.isSupported`、
  `VTSuperResolutionScalerConfiguration.isSupported` 等**运行时能力检测**判断；
  不支持时 App 会禁用对应模式按钮并提示原因。
- **系统模型下载**：离线高质量 `VTSuperResolutionScalerConfiguration` 可能需要在系统层面按需下载 AI 权重。
  App 在 `startSession` 前检查 `configurationModelStatus`（`downloadRequired` / `downloading` / `ready`），
  通过 `downloadConfigurationModel(completionHandler:)` 驱动下载，并用
  `configurationModelPercentageAvailable` 展示进度（见 `VTFrameProcessorSession.ensureModelAvailable`）。
- **实时低延迟配置**（`VTLowLatencyXXX`）的系统权重随系统预置，无需额外下载。
- 建议真机运行；模拟器上 `isSupported` 通常为 `false`，属于预期行为。

> 工程会在会话启动阶段做能力检测，若设备不支持会以 `AppError.engineUnsupported` 上报，
> UI 层弹出友好提示并置灰按钮。

---

## 5. 用户 mlpackage 模型张量规格要求

用户导入 CoreML 引擎（`CoreMLImportEngine`）需要用户通过「设置 → CoreML 模型管理」导入
**补帧** 与 **超分** 两类 `.mlpackage`（CoreML 编译产物目录）。模型不打包内置，仅存 App 沙盒
`Documents/ImportedModels/`，导入时自动做张量维度校验（`CoreMLModelValidator`）。

### 统一约定

| 维度 | 说明 |
|---|---|
| 输入/输出类型 | 图像（`MLImageConstraint`）或张量（`MLMultiArray`）均可 |
| 张量布局 | 支持 `NCHW [1,3,H,W]` / `NHWC [1,H,W,3]` / `CHW` / `HWC`（自动识别） |
| 像素格式 | 图像输入建议 BGRA / RGB；张量输入由引擎统一转换为 `float32 RGB [0,1]` |
| 数据格式 | 张量 `float32` |

### 补帧模型（frameInterpolation）

- **输入**：2 个图像/张量输入（相邻两帧 frameA / frameB，命名不限，引擎取前两个），两帧尺寸一致；
  - 可选：1 个标量输入（`double`，名字含 `timestep` / `phase` / `t` 等），取值 `[0,1]`，用于倍率可调；
- **输出**：1 个图像/张量输出，分辨率与输入一致（`frameA` 与 `frameB` 之间的插值帧）；
- 示例：`[frameA: [1,3,256,256]] + [frameB: [1,3,256,256]] (+[timestep: double]) → [output: [1,3,256,256]]`。

### 超分模型（superResolution）

- **输入**：1 个图像/张量输入；
- **输出**：1 个图像/张量输出，**输出尺寸必须大于输入尺寸**（校验不通过会回滚删除并提示）；
- 示例：`[input: [1,3,256,256]] → [output: [1,3,512,512]]`（2x）。

> 推荐使用**固定输入尺寸**的模型以获得确定性（运行时引擎会先把帧 vImage 缩放到模型输入尺寸再推理，
> 固定尺寸可避免每帧重复分配）。动态尺寸模型也能通过宽松校验，但性能与内存波动更大。

---

## 6. 工程目录结构

```
FrameFlowAI/
├── FrameFlowAI.xcodeproj/          # Xcode 工程（objectVersion 77，同步组自动纳源）
├── FrameFlowAI/
│   ├── App/
│   │   ├── FrameFlowAIApp.swift    # @main 入口 + Liquid Glass 衬底渐变
│   │   └── Info.plist              # 隐私权限键（相机/相册读/相册写）
│   ├── Assets.xcassets/            # 资源（AccentColor / AppIcon）
│   ├── Models/                     # 纯数据模型
│   │   ├── EngineKind.swift        # 双引擎枚举
│   │   ├── ProcessingMode.swift    # 5 种业务模式
│   │   ├── EngineCapability.swift  # 引擎×模式可用性
│   │   ├── EngineConfiguration.swift
│   │   ├── EngineModelStatus.swift
│   │   ├── EngineState.swift
│   │   ├── OfflineJob.swift        # 离线任务状态机
│   │   └── CoreMLModelInfo.swift
│   ├── AIEngines/                  # 双 AI 引擎（分层核心）
│   │   ├── AIFrameProcessingEngine.swift   # 统一抽象协议
│   │   ├── EngineFactory.swift             # 引擎工厂
│   │   ├── VTFrameProcessorEngine/         # 系统引擎（iOS26+）
│   │   │   ├── VTFrameProcessorConfigFactory.swift
│   │   │   ├── VTFrameProcessorSession.swift
│   │   │   └── VTFrameProcessorEngine.swift
│   │   └── CoreMLImportEngine/             # 用户导入引擎
│   │       ├── CoreMLFrameProcessingEngine.swift
│   │       ├── CoreMLInferenceStage.swift
│   │       ├── CoreMLModelStore.swift
│   │       ├── CoreMLModelValidator.swift
│   │       └── CoreMLPixelBufferUtility.swift
│   ├── Services/                   # 媒体服务层
│   │   ├── CameraService.swift     # AVCaptureSession
│   │   ├── RealtimePipelineService.swift
│   │   ├── OfflinePipelineService.swift    # AVAssetReader/Writer
│   │   ├── PerformanceMonitor.swift
│   │   ├── PhotoLibraryService.swift
│   │   └── VideoImportService.swift
│   ├── ViewModels/                 # ViewModel 层
│   │   ├── MainViewModel.swift
│   │   ├── RealtimeViewModel.swift
│   │   ├── OfflineViewModel.swift
│   │   └── PlayerViewModel.swift
│   ├── Views/                      # SwiftUI Liquid Glass UI
│   │   ├── MainView.swift
│   │   ├── Components/             # 玻璃组件 / 预览包装
│   │   ├── Realtime/               # 实时页
│   │   ├── Offline/                # 离线页
│   │   ├── Player/                 # 自定义 AVPlayer 播放器
│   │   └── Settings/               # 设置 / 模型导入
│   └── Utilities/                  # 错误 / 日志 / 系统指标
├── docs/                           # 架构框图 / 数据流 / 性能说明
├── .github/workflows/build.yml     # GitHub Actions 在线编译
├── README.md
└── .gitignore
```

---

## 7. 编译步骤

### 7.1 本地编译（需要 Mac）

1. **环境**：macOS 26（Xcode 26 / 27）+ Xcode 最新版（需含 iOS 26 SDK）。
2. **打开工程**：双击 `FrameFlowAI.xcodeproj`（或 `open FrameFlowAI.xcodeproj`）。
3. **签名**：Target → Signing & Capabilities，选择你的 Team（`DEVELOPMENT_TEAM` 已留空）。
4. **部署目标**：已设为 iOS 26.0（Target 与 Project 的 `IPHONEOS_DEPLOYMENT_TARGET = 26.0`）；
   纯 iOS（`SUPPORTS_MACCATALYST = NO`，`SUPPORTED_PLATFORMS = iphoneos iphonesimulator`）。
5. **运行**：选一台 **iOS 26+ 真机**（系统 VT 引擎需要真机神经引擎；CoreML 引擎模拟器可编译但推理受限）。
6. **无第三方依赖**：无需 `pod install` / SPM，工程零外部依赖，直接 ⌘R 即可。

> 若你的 SDK 中 `VTFrameRateConversionConfiguration` 的属性名与本工程假设
> （`sourceFrameRate` / `conversionFrameRate`）不同，只需修改
> `AIEngines/VTFrameProcessorEngine/VTFrameProcessorConfigFactory.swift` 的
> `makeConfiguration` 中 `highQualityFrameRateConversion` 分支一处。
> （该配置类的公开文档页在编写时不可访问，属性名依据 WWDC25 Session 300 示例编写。）

### 7.2 直接用 GitHub 在线编译（无需本地 Mac）

仓库已内置 CI（`.github/workflows/build.yml`）：每次 push 到 `main`（或手动触发）都会在
GitHub 托管的 **`macos-26`** 运行器上用 **Xcode 26** 直接编译本项目。

- **编译命令**（与 CI 相同，Mac 上亦可本地执行）：
  ```
  xcodebuild -project FrameFlowAI.xcodeproj -scheme FrameFlowAI \
    -configuration Debug -destination 'generic/platform=iOS' \
    -derivedDataPath DerivedData \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
  ```
- **查看结果**：仓库 → **Actions** 页签 → 「Build iOS」工作流；绿色通过 / 红色失败，点进 job 看日志。
- **下载产物**：运行成功后 job 底部可下载 `FrameFlowAI-debug.app`。
- **注意事项**：
  - 必须用 `macos-26` 镜像（内置 Xcode 26）；`macos-latest` 目前解析到 macos-15 / Xcode 16.4，
    无法编译 iOS 26 SDK API；
  - 编译**无需签名**（`CODE_SIGNING_ALLOWED=NO`），产物为未签名的 Debug .app，仅用于编译验证，
    不可直接装真机；若要装真机 / 上架，仍需在本地或 CI 配置证书签名；
  - 免费分钟数：**公开仓库**的 macOS 运行器免费；**私有仓库**需付费计划（macOS 分钟数计费）。
  - 若某次编译失败，日志中第一个 `error:` 即为需修正的 API / 语法问题。

---

## 8. 使用教程

### 实时模式
1. 进入「实时」页；
2. 顶部切换引擎（系统引擎 / CoreML）；选择一种实时模式；
3. 首次使用会请求相机权限；点击「启动实时预览」；
4. 画面上叠加 FPS / 端到端延迟 / 引擎指标；点击「停止」结束。

### 离线模式
1. 进入「离线」页，选择引擎与模式（离线补帧 / 离线超分）；
2. 点击「选择视频文件」，从系统文件选择器选一个本地视频（自动复制到沙盒并显示分辨率/帧率/时长）；
3. 点击「开始处理」，任务进入队列（显示进度条，可「取消」）；
4. 完成后可「预览」（自定义 AVPlayer）或「保存相册」。

### 自定义播放器（离线预览）
- **拖拽进度条**：按住滑块左右拖动，实时预览时间点，松手跳转；
- **点击画面**：显示 / 隐藏液态玻璃控制面板；
- **长按画面**：临时 3x 加速，松手恢复所选倍速；
- **倍速档位**：0.5x / 1.0x / 1.5x / 2.0x。

### 导入 CoreML 模型
1. 进入「设置 → CoreML 模型管理」；
2. 分别导入「补帧模型」与「超分模型」的 `.mlpackage`（系统文件选择器选目录）；
3. 导入时自动校验张量维度（不通过会回滚并提示）；
4. 回到实时 / 离线页切换到 CoreML 引擎即可使用。

---

## 9. 已知性能限制

- **VTFrameProcessor 仅 iOS 26+**：iOS 26 以下无法使用系统引擎（部署目标已限制为 26.0）；模拟器上
  `isSupported` 通常为 `false`，属预期。
- **实时链路有背压**：为控制端到端延迟，处理队列不做积压，上一帧未完成时丢弃新帧；
  帧率上限受单帧推理耗时限制（低延迟 VT 配置比 CoreML 通用模型更快）。
- **系统模型下载**：离线高质量超分首次启动可能触发系统权重下载，受网络影响；下载前会给出状态提示。
- **CoreML 模型质量取决于导入的模型**：App 只做张量规格校验，不做模型精度/速度担保；
  固定输入尺寸、int8/FP16 量化的模型推理更快。
- **内存**：离线处理为逐帧串行 + 每帧局部作用域回收，但极长/超高分辨率视频仍可能占用较多内存；
  建议 4K 以下源视频。
- **音频**：离线链路复制原音频轨；补帧后视频帧率变高但时长不变，音频保持同步。
- **ANE/GPU 优化与延迟控制**的详细说明见 `docs/性能说明.md`。

---

## 10. 隐私与合规

- 相机 / 相册 / 文件权限声明见 `FrameFlowAI/App/Info.plist`：
  - `NSCameraUsageDescription`（实时模式采集）
  - `NSPhotoLibraryUsageDescription`（从相册选择视频）
  - `NSPhotoLibraryAddUsageDescription`（保存输出）
- 所有处理均在设备本地完成，画面、视频、模型数据**不会上传**。
- 本工程仅使用 Apple 公开 API，无私有 API、无 FFmpeg、无第三方推理运行时、无第三方 UI 库。

---

## License

仅供学习与评估。使用前请确认所用模型与素材的授权合规。
