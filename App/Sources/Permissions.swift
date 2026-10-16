import AVFoundation
import DeeCore
import Foundation
import Network
import Speech

/// The four permission cards of onboarding (providers-wake-onboarding §5). Each card
/// explains first; only its "Allow" button asks iOS. Nothing here touches the network
/// except the Local Network card, which sends one Bonjour browse on the LAN to make iOS
/// show its prompt (no data leaves the phone's network).
@MainActor
enum Permissions {
    static func state(_ kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .undetermined
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .undetermined
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .undetermined
            }
        case .localNetwork:
            // iOS has no query for it: remembered after the card ran its browse.
            return LocalNetworkPrompt.answered ? .granted : .undetermined
        }
    }

    static var all: [PermissionKind: PermissionState] {
        Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, state($0)) })
    }

    /// Asks iOS (only from the card's "Allow" button).
    static func request(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .microphone:
            _ = await AVAudioApplication.requestRecordPermission()
        case .speech:
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in c.resume() }
            }
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .localNetwork:
            await LocalNetworkPrompt.trigger()
        }
        return state(kind)
    }

    static func card(_ kind: PermissionKind) -> (title: String, symbol: String, body: String) {
        switch kind {
        case .microphone:
            ("Her ears", "mic.fill",
             "Dee listens for her wake phrase right here on your iPhone — that never leaves the phone. Only after she wakes does what she hears go to the AI you choose, until the conversation ends.")
        case .speech:
            ("Hearing her name", "waveform.badge.mic",
             "Apple's speech recognition, running on this iPhone, is how Dee notices her wake phrase. Nothing is sent anywhere to listen for it.")
        case .camera:
            ("Her eyes", "camera.fill",
             "Dee looks at you and the things around her: her eyes follow your face and she recognises friends. Video stays on this iPhone — never recorded, never sent.")
        case .localNetwork:
            ("Your home network", "wifi",
             "If you run an AI on your own Mac or server, Dee needs to reach it on your Wi-Fi. She only ever talks to the address you give her. Using OpenAI only? You can skip this.")
        }
    }
}

/// Triggers the Local Network prompt with a short Bonjour browse (NSBonjourServices
/// lists `_http._tcp`), and remembers that the card ran.
@MainActor
enum LocalNetworkPrompt {
    static let answeredKey = "localNetworkPrompted"
    static var answered: Bool { UserDefaults.standard.bool(forKey: answeredKey) }

    static func trigger() async {
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .waiting:
                    if once.take() { c.resume() }
                default:
                    break
                }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if once.take() { c.resume() } }
        }
        browser.cancel()
        UserDefaults.standard.set(true, forKey: answeredKey)
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
