import Foundation

/// Something wrong with Dee's ears or voice that the person in front of her must be
/// able to see (audit C11). Before, a denied permission, a speech model still
/// downloading or a failing recognizer only reached the hidden debug transcript:
/// the phone looked like it was listening, and it was not.
public enum VoiceProblem: Sendable, Equatable {
    /// Microphone permission is off: she cannot hear at all.
    case microphoneOff
    /// Speech-recognition permission is off: she hears sounds, not words.
    case speechRecognitionOff
    /// Her ears are still starting (first launch: the speech model is downloading).
    case preparingEars
    /// Speech recognition failed and is retrying.
    case earsUnavailable(String)
    /// This device has no on-device speech recognition for her language; retrying
    /// will not help.
    case speechUnsupported(String)
    /// The audio session or engine failed and is retrying.
    case audioUnavailable(String)
    /// The cloud voice (realtime speech) can't be reached; it keeps retrying.
    case cloudVoiceUnavailable(String)
    /// The cloud voice refuses the app (no key, or the key was rejected).
    case cloudVoiceNeedsSetup(String)

    /// One short line for the screen.
    public var message: String {
        switch self {
        case .microphoneOff: "I can't hear you. Turn on the microphone in Settings › Dee."
        case .speechRecognitionOff: "I can't understand words. Turn on Speech Recognition in Settings › Dee."
        case .preparingEars: "Getting my ears ready…"
        case .earsUnavailable: "My ears stopped working. Trying again…"
        case .speechUnsupported: "I can't understand words on this device."
        case .audioUnavailable: "My microphone or speaker isn't working. Trying again…"
        case .cloudVoiceUnavailable: "I can't reach my voice service. Trying again…"
        case .cloudVoiceNeedsSetup: "My voice service needs a valid key in Settings › Dee."
        }
    }

    /// An SF Symbol for the problem.
    public var symbol: String {
        switch self {
        case .microphoneOff: "mic.slash.fill"
        case .speechRecognitionOff, .earsUnavailable, .speechUnsupported: "ear.trianglebadge.exclamationmark"
        case .preparingEars: "ear.badge.waveform"
        case .audioUnavailable: "speaker.slash.fill"
        case .cloudVoiceUnavailable, .cloudVoiceNeedsSetup: "icloud.slash"
        }
    }

    /// Needs the user to change a setting (it will not fix itself).
    public var needsUser: Bool {
        switch self {
        case .microphoneOff, .speechRecognitionOff, .cloudVoiceNeedsSetup: true
        default: false
        }
    }
}

/// Folds the voice service's events into the one problem to show, if any.
///
/// Fed by the app from `VoiceEvent`s (strings in, so DeeCore stays independent of
/// DeeVoice): `.permission`, `.ready`, `.listening`, any heard words, and `.error`
/// messages. Error messages are classified by their stable prefixes (see
/// `classify`); unknown messages are diagnostics only and never shown.
public struct VoiceHealth: Sendable, Equatable {
    /// How long ears may take to open after the voice is ready before the user is
    /// told they are still starting (the first launch downloads a speech model).
    public static let preparingAfter: TimeInterval = 4

    public private(set) var microphone = true
    public private(set) var speech = true
    /// When listening was first wanted with the voice ready (nil: not yet).
    public private(set) var waitingForEarsSince: Date?
    /// Ears have opened at least once (recognizer running).
    public private(set) var earsOpened = false
    public private(set) var failure: VoiceProblem?
    /// The cloud voice's problem, if any (`cloudVoice(_:)`).
    public private(set) var cloudFailure: VoiceProblem?
    /// Her ears are on-device speech recognition. False while the cloud voice hears
    /// for her: speech-recognition permission, recognizer failures and the speech
    /// model download then don't stop her understanding, and are not shown.
    public var onDeviceSpeech = true

    public init() {}

    public mutating func permission(microphone: Bool, speech: Bool) {
        self.microphone = microphone
        self.speech = speech
    }

    /// The voice is up and the app wants it to listen (call when both become true;
    /// pass nil when listening is no longer wanted).
    public mutating func listeningWanted(since: Date?) {
        guard !earsOpened else { return }
        waitingForEarsSince = since
    }

    /// Recognition opened, or words arrived: the ears work.
    public mutating func earsWorking() {
        earsOpened = true
        waitingForEarsSince = nil
        switch failure {
        case .earsUnavailable?, .speechUnsupported?, .audioUnavailable?: failure = nil
        default: break
        }
    }

    /// Dee's own voice played: the audio engine works.
    public mutating func audioWorking() {
        if case .audioUnavailable = failure { failure = nil }
    }

    /// An error message from the voice service. Returns whether it is shown.
    @discardableResult
    public mutating func error(_ message: String) -> Bool {
        guard let problem = Self.classify(message) else { return false }
        if problem == .microphoneOff { microphone = false; return true }
        failure = problem
        return true
    }

    /// The cloud voice's state from its owner: nil when it works (connected,
    /// hearing), else `.cloudVoiceUnavailable` or `.cloudVoiceNeedsSetup`. Other
    /// problems are ignored.
    public mutating func cloudVoice(_ problem: VoiceProblem?) {
        switch problem {
        case .cloudVoiceUnavailable?, .cloudVoiceNeedsSetup?, nil: cloudFailure = problem
        default: break
        }
    }

    /// The problem to show now, most fundamental first.
    public func problem(at now: Date) -> VoiceProblem? {
        if !microphone { return .microphoneOff }
        if onDeviceSpeech, !speech { return .speechRecognitionOff }
        if let cloudFailure { return cloudFailure }
        if let failure {
            switch failure {
            case .earsUnavailable, .speechUnsupported: if onDeviceSpeech { return failure }
            default: return failure
            }
        }
        if onDeviceSpeech, let since = waitingForEarsSince, now.timeIntervalSince(since) >= Self.preparingAfter { return .preparingEars }
        return nil
    }

    /// The problem an error message describes, or nil for diagnostics (a sound
    /// classifier hiccup, a voice that wasn't ready for one line).
    /// Texts of the recognizer failures the voice does not retry
    /// (`SpeechInput.Failure.isPermanent`).
    static let permanentSpeechFailures = ["isn't available on this device", "No supported English speech model"]

    public static func classify(_ message: String) -> VoiceProblem? {
        if message.hasPrefix("Missing NSMicrophoneUsageDescription") { return .microphoneOff }
        if message.hasPrefix("Speech recognition unavailable") || message.hasPrefix("Speech recognition stopped") {
            // The voice reports these two without retrying (no model for this device
            // or language): saying "trying again" would be a lie.
            if permanentSpeechFailures.contains(where: message.contains) { return .speechUnsupported(message) }
            return .earsUnavailable(message)
        }
        if message.hasPrefix("Audio session unavailable") || message.hasPrefix("Audio engine failed")
            || message.hasPrefix("Audio engine couldn't restart") {
            return .audioUnavailable(message)
        }
        return nil
    }
}
