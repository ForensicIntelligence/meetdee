import Foundation

/// A touch on Dee's face, as the mind understands it (DeeSense's `TouchGesture`
/// maps onto this one-to-one).
public enum Touch: Sendable, Equatable {
    case tap, doubleTap
    /// Slow strokes. `gentleness` 0…1.
    case pet(gentleness: Double, seconds: Double)
    /// Still, steady contact — a hug.
    case hold(seconds: Double)
    /// Rapid repeated taps. `count` is the running total of the burst so far
    /// (DeeSense's `TouchGesture.pokes(…, total:)`), not the pokes in one event.
    case pokes(count: Int)
    /// Fast, hard, short contact. `force` 0…1.
    case slap(force: Double)
    case tickle(seconds: Double)

    /// Short human word, for prompts and logs.
    public var word: String {
        switch self {
        case .tap: "tap"
        case .doubleTap: "double tap"
        case .pet: "pet"
        case .hold: "hug"
        case .pokes: "pokes"
        case .slap: "slap"
        case .tickle: "tickle"
        }
    }
}

extension Appraisal {
    /// Tickling stops being fun after about this many seconds.
    public static let tickleFunSeconds = 4.0
    /// Up to this many pokes in a burst are playful; past it they grate.
    public static let playfulPokes = 4.0

    /// What a touch means emotionally. Gentle, caring touch reads as kindness (warmth,
    /// affection, care) — so it raises joy, affection, trust and drifts personality
    /// toward agreeable and confident, habituating like kind words do. Rough touch
    /// reads as hostility and dominance.
    public static func touch(_ t: Touch) -> Appraisal {
        var a = Appraisal()
        a.touch = t
        a.aimedAtDee = true
        a.novelty = 0.4
        switch t {
        case .tap:
            // "Hey, look at me": mild attention.
            a.interestInDee = 0.3
            a.warmth = 0.1
            a.valence = 0.1
            a.novelty = 0.6
        case .doubleTap:
            a.humor = 0.35
            a.warmth = 0.2
            a.interestInDee = 0.2
            a.valence = 0.25
            a.novelty = 0.6
        case let .pet(gentleness, seconds):
            let g = clamp01(gentleness)
            // Scaled by gentleness and by how long it lasted (a brief stroke counts
            // less than a long, slow pet; saturates around 6 s).
            let s = g * min(1, 0.35 + max(0, seconds) / 6)
            a.warmth = 0.75 * s
            a.affection = 0.45 * s
            a.care = s
            a.valence = 0.55 * s
            a.dominance = -0.2 * s
            a.loudness = -0.5 * s      // the touch equivalent of speaking softly
            // A rough "pet" (low gentleness) is mildly unwelcome.
            if g < 0.3 {
                a.hostility = (0.3 - g) * 0.6
                a.valence -= (0.3 - g)
            }
        case let .hold(seconds):
            let s = min(1, 0.35 + max(0, seconds) / 8)
            a.warmth = 0.65 * s
            a.affection = 0.6 * s
            a.care = 0.9 * s
            a.valence = 0.55 * s
            a.dominance = -0.15 * s
            a.loudness = -0.5 * s
        case let .pokes(count):
            // `count` is the burst total so far; each event of a burst is appraised
            // at its total, so a long burst escalates. A few pokes are a playful
            // "hey!"; from about 6 they start to grate; 10+ is plainly annoying.
            let n = Double(max(1, count))
            let annoying = max(0, n - playfulPokes)          // pokes past the fun ones
            a.interestInDee = max(0, 0.25 - 0.04 * n)
            a.humor = max(0, 0.25 - 0.05 * n)
            a.hostility = min(0.65, 0.01 * n + 0.07 * annoying)
            a.dominance = min(0.8, 0.07 * n)
            a.intensity = min(0.6, 0.1 + 0.04 * n)
            a.valence = annoying > 0 ? -min(0.6, 0.06 * annoying) : 0.1 - 0.02 * n
            a.repetition = min(0.6, 0.06 * annoying)
            a.novelty = annoying > 0 ? 0.2 : 0.4
        case let .slap(force):
            let f = clamp01(force)
            a.hostility = 0.4 + 0.5 * f
            a.intensity = 0.5 + 0.5 * f
            a.dominance = 0.6 + 0.35 * f
            a.valence = -(0.5 + 0.4 * f)
            a.startle = 0.5 + 0.5 * f
            a.novelty = 0.3
        case let .tickle(seconds):
            let over = clamp01((max(0, seconds) - tickleFunSeconds) / 6)
            a.overstimulation = over
            a.humor = max(0, min(1, 0.55 + 0.1 * seconds) * (1 - over))
            a.warmth = 0.3 * (1 - over)
            a.valence = 0.5 - 0.9 * over
            a.intensity = 0.2 + 0.5 * over
            a.startle = 0.15 + 0.3 * over
            if over > 0.5 { a.hostility = (over - 0.5) * 0.4 }
            a.novelty = 0.5
        }
        return a
    }

