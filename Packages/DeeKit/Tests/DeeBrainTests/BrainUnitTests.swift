import DeeCore
import DeeMemory
import DeeRealtime
@testable import DeeSelf
import Foundation
import Synchronization
import Testing
@testable import DeeBrain

@Suite struct TurnPolicyTests {
    @Test func fastByDefaultExactWhenTheWordsMatter() {
        let base = TurnPolicy.Context(signals: CueModeSignals(turnsThisConversation: 3))
        #expect(TurnPolicy.onCommit(base) == .respondFast)

        var c = base
        c.signals.repair = .ruptured
        #expect(TurnPolicy.onCommit(c) == .waitForWords, "repair")
        c = base
        c.prosody = ProsodyRead(loudness: 0.6)
        #expect(TurnPolicy.onCommit(c) == .waitForWords, "loud")
        c = base
        c.prosody = ProsodyRead(intensity: 0.7)
        #expect(TurnPolicy.onCommit(c) == .waitForWords, "intense")
        c = base
        c.previousNotes = [.followUp]
        #expect(TurnPolicy.onCommit(c) == .waitForWords, "a follow-up was asked")
        c = base
        c.previousNotes = [.deixisAmbiguous]
        #expect(TurnPolicy.onCommit(c) == .waitForWords, "ambiguous pointing")
        c = base
        c.signals.statedHypothesis = true
        #expect(TurnPolicy.onCommit(c) == .waitForWords)
        c = base
        c.signals.distressLive = true
        #expect(TurnPolicy.onCommit(c) == .waitForWords)
        c = base
        c.signals.unidentifiedSpeaker = true
        #expect(TurnPolicy.onCommit(c) == .respondFast, "a stranger after the first turn")
        c.signals.turnsThisConversation = 0
        #expect(TurnPolicy.onCommit(c) == .waitForWords, "a stranger's first turn (name)")
        c = base
        c.sinceHerVoice = -0.5
        #expect(TurnPolicy.onCommit(c) == .waitForWords, "talked over her")
        c.sinceHerVoice = 0.2
        #expect(TurnPolicy.onCommit(c) == .waitForWords, "overlapping her echo tail")
        c.sinceHerVoice = 0.5
        #expect(TurnPolicy.onCommit(c) == .respondFast, "a quick answer (measured late) stays fast")
        c.sinceHerVoice = 2.0
        #expect(TurnPolicy.onCommit(c) == .respondFast, "ordinary turn-taking stays fast")
        c = base
        c.signals.repair = .ruptured
        c.answersOnCommit = false
        #expect(TurnPolicy.onCommit(c) == .waitForAddress, "asleep or not engaged wins")
    }

    @Test func initiativeGate() {
        #expect(TurnPolicy.initiativeAllowed(connected: true, userSpeaking: false, replyOutstanding: false, awaitingWords: false))
        #expect(!TurnPolicy.initiativeAllowed(connected: false, userSpeaking: false, replyOutstanding: false, awaitingWords: false))
        #expect(!TurnPolicy.initiativeAllowed(connected: true, userSpeaking: true, replyOutstanding: false, awaitingWords: false))
        #expect(!TurnPolicy.initiativeAllowed(connected: true, userSpeaking: false, replyOutstanding: true, awaitingWords: false))
        #expect(!TurnPolicy.initiativeAllowed(connected: true, userSpeaking: false, replyOutstanding: false, awaitingWords: true))
    }

    /// Rendered DNAs have no blank lines: the notes close section 7, right before "8 THIS TURN".
    @Test func extraNotesGoIntoSectionSevenWithoutBrackets() {
        let text = "DEE DNA v2\n7 RIGHT NOW\nSomeone is here.\n8 THIS TURN\nThey just spoke."
        let out = RealtimeBrain.insert(["(Their name is Maya. You will remember it.)", "[x]"], into: text)
        #expect(out == "DEE DNA v2\n7 RIGHT NOW\nSomeone is here.\nKeep in mind: Their name is Maya. You will remember it.\nKeep in mind: x\n8 THIS TURN\nThey just spoke.")
    }
}

