import SwiftUI

@main
struct DeeApp: App {
    @State private var model = DeeModel()
    @State private var splashDone = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                if splashDone {
                    RootView()
                        .environment(model)
                        .transition(.opacity)
                        // Dee wakes only after the splash, so her audio session and the
                        // permission prompts never land on top of it.
                        .task { await model.start() }
                } else {
                    SplashView { withAnimation(.easeInOut(duration: 0.6)) { splashDone = true } }
                        .transition(.opacity)
                }
            }
            .background(Color.black)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                // Time away counts as the user being absent; age options live in the
                // Settings app, so pick up changes on return.
                if splashDone, phase == .active || phase == .background {
                    Task { await model.sceneBecame(active: phase == .active) }
                }
            }
        }
    }
}
