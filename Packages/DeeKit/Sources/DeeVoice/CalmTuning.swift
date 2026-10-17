import Foundation

/// Spec "calm" (0.6.x, mode 1): Dee yields to sounds by *ducking* and stops only for real
/// interruptions. Every tunable of it, in one place.
///
/// The user's words after 0.6.0: "Wow! It works! But it's too sensitive to interruptions" —
/// background noise / TV, and their own short sounds (mm-hm, yeah, laughs, coughs, breaths).
/// Before calm, every voice onset over Dee's reply paused Dee (`CloudVoice.FloorHold`) within
/// ~0.15 s; 100 % of backchannels went silent for 1.27 s p50 / 2.68 s p90.
///
/// With calm the same onset evidence *ducks* Dee (−12 dB; −6 dB in a TV room) while Dee keeps
/// talking. Dee goes fully silent (the old pause) only for sustained voice (`sustainVoice`),
/// a stop or command word, words that are not "go on", or the brain asking for a reply.
/// No deadline of a duck ever cuts the reply.
public enum CalmTuning {
    // MARK: The duck

    /// Dee's gain while ducked: clearly gives way, still intelligible.
    public static let duckGainDB = -12.0
    /// …in a TV room (`RoomBed.tvLike`): TV peaks cause less pumping.
    public static let duckGainTVDB = -6.0
    /// Linear ramps per sample: down to the duck gain over `duckAttack`, back up over
    /// `duckRelease`. `PCMStreamPlayer.hold()` keeps its 5 ms fade to 0 from any gain.
    public static let duckAttack = 0.040
    public static let duckRelease = 0.200

    // MARK: Sustain (`EarCore.sustainedVoice`)

    /// Counted near-end voice that pauses a ducked Dee (decision D2, round 2: "~1.2 s of
    /// continuous near-field voice"). Round 1's 0.50 s paused Dee on 15 of 33 continuers live
    /// ("Mm-hm" 0.82 s, "Oh wow" 1.04 s voiced); measured on the harness fixtures the longest
    /// continuer counts 0.96 s (clean) and a real question 0.72–1.16 s, so a question is not
    /// paused by its sound: its words do that (`.answer`), stop words and Dee's name at their
    /// first transcript delta. `DEE_SUSTAIN_VOICE` (`sustainRange`) overrides it, for replay A/B.
    public static let sustainVoice: Double = sustainOverride() ?? 1.2
    /// …of which at least this much pitched (a coughing fit, breaths, clatter stay unpitched).
    public static let sustainPitched = 0.6
    /// Round 2, no echo cancellation only (`EarCore.serverSustain`): the ducked item's speech
    /// open this long after its onset, `sustainServerNear` of near-end voice in the burst
    /// (half of it pitched), the last near frame within `sustainServerLive`.
    public static let sustainServerOpen = 1.5
    public static let sustainServerNear = 0.5
    public static let sustainServerLive = 0.2
    /// Gaps up to this long are bridged (not counted): "Wait, — stop" stays one burst.
    public static let sustainGap = 0.25
    /// Only a user who is still talking pauses Dee: their last near frame this recent.
    public static let sustainLive = 0.12
    /// The burst may have begun this long before the duck.
    public static let sustainLookback = 1.0

    // MARK: TV room

    /// Round 2: a room counts as a TV room ("a loud bed") also when its bed's ceiling is at
    /// least this loud — live, the voice-like share never qualified at tv15 (the bed only
    /// learns the frames under its gate, where a TV is not voice-like): 1 duck of 30 had the
    /// TV gain. The harness TV / fan / kitchen beds at 15 dB SNR sit at −46…−36 dBFS, a quiet
    /// room under −55. Every TV-room rule only asks the user's voice to stand clearly above
    /// the bed, which a voice at the phone does (+10 dB or more at 15 dB SNR).
    public static let loudBedDB = -46.0
    /// …and only a bed that comes and goes like talk: its ceiling this far over its floor
    /// (round 2 review, regress F1). Measured on the harness beds at 10–20 dB SNR: TV
    /// 9.8 dB, the long TV 4.7 dB; a fan 2.6 dB, a kitchen 0.8 dB (its clatter never enters
    /// the bed; its hum is steady). A steady bed has nobody talking in it.
    public static let tvSpreadDB = 3.5
    /// TV room: a stop / command word or Dee's name counts as the user's only with at least
    /// this much of the item's own voice at the TV bar (a lone "Stop." has 0.32–0.44 s at
    /// tv10–tv15; a TV phrase 4 dB over the bed's ceiling passes 0.15 s).
    public static let commandVoice = 0.25
    /// Round 3 (live calm-ask-tv15 c03, both runs: the user's "Wait." — split off by the quick
    /// commit — was dropped as the TV, silent only 2.5 s later): a stop / command word, Dee's
    /// name, or a question ("…?") in a TV room is also the user's with near-field evidence —
    /// its loudest near-end frame at least this far over the bed's ceiling, with at least
    /// `commandPeakVoice` at the TV bar. Measured (RoomSim, harness beds tv15 / tv10 / tvlong,
    /// the item's first 0.7 s): the user's c03 "Wait," +13.7…+21.8 dB (0.08–0.16 s at the TV
    /// bar), c01 / c08 +19.7…+28.3; TV speech as loud as the bed's loud parts +3.8…+11.1, 2 dB
    /// louder at most +12.9. (A soft user — q03 at tv15, +10.4 — stays the round-2 residual: its
    /// whole utterance decides, `ambientHold`.)
    public static let commandPeakDB = 13.0
    public static let commandPeakVoice = 0.08
    /// Round 3 review (regress F1): an item that begins at most this long after our own quick
    /// commit closed the one before it is the rest of the same utterance (live calm-ask-tv15 q03:
    /// «What?» committed by us, «time is it?» begun ~0.3 s later). The TV's voice is summed over
    /// one such utterance only, never over phrases the server's VAD split.
    public static let splitJoinGap = 0.8
    // Round 3 (live calm-ask-tv15 q03: "What?" | "time is it?" split by the quick commit, all
    // dropped as the TV when the first item's words came while the next was still being said):
    // in a TV room the hold's words are judged as the TV only once no item of it is still open
    // or waiting for its words (`CloudVoice.FloorHold.tvPending`), up to `duckMax`, and on all
    // of its items together (their voice at the TV bar over their spans).