@Suite struct CloudStatusTests {
    @Test func voiceProblemsMapToTheChip() {
        #expect(CloudStatus(nil) == nil)
        #expect(CloudStatus(.cloudVoiceNeedsSetup("No OpenAI key.")) == .noKey)
        #expect(CloudStatus(.cloudVoiceNeedsSetup("The OpenAI key was refused.")) == .badKey)
        #expect(CloudStatus(.cloudVoiceNeedsSetup("The OpenAI key was refused: invalid_api_key")) == .badKey)
        #expect(CloudStatus(.cloudVoiceUnavailable("Rate limited.")) == .rateLimited)
        #expect(CloudStatus(.cloudVoiceUnavailable("The OpenAI quota or spend limit was reached.")) == .quota)
        #expect(CloudStatus(.cloudVoiceUnavailable("Connection lost: network")) == .offline)
        #expect(CloudStatus(.cloudVoiceUnavailable("Couldn't connect: timeout")) == .offline)
        #expect(CloudStatus(.cloudVoiceUnavailable("Server error: http 503")) == .serverTrouble)
        let mic = CloudStatus(.microphoneOff)
        #expect(mic == .other(message: VoiceProblem.microphoneOff.message, symbol: VoiceProblem.microphoneOff.symbol))
        #expect(mic?.cloudOff == false)
        #expect(CloudStatus.noKey.message == "Add your OpenAI key in Settings › Dee")
        #expect(CloudStatus.noKey.needsUser && CloudStatus.badKey.needsUser && !CloudStatus.offline.needsUser)
        #expect(CloudStatus.offline.cloudOff)
    }

    /// CloudVoice's own problem texts (the strings the mapping relies on).
    @Test func cloudVoiceTextsMap() {
        let reasons: [(FallbackReason, CloudStatus)] = [
            (.noKey, .noKey), (.unauthorized, .badKey), (.rateLimited(retryAfter: 3), .rateLimited),
            (.quotaExceeded, .quota), (.socketLost(code: 1006, detail: "x"), .offline),
            (.connectFailed("timeout"), .offline), (.serverError("http 500"), .serverTrouble),
        ]
        for (reason, expected) in reasons {
            let problem = CloudVoiceProblemText.problem(for: reason)
            #expect(CloudStatus(problem) == expected, "\(reason)")
        }
    }
}

/// The texts CloudVoice.problem(for:) produces (it is internal to DeeVoice; mirrored
/// here so a wording change there shows up as a failing mapping).
enum CloudVoiceProblemText {
    static func problem(for reason: FallbackReason) -> VoiceProblem? {
        switch reason {
        case .noKey: .cloudVoiceNeedsSetup("No OpenAI key.")
        case .unauthorized: .cloudVoiceNeedsSetup("The OpenAI key was refused.")
        case .quotaExceeded: .cloudVoiceUnavailable("The OpenAI quota or spend limit was reached.")
        case .rateLimited: .cloudVoiceUnavailable("Rate limited.")
        case .socketLost(_, let d): .cloudVoiceUnavailable("Connection lost\(d.map { ": \($0)" } ?? ".")")
        case .connectFailed(let d): .cloudVoiceUnavailable("Couldn't connect: \(d)")
        case .serverError(let d): .cloudVoiceUnavailable("Server error\(d.map { ": \($0)" } ?? ".")")
        case .noResponse, .congested: nil
        }
    }
}

@Suite struct KeyIntakeTests {
    static func defaults() -> UserDefaults {
        let name = "dee.brain.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    final class Seen: @unchecked Sendable {
        private let m = Mutex<[URLRequest]>([])
        func add(_ r: URLRequest) { m.withLock { $0.append(r) } }
        var all: [URLRequest] { m.withLock { $0 } }
    }

