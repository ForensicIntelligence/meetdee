import DeeBrain
import DeeCore
import DeeRealtime
import SwiftUI

/// Splash → onboarding (first launch, or until a provider is set up) → Dee.
///
/// Nothing uses the microphone, camera or network before `.dee`: the old Settings.bundle
/// key is migrated to the Keychain with no network call before onboarding shows, and
/// `model.start()` runs only in `.dee`.
@main
struct DeeApp: App {
    enum Phase: Equatable { case splash, onboarding, dee }

    @State private var model = DeeModel()
    @State private var store = ProviderStore()
    @State private var phase: Phase = .splash
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let prefs = DeePrefs()
        // K1: before anything else (no network).
        prefs.migrate(intake: KeyIntake(keyStore: KeychainSecrets().store(account: KeyStore.defaultAccount)))
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-DeeResetOnboarding") { prefs.onboardingVersion = 0 }
        if args.contains("-DeeSkipOnboarding") {
            if prefs.providerConfig == nil { prefs.providerConfig = .openAI() }
            prefs.onboardingVersion = OnboardingFlow.version
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                switch phase {
                case .splash:
                    SplashView {
                        store.reload()
                        withAnimation(.easeInOut(duration: 0.6)) { phase = store.prefs.needsOnboarding ? .onboarding : .dee }
                    }
                    .transition(.opacity)
                case .onboarding:
                    OnboardingView(store: store, startAt: store.prefs.providerConfig == nil || store.prefs.onboardingVersion == 0 ? .meet : .provider) {
                        withAnimation(.easeInOut(duration: 0.5)) { phase = .dee }
                        Task { await model.settingsChanged() }
                    }
                    .transition(.opacity)
                case .dee:
                    RootView(store: store) {
                        store.reload()
                        withAnimation { phase = .onboarding }
                        Task { await model.leaveForOnboarding() }
                    }
                    .environment(model)
                    .transition(.opacity)
                    // Dee wakes only after the splash and onboarding, so her audio session
                    // and permission prompts never land on top of them.
                    .task { await model.start() }
                }
            }
            .background(Color.black)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, p in
                // Time away counts as the user being absent.
                if phase == .dee, p == .active || p == .background {
                    Task { await model.sceneBecame(active: p == .active) }
                }
            }
        }
    }
}
