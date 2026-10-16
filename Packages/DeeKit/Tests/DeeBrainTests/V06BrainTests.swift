import DeeCore
import DeeLocal
import DeeMind
import DeeRealtime
import DeeWake
import Foundation
import Testing
@testable import DeeBrain

// v0.6 (providers-wake-onboarding): the shared window rule in StandaloneHost, the
// voice command to change the wake phrase, the provider timing profile on the brain,
// and the in-app prefs (K1, migration).

@MainActor
@Suite struct V06WindowRuleTests {
    static func host(phrase: Bool) async throws -> StandaloneHost {
        let h = await StandaloneHost(mind: try Mind(databaseURL: nil))
        if phrase { h.wakeMode = .phrase }
        var t: TimeInterval = 100
        h.monotonic = { t += 0.01; return t }
        return h
    }

    static func turn(_ text: String) -> HeardTurn {
        HeardTurn(source: .voice(itemID: "item_\(UUID().uuidString.prefix(4))"), text: text, duration: 1)
    }

    static func hit() -> WakeHit {
        WakeHit(onsetFrame: 48_000, onsetFromFinal: false, detectedFrame: 60_000, matched: "hey dee", tier: .exact)
    }

    /// W1: while dormant, a server transcript with her name or the phrase changes nothing.
    @Test func dormantIgnoresEverythingIncludingHerName() async throws {
        let h = try await Self.host(phrase: true)
        for text in ["Hey Dee, what time is it?", "Dee, are you awake?", "Wake up!", "go to sleep"] {
            #expect(await h.heard(Self.turn(text)) == .ignored, "\(text)")
        }
        #expect(!h.answersOnCommit)
        #expect(h.window.isDormant)
        #expect(h.windowActions.isEmpty, "no wake action from a server transcript")
        #expect(h.commands.isEmpty)
    }

    @Test func openWindowAnswersAndAcceptedTurnsRefreshIt() async throws {
        let h = try await Self.host(phrase: true)
        let woke = h.window(.phraseHeard(Self.hit()))
        #expect(woke.first == .eyesWake)
        #expect(woke.contains(.connect(resume: true)))
        #expect(!h.answersOnCommit, "waking is not open yet")
        h.window(.connected)
        #expect(h.answersOnCommit)
        guard case .answer = await h.heard(Self.turn("What's the weather like?")) else {
            Issue.record("an open window answers")
            return
        }
        #expect(h.window.acceptedTurns == 1)
    }

    /// "Computer, go to sleep" with a custom phrase closes the window at once.
    @Test func closeCommandsWithACustomPhraseCloseTheWindow() async throws {
        let h = try await Self.host(phrase: true)
        h.wakePhrase = try WakePhrase(validating: "Computer")
        h.window(.tapToTalk(captureFrame: 1000))
        h.window(.connected)
        #expect(await h.heard(Self.turn("Computer, stop listening")) == .handled)
        #expect(h.commands == [.stopListening])
        #expect(h.window.isDormant)
        #expect(h.windowActions.contains(.sayGoodbye))
        #expect(h.windowActions.contains(.disconnect))
        #expect(h.windowActions.last == .eyesListeningOff)
        #expect(await h.heard(Self.turn("Are you there?")) == .ignored)
    }

    /// The tune-2 baseline: always open, today's rule (engaged && awake).
    @Test func alwaysOpenIsTodaysRule() async throws {
        let h = try await Self.host(phrase: false)
        #expect(h.answersOnCommit)
        h.engaged = false
        #expect(!h.answersOnCommit)
        #expect(await h.heard(Self.turn("Dee, are you awake?")) == .ignored, "her name no longer re-engages her (W1)")
        #expect(!h.engaged)
        #expect(h.window(.closeCommand).isEmpty, "the window is not driven in always-open mode")
    }

    @Test func changeWakePhraseByVoiceNeedsAYes() async throws {
        let h = try await Self.host(phrase: false)
        #expect(await h.heard(Self.turn("Change your wake phrase to Hey Robo")) == .handled)
        let prompt = try #require(h.phrasePrompts.last)
        guard case .confirm(let p, let line) = prompt else {
            Issue.record("\(prompt)")
            return
        }
        #expect(p.text == "Hey Robo")
        #expect(line == "My wake phrase will be “Hey Robo”. Is that right?")
        #expect(h.wakePhrase == .default, "not saved before the yes")
        #expect(await h.heard(Self.turn("Yes, that's right")) == .handled)
        #expect(h.wakePhrase.text == "Hey Robo")
        #expect(h.phraseOutcomes.count == 1)
    }
}

