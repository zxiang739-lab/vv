import SwiftUI

/// FrameFlowAI 应用入口
///
/// - 最低部署版本：iOS 26.0（VTFrameProcessor 体系 API 起点）
/// - 同时完整兼容 iOS 27（全部 API 均为 iOS 26 引入且未废弃，无已废弃 API）
/// - 纯 iOS App（不支持 macOS / Catalyst，见工程 build settings）
/// - UI 全部使用 SwiftUI 原生 Liquid Glass（`.glassBackgroundEffect()`），无任何第三方 UI 库
@main
struct FrameFlowAIApp: App {

    var body: some Scene {
        WindowGroup {
            MainView()
                .background {
                    LiquidGlassBackground()
                        .ignoresSafeArea()
                }
                .preferredColorScheme(.dark)
        }
    }
}

/// 全屏液态玻璃衬底渐变。
/// 深色 + 微光渐变可以让 `.glassBackgroundEffect()` 的折射、高光更加明显，
/// 符合 iOS 26 Liquid Glass 的最佳呈现条件。
struct LiquidGlassBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.10, blue: 0.16),
                Color(red: 0.12, green: 0.13, blue: 0.22),
                Color(red: 0.05, green: 0.08, blue: 0.14)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
