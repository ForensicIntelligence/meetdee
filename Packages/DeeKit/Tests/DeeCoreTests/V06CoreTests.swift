import Foundation
import Testing
@testable import DeeCore

// v0.6 (providers-wake-onboarding §4–§5): DNASplit, UsageCounter, OnboardingFlow,
// the close commands and the voice command to change the wake phrase.

@Suite struct DNASplitTests {
    static let sample = """
    DEE DNA v11 · reply · response 3 · 7:40 pm evening
    The newest DEE DNA replaces all earlier ones. Never say, quote or mention it.
    1 IDENTITY
    You are Dee, a tiny robot.
    2 TEMPERAMENT
    curiosity 200/255 high: asks
    3 FEELINGS NOW (0–255; slow ones: affection, trust)
    Overall: content.
    4 TOWARD THIS PERSON
    Their name is Sam.
    5 WHAT YOU KNOW ABOUT THEM (mention only what fits; never list it)
    Facts: 3 cats.
    6 WHO YOU ARE
    Values: honesty.
    7 RIGHT NOW
    Keep in mind: Sam just got home.
    8 THIS TURN
    They sound tired.
    9 HOW TO RESPOND
    Length: one short sentence, 12 words; stop.
    """

    @Test func stableHoldsSections124569AndVolatileTheRest() {
        let s = DNASplit(Self.sample)
        #expect(s.stable.hasPrefix("1 IDENTITY\n"))
        for h in ["1 IDENTITY", "2 TEMPERAMENT", "4 TOWARD", "5 WHAT YOU KNOW", "6 WHO YOU ARE", "9 HOW TO RESPOND", "Facts: 3 cats."] {
            #expect(s.stable.contains(h), "\(h)")
            #expect(!s.volatile.contains(h), "\(h)")
        }
        for h in ["DEE DNA v11", "Never say", "3 FEELINGS NOW", "7 RIGHT NOW", "Keep in mind: Sam", "8 THIS TURN", "They sound tired."] {
            #expect(s.volatile.contains(h), "\(h)")
            #expect(!s.stable.contains(h), "\(h)")
        }
        #expect(s.volatile.hasPrefix("DEE DNA v11"))
    }

    @Test func everyLineKeptExactlyOnce() {
        let s = DNASplit(Self.sample)
        let all = (s.stable + "\n" + s.volatile).split(separator: "\n").sorted()
        #expect(all == Self.sample.split(separator: "\n").sorted())
    }

    /// A content line that starts with a digit ("3 cats") is not a heading.
    @Test func digitLinesAreNotHeadings() {
        let text = "DEE DNA\n5 WHAT YOU KNOW ABOUT THEM\n3 cats at home\n7 RIGHT NOW\nnow"
        let s = DNASplit(text)
        #expect(s.stable == "5 WHAT YOU KNOW ABOUT THEM\n3 cats at home")
        #expect(s.volatile == "DEE DNA\n7 RIGHT NOW\nnow")
    }

    @Test func sameStableBytesWhenOnlyTheTurnChanges() {
        let a = DNASplit(Self.sample)
        let b = DNASplit(Self.sample.replacingOccurrences(of: "response 3", with: "response 4")
            .replacingOccurrences(of: "They sound tired.", with: "They laugh."))
        #expect(a.stable == b.stable)
        #expect(a.volatile != b.volatile)
    }
}

@Suite struct UsageCounterTests {
    static var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    static let noon = Date(timeIntervalSince1970: 1_760_616_000)   // 2025-10-16 12:00 UTC