@Suite struct WakePhraseChangeTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func confirmSaveRefuseExpire() throws {
        var c = WakePhraseChange()
        guard case .confirm = c.propose("Okay Pixel", current: .default, at: Self.t0) else {
            Issue.record("valid phrase")
            return
        }
        #expect(c.answer("no", current: .default, at: Self.t0.addingTimeInterval(3)) == .kept(line: "Okay, I'll keep “Hey Dee”."))
        #expect(!c.isPending)

        _ = c.propose("Okay Pixel", current: .default, at: Self.t0)
        #expect(c.answer("yes", current: .default, at: Self.t0.addingTimeInterval(21)) == nil, "20 s to answer")
        #expect(!c.isPending)

        _ = c.propose("Okay Pixel", current: .default, at: Self.t0)
        #expect(c.answer("what's for dinner", current: .default, at: Self.t0.addingTimeInterval(2)) == nil)
        #expect(!c.isPending, "anything else drops the proposal")
    }

    @Test func invalidAndUnchangedAndShort() throws {
        var c = WakePhraseChange()
        guard case .invalid(let line) = c.propose("one two three four five", current: .default, at: Self.t0) else {
            Issue.record("five words are invalid")
            return
        }
        #expect(line.hasPrefix("I can't use that as my wake phrase."))
        #expect(!c.isPending)
        #expect(c.propose("hey dee", current: .default, at: Self.t0) == .unchanged(line: "That's already my wake phrase."))
        let short = try WakePhrase(validating: "Bo")
        if short.isShort, case .confirm(_, let l) = c.propose("Bo", current: .default, at: Self.t0) {
            #expect(l.hasSuffix(WakePhrase.shortPhraseWarning))
        }
    }
}

@Suite struct TimingOptionsTests {
    /// Mode 1 is today's path exactly.
    @Test func realtimeProfileChangesNothing() {
        let a = RealtimeBrain.Options()
        let b = RealtimeBrain.Options(timing: .realtime)
        #expect(a.stallRetryAfter == b.stallRetryAfter && a.wordsWait == b.wordsWait && a.exactWait == b.exactWait
            && a.partialSettle == b.partialSettle && a.addressWait == b.addressWait && a.overlapWait == b.overlapWait)
        #expect(b.timing == .realtime)
        #expect(a.stallRetryAfter == 8)
    }

    @Test func cascadedProfileHasNoStallRetryAndLongerWordWaits() {
        let lan = RealtimeBrain.Options(timing: .cascaded(stt: .lanREST))
        let base = RealtimeBrain.Options()
        #expect(lan.stallRetryAfter == .infinity)
        #expect(lan.wordsWait > base.wordsWait)
        #expect(lan.partialSettle > base.partialSettle)
        #expect(lan.timing.slowClipOncePerWindow)
        let onDevice = RealtimeBrain.Options(timing: .cascaded(stt: .onDevice))
        #expect(onDevice.wordsWait == base.wordsWait)
        #expect(onDevice.stallRetryAfter == .infinity)
    }
}

@Suite struct DeePrefsTests {
    static func prefs() -> DeePrefs {
        let name = "dee.prefs.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.set(name, forKey: "suite.name")
        return DeePrefs(defaults: d)
    }

    /// This suite's own values (not the global domain the OS merges in).
    static func domain(_ p: DeePrefs) -> [String: Any] {
        p.defaults.persistentDomain(forName: p.defaults.string(forKey: "suite.name")!) ?? [:]
    }

