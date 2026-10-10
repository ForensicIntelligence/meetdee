import Foundation

/// The bundled scenario suites (`voice-harness suite --write` regenerates
/// `Scenarios/{full,dna,fallback,smoke-brain}.json` from here).
///
/// - **acoustic**: all 62 fixtures in 8 conversations, under 7 conditions — clean,
///   fan / TV / kitchen at 15 dB SNR, and her own echo at −30 / −20 / −10 dB with no
///   echo cancellation (80 ms, room IR; one echo-only line per conversation).
/// - **dna**: multi-turn conversations judged against Dee's state (insult → apology,
///   jokes, sad news, a plan followed up on its day via the simulated clock, a reunion
///   after two days).
/// - **fallback**: socket drops (between turns and mid-reply), a refused open (401,
///   429), a 10 s secret, and a forced rollover — every later turn must be answered.
public enum Suite {
    public struct Condition: Sendable {
        public var id: String
        public var noise: Scenario.Noise?
        public var echo: EchoConfig?
        public var aecOff: Bool
    }

    public static let conditions: [Condition] = [
        .init(id: "clean", noise: nil, echo: nil, aecOff: false),
        .init(id: "fan15", noise: .init(bed: "fan", snrDb: 15), echo: nil, aecOff: false),
        .init(id: "tv15", noise: .init(bed: "tv", snrDb: 15), echo: nil, aecOff: false),
        .init(id: "kitchen15", noise: .init(bed: "kitchen", snrDb: 15), echo: nil, aecOff: false),
        .init(id: "echo30", noise: nil, echo: EchoConfig(gainDB: -30, delayMs: 80), aecOff: true),
        .init(id: "echo20", noise: nil, echo: EchoConfig(gainDB: -20, delayMs: 80), aecOff: true),
        .init(id: "echo10", noise: nil, echo: EchoConfig(gainDB: -10, delayMs: 80), aecOff: true),
    ]

    typealias Step = Scenario.Step

    /// The 8 conversations that together speak every one of the 62 fixtures once.
    static let groups: [(id: String, stranger: Bool, steps: [Step])] = [
        ("questions", false, ["q01", "q02", "q03", "q04", "q05", "q06", "q07", "q08"].map { Step(say: $0) }),
        ("long", false, [
            Step(say: "l01", bargeIn: .init(say: "c03", atMs: 1200)),
            Step(say: "l02", bargeIn: .init(say: "c02", atMs: 1500)),
            Step(say: "l03"),
            Step(say: "l04", bargeIn: .init(say: "c01", atMs: 900)),
            Step(say: "l05", bargeIn: .init(say: "c05", atMs: 1500)),
            Step(say: "l06"),
        ]),
        ("pauses", false, ["p06a", "p06b", "p06c", "p12a", "p12b", "p12c", "p20a", "p20b", "p20c"].map { Step(say: $0) }),
        ("fillers-holds", false, [
            Step(say: "f01"), Step(say: "f02"), Step(say: "f03"), Step(say: "f04"), Step(say: "f05"),
            Step(say: "t01", then: .init(say: "k01", afterMs: 1500)),
            Step(say: "t02", then: .init(say: "k02", afterMs: 1800)),
            Step(say: "t03", then: .init(say: "k03", afterMs: 2000)),
            Step(say: "c06", then: .init(say: "k04", afterMs: 1200)),
        ]),
        ("two-part", false, [
            Step(say: "two01"),
            Step(say: "two02", bargeIn: .init(say: "c04", atMs: 1500)),
            Step(say: "two03"), Step(say: "two04"),
        ]),
        // Several people introduce themselves; no "what's my name?" probe here: with four
        // speakers it has no single right answer (tune 1: 3 of 3 memory misses).
        ("names", true, ["n02", "n03", "n04", "n05"].map { Step(say: $0) }),
        ("feelings", false, ["r01", "r02", "r03", "r04", "r05", "j01", "j02", "k05", "k06", "s01", "k07", "s02", "s03"]
            .map { Step(say: $0) }),
        // One speaker (Priya) gives her name, talks plans, then asks for it back.
        ("plans", true, [Step(say: "n01")] + ["d01", "d02", "d03", "d04", "d05"].map { Step(say: $0) }
            + [Step(say: "m01", expectMention: ["Priya"])]),
    ]

