import SwiftUI

@main
struct DeeApp: App {
    @State private var model = DeeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Time away counts as the user being absent; age options live in the
                    // Settings app, so pick up changes on return.
                    if phase == .active || phase == .background {
                        Task { await model.sceneBecame(active: phase == .active) }
                    }
                }
        }
    }
}