    static func intake(status: Int?, seen: Seen) -> KeyIntake {
        KeyIntake(keyStore: KeyStore(storage: MemorySecretStorage())) { request in
            seen.add(request)
            guard let status else { throw URLError(.notConnectedToInternet) }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func aGoodKeyIsValidatedStoredAndClearedFromSettings() async throws {
        let seen = Seen()
        let intake = Self.intake(status: 200, seen: seen)
        let d = Self.defaults()
        d.set("  sk-proj-abc123def456ghi789  \n", forKey: CloudSettings.Key.apiKey)
        let outcome = await intake.absorb(from: d)
        #expect(outcome == .stored(validated: true))
        #expect(try intake.keyStore.load() == "sk-proj-abc123def456ghi789")
        #expect(d.string(forKey: CloudSettings.Key.apiKey) == nil, "the plaintext copy is gone")
        let r = try #require(seen.all.first)
        #expect(r.httpMethod == "GET")
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-proj-abc123def456ghi789")
    }

    @Test func aRefusedKeyIsNotStoredButStillCleared() async throws {
        let seen = Seen()
        let intake = Self.intake(status: 401, seen: seen)
        let d = Self.defaults()
        d.set("sk-wrong-key-000000000000", forKey: CloudSettings.Key.apiKey)
        let outcome = await intake.absorb(from: d)
        #expect(outcome == .rejected("OpenAI refused that key."))
        #expect(try intake.keyStore.load() == nil)
        #expect(d.string(forKey: CloudSettings.Key.apiKey) == nil)
    }

    @Test func offlineKeepsTheKeyUnvalidated() async throws {
        let seen = Seen()
        let intake = Self.intake(status: nil, seen: seen)
        let outcome = await intake.absorb("sk-offline-000000000000")
        #expect(outcome == .stored(validated: false))
        #expect(try intake.keyStore.load() == "sk-offline-000000000000")
    }

    @Test func notAKeyAndNothingPasted() async {
        let seen = Seen()
        let intake = Self.intake(status: 200, seen: seen)
        #expect(await intake.absorb("hello") == .rejected("That doesn't look like an OpenAI key."))
        #expect(await intake.absorb(from: Self.defaults()) == .nothing)
        #expect(seen.all.isEmpty)
    }

    @Test func settingsFallBackToValidValues() {
        #expect(CloudSettings(voice: "nonsense", model: "gpt-4").voice == "marin")
        #expect(CloudSettings(voice: "cedar", model: "gpt-realtime-2.1").model == "gpt-realtime-2.1")
        let c = CloudSettings(voice: "cedar").sessionConfig()
        #expect(c.voice == .named("cedar"))
        #expect(c.instructions == DNASessionInstructions.current)
        #expect(c.reasoningEffort == "low")
        #expect(c.model == "gpt-realtime-2.1-mini")
    }
}

/// F3: sensitive facts never leave the device through `recall` or `forget`.
@Suite struct PrivateFactsTests {
    @Test func redaction() {
        let priv: Set<String> = ["has diabetes"]
        let recall = "Name: Maya. Met 3 times since May 2026.\n- likes jazz\n- has diabetes"
        let out = PrivateFactsFilter.redact(recall, privateTexts: priv)
        #expect(!out.contains("diabetes"))
        #expect(out.contains("- likes jazz"))
        #expect(out.contains("1 private thing"))
        #expect(PrivateFactsFilter.redact("Forgot: has diabetes; likes jazz.", privateTexts: priv) == "Forgot: something private; likes jazz.")
        let candidates = "Several facts match; ask which one, then call forget_fact with its exact text:\n- has diabetes\n- has a dog"
        #expect(!PrivateFactsFilter.redact(candidates, privateTexts: priv).contains("diabetes"))
    }

    @Test func recallThroughTheBrainToolboxHidesSensitiveFacts() async throws {
        let store = try MemoryStore(databaseURL: nil)
        let p = try #require(await store.addPerson(named: "Maya", at: Date()))
        _ = await store.remember("likes jazz", category: .preference, about: p.id, at: Date())
        _ = await store.remember("has diabetes", category: .health, about: p.id, at: Date())
        let id = p.id
        let box = BrainToolbox(tools: BrainToolbox.memoryTools(store: store, currentPerson: { id }))
        let r = await box.run(RealtimeToolCall(callID: "c", name: "recall", arguments: #"{"query":"everything"}"#, responseID: "r", itemID: "i"))
        #expect(r.output.contains("jazz"))
        #expect(!r.output.lowercased().contains("diabetes"), "\(r.output)")
        #expect(BrainToolbox.memoryTools(store: store, currentPerson: { id }, share: false).isEmpty)
    }
}

/// F2 / F8: what a DNA may carry.
@Suite struct DNAContentTests {
    @Test func notesRespectTheMinimalDNAAndTheCap() {
        var r = DNARender(text: "a\n7 RIGHT NOW\nb\n8 THIS TURN\nc", estimatedTokens: 5, steps: [.minimal], dropped: [],
                          sectionBytes: [], fixedEchoes: 0)
        RealtimeBrain.addNotes(["Their name is Maya."], to: &r)
        #expect(!r.text.contains("Maya"), "no notes in a minimal DNA (V12)")
        r.steps = []
        RealtimeBrain.addNotes(["Their name is Maya."], to: &r, cap: 3)
        #expect(!r.text.contains("Maya"), "never past the cap")
        RealtimeBrain.addNotes(["Their name is Maya."], to: &r)
        #expect(r.text.contains("b\nKeep in mind: Their name is Maya.\n8 THIS TURN"))
        #expect(r.estimatedTokens == DNAPrompt.estimate(r.text))
    }
}

/// F10: the pasted key is not lost when the Keychain refuses it.
@Suite struct KeyIntakeKeychainTests {
    final class Refusing: SecretStorage, @unchecked Sendable {
        func read(account: String) throws -> String? { nil }
        func write(_ value: String, account: String) throws { throw KeyStoreError.keychain(-25300) }
        func remove(account: String) throws {}
    }

    @Test func aKeychainFailureKeepsTheField() async {
        let intake = KeyIntake(keyStore: KeyStore(storage: Refusing())) { r in
            (Data(), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let d = UserDefaults(suiteName: "dee.keychain.\(UUID().uuidString)")!
        d.set("sk-proj-abc123def456ghi789", forKey: CloudSettings.Key.apiKey)
        #expect(await intake.absorb(from: d) == .rejected(KeyIntake.keychainFailure))
        #expect(d.string(forKey: CloudSettings.Key.apiKey) == "sk-proj-abc123def456ghi789")
    }
}