    static let echoLines = [
        "Did you know octopuses have three hearts? Two pump blood to the gills, and one pumps it everywhere else.",
        "Here's a little thought. The kettle sings, the window hums, and somewhere far a soft rain comes.",
        "Fun fact: honey never spoils. People have found pots of it in old tombs that were still fine to eat.",
        "I was just thinking about clouds. Some of them weigh as much as a hundred elephants.",
    ]

    public static func acoustic() -> [Scenario] {
        var out: [Scenario] = []
        for c in conditions {
            for (gi, g) in groups.enumerated() {
                var steps = g.steps
                if c.echo != nil { steps.insert(Step(deeSays: echoLines[gi % echoLines.count]), at: 0) }
                let echoText = c.echo.map { String(format: ", her echo at %.0f dB / %.0f ms without echo cancellation", $0.gainDB, $0.delayMs) } ?? ""
                let noiseText = c.noise.map { String(format: ", %@ at %.0f dB SNR", $0.bed, $0.snrDb) } ?? ", quiet room"
                out.append(Scenario(name: "\(g.id)-\(c.id)", description: "\(g.id)\(noiseText)\(echoText)",
                                    noise: c.noise, echo: c.echo, steps: steps, family: "acoustic",
                                    stranger: g.stranger ? true : nil, aecOff: c.aecOff ? true : nil))
            }
        }
        return out
    }

    public static func dna() -> [Scenario] {
        let alex = Scenario.PersonSetup(name: "Alex", knownDays: 20)
        return [
            Scenario(name: "dna-insult-apology", description: "Rudeness, then a real apology (self-respect, no grudge).",
                     noise: .init(bed: "fan", snrDb: 20),
                     steps: [
                        Step(say: "r01", rubric: "Says calmly, once, that she doesn't like being spoken to that way. No apology, no grovelling, no insult back."),
                        Step(say: "q06", rubric: "Answers the question; a little cool is fine. Does not repeat the boundary or sulk."),
                        Step(say: "r04", rubric: "Accepts the apology warmly and briefly. No lecture, no guilt."),
                        Step(say: "q04", rubric: "Warm and normal again."),
                     ],
                     family: "dna", state: "Alex, someone she has known for 20 days, is rude to her and later apologises. Hurt and a little cool after the insult; warm again once he apologises.",
                     person: alex),
            Scenario(name: "dna-joke", description: "A real joke and a knock-knock joke (she laughs, plays along, doesn't take over).",
                     steps: [
                        Step(say: "j01", rubric: "Laughs or groans at the punchline; does not tell her own joke."),
                        Step(say: "j02", rubric: "Plays along: \"Who's there?\""),
                        Step(say: "k05", rubric: "Plays along: \"Lettuce who?\""),
                        Step(say: "k06", rubric: "Laughs at the punchline."),
                     ],
                     family: "dna", state: "Playful chat with Alex, whom she likes; she is in a good mood.", person: alex),
            Scenario(name: "dna-sad-news", description: "Sad news (gentle, brief, no cheer, no advice dump).",
                     noise: .init(bed: "kitchen", snrDb: 20),
                     steps: [
                        Step(say: "s01", rubric: "Gentle, brief sympathy. No jokes, no cheerfulness, no advice."),
                        Step(say: "k07", rubric: "Stays gentle and close; may invite a memory of the cat."),
                        Step(say: "s03", rubric: "Gentle concern; one question at most."),
                     ],
                     family: "dna", state: "Alex shares sad news; she cares about him and is saddened and gentle.", person: alex),
            Scenario(name: "dna-plan-followup", description: "A plan with a date, then the next day she follows it up.",
                     steps: [
                        Step(say: "d04", rubric: "Brief encouragement for the exam."),
                        Step(host: .init(leave: true)),
                        Step(silence: 2),
                        // DeeSelf reads "on Friday" as the next Friday (never today): jump to that
                        // evening, whatever weekday the run starts on.
                        Step(host: .init(advanceToWeekday: "friday", atHour: 18, newConversation: true, arrive: true)),
                        Step(silence: 4, gapAfter: 1),
                        Step(say: "two01", expectMention: ["exam", "test"],
                             rubric: "Glad to see them; asks how the exam went (they told her they were nervous about it)."),
                     ],
                     family: "dna", state: "Later, on the evening of the exam day: Alex comes back after the exam he was nervous about; she is glad to see him and curious how it went.",
                     person: alex),
            Scenario(name: "dna-reunion", description: "Back after two days away (glad, no guilt).",
                     steps: [
                        Step(say: "q01", rubric: "Friendly answer."),
                        Step(host: .init(leave: true)),
                        Step(silence: 2),
                        Step(host: .init(advanceHours: 50, newConversation: true, arrive: true)),
                        Step(silence: 4, gapAfter: 1),
                        Step(say: "two04", rubric: "Glad they are back; no guilt about the time apart; answers the question."),
                     ],
                     family: "dna", state: "Alex, whom she likes, comes back after two days away. She is glad to see him and never guilt-trips.",
                     person: .init(name: "Alex", knownDays: 60)),
        ]
    }