    /// In a TV room the sustain bar (and the local-only path's bar) is this far over the
    /// bed's ceiling (the room bar elsewhere uses +3 dB).
    public static let tvCeilingMarginDB = 6.0
    /// The bed is a TV once the median share of voice-like frames over its slices reaches
    /// this, with at least `tvMinSpan` of slices…
    public static let tvVoiceShare = 0.25
    public static let tvMinSpan = 3.0
    /// …and stays one until `tvHold` passed with no qualifying slice.
    public static let tvHold = 30.0
    /// TV room: non-continuer words of a ducked item escalate only with this much of the
    /// item's own near-end voice at the TV bar, and this share of its speech span (or a stop /
    /// command word, or "Dee", or `.sustained`). Round 2: the TV bar is ceiling + 6 dB, which
    /// the harness TV bed alone never reaches (no 40 ms frame over ceiling + 3 in 52 s), and a
    /// TV phrase as loud as the bed's loud parts reaches for ~0.1 s; round 1's 0.35 s / 40 %
    /// dropped real questions in a loud room ("What time is it?" at tv15: 0.36 s of 2.0 s,
    /// 18 %; "Hold on, hold on." 37 %). Residual: a TV phrase 2 dB or more over the bed's own
    /// loud parts measures like a soft user (tv15 "What time is it?" 0.28 s over the bar).
    public static let itemSustain = 0.25
    public static let itemSustainShare = 0.12

    /// Round 2: a stop word in an item already rejected as Dee's echo pauses Dee only with
    /// at least this much of the user's near-end voice in the last `rejectedStopWindow`.
    public static let rejectedStopVoice = 0.12
    public static let rejectedStopWindow = 3.0

    // MARK: Ducked deadlines (none of them cuts the reply)

    /// Unduck this long after `speech_stopped` or the quick commit when no words came.
    public static let duckWordsWait = 0.6
    /// Unduck when the duck has no server item this long.
    public static let duckNoItem = 1.5
    /// A duck never lasts longer than this.
    public static let duckMax = 3.0
    /// A SoundAnalysis cough / sneeze / laughter / breathing label this confident that
    /// overlaps the burst releases the duck when the words have at most `labelMaxTokens`.
    public static let labelConfidence = 0.4
    public static let labelMaxTokens = 2

    // MARK: Words

    /// Laugh tokens, sound tags and fillers count as "go on" inside a hold only when the
    /// item's burst (its pitched voice) is at most this long.
    public static let tokenBurstMax = 1.5
    /// A hold resolved by a resume or an unduck still claims its items this long
    /// (`CloudVoice.holdClaims`): the brain's `wordsFailed` never answers them.
    public static let recentlyResolvedTTL = 5.0

    /// One word that, alone, stops Dee or calls Dee (`CloudVoice.stopsHerAlone`).
    public static let stopAlone: Set<String> = ["stop", "wait", "no", "hey", "hello", "what"]
    /// Round 2: a clause that begins with one of these (fillers aside) stops Dee: "Stop
    /// talking for a second.", "Wait, I have a question." ("Don't stop" never does).
    public static let stopLeads: Set<String> = ["stop", "wait"]
    /// Words or phrases that stop Dee anywhere in what they said. Dee's name (and the
    /// persona's: `hasCommandWord(_:names:)`) is one of them.
    public static let commandPhrases: [String] = ["hold on", "hang on", "hold up", "excuse me", "be quiet", "quiet",
                                                  "shush", "stop talking", "one second", "one sec", "dee"]
    static let aloneFillers: Set<String> = ["please", "just", "so", "well", "now", "a", "an", "uh", "um", "oh", "okay", "ok"]