    /// K1: the saved provider config holds no secret, and a config that would leak is not saved.
    @Test func providerConfigNeverHoldsASecret() throws {
        let p = Self.prefs()
        let lan = EndpointConfig(baseURL: URL(string: "http://192.168.1.20:11434")!, model: "qwen3.8:27b",
                                 keyAccount: SecretAccount.lan(.brain))
        p.providerConfig = .lanEverything(brain: lan, stt: .onDevice, tts: .onDevice)
        #expect(p.providerConfig?.brain?.model == "qwen3.8:27b")
        let data = try #require(p.defaults.data(forKey: DeePrefs.Key.providerConfig))
        #expect(DeePrefs.leaks(in: data).isEmpty, "\(DeePrefs.leaks(in: data))")
        #expect(DeePrefs.leaks(inDomain: Self.domain(p)).isEmpty)

        let bad = EndpointConfig(baseURL: URL(string: "http://me:sk-secret@192.168.1.20:11434/?key=sk-x")!, model: "m")
        p.providerConfig = .lanEverything(brain: bad)
        #expect(p.providerConfig?.brain?.model == "qwen3.8:27b", "a leaking config is refused, the old one kept")
        #expect(!DeePrefs.leaks(in: try JSONEncoder().encode(ProviderConfig.lanEverything(brain: bad))).isEmpty)
    }

    @Test func leakScannerFindsKeysAndKeyFields() {
        let json = #"{"apiKey":"x","nested":{"token":"t"},"u":"https://a.b/?q=1","s":"sk-abc","keyAccount":"lan.brain.key","keepAlive":"30m"}"#
        let found = DeePrefs.leaks(in: Data(json.utf8))
        #expect(found.contains("$.apiKey"))
        #expect(found.contains("$.nested.token"))
        #expect(found.contains("$.u: url"))
        #expect(found.contains("$.s: sk-"))
        #expect(!found.contains { $0.contains("keyAccount") || $0.contains("keepAlive") })
    }

    /// Migration before onboarding: no network, plaintext removed, a mode-1 draft from
    /// the old voice/model, onboarding still shown.
    @Test func migrationPrefillsModeOneWithoutNetwork() throws {
        let p = Self.prefs()
        p.defaults.set("sk-proj-abc123def456ghi789", forKey: CloudSettings.Key.apiKey)
        p.defaults.set("cedar", forKey: CloudSettings.Key.voice)
        p.defaults.set("gpt-realtime-2.1", forKey: CloudSettings.Key.model)
        let calls = Counter()
        let intake = KeyIntake(keyStore: KeyStore(storage: MemorySecretStorage())) { r in
            calls.bump()
            return (Data(), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let report = p.migrate(intake: intake)
        #expect(report == DeePrefs.MigrationReport(key: .moved, prefilled: true))
        #expect(calls.value == 0)
        #expect(p.providerConfig == .openAI(model: "gpt-realtime-2.1", voice: "cedar"))
        #expect(p.needsOnboarding, "the explainer still shows once")
        #expect(DeePrefs.leaks(inDomain: Self.domain(p)).isEmpty)
    }

    @Test func prefsDefaults() throws {
        let p = Self.prefs()
        #expect(p.wakePhrase == .default)
        #expect(!p.speakFirst)
        #expect(p.needsOnboarding)
        p.wakePhrase = try WakePhrase(validating: "Okay Pixel")
        #expect(p.wakePhrase.text == "Okay Pixel")
        p.defaults.set("one two three four five six", forKey: DeePrefs.Key.wakePhrase)
        #expect(p.wakePhrase == .default, "an invalid stored phrase falls back")
        p.providerConfig = .openAI()
        p.onboardingVersion = OnboardingFlow.version
        #expect(!p.needsOnboarding)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }
}

/// W1 lint: no host may wake or gate on her name in a server transcript again
/// (`SpokenCommand.addressesDee` stays only as information for the harness).
@Suite struct W1LintTests {
    static let repo = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // Packages/DeeKit
        .deletingLastPathComponent().deletingLastPathComponent()                               // repo root

    @Test func hostsNeverCallAddressesDee() throws {
        let files = ["Packages/DeeKit/Sources/DeeBrain/StandaloneHost.swift", "Packages/DeeKit/Sources/DeeBrain/RealtimeBrain.swift",
                     "Packages/DeeKit/Sources/DeeBrain/WakeController.swift", "App/Sources/DeeModel.swift"]
        for f in files {
            let url = Self.repo.appendingPathComponent(f)
            try #require(FileManager.default.fileExists(atPath: url.path), "\(f) moved: update this lint")
            let code = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
                .map { $0.components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
            #expect(!code.contains("addressesDee("), "\(f) wakes or gates on a server transcript (W1)")
        }
    }
}