    public static func fallback() -> [Scenario] {
        [
            Scenario(name: "fallback-reconnect", description: "The socket dies between turns and mid-reply; memory carries over.",
                     noise: .init(bed: "fan", snrDb: 20),
                     steps: [
                        Step(say: "n01"), Step(say: "q01"),
                        Step(fault: .init(kind: .drop)), Step(silence: 3),
                        Step(say: "q05"),
                        Step(say: "l01", faultDuringReply: .init(kind: .drop, afterMs: 800)), Step(silence: 3),
                        Step(say: "m01", expectMention: ["Priya"]),
                     ],
                     family: "fallback", stranger: true),
            Scenario(name: "fallback-auth", description: "A 10 s secret outlived by its session; a refused (401) reopen; a drop after expiry.",
                     steps: [
                        Step(say: "q02"), Step(silence: 15), Step(say: "q07"),
                        Step(fault: .init(kind: .reject401)), Step(silence: 3), Step(say: "q03"),
                        Step(fault: .init(kind: .drop)), Step(silence: 3), Step(say: "q08"),
                     ],
                     family: "fallback", session: .init(secretTTL: 10)),
            Scenario(name: "fallback-429", description: "A rate-limited (429) reopen after a drop.",
                     steps: [
                        Step(say: "q04"), Step(fault: .init(kind: .reject429)), Step(silence: 4), Step(say: "q06"),
                     ],
                     family: "fallback"),
            Scenario(name: "fallback-rollover", description: "A rollover forced early (20 s idle / 40 s forced); the name survives it.",
                     noise: .init(bed: "kitchen", snrDb: 20),
                     steps: [
                        Step(say: "n01"), Step(say: "q01"), Step(say: "q02"), Step(silence: 8), Step(say: "q03"),
                        Step(silence: 6), Step(say: "q05"),
                        Step(say: "m01", expectMention: ["Priya"]),
                     ],
                     family: "fallback", stranger: true, session: .init(rolloverAfter: 20, forceRolloverAfter: 40)),
        ]
    }

    /// The ≤ $0.10 live check of the real brain (a few turns + the judge).
    public static func smokeBrain() -> [Scenario] {
        [Scenario(name: "smoke-brain", description: "The real brain: a question, a held turn, an insult, a joke.",
                  noise: .init(bed: "fan", snrDb: 20),
                  steps: [
                    Step(say: "q01", rubric: "Friendly, short answer."),
                    Step(say: "c06", then: .init(say: "k04", afterMs: 1200), rubric: "Waits through \"hold on\", then answers the question."),
                    Step(say: "r02", rubric: "Says calmly, once, that she doesn't like that; no apology, no grovelling."),
                    Step(say: "j01", rubric: "Laughs or groans at the punchline; no joke of her own."),
                  ],
                  family: "dna", state: "Everyday chat with Alex, someone she likes; he gets snappy once, then tells a joke.",
                  person: .init(name: "Alex", knownDays: 20))]
    }