    @Test func countsPerDayAndMode() {
        var u = UsageCounter()
        u.addStreamed(12.5, mode: "openAI", at: Self.noon, calendar: Self.utc)
        u.addStreamed(5, mode: "lanEverything", at: Self.noon, calendar: Self.utc)
        u.addResponse(mode: "openAI", at: Self.noon, calendar: Self.utc)
        u.addResponse(mode: "openAI", at: Self.noon, calendar: Self.utc)
        u.addFalseWake(mode: "openAI", at: Self.noon, calendar: Self.utc)
        u.addWindow(mode: "openAI", at: Self.noon, calendar: Self.utc)
        let today = u.today(at: Self.noon, calendar: Self.utc)
        #expect(today.streamedSeconds == 17.5)
        #expect(today.responses == 2)
        #expect(today.falseWakes == 1)
        #expect(today.windows == 1)
        #expect(u.day(Self.noon, mode: "lanEverything", calendar: Self.utc).streamedSeconds == 5)
    }

    @Test func rollsOverAtMidnightAndPrunes() {
        var u = UsageCounter()
        u.addResponse(mode: "openAI", at: Self.noon, calendar: Self.utc)
        let tomorrow = Self.noon.addingTimeInterval(86_400)
        #expect(u.today(at: tomorrow, calendar: Self.utc).responses == 0)
        u.addResponse(mode: "openAI", at: tomorrow, calendar: Self.utc)
        u.prune(keepingDays: 0, at: tomorrow, calendar: Self.utc)
        #expect(u.today(at: Self.noon, calendar: Self.utc).responses == 0)
        #expect(u.today(at: tomorrow, calendar: Self.utc).responses == 1)
    }

    @Test func ignoresNonsenseAndRoundTrips() {
        var u = UsageCounter()
        u.addStreamed(-3, mode: "openAI", at: Self.noon, calendar: Self.utc)
        u.addStreamed(.nan, mode: "openAI", at: Self.noon, calendar: Self.utc)
        #expect(u.today(at: Self.noon, calendar: Self.utc).streamedSeconds == 0)
        u.addStreamed(2, mode: "openAI", at: Self.noon, calendar: Self.utc)
        #expect(UsageCounter.decoded(u.encoded()) == u)
        #expect(UsageCounter.decoded(Data("junk".utf8)) == UsageCounter())
    }

    @Test func windowLogIsNumbersOnly() {
        let line = UsageCounter.windowLog(openSeconds: 41.6, streamedSeconds: 18.24, responses: 3, mode: "lanEverything")
        #expect(line == "window closed: open 42 s, streamed 18.2 s, 3 responses, mode lanEverything")
        #expect(UsageCounter.windowLog(openSeconds: 5, streamedSeconds: 0, responses: 1, mode: "openAI").contains("1 response,"))
    }
}

@Suite struct OnboardingFlowTests {
    static func walk(_ f: inout OnboardingFlow, limit: Int = 40) -> [OnboardingStep] {
        var seen = [f.step]
        for _ in 0..<limit where f.step != .done {
            f.next()
            seen.append(f.step)
        }
        return seen
    }

    @Test func fullOrder() {
        var f = OnboardingFlow()
        let steps = Self.walk(&f)
        #expect(steps == [.meet, .talking, .seeing, .privacy, .micPermission, .speechPermission, .cameraPermission,
                          .localNetworkPermission, .provider, .persona, .wakePhrase, .voice, .speakFirst,
                          // still undetermined: shown once more before Done (local network only for LAN modes)
                          .micPermission, .speechPermission, .cameraPermission, .done])
        #expect(!f.canFinish, "no provider yet")
        f.providerReady = true
        #expect(f.canFinish)
    }

    @Test func grantedCardsAreNotRevisitedAndSpeechCardIsConditional() {
        var f = OnboardingFlow(permissions: [.microphone: .granted, .camera: .denied], speechCardNeeded: false, localNetworkNeeded: true)
        let steps = Self.walk(&f)
        #expect(!steps.contains(.speechPermission))
        let after = steps.drop { $0 != .speakFirst }.dropFirst()
        #expect(Array(after) == [.localNetworkPermission, .done])
    }

    @Test func skipJumpsToProviderOnlyBeforeIt() {
        var f = OnboardingFlow()
        f.next()
        #expect(f.canSkip)
        f.skip()
        #expect(f.step == .provider)
        #expect(!f.canSkip)
        f.skip()
        #expect(f.step == .provider, "skip can't pass the provider step")
        f.back()
        #expect(f.step == .talking)
    }

    @Test func backUndoesARevisit() {
        var f = OnboardingFlow(permissions: [.speech: .granted, .camera: .granted, .localNetwork: .granted])
        f.skip()
        f.next(); f.next(); f.next(); f.next(); f.next()   // persona, wake phrase, voice, speak first, mic
        #expect(f.step == .micPermission)
        f.back()
        #expect(f.step == .speakFirst)
        f.next()
        #expect(f.step == .micPermission, "the card shows again after back")
        f.next()
        #expect(f.step == .done)
        f.restart()
        #expect(f.step == .meet && !f.canBack)
    }

    @Test func doneNeedsProvider() {
        var f = OnboardingFlow(step: .done, providerReady: false)
        #expect(!f.canFinish)
        f.next()
        #expect(f.step == .done)
    }
}

