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
        ("names", true, ["n02", "n03", "n04", "n05", "n01"].map { Step(say: $0) }
            + [Step(say: "m01", expectMention: ["Priya"])]),
        ("feelings", false, ["r01", "r02", "r03", "r04", "r05", "j01", "j02", "k05", "k06", "s01", "k07", "s02", "s03"]
            .map { Step(say: $0) }),
        ("plans", false, ["d01", "d02", "d03", "d04", "d05"].map { Step(say: $0) }),
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
}
