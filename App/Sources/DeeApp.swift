import SwiftUI

@main
struct DeeApp: App {
    @State private var model = DeeModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task { await model.loadIfNeeded() }
        }
    }
}
