import SwiftUI

/// App 主界面：三个 Tab（实时 / 离线 / 设置），Liquid Glass 风格。
struct MainView: View {

    @StateObject private var mainViewModel = MainViewModel()
    @StateObject private var realtimeViewModel = RealtimeViewModel()
    @StateObject private var offlineViewModel = OfflineViewModel()

    var body: some View {
        TabView {
            RealtimeView(mainViewModel: mainViewModel, realtimeViewModel: realtimeViewModel)
                .tabItem { Label("实时", systemImage: "video.fill") }

            OfflineView(mainViewModel: mainViewModel, offlineViewModel: offlineViewModel)
                .tabItem { Label("离线", systemImage: "film.stack.fill") }

            SettingsView(mainViewModel: mainViewModel)
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .tint(.orange)
    }
}

#Preview {
    MainView()
}