    /// What a sound in the room means. `loudness` is 0…1, or dBFS when negative
    /// (−60 dB → 0 … −10 dB → 1). Unexpected loud sounds startle (surprise, a little
    /// fear) and catch interest; music, laughter and applause/cheering delight;
    /// crying draws concern (not fright); alarming sounds (sirens, alarms, breaking
    /// glass, screams) frighten. Not social: a sound moves feelings but never the
    /// bond or personality.
    public static func sound(label: String, unexpected: Bool, loudness: Double) -> Appraisal {
        var a = Appraisal()
        a.social = false
        a.aimedAtDee = false
        a.soundLabel = label
        let loud = loudness < 0 ? clamp01((loudness + 60) / 50) : clamp01(loudness)
        let kind = SoundKind(label)
        a.novelty = unexpected ? 0.75 : 0.25
        a.startle = unexpected ? 0.25 + 0.6 * loud : 0.1 * loud
        a.intensity = loud * (unexpected ? 0.6 : 0.3)
        switch kind {
        case .alarming:
            a.alarm = 0.45 + 0.45 * loud
            a.valence = -0.4
        case .music:
            a.delight = 0.5 + 0.2 * (1 - abs(loud - 0.5))
            a.valence = 0.4
            a.startle *= 0.4
        case .laughter:
            a.delight = 0.4
            a.humor = 0.6
            a.valence = 0.4
            a.startle *= 0.4
        case .applause:
            a.delight = 0.55
            a.humor = 0.2
            a.valence = 0.45
            a.startle *= 0.4
        case .crying:
            a.distress = 0.5
            a.valence = -0.15
            a.startle *= 0.5
        case .pleasant:
            a.delight = 0.35
            a.valence = 0.25
            a.startle *= 0.6
        case .other:
            a.valence = 0
        }
        return a
    }

    /// Dee's own internal event (v0.5): `relief` (0…1) when an expectation Dee
    /// was nervous about resolved well, `pride` (0…1) when Dee completed one of Dee's
    /// intentions. Not social: it moves joy, fear, sadness and interest, never the
    /// bond, loneliness, the relationship counters or personality. No startle, no
    /// novelty. Values are clamped to 0…1.
    public static func `internal`(relief: Double = 0, pride: Double = 0) -> Appraisal {
        var a = Appraisal()
        a.social = false
        a.aimedAtDee = false
        a.isInternal = true
        a.relief = clamp01(relief)
        a.pride = clamp01(pride)
        a.novelty = 0
        a.valence = min(1, 0.4 * a.relief + 0.4 * a.pride)
        return a
    }

    /// Dee saw something. `novelty` 0…1 (never seen / not seen recently = 1).
    public static func sight(novelty: Double) -> Appraisal {
        var a = Appraisal()
        let n = clamp01(novelty)
        a.social = false
        a.aimedAtDee = false
        a.isSight = true
        a.novelty = n
        a.startle = 0.25 * n
        a.delight = 0.15 * n
        a.valence = 0.1 * n
        return a
    }
}

/// Coarse categories of `HeardSound.label`s (Apple's SoundAnalysis vocabulary, in words).
enum SoundKind: Equatable {
    /// `applause` covers applause, cheering and clapping (social delight);
    /// `crying` (sobbing, a baby crying) draws concern, not alarm.
    case alarming, crying, music, laughter, applause, pleasant, other

    init(_ label: String) {
        let l = label.lowercased()
        let words = l.split { !$0.isLetter }.map(String.init)
        // Single-word keys match the start of a word ("laugh" → "laughing", but
        // "rain" ≠ "train"); multi-word keys match as a phrase.
        func has(_ keys: [String]) -> Bool {
            keys.contains { k in k.contains(" ") ? l.contains(k) : words.contains { $0.hasPrefix(k) } }
        }
        if has(["alarm", "siren", "smoke", "scream", "shout", "yell", "crash", "breaking", "shatter", "explosion",
                "gunshot", "gun", "firework", "thunder", "smash", "bang", "slam", "growl", "honk", "boom"]) {
            self = .alarming
        } else if words.contains(where: { ["cry", "cries", "cried", "crying"].contains($0) }) || has(["sobb", "whimper", "weep", "wail"]) {
            self = .crying
        } else if has(["applau", "cheer", "clap", "crowd cheering", "ovation", "hooray", "bravo"]) {
            self = .applause
        } else if has(["doorbell", "knock", "door", "phone", "ring", "ding", "beep", "footstep", "speech", "talk", "voice"]) {
            self = .other
        } else if has(["laugh", "giggl", "chuckl", "snicker"]) {
            self = .laughter
        } else if has(["music", "sing", "song", "guitar", "piano", "violin", "drum", "instrument", "whistl", "choir",
                       "humming", "orchestra", "chime", "ukulele", "flute", "trumpet", "saxophone", "harp"]) {
            self = .music
        } else if has(["bird", "chirp", "tweet", "purr", "meow", "rain", "stream", "ocean", "cat", "kitten", "coo"]) {
            self = .pleasant
        } else {
            self = .other
        }
    }
}

@inline(__always) func clamp01(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
