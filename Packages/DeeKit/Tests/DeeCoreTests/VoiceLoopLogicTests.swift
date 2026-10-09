import Foundation
import Testing
@testable import DeeCore

/// Voice-loop audit (scratchpad voice-audit.md): the pure pieces of the fixes.
/// - C8: spoken commands are whole utterances (`SpokenCommand`);
/// - C1: speech with nobody in view is answered only when it addresses Dee;
/// - C9: history keeps only what she said out loud (`SpokenReply`, `ReplySettlement`);
/// - C11: permission and recognizer failures become a visible state (`VoiceHealth`).
@Suite struct SpokenCommandTests {
    @Test(arguments: [
        ("stop", SpokenCommand.stop), ("Stop.", .stop), ("Dee, stop!", .stop), ("please stop", .stop),
        ("stop please", .stop), ("okay Dee stop now", .stop), ("Stop, stop, stop!", .stop), ("shh", .stop),
        ("Be quiet.", .stop), ("hush", .stop), ("that's enough", .stop), ("stop talking", .stop), ("Stop it.", .stop),
        ("Let's start over.", .newConversation), ("new conversation", .newConversation), ("Dee, fresh start please", .newConversation),
        ("Go to sleep.", .sleep), ("Goodnight, Dee!", .sleep), ("good night", .sleep), ("nap time", .sleep),
    ])
    func commands(_ text: String, _ expected: SpokenCommand) {
        #expect(SpokenCommand.match(text, deeIsTalking: true) == expected, "\"\(text)\"")
    }

    /// C8: these used to silence her (prefix/suffix match) or wipe the conversation.
    @Test(arguments: [
        "don't stop", "Don't stop!", "it's so quiet", "It's so quiet in here", "please don't stop",
        "stop it, that tickles", "Stop it, that tickles!", "I can't stop", "we had to stop", "the bus didn't stop",
        "quiet please, I'm thinking about what to say", "then we had a new conversation", "I want a fresh start in life",
        "let's not start over", "I don't want to go to sleep", "the kids go to sleep at eight", "goodnight moon is my favourite book",
        "stop and think about it", "", "   ", "dee",
    ])
    func conversationNotCommands(_ text: String) {
        #expect(SpokenCommand.match(text, deeIsTalking: true) == nil, "\"\(text)\"")
    }

    /// "Stop" to a silent Dee is conversation: she answers it instead of ignoring them.
    @Test func stopOnlyWhenThereIsSomethingToStop() {
        #expect(SpokenCommand.match("stop", deeIsTalking: false) == nil)
        #expect(SpokenCommand.match("quiet", deeIsTalking: false) == nil)
        #expect(SpokenCommand.match("start over", deeIsTalking: false) == .newConversation)
        #expect(SpokenCommand.match("go to sleep", deeIsTalking: false) == .sleep)
    }

    @Test func core() {
        #expect(SpokenCommand.core(of: "Hey Dee, stop it now please!") == "stop it")
        #expect(SpokenCommand.core(of: "Um, okay, stop. Thank you.") == "stop")
        #expect(SpokenCommand.core(of: "Dee Dee") == "")
        #expect(SpokenCommand.core(of: "STOP STOP") == "stop")
        #expect(SpokenCommand.core(of: "don\u{2019}t stop") == "don't stop")
    }

    /// C1: with nobody in view (or asleep) only speech aimed at her is answered.
    @Test func addressesDee() {
        for t in ["Dee, are you there?", "hey dee", "Wake up!", "Are you awake?", "Hi Dee.", "Where's Dee's charger?", "D, come here"] {
            #expect(SpokenCommand.addressesDee(t), "\"\(t)\"")
        }
        for t in ["and now the weather", "deep down I knew", "the defence rests", "Deedee's coming", "good morning everyone", ""] {
            #expect(!SpokenCommand.addressesDee(t), "\"\(t)\"")
        }
    }

    /// Review M4: a TV saying "D" or "wake up" must not open a minute of answers.
    @Test func theLetterDAndWakeUpOnlyWhenAddressed() {
        for t in ["Vitamin D is good for you", "I got a D on my test", "I got a D", "Plan D", "D is for dog",
                  "I can't wake up early", "Did he wake up?", "Time to wake up the kids", "Is he awake?"] {
            #expect(!SpokenCommand.addressesDee(t), "\"\(t)\"")
        }
        for t in ["Hey D", "Hey D come here", "Okay D, what's up?", "Thanks, D", "D, are you there?", "Wake up!", "Hey, wake up",
                  "Oh, are you awake?", "You awake?", "Wake up, sleepyhead"] {
            #expect(SpokenCommand.addressesDee(t), "\"\(t)\"")
        }
    }
}

