import Testing
@testable import DeeVoice

@Suite struct UnexpectedSoundFilterTests {
    let ambient = -60.0

    func eval(_ f: inout UnexpectedSoundFilter, _ id: String, conf: Double = 0.9, db: Double = -30, at t: Double) -> HeardSound? {
        f.evaluate(identifier: id, confidence: conf, loudnessDB: db, ambientDB: ambient, at: t)
    }

    @Test func speechSilenceAmbientAreNeverReported() {
        var f = UnexpectedSoundFilter()
        for id in ["speech", "silence", "whispering", "mechanical_fan", "air_conditioner", "rain", "typing", "breathing"] {
            #expect(eval(&f, id, at: 0) == nil, "\(id)")
        }
    }

    @Test func novelSalientSoundIsUnexpectedOnce() throws {
        var f = UnexpectedSoundFilter()
        let s = try #require(eval(&f, "door_bell", at: 0))
        #expect(s.isUnexpected)
        #expect(s.label == "the doorbell")
        #expect(s.identifier == "door_bell")
        #expect(s.kind == .event)
        #expect(eval(&f, "door_bell", at: 30) == nil)          // heard recently
        #expect(eval(&f, "door_bell", at: 300) == nil)         // still within 10 min of the 30 s ring
        #expect(eval(&f, "door_bell", at: 300 + 601)?.isUnexpected == true)
    }

    @Test func confidenceAndLoudnessGates() {
        var f = UnexpectedSoundFilter()
        #expect(eval(&f, "dog_bark", conf: 0.3, at: 0) == nil)
        #expect(eval(&f, "glass_breaking", db: -57, at: 0) == nil)   // barely above the room
        // A weak hit still counts as "heard" for novelty purposes.
        var g = UnexpectedSoundFilter()
        #expect(eval(&g, "cat_meow", conf: 0.5, at: 0) == nil)
        #expect(eval(&g, "cat_meow", conf: 0.9, at: 10) == nil)
    }

    @Test func musicOnlyWhenItStarts() {
        var f = UnexpectedSoundFilter()
        #expect(eval(&f, "music", at: 0)?.isUnexpected == true)
        #expect(eval(&f, "guitar", at: 5) == nil)           // music still playing
        #expect(eval(&f, "piano", at: 20) == nil)
        // Silence for > 30 s, then a new instrument starts.
        #expect(eval(&f, "violin_fiddle", at: 70)?.isUnexpected == true)
        // Same song family heard within 10 min but after a pause: still familiar.
        #expect(eval(&f, "music", at: 120) == nil)
    }

    /// Dee can laugh along at any time: laughter is always reported (not as unexpected).
    @Test func laughterIsAlwaysReportedButRateLimited() throws {
        var f = UnexpectedSoundFilter()
        let first = try #require(eval(&f, "laughter", conf: 0.6, db: -45, at: 0))
        #expect(first.isUnexpected == false)
        #expect(first.kind == .laughter)
        #expect(eval(&f, "giggling", at: 3) == nil)                  // within 6 s
        #expect(eval(&f, "belly_laugh", at: 7)?.kind == .laughter)    // familiar but still reported
        #expect(eval(&f, "laughter", at: 400)?.isUnexpected == false)
        #expect(eval(&f, "baby_crying", at: 401)?.kind == .crying)
        #expect(eval(&f, "applause", at: 402)?.kind == .applause)
        #expect(eval(&f, "laughter", conf: 0.3, at: 500) == nil)
        #expect(eval(&f, "laughter", db: -58, at: 600) == nil)
    }

    @Test func resetForgets() {
        var f = UnexpectedSoundFilter()
        _ = eval(&f, "knock", at: 0)
        #expect(eval(&f, "knock", at: 10) == nil)
        f.reset()
        #expect(eval(&f, "knock", at: 11)?.isUnexpected == true)
    }
}

@Suite struct SoundCatalogTests {
    @Test func labelsAreHumanWords() {
        #expect(SoundCatalog.label(for: "dog_bark") == "a dog barking")
        #expect(SoundCatalog.label(for: "door_bell") == "the doorbell")
        #expect(SoundCatalog.label(for: "smoke_detector") == "the smoke alarm")
        #expect(SoundCatalog.label(for: "rowboat_canoe_kayak") == "rowboat canoe kayak")
        for (_, label) in SoundCatalog.labels { #expect(!label.contains("_")) }
    }

    @Test func kinds() {
        #expect(SoundCatalog.kind(of: "silence") == .silence)
        #expect(SoundCatalog.kind(of: "speech") == .speech)
        #expect(SoundCatalog.kind(of: "chuckle_chortle") == .laughter)
        #expect(SoundCatalog.kind(of: "crying_sobbing") == .crying)
        #expect(SoundCatalog.kind(of: "cheering") == .applause)
        #expect(SoundCatalog.kind(of: "saxophone") == .music)
        #expect(SoundCatalog.kind(of: "air_conditioner") == .ambient)
        #expect(SoundCatalog.kind(of: "glass_breaking") == .event)
        #expect(SoundCatalog.kind(of: "something_new") == .event)
        #expect(SoundKind.laughter.isSocial && !SoundKind.event.isSocial)
    }

    @Test func familiesDoNotOverlap() {
        let sets = [SoundCatalog.speech, SoundCatalog.laughter, SoundCatalog.crying, SoundCatalog.applause,
                    SoundCatalog.music, SoundCatalog.ambient]
        for i in sets.indices {
            for j in sets.indices where j > i { #expect(sets[i].isDisjoint(with: sets[j])) }
        }
    }
}
