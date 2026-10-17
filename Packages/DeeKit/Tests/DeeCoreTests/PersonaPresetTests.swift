import DeeCore
import Foundation
import Testing

// Persona presets (persona spec §2, §3, §11.10 DeeCoreTests): the pronoun table and
// agreement, the catalog's shape, and the onboarding order provider → companion → wake.
@Suite struct PronounTests {
    @Test func table() {
        let rows: [(Pronouns, [String])] = [
            (.she, ["she", "her", "her", "hers", "herself", "is", "has", "doesn't"]),
            (.he, ["he", "him", "his", "his", "himself", "is", "has", "doesn't"]),
            (.they, ["they", "them", "their", "theirs", "themself", "are", "have", "don't"]),
        ]
        for (p, want) in rows {
            #expect([p.subject, p.object, p.possessiveDet, p.possessive, p.reflexive, p.be, p.have, p.doNot] == want, "\(p)")
        }
        #expect(Pronouns.she.label == "she/her" && Pronouns.he.label == "he/him" && Pronouns.they.label == "they/them")
    }

    @Test func verbAgreement() {
        #expect(Pronouns.she.verb("listen") == "listens")
        #expect(Pronouns.he.verb("watch") == "watches")
        #expect(Pronouns.she.verb("carry") == "carries")
        #expect(Pronouns.he.verb("play") == "plays")
        #expect(Pronouns.she.verb("go") == "goes")
        #expect(Pronouns.they.verb("listen") == "listen")
        #expect(Pronouns.they.verb("carry") == "carry")
        #expect(Pronouns.he.verb("have") == "has" && Pronouns.they.verb("have") == "have")
    }

    @Test func pronounTextAgreesWithTheNameAndThePronoun() {
        let nova = PersonaCatalog.nova.text
        #expect("\(PersonaCatalog.nova.name) \(Pronouns.thirdPerson("be")) listening" == "Nova is listening")
        #expect(nova.theyAre + " listening" == "they are listening")
        #expect(nova.They("hear") == "They hear")
        #expect(nova.their == "their" && nova.Their == "Their" && nova.them == "them" && nova.themself == "themself")
        let rio = PersonaCatalog.rio.text
        #expect(rio.theyAre == "he is" && rio.They("hear") == "He hears" && rio.their == "his" && rio.theyDoNot == "he doesn't")
        let mira = PersonaCatalog.mira.text
        #expect(mira.they("see") == "she sees" && mira.Their == "Her")
    }
}

@Suite struct PersonaCatalogTests {
    @Test func sixAdultsTwoTwoTwoPlusClassic() {
        let all = PersonaCatalog.all
        #expect(all.map(\.id) == ["mira", "vera", "rio", "atlas", "nova", "haven"])
        #expect(all.map(\.name) == ["Mira", "Vera", "Rio", "Atlas", "Nova", "Haven"])
        for pronoun in Pronouns.allCases {
            let ages = all.filter { $0.pronouns == pronoun }.compactMap(\.age).sorted()
            #expect(ages.count == 2, "\(pronoun)")
            #expect((20..<30).contains(ages[0]) && (40..<50).contains(ages[1]), "\(pronoun): one 20-something, one 40-something")
        }
        #expect(all.map(\.age) == [24, 46, 27, 44, 23, 47])
        #expect(all.allSatisfy { $0.traitTargets.count == 13 && !$0.isLegacy && !$0.isClassic })
        #expect(PersonaCatalog.classic.isClassic && PersonaCatalog.classic.isLegacy && PersonaCatalog.classic.age == nil)
    }

    @Test func defaultIsTheTwentySomethingWoman() {
        let d = PersonaCatalog.default
        #expect(d.id == "mira" && d.pronouns == .she && d.age == 24)
        #expect(PersonaCatalog.defaultID == "mira")
    }

    @Test func unknownOrMissingIdIsClassic() {
        #expect(PersonaCatalog.preset(id: nil).isClassic)
        #expect(PersonaCatalog.preset(id: "nobody").isClassic)
        #expect(PersonaCatalog.preset(id: "rio").name == "Rio")
        #expect(PersonaCatalog.offered(current: "classic").count == 7)
        #expect(PersonaCatalog.offered(current: "mira").count == 6, "Classic is offered only to whoever has it")
    }