@Suite struct SpokenReplyTests {
    static let text = "Oh, I love that! We could paint the lamp blue. Or green, maybe."

    @Test func prefixKeepsWholeWordsAndMarksTheCut() {
        #expect(SpokenReply.prefix(of: Self.text, characters: 0) == "")
        #expect(SpokenReply.prefix(of: Self.text, characters: 2) == "", "\"Oh,\" not finished")
        #expect(SpokenReply.prefix(of: Self.text, characters: 3) == "Oh—", "a cut after a comma ends in a dash, not \",—\"")
        #expect(SpokenReply.prefix(of: Self.text, characters: 4) == "Oh—")
        #expect(SpokenReply.prefix(of: Self.text, characters: 9) == "Oh, I—", "\"love\" was mid-word")
        #expect(SpokenReply.prefix(of: Self.text, characters: 18) == "Oh, I love that!", "a whole sentence: no dash")
        #expect(SpokenReply.prefix(of: Self.text, characters: 22) == "Oh, I love that! We—")
        #expect(SpokenReply.prefix(of: Self.text, characters: 500) == Self.text)
        #expect(SpokenReply.prefix(of: "  padded reply.  ", characters: 100) == "padded reply.")
    }

    @Test func heardFollowsTheClock() {
        var r = SpokenReply()
        for piece in ["Oh, I love", " that! We could", " paint the lamp blue.", " Or green, maybe."] { r.append(piece) }
        #expect(r.text == Self.text)
        let cps = SpokenReply.charactersPerSecond(rate: 0.5)
        #expect(cps == 13)
        #expect(r.heard(afterSeconds: 0, charactersPerSecond: cps) == "")
        #expect(r.heard(afterSeconds: -1, charactersPerSecond: cps) == "")
        #expect(r.heard(afterSeconds: 1.4, charactersPerSecond: cps) == "Oh, I love that!")   // 18 chars
        #expect(r.heard(afterSeconds: 60, charactersPerSecond: cps) == Self.text)
        #expect(SpokenReply.charactersPerSecond(rate: 0.64) > cps)
        #expect(SpokenReply.charactersPerSecond(rate: 0.36) < cps)
    }

    @Test func settlement() {
        let cps = 13.0
        // Played out: keep (her history is exactly what she said).
        #expect(ReplySettlement.decide(streamed: Self.text, audioStarted: true, audioFinished: true, playedSeconds: 1, charactersPerSecond: cps) == .keep)
        // Never reached her voice (superseded, an initiative that gave way): withdraw.
        #expect(ReplySettlement.decide(streamed: Self.text, audioStarted: false, audioFinished: false, playedSeconds: 0, charactersPerSecond: cps) == .retract)
        // Cut off after one sentence (C9: decode runs ahead of speech).
        #expect(ReplySettlement.decide(streamed: Self.text, audioStarted: true, audioFinished: false, playedSeconds: 1.4, charactersPerSecond: cps)
                == .truncate("Oh, I love that!"))
        // Barely started: nothing intelligible was heard.
        #expect(ReplySettlement.decide(streamed: Self.text, audioStarted: true, audioFinished: false, playedSeconds: 0.1, charactersPerSecond: cps) == .retract)
        // Stopped after the last word had played: keep.
        #expect(ReplySettlement.decide(streamed: Self.text, audioStarted: true, audioFinished: false, playedSeconds: 30, charactersPerSecond: cps) == .keep)
    }
}