    /// `text` holds a stop or command word: alone, "stop" / "wait" / "no" / "hey" /
    /// "hello" / "what"; at the start of a clause, "stop" / "wait"; anywhere, "hold on",
    /// "hang on", "hold up", "excuse me", "be quiet", "quiet", "shush", "stop talking",
    /// "one second", "Dee" or one of `names` (the persona's name). Works on the first
    /// transcript delta ("Stop", "Wait") as on the full words.
    ///
    /// `partial`: `text` is transcript deltas so far — a word that stops Dee only alone
    /// ("No", "What", "Hey") counts only once a closing mark (`.`, `!`, `?`, `…`) ends it ("What"
    /// may become "What's", "What time is it?"; round 2 review: a comma ends no utterance —
    /// "No," is the start of "No, keep going.", "Hey," of "Hey, that's cool."); "Stop" / "Wait"
    /// count at once. The phrases and the names count only for words a later delta can no
    /// longer lengthen (followed by a space or a mark): "Dee" may be the start of "Deep",
    /// "haven" of "haven't".
    public static func hasCommandWord(_ text: String, names: [String] = [], partial: Bool = false) -> Bool {
        let flat = text.replacingOccurrences(of: "-", with: " ")
        let w = Backchannel.words(flat)
        guard !w.isEmpty else { return false }
        let kept = w.filter { !aloneFillers.contains($0) }
        let last = flat.last
        let ended = !partial || last.map { ".!?…".contains($0) } == true
        if kept.count == 1, stopAlone.contains(kept[0]), ended || stopLeads.contains(kept[0]) { return true }
        for clause in flat.split(whereSeparator: { ",.!?;:…—".contains($0) }) {
            if let first = Backchannel.words(String(clause)).first(where: { !aloneFillers.contains($0) }),
               stopLeads.contains(first) { return true }
        }
        let whole = !partial || last.map { $0.isWhitespace || ".!?,;:…—)\"".contains($0) } == true
        let complete = whole ? w : Array(w.dropLast())
        let joined = " " + complete.joined(separator: " ") + " "
        let extra = names.map { Backchannel.words($0).joined(separator: " ") }.filter { !$0.isEmpty }
        return (commandPhrases + extra).contains { joined.contains(" \($0) ") }
    }

    /// Words that only stop or call Dee — command words, the names and fillers, nothing else
    /// ("Stop talking for a second.", "Wait.", "Hold on, Dee."): no question or turn of their
    /// own. Round 2 review (correct F3): anything more ("Wait, what did you say about the
    /// moon?") is a turn the brain answers.
    public static func isOnlyCommand(_ text: String, names: [String] = []) -> Bool {
        guard hasCommandWord(text, names: names) else { return false }
        var rest = Set(Backchannel.words(text.replacingOccurrences(of: "-", with: " ")))
        rest.subtract(aloneFillers)
        rest.subtract(stopAlone)
        rest.subtract(commandOnlyWords)
        for n in names { rest.subtract(Backchannel.words(n)) }
        return rest.isEmpty
    }
    static let commandOnlyWords: Set<String> = ["hold", "on", "hang", "up", "excuse", "me", "be", "quiet", "shush", "talking",
                                                "one", "second", "sec", "dee", "for", "moment", "minute", "a", "the", "sorry",
                                                "there", "it", "that", "you", "stop", "wait"]

    /// Round 2: a stop that is not only one of the short words Dee's own echo is often
    /// misheard as ("No.", "What?", "Hey.", "Hello."): "Stop.", "Wait.", "Stop talking…",
    /// "Hold on", "Dee".
    public static func isStrongStop(_ text: String, names: [String] = []) -> Bool {
        guard hasCommandWord(text, names: names) else { return false }
        let kept = Backchannel.words(text.replacingOccurrences(of: "-", with: " ")).filter { !aloneFillers.contains($0) }
        return !(kept.count == 1 && ["no", "hey", "hello", "what"].contains(kept[0]))
    }

    // MARK: Environment (A/B without a rebuild)

    /// `DEE_DUCK_ON_ONSET=0|1`: overrides the default of `CloudVoice.Configuration.duckOnOnset`
    /// (an explicit setting still wins). Read where `CloudSettings` reads its VAD knob.
    public static let duckEnvironmentKey = "DEE_DUCK_ON_ONSET"
    /// `DEE_SUSTAIN_VOICE=0.45…2.0`: overrides `sustainVoice` (replay A/B only).
    public static let sustainEnvironmentKey = "DEE_SUSTAIN_VOICE"
    public static let sustainRange = 0.45...2.0

    public static func duckOverride(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool? {
        switch env[duckEnvironmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "on", "yes": true
        case "0", "false", "off", "no": false
        default: nil
        }
    }

    public static func sustainOverride(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        guard let raw = env[sustainEnvironmentKey]?.trimmingCharacters(in: .whitespaces), let v = Double(raw),
              sustainRange.contains(v) else { return nil }
        return v
    }

    /// dB → linear amplitude.
    static func gain(_ db: Double) -> Float { Float(pow(10, db / 20)) }
}
