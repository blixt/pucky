import SwiftUI

@main
struct PuckyApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isModelLoaded {
                    MainNavigationView()
                        .transition(.opacity)
                } else {
                    OnboardingView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: appState.isModelLoaded)
            .environment(appState)
            .preferredColorScheme(.dark)
            .task {
                await appState.initialize()
            }
        }
    }
}