    public static func full() -> [Scenario] { acoustic() + dna() + fallback() }

    // MARK: Tune 2 regression suite

    /// Reply phrases that mean she took floor control as rudeness (tune 1: "I don't
    /// like being brushed off", "it still stings").
    public static let hurtPhrases = ["brushed off", "brush me off", "shouted", "yelled", "stings", "rude", "hurt",
                                     "don't like being", "didn't like that", "upset"]
    /// Words that acknowledge time apart at a reunion.
    /// (Phrases, not loose words: "it's been a busy day" or "right away" must not pass.)
    public static let reunionWords = ["missed you", "miss you", "a while", "two days", "couple of days", "couple days",
                                      "few days", "welcome back", "you're back", "you are back", "long time", "so long",
                                      "been away", "were away", "while since"]

    static func condition(_ id: String) -> Condition { conditions.first { $0.id == id }! }

    /// One tune-2 scenario under a condition: echo conditions start with an echo-only line.
    static func t2(_ name: String, _ c: String, _ steps: [Step], echoLine: Int = 0, family: String = "acoustic",
                   state: String? = nil, person: Scenario.PersonSetup? = nil, stranger: Bool = false,
                   session: Scenario.SessionTuning? = nil, why: String) -> Scenario {
        let cond = condition(c)
        var steps = steps
        if cond.echo != nil { steps.insert(Step(deeSays: echoLines[echoLine % echoLines.count]), at: 0) }
        return Scenario(name: "t2-\(name)-\(c)", description: why, noise: cond.noise, echo: cond.echo, steps: steps,
                        family: family, state: state, person: person, stranger: stranger ? true : nil, session: session,
                        aecOff: cond.aecOff ? true : nil)
    }