@Suite struct VoiceHealthTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func permissionsComeFirst() {
        var h = VoiceHealth()
        #expect(h.problem(at: Self.t0) == nil)
        h.permission(microphone: false, speech: false)
        #expect(h.problem(at: Self.t0) == .microphoneOff)
        #expect(h.problem(at: Self.t0)?.needsUser == true)
        h.permission(microphone: true, speech: false)
        #expect(h.problem(at: Self.t0) == .speechRecognitionOff)
        h.permission(microphone: true, speech: true)
        #expect(h.problem(at: Self.t0) == nil)
        let shown = h.error("Missing NSMicrophoneUsageDescription; Dee can't listen.")
        #expect(shown)
        #expect(h.problem(at: Self.t0) == .microphoneOff)
    }

    /// First launch: the speech model downloads for minutes. Say so, instead of
    /// looking like she's listening.
    @Test func slowEarsShowAsPreparing() {
        var h = VoiceHealth()
        h.listeningWanted(since: Self.t0)
        #expect(h.problem(at: Self.t0.addingTimeInterval(1)) == nil)
        #expect(h.problem(at: Self.t0.addingTimeInterval(VoiceHealth.preparingAfter)) == .preparingEars)
        h.earsWorking()
        #expect(h.problem(at: Self.t0.addingTimeInterval(60)) == nil)
        h.listeningWanted(since: Self.t0.addingTimeInterval(100))
        #expect(h.problem(at: Self.t0.addingTimeInterval(200)) == nil, "once open, never 'preparing' again")
        var off = VoiceHealth()
        off.listeningWanted(since: Self.t0)
        off.listeningWanted(since: nil)
        #expect(off.problem(at: Self.t0.addingTimeInterval(60)) == nil, "not wanted: not waiting")
    }

    @Test func recognizerAndAudioFailuresShowUntilTheyRecover() {
        var h = VoiceHealth()
        var shown = h.error("Speech recognition stopped: The operation couldn't be completed.")
        #expect(shown)
        guard case .earsUnavailable = h.problem(at: Self.t0) else { Issue.record("expected earsUnavailable"); return }
        h.earsWorking()
        #expect(h.problem(at: Self.t0) == nil)
        shown = h.error("Speech recognition unavailable: No supported English speech model.")
        #expect(shown)
        #expect(h.problem(at: Self.t0)?.needsUser == false)
        shown = h.error("Audio engine couldn't restart: busy")
        #expect(shown)
        guard case .audioUnavailable = h.problem(at: Self.t0) else { Issue.record("expected audioUnavailable"); return }
        h.audioWorking()
        #expect(h.problem(at: Self.t0) == nil)
    }

    @Test func diagnosticsAreNotShown() {
        var h = VoiceHealth()
        for m in ["Sound recognition stopped: x", "Dee's voice isn't started yet.", "Audio services were reset; voice restarting.", "anything else"] {
            let shown = h.error(m)
            #expect(!shown, "\(m)")
        }
        #expect(h.problem(at: Self.t0) == nil)
    }

    /// Review L5: a failure the voice never retries must not say "trying again".
    @Test func permanentRecognizerFailureIsNotRetrying() {
        var h = VoiceHealth()
        h.error("Speech recognition unavailable: On-device speech recognition isn't available on this device.")
        #expect(h.problem(at: Self.t0) == .speechUnsupported("Speech recognition unavailable: On-device speech recognition isn't available on this device."))
        #expect(h.problem(at: Self.t0)?.message.contains("Trying again") == false)
        h.error("Speech recognition unavailable: No supported English speech model.")
        guard case .speechUnsupported = h.problem(at: Self.t0) else { Issue.record("expected speechUnsupported"); return }
        h.error("Speech recognition unavailable: Speech recognition couldn't agree on an audio format.")
        guard case .earsUnavailable = h.problem(at: Self.t0) else { Issue.record("a retried failure still says it retries"); return }
    }

    /// Review L5: with the cloud voice hearing for her, on-device speech problems
    /// don't matter; the cloud voice's own problems do.
    @Test func cloudVoiceProblemsReplaceOnDeviceSpeechOnes() {
        var h = VoiceHealth()
        h.permission(microphone: true, speech: false)
        h.listeningWanted(since: Self.t0)
        h.error("Speech recognition unavailable: No supported English speech model.")
        #expect(h.problem(at: Self.t0) == .speechRecognitionOff)
        h.onDeviceSpeech = false
        #expect(h.problem(at: Self.t0.addingTimeInterval(60)) == nil, "denied SFSpeech, a missing model, slow ears: irrelevant to the cloud voice")
        h.cloudVoice(.cloudVoiceUnavailable("socket closed"))
        #expect(h.problem(at: Self.t0) == .cloudVoiceUnavailable("socket closed"))
        #expect(h.problem(at: Self.t0)?.needsUser == false)
        h.cloudVoice(.cloudVoiceNeedsSetup("unauthorized"))
        #expect(h.problem(at: Self.t0)?.needsUser == true)
        h.cloudVoice(.microphoneOff)
        #expect(h.problem(at: Self.t0) == .cloudVoiceNeedsSetup("unauthorized"), "only cloud problems are taken")
        h.cloudVoice(nil)
        #expect(h.problem(at: Self.t0) == nil)
        h.permission(microphone: false, speech: false)
        #expect(h.problem(at: Self.t0) == .microphoneOff, "the microphone matters to both")
        h.permission(microphone: true, speech: false)
        h.error("Audio engine failed to start: x")
        guard case .audioUnavailable = h.problem(at: Self.t0) else { Issue.record("audio problems still show"); return }
    }

    @Test func everyProblemHasWordsAndASymbol() {
        for p in [VoiceProblem.microphoneOff, .speechRecognitionOff, .preparingEars, .earsUnavailable("x"), .speechUnsupported("z"),
                  .audioUnavailable("y"), .cloudVoiceUnavailable("c"), .cloudVoiceNeedsSetup("k")] {
            #expect(!p.message.isEmpty && p.message.count <= 80)
            #expect(!p.symbol.isEmpty)
        }
    }
}