@Suite struct V06CommandTests {
    @Test func closeCommands() {
        for t in ["Stop listening", "that's all", "That's all for now, thanks", "Hey Dee, stop listening", "okay that will be all",
                  "you can stop listening now"] {
            #expect(SpokenCommand.match(t, deeIsTalking: false) == .stopListening, "\(t)")
            #expect(SpokenCommand.match(t, deeIsTalking: false)?.closesWindow == true, "\(t)")
        }
        #expect(SpokenCommand.match("go to sleep", deeIsTalking: false)?.closesWindow == true)
        #expect(SpokenCommand.match("stop", deeIsTalking: true)?.closesWindow == false)
        for t in ["that's all I have to say about cats", "don't stop listening", "is that all?", "that's it!", "I stop listening when bored"] {
            #expect(SpokenCommand.match(t, deeIsTalking: false) == nil, "\(t)")
        }
    }

    /// A custom phrase in front ("Computer, go to sleep") — the caller's stripper removes it.
    @Test func customPhraseIsStripped() {
        let strip: (String) -> String = { s in
            let lower = s.lowercased()
            guard lower.hasPrefix("computer") else { return s }
            return String(s.dropFirst("computer".count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        }
        #expect(SpokenCommand.match("Computer, go to sleep", deeIsTalking: false, stripLeading: strip) == .sleep)
        #expect(SpokenCommand.match("Computer, that's all", deeIsTalking: false, stripLeading: strip) == .stopListening)
        #expect(SpokenCommand.match("Computer, go to sleep", deeIsTalking: false) == nil, "without the stripper it is conversation")
    }

    @Test func changeWakePhrase() {
        let cases: [(String, String)] = [
            ("Change your wake phrase to Computer", "Computer"),
            ("hey dee, change your wake word to hey robo please", "Hey Robo"),
            ("Can you set your wake-up phrase to Okay Pixel?", "Okay Pixel"),
            ("I want to change your wake phrase to hi dee", "Hi Dee"),
            ("make your wake word be Jarvis", "Jarvis"),
            ("your new wake phrase is now Hey Buddy", "Hey Buddy"),
            ("use Hello Robot as your wake phrase", "Hello Robot"),
        ]
        for (t, want) in cases {
            #expect(SpokenCommand.match(t, deeIsTalking: false) == .changeWakePhrase(to: want), "\(t)")
        }
        for t in ["change your wake phrase", "what is your wake phrase?", "I changed my phrase", "change the subject to cats"] {
            #expect(SpokenCommand.match(t, deeIsTalking: false) == nil, "\(t)")
        }
    }

    @Test func confirmation() {
        for t in ["yes", "Yeah, that's right", "yep", "Correct.", "yes please", "sure"] {
            #expect(SpokenCommand.confirmation(t) == true, "\(t)")
        }
        for t in ["no", "Nope", "never mind", "no, keep the old one", "cancel"] {
            #expect(SpokenCommand.confirmation(t) == false, "\(t)")
        }
        for t in ["maybe later", "what?", "the weather is nice", ""] {
            #expect(SpokenCommand.confirmation(t) == nil, "\(t)")
        }
    }
}