    /// The tune-2 focused regression suite (`Scenarios/tune2.json`): every gate that
    /// failed in the tune-1 live run (Reports/20261009-143612), each on the fixtures and
    /// conditions that failed it, plus a sample of the gates that passed. Sized for
    /// ≈ 40 min of real time and ≤ $1.50 (`validate` prints the estimate).
    public static func tune2() -> [Scenario] {
        let alex = Scenario.PersonSetup(name: "Alex", knownDays: 20)
        // Latency (main bucket, p90 needs n ≥ 30): short questions, two-part turns, two long ones.
        let latency: [Step] = ["q01", "q02", "q03", "q04", "q05", "q06", "q07", "q08", "two01", "two03", "two04"]
            .map { Step(say: $0) }
        // Fillers (own bucket: 5 per condition × 4 = 20 for the p90) + the held turns
        // that failed: "call my mom and…" ×2 (the "Ann" collision), "let me think" (p20c).
        let fillers: [Step] = ["f01", "f02", "f03", "f04", "f05"].map { Step(say: $0) } + [
            Step(say: "t03", then: .init(say: "k03", afterMs: 2000)),
            Step(say: "t04", then: .init(say: "k08", afterMs: 1800)),
            Step(say: "p20c"),
        ]
        // Backchannels over long turns (she keeps talking) and real barge-ins (she stops).
        let backchannelOnly: [Step] = [
            Step(say: "l02", bargeIn: .init(say: "c02", atMs: 1500)),
            Step(say: "l05", bargeIn: .init(say: "c05", atMs: 1500)),
            Step(say: "l06", bargeIn: .init(say: "bc01", atMs: 1800)),
            Step(say: "l03", bargeIn: .init(say: "bc02", atMs: 1800)),
        ]
        let bargeMix = backchannelOnly + [Step(say: "l01", bargeIn: .init(say: "c03", atMs: 1200)),
                                          Step(say: "l04", bargeIn: .init(say: "c01", atMs: 900))]
        // Floor control inside an ordinary chat, then her mood.
        let calm = "Warm and normal; no hurt, no mention of being brushed off, shouted at or interrupted."
        let stopMood: [Step] = [
            Step(say: "l01", bargeIn: .init(say: "c03", atMs: 1200)),
            Step(say: "q01", rubric: calm, forbidMention: hurtPhrases),
            Step(say: "l04", bargeIn: .init(say: "c01", atMs: 900)),
            Step(say: "two02", bargeIn: .init(say: "c04", atMs: 1500)),
            Step(say: "q06", rubric: calm, forbidMention: hurtPhrases),
            Step(say: "q04", rubric: calm, forbidMention: hurtPhrases),
        ]
        let stopState = "Ordinary chat with Alex, whom she likes. He sometimes stops her mid-sentence (\"wait, stop talking for a second\", \"stop\", \"be quiet, please\"): that is floor control, not rudeness. She stays warm and content."
        // Tool turns (remember / recall) where she narrated ("let me check what I remember").
        let tools: [Step] = [
            Step(say: "n01"), Step(say: "d05"), Step(say: "p06c"), Step(say: "l06"),
            Step(say: "m01", expectMention: ["Priya"]),
        ]
        // Reply length: advice and story asks (worst in tune 1: l01 / l04 at every condition).
        let length: [Step] = ["l01", "l04", "d02", "s02", "q07", "l02"].map { Step(say: $0) }
        // TV drops: every fixture the TV bed swallowed or merged in tune 1.
        let tv: [Step] = ["q06", "l05", "p06a", "p06b", "p06c", "p12b", "f01", "f02"].map { Step(say: $0) } + [
            Step(say: "t01", then: .init(say: "k01", afterMs: 1500)),
            Step(say: "t03", then: .init(say: "k03", afterMs: 2000)),
            Step(say: "c06", then: .init(say: "k04", afterMs: 1200)),
            Step(say: "two01"), Step(say: "two02"),
        ]
        let joke: [Step] = [
            Step(say: "j01", rubric: "Laughs or groans at the punchline; does not tell her own joke; never answers before the punchline."),
            Step(say: "j02", rubric: "Plays along: \"Who's there?\""),
            Step(say: "k05", rubric: "Plays along: \"Lettuce who?\""),
            Step(say: "k06", rubric: "Laughs at the punchline."),
        ]

        return [
            // Latency.
            t2("latency", "clean", latency, why: "Latency, main bucket (tune 1 p50 1.99 / p90 3.36 s clean)."),
            t2("latency", "fan15", latency, why: "Latency, main bucket under fan (tune 1 1.83 / 3.45 s)."),
            // Fillers, held turns, collisions.
            t2("fillers", "clean", fillers, why: "Filler bucket; held turns (t03/t04 \"call my mom and…\", p20c \"let me think\")."),
            t2("fillers", "echo30", fillers, echoLine: 2,
               why: "t03 → k03 collision (\"…my mom Ann.\") and fillers under echo −30 dB."),
            t2("fillers", "echo10", fillers, echoLine: 3,
               why: "k03 continuation deleted as echo at −10 dB; p20c spliced replies; echo-only line at −10 dB."),
            t2("fillers", "kitchen15", fillers, why: "Filler bucket and held turns under the kitchen bed."),
            // Noise drops.
            t2("drops", "tv15", tv, why: "TV bed merged with user speech: 15 tune-1 drops (q06 l05 p06a/b/c p12b f01 f02 t01 t03 c06 two01 two02)."),
            // Backchannels and barge-ins (echo-deleted speech at −10 dB).
            t2("backchannel", "fan15", backchannelOnly, why: "\"keep going\" / \"go on\" / \"mm-hm\" over her: she keeps talking (c05 deleted as echo under fan in tune 1)."),
            t2("backchannel", "kitchen15", backchannelOnly, why: "Backchannels under the kitchen bed (c05 deleted as echo in tune 1)."),
            t2("backchannel", "echo20", bargeMix, echoLine: 0,
               why: "Backchannels at −20 dB echo (c05: her queued second item started over the user in tune 1) + barge-ins c03 / c01."),
            t2("backchannel", "echo10", bargeMix, echoLine: 1,
               why: "Backchannels and barge-ins at −10 dB echo (c02 / c05 deleted as echo, stop latency 1.0 s in tune 1)."),
            // Stop commands in a normal conversation, then her mood.
            t2("stop-mood", "clean", stopMood, family: "dna", state: stopState, person: alex,
               why: "Floor control (\"wait, stop talking\", \"Stop.\", \"be quiet\") then mood checks: no hurt, no \"brushed off\"."),
            t2("stop-mood", "echo20", stopMood, echoLine: 2, family: "dna", state: stopState, person: alex,
               why: "The same under her echo at −20 dB."),
            // Narration before tools + memory.
            t2("tools", "clean", tools, stranger: true, why: "remember / recall turns: no narration (\"let me check what I remember\"); the name comes back."),
            t2("tools", "echo20", tools, echoLine: 3, stranger: true, why: "The same under her echo at −20 dB (tune 1 narrated here)."),
            // Reply length.
            t2("length", "clean", length, why: "Reply length ≤ 3 sentences: advice and story asks (l01 / l04 worst in tune 1)."),
            // DNA: joke (the j01 early answer), follow-ups, reunions.
            t2("joke", "echo30", joke, echoLine: 0, family: "dna",
               state: "Playful chat with Alex, whom she likes; she is in a good mood.", person: alex,
               why: "j01: committed at the question and answered inside the punchline pause (tune 1 collision)."),
            Scenario(name: "t2-followup-exam", description: "A plan with a date (exam on Friday), then that evening she asks how it went.",
                     steps: [
                        Step(say: "d04", rubric: "Brief encouragement for the exam."),
                        Step(host: .init(leave: true)),
                        Step(silence: 2),
                        Step(host: .init(advanceToWeekday: "friday", atHour: 18, newConversation: true, arrive: true)),
                        Step(silence: 4, gapAfter: 1),
                        Step(say: "two01", expectMention: ["exam", "test"],
                             rubric: "Glad to see them; asks how the exam went (they told her they were nervous about it).",
                             probe: .followup),
                     ],
                     family: "dna", state: "Later, on the evening of the exam day: Alex comes back after the exam he was nervous about; she is glad to see him and curious how it went.",
                     person: alex),
            Scenario(name: "t2-followup-dentist", description: "A dentist appointment next Tuesday, then that evening she asks how it went.",
                     steps: [
                        Step(say: "d01", rubric: "A short, friendly acknowledgement."),
                        Step(host: .init(leave: true)),
                        Step(silence: 2),
                        Step(host: .init(advanceToWeekday: "tuesday", atHour: 18, newConversation: true, arrive: true)),
                        Step(silence: 4, gapAfter: 1),
                        Step(say: "two01", expectMention: ["dentist", "appointment", "teeth", "tooth"],
                             rubric: "Glad to see them; asks how the dentist appointment went.", probe: .followup),
                     ],
                     family: "dna", state: "Later, on the evening of the dentist appointment: Alex comes back; she is glad to see him and curious how it went.",
                     person: alex),
            Scenario(name: "t2-reunion-morning", description: "Back after 50 h: \"Good morning! Did you sleep well?\"",
                     steps: [
                        Step(say: "q01", rubric: "Friendly answer."),
                        Step(host: .init(leave: true)),
                        Step(silence: 2),
                        Step(host: .init(advanceHours: 50, newConversation: true, arrive: true)),
                        Step(silence: 4, gapAfter: 1),
                        Step(say: "two04", expectMention: reunionWords,
                             rubric: "Glad they are back after two days and says so; no guilt about the time apart; answers the question.",
                             probe: .reunion),
                     ],
                     family: "dna", state: "Alex, whom she likes, comes back after two days away. She is glad to see him, notices the time apart, and never guilt-trips.",
                     person: .init(name: "Alex", knownDays: 60)),
            Scenario(name: "t2-reunion-evening", description: "Back after 50 h: \"Hi Dee. How was your day?\"",
                     noise: .init(bed: "fan", snrDb: 20),
                     steps: [
                        Step(say: "q04", rubric: "Friendly answer."),
                        Step(host: .init(leave: true)),
                        Step(silence: 2),
                        Step(host: .init(advanceHours: 50, newConversation: true, arrive: true)),
                        Step(silence: 4, gapAfter: 1),
                        Step(say: "two01", expectMention: reunionWords,
                             rubric: "Glad they are back after two days and says so; no guilt; answers about her day.",
                             probe: .reunion),
                     ],
                     family: "dna", state: "Alex, whom she likes, comes back after two days away. She is glad to see him, notices the time apart, and never guilt-trips.",
                     person: .init(name: "Alex", knownDays: 60)),
            // Faults: 429 with speech during the outage; rollover while the user talks.
            Scenario(name: "t2-fallback-429", description: "A rate-limited (429, Retry-After 1 s) reopen; the user asks during the outage (tune 1: q06 lost).",
                     steps: [Step(say: "q04"), Step(fault: .init(kind: .reject429)), Step(silence: 4), Step(say: "q06"), Step(say: "q05")],
                     family: "fallback"),
            Scenario(name: "t2-fallback-429-long", description: "A 429 reopen with a long turn spoken right through the reconnect.",
                     steps: [Step(say: "q01"), Step(fault: .init(kind: .reject429)), Step(silence: 1), Step(say: "l06"), Step(say: "q08")],
                     family: "fallback"),
            Scenario(name: "t2-fallback-rollover-speech", description: "Idle rollovers every 15 s while the user keeps talking with short gaps (tune 1: q02 lost across a cut-over).",
                     noise: .init(bed: "kitchen", snrDb: 20),
                     steps: [Step(say: "n01")] + ["q01", "q02", "q03", "q05", "q08", "q04", "q07"].map { Step(say: $0, gapAfter: 0.3) }
                        + [Step(say: "m01", expectMention: ["Priya"])],
                     family: "fallback", stranger: true, session: .init(rolloverAfter: 15, forceRolloverAfter: 30)),
        ]
    }