    @Test func humourPairsAndSeedsAndVoicesAreDistinct() {
        let all = PersonaCatalog.all
        let pairs = all.map { "\($0.humour ?? "")/\($0.humourSecondary ?? "")" }
        #expect(Set(pairs).count == 6, "\(pairs)")
        #expect(Set(all.map(\.openAIVoice)).count == 6)
        for p in all {
            #expect(p.seed == PersonaPreset.fnv1a64(p.id))
            #expect(p.wakePhraseDefault == "Hey \(p.name)")
            #expect(p.addressingWords.contains(p.name.lowercased()))
            #expect(p.appleVoice != nil && p.realtimeSpeed != nil && p.rituals != nil && p.speechStyle != nil)
            #expect(!p.dnaVoice.contains("tiny") && !p.ttsStyle.contains("tiny"))
        }
        // FNV-1a 64 reference value.
        #expect(PersonaPreset.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
        #expect(PersonaPreset.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)
    }

    /// A confusion is never another preset's name (Rio vs Leo; Nova vs Noah).
    @Test func confusionsNeverNameAnotherPreset() {
        let names = Set(PersonaCatalog.all.map { $0.name.lowercased() })
        for p in PersonaCatalog.all {
            for c in p.wakeConfusions + p.heyOnlyConfusions + p.addressingWords where c != p.name.lowercased() {
                #expect(!names.contains(c), "\(p.name): \(c)")
            }
        }
    }

    @Test func personaCarriesThePresetFields() {
        let p = Persona(preset: PersonaCatalog.haven)
        #expect(p.name == "Haven" && p.pronouns == .they && p.presetID == "haven" && p.age == 47)
        #expect(p.preset == PersonaCatalog.haven)
        #expect(Persona().preset.isClassic && Persona().pronouns == .she)
    }
}

@Suite struct PersonaOnboardingTests {
    @Test func companionComesAfterTheProviderAndBeforeTheWakePhrase() {
        #expect(OnboardingFlow.setupSteps == [.provider, .persona, .wakePhrase, .voice, .speakFirst])
        var f = OnboardingFlow()
        f.skip()
        #expect(f.step == .provider)
        f.next()
        #expect(f.step == .persona)
        f.next()
        #expect(f.step == .wakePhrase)
        f.back()
        #expect(f.step == .persona)
    }
}

@Suite struct PersonaAddressingTests {
    @Test func eachPresetIsAddressedByItsOwnWords() {
        for p in PersonaCatalog.all {
            for w in p.addressingWords {
                #expect(SpokenCommand.addresses("\(w.capitalized), are you awake?", words: p.addressingWords), "\(p.id): \(w)")
            }
            #expect(SpokenCommand.addresses("What do you think, \(p.name)?", words: p.addressingWords))
            #expect(SpokenCommand.addresses("Wake up!", words: p.addressingWords))
            #expect(!SpokenCommand.addresses("The weather is nice today.", words: p.addressingWords))
        }
    }

    @Test func lookalikesSaidBareNeverAddress() {
        #expect(!SpokenCommand.addresses("At last, the bus is here.", words: PersonaCatalog.atlas.addressingWords))
        #expect(!SpokenCommand.addresses("I haven't seen it.", words: PersonaCatalog.haven.addressingWords))
        #expect(!SpokenCommand.addresses("Leo called me.", words: PersonaCatalog.rio.addressingWords))
        #expect(!SpokenCommand.addresses("Noah is coming over.", words: PersonaCatalog.nova.addressingWords))
        #expect(!SpokenCommand.addresses("Look in the mirror.", words: PersonaCatalog.mira.addressingWords))
    }

    @Test func commandsTakeThePersonasName() {
        let rio = PersonaCatalog.rio.addressingWords
        #expect(SpokenCommand.match("Rio, go to sleep", deeIsTalking: false, names: rio) == .sleep)
        #expect(SpokenCommand.match("Hey Rio, stop listening", deeIsTalking: false, names: rio) == .stopListening)
        #expect(SpokenCommand.match("stop, Rio", deeIsTalking: true, names: rio) == .stop)
        #expect(SpokenCommand.match("Rio, go to sleep", deeIsTalking: false) == nil, "without the names: conversation, as before")
        #expect(SpokenCommand.match("Dee, go to sleep", deeIsTalking: false) == .sleep, "Classic unchanged")
    }
}
