import Foundation

/// The first-launch onboarding pages (providers-wake-onboarding §5). Pure; the app's
/// `OnboardingView` renders `OnboardingFlow.step` and calls `next/back/skip`.
public enum OnboardingStep: String, CaseIterable, Sendable, Codable {
    /// What Dee is: a little robot with eyes who talks, listens, has moods and memories.
    case meet
    /// The wake phrase, "go to sleep", interrupting, "keep going", keep the app open.
    case talking
    /// What she sees: presence, faces — all on the phone.
    case seeing
    /// What is sent where for each mode, and what it costs.
    case privacy
    case micPermission, speechPermission, cameraPermission, localNetworkPermission
    /// Mode choice, key / server entry, Test connection.
    case provider
    case wakePhrase, voice, speakFirst
    case done

    public var permission: PermissionKind? {
        switch self {
        case .micPermission: .microphone
        case .speechPermission: .speech
        case .cameraPermission: .camera
        case .localNetworkPermission: .localNetwork
        default: nil
        }
    }
}

public enum PermissionKind: String, CaseIterable, Sendable, Codable {
    case microphone, speech, camera, localNetwork

    public var step: OnboardingStep {
        switch self {
        case .microphone: .micPermission
        case .speech: .speechPermission
        case .camera: .cameraPermission
        case .localNetwork: .localNetworkPermission
        }
    }
}

public enum PermissionState: String, Sendable, Codable { case undetermined, granted, denied }

/// Step order, skip and finish rules.
///
/// - Explainers and permission cards come first; **Skip** (only offered before the
///   provider step) jumps straight to the provider — Dee can't work without one.
/// - The speech card shows only if the device needs it (`speechCardNeeded`); the
///   local-network card is offered before the provider (it explains the home-server
///   option) and again after it when the chosen mode needs the LAN.
/// - After provider → wake phrase → voice → speak first, every permission card still
///   undetermined is shown once more, then Done.
/// - Done (`canFinish`) needs a ready provider (`ProviderConfig.validate()` empty and
///   every tested part OK — the app computes `providerReady`).
public struct OnboardingFlow: Sendable, Equatable {
    /// Stored in prefs "onboardingVersion"; a smaller stored value re-shows onboarding.
    public static let version = 1
    public static let versionKey = "onboardingVersion"

    public private(set) var step: OnboardingStep
    public var permissions: [PermissionKind: PermissionState]
    public var speechCardNeeded: Bool
    /// The chosen mode uses a LAN server (modes 2 and 3).
    public var localNetworkNeeded: Bool
    public var providerReady: Bool
    private var history: [OnboardingStep] = []
    private var revisited: Set<PermissionKind> = []

    public init(step: OnboardingStep = .meet, permissions: [PermissionKind: PermissionState] = [:],
                speechCardNeeded: Bool = true, localNetworkNeeded: Bool = false, providerReady: Bool = false) {
        self.step = step
        self.permissions = permissions
        self.speechCardNeeded = speechCardNeeded
        self.localNetworkNeeded = localNetworkNeeded
        self.providerReady = providerReady
    }

    public func state(_ p: PermissionKind) -> PermissionState { permissions[p] ?? .undetermined }

    /// The pages before the provider step, for the current flags.
    public var introSteps: [OnboardingStep] {
        var s: [OnboardingStep] = [.meet, .talking, .seeing, .privacy, .micPermission]
        if speechCardNeeded { s.append(.speechPermission) }
        s += [.cameraPermission, .localNetworkPermission]
        return s
    }

    public static let setupSteps: [OnboardingStep] = [.provider, .wakePhrase, .voice, .speakFirst]

    /// Permission cards still to show after the setup steps.
    public var pendingPermissions: [PermissionKind] {
        PermissionKind.allCases.filter { p in
            guard state(p) == .undetermined, !revisited.contains(p) else { return false }
            switch p {
            case .speech: return speechCardNeeded
            case .localNetwork: return localNetworkNeeded
            default: return true
            }
        }
    }

    /// True once the provider step has been reached (the setup half of the flow).
    public var pastProvider: Bool { step == .provider || history.contains(.provider) }
    public var isIntro: Bool { !pastProvider && step != .done }
    public var canSkip: Bool { isIntro }
    public var canBack: Bool { !history.isEmpty }
    public var canFinish: Bool { step == .done && providerReady }

    public mutating func next() {
        guard step != .done else { return }
        let from = step
        history.append(from)
        step = following(from)
        if let p = step.permission, pastProvider { revisited.insert(p) }
    }

    public mutating func back() {
        guard let previous = history.popLast() else { return }
        if let p = step.permission, history.contains(.provider) || previous == .provider { revisited.remove(p) }
        step = previous
    }

    /// Skip the explainers and permission cards: go to the provider step.
    public mutating func skip() {
        guard canSkip else { return }
        history.append(step)
        step = .provider
    }

    /// Re-run from the start (settings › "Run onboarding again").
    public mutating func restart() {
        history = []
        revisited = []
        step = .meet
    }

    /// `history` already ends with `s`.
    private func following(_ s: OnboardingStep) -> OnboardingStep {
        if !history.contains(.provider), let i = introSteps.firstIndex(of: s) {
            return i + 1 < introSteps.count ? introSteps[i + 1] : .provider
        }
        if let i = Self.setupSteps.firstIndex(of: s), i + 1 < Self.setupSteps.count { return Self.setupSteps[i + 1] }
        // After speak-first, or a revisited card: the next pending card, then Done.
        return pendingPermissions.first { $0.step != s }?.step ?? .done
    }
}