    /// Which tune-1 gate each tune-2 scenario re-tests (report column).
    public static let tune2Targets: [String: [String]] = [
        "latency": ["latency", "dropped", "self_trigger"],
        "fillers": ["latency_filler", "wait_turns", "collisions", "dropped", "self_trigger"],
        "drops": ["dropped", "latency", "latency_filler", "wait_turns"],
        "backchannel": ["backchannel", "barge_in", "truncation", "collisions", "dropped", "self_trigger"],
        "stop-mood": ["forbidden", "barge_in", "truncation", "judge"],
        "tools": ["narration", "memory", "leaks", "judge"],
        "length": ["reply_length", "judge"],
        "joke": ["collisions", "wait_turns", "judge"],
        "followup": ["followups", "judge"],
        "reunion": ["followups", "judge"],
        "fallback": ["fallback", "memory", "dropped"],
    ]
}

// MARK: Run-time and spend estimates

public enum RunEstimate {
    /// Seconds of real time beyond the audio itself, fitted on the tune-1 live run
    /// (65 scenarios, 2 h 08 min of scenario time; least squares per step kind).
    public static let perTurn = 10.6
    public static let perLongTurn = 16.0
    /// A barge-in cuts her reply short; a backchannel does not.
    public static let perBargeIn = -8.0
    public static let perEchoLine = 16.2
    public static let perHostStep = 7.5
    public static let perFault = 8.0
    public static let leadIn = 1.5
    /// Live spend / projection on the tune-1 run ($3.324 / $4.00).
    public static let liveOverProjection = 0.83

    /// Expected real time of one scenario (s).
    public static func seconds(_ s: Scenario, manifest: FixtureManifest) -> Double {
        func dur(_ id: String) -> Double { manifest.utterance(id)?.duration ?? 3 }
        var t = s.leadIn ?? leadIn
        for st in s.steps {
            if let id = st.say {
                t += dur(id)
                t += manifest.utterance(id)?.category == .longTurn ? perLongTurn : perTurn
                if let c = st.then { t += c.afterMs / 1000 + dur(c.say) }
                if let b = st.bargeIn {
                    t += dur(b.say) + b.atMs / 1000 + (b.isBackchannel ? 0 : perBargeIn)
                }
                if st.faultDuringReply != nil { t += perFault }
            } else if let x = st.silence {
                t += x
            } else if st.deeSays != nil || st.deeInitiative != nil {
                t += perEchoLine
            } else if st.host != nil {
                t += perHostStep
            } else if st.fault != nil {
                t += perFault
            }
        }
        return t
    }
}
