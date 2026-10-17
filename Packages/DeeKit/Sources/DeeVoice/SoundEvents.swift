import Foundation

/// Human words and families for the SoundAnalysis v1 classifier identifiers.
public enum SoundCatalog {
    public static func label(for identifier: String) -> String {
        if let l = labels[identifier] { return l }
        return identifier.replacingOccurrences(of: "_", with: " ")
    }

    public static func kind(of identifier: String) -> SoundKind {
        if identifier == "silence" { return .silence }
        if speech.contains(identifier) { return .speech }
        if laughter.contains(identifier) { return .laughter }
        if crying.contains(identifier) { return .crying }
        if applause.contains(identifier) { return .applause }
        if music.contains(identifier) { return .music }
        if ambient.contains(identifier) { return .ambient }
        return .event
    }

    static let speech: Set<String> = ["speech", "whispering", "chatter", "crowd", "babble", "children_shouting"]
    static let laughter: Set<String> = ["laughter", "baby_laughter", "giggling", "snicker", "belly_laugh", "chuckle_chortle"]
    static let crying: Set<String> = ["crying_sobbing", "baby_crying"]
    static let applause: Set<String> = ["clapping", "cheering", "applause"]

    static let music: Set<String> = [
        "music", "singing", "choir_singing", "yodeling", "rapping", "humming", "whistling",
        "plucked_string_instrument", "guitar", "electric_guitar", "bass_guitar", "acoustic_guitar",
        "steel_guitar_slide_guitar", "guitar_tapping", "guitar_strum", "banjo", "sitar", "mandolin", "zither",
        "ukulele", "keyboard_musical", "piano", "electric_piano", "organ", "electronic_organ", "hammond_organ",
        "synthesizer", "harpsichord", "percussion", "drum_kit", "drum", "snare_drum", "bass_drum", "timpani",
        "tabla", "cymbal", "hi_hat", "tambourine", "rattle_instrument", "gong", "mallet_percussion",
        "marimba_xylophone", "glockenspiel", "vibraphone", "steelpan", "orchestra", "brass_instrument",
        "french_horn", "trumpet", "trombone", "bowed_string_instrument", "violin_fiddle", "cello", "double_bass",
        "wind_instrument", "flute", "saxophone", "clarinet", "oboe", "bassoon", "harp", "harmonica", "accordion",
        "bagpipes", "didgeridoo", "theremin", "singing_bowl", "disc_scratching",
    ]

    /// The room's furniture: always there, never news.
    static let ambient: Set<String> = [
        "breathing", "wind", "wind_rustling_leaves", "wind_noise_microphone", "rain", "raindrop",
        "stream_burbling", "water", "ocean", "sea_waves", "gurgling", "mechanical_fan", "air_conditioner",
        "traffic_noise", "car_passing_by", "engine", "engine_idling", "clock", "tick", "tick_tock",
        "typing", "typing_computer_keyboard", "click", "person_walking", "person_shuffling", "chewing",
        "liquid_trickle_dribble", "liquid_dripping", "underwater_bubbling", "writing", "rail_transport",
        "subway_metro", "aircraft", "airplane", "insect", "cricket_chirp", "fire", "fire_crackle", "boiling",
        "frying_food", "white_noise", "pink_noise", "hum", "sink_filling_washing", "water_tap_faucet",
    ]

    static let labels: [String: String] = [
        "shout": "someone shouting", "yell": "someone yelling", "battle_cry": "a battle cry",
        "screaming": "screaming", "laughter": "laughter", "baby_laughter": "a baby laughing",
        "giggling": "giggling", "snicker": "a snicker", "belly_laugh": "a big belly laugh",
        "chuckle_chortle": "a chuckle", "crying_sobbing": "crying", "baby_crying": "a baby crying",
        "sigh": "a sigh", "singing": "singing", "humming": "humming", "whistling": "whistling",
        "snoring": "snoring", "gasp": "a gasp", "cough": "a cough", "sneeze": "a sneeze",
        "nose_blowing": "someone blowing their nose", "person_running": "running footsteps",
        "burp": "a burp", "hiccup": "hiccups", "slurp": "slurping", "finger_snapping": "finger snapping",
        "clapping": "clapping", "cheering": "cheering", "applause": "applause", "booing": "booing",
        "dog": "a dog", "dog_bark": "a dog barking", "dog_howl": "a dog howling", "dog_bow_wow": "a dog barking",
        "dog_growl": "a dog growling", "dog_whimper": "a dog whimpering", "cat": "a cat", "cat_purr": "a cat purring",
        "cat_meow": "a cat meowing", "horse_neigh": "a horse", "cow_moo": "a cow mooing", "rooster_crow": "a rooster",
        "duck_quack": "a duck quacking", "bird": "a bird", "bird_vocalization": "birds", "bird_chirp_tweet": "birds chirping",
        "owl_hoot": "an owl hooting", "crow_caw": "a crow", "mosquito_buzz": "a mosquito", "fly_buzz": "a buzzing fly",
        "bee_buzz": "a buzzing bee", "frog_croak": "a frog croaking", "music": "music", "guitar": "a guitar",
        "piano": "a piano", "drum": "drums", "drum_kit": "drums", "violin_fiddle": "a violin", "bell": "a bell",
        "church_bell": "church bells", "bicycle_bell": "a bicycle bell", "chime": "a chime", "wind_chime": "wind chimes",
        "thunderstorm": "a thunderstorm", "thunder": "thunder", "car_horn": "a car horn", "vehicle_skidding": "tyres skidding",
        "air_horn": "an air horn", "reverse_beeps": "reversing beeps", "emergency_vehicle": "an emergency vehicle",
        "police_siren": "a police siren", "ambulance_siren": "an ambulance siren", "fire_engine_siren": "a fire engine",
        "motorcycle": "a motorcycle", "train_whistle": "a train whistle", "train_horn": "a train horn",
        "helicopter": "a helicopter", "lawn_mower": "a lawn mower", "chainsaw": "a chainsaw", "engine_starting": "an engine starting",
        "engine_accelerating_revving": "an engine revving", "door": "a door", "door_bell": "the doorbell",
        "door_sliding": "a sliding door", "door_slam": "a door slamming", "knock": "knocking", "tap": "tapping",
        "squeak": "a squeak", "drawer_open_close": "a drawer", "dishes_pots_pans": "pots and pans",
        "cutlery_silverware": "cutlery clinking", "chopping_food": "chopping", "microwave_oven": "the microwave",
        "blender": "a blender", "hair_dryer": "a hair dryer", "toilet_flush": "a toilet flushing",
        "toothbrush": "a toothbrush", "vacuum_cleaner": "a vacuum cleaner", "zipper": "a zipper",
        "keys_jangling": "jangling keys", "coin_dropping": "a dropped coin", "scissors": "scissors",
        "electric_shaver": "an electric shaver", "telephone": "a phone", "telephone_bell_ringing": "a phone ringing",
        "ringtone": "a ringtone", "alarm_clock": "an alarm clock", "siren": "a siren", "civil_defense_siren": "an air-raid siren",
        "smoke_detector": "the smoke alarm", "foghorn": "a foghorn", "printer": "a printer", "camera": "a camera shutter",
        "hammer": "hammering", "saw": "sawing", "power_tool": "a power tool", "drill": "a drill",
        "gunshot_gunfire": "a bang like a gunshot", "artillery_fire": "booming", "fireworks": "fireworks",
        "firecracker": "a firecracker", "boom": "a boom", "wood_cracking": "wood cracking", "glass_clink": "glasses clinking",
        "glass_breaking": "glass breaking", "liquid_splashing": "splashing", "liquid_pouring": "pouring",
        "whoosh_swoosh_swish": "a whoosh", "thump_thud": "a thud", "basketball_bounce": "a bouncing ball",
        "slap_smack": "a slap", "crushing": "crunching", "crumpling_crinkling": "crinkling", "tearing": "tearing",
        "beep": "a beep", "sewing_machine": "a sewing machine", "typewriter": "a typewriter",
    ]
}

/// Decides which classifier results Dee should hear about.
///
/// - Speech, silence and ambient classes are never reported.
/// - Music is reported only when it *starts* (not while it keeps playing).
/// - A class counts as unexpected only if it is confident, louder than the room by
///   a margin, and not heard in the last ~10 minutes.
/// - Social sounds (laughter, crying, applause) are always reported — rate-limited
///   and with `isUnexpected == false` — so Dee can laugh along with you whatever
///   Dee's mood. That's what makes Dee feel alive.
public struct UnexpectedSoundFilter: Sendable {
    public var minConfidence: Double = 0.6
    public var minAboveAmbientDB: Double = 8
    public var noveltyWindow: Double = 600
    public var musicHold: Double = 30
    public var socialMinConfidence: Double = 0.5
    public var socialMinAboveAmbientDB: Double = 4
    public var socialRepeat: Double = 6

    private var lastHeard: [String: Double] = [:]
    private var lastMusic: Double?
    private var lastSocial: [SoundKind: Double] = [:]

    public init() {}

    public mutating func evaluate(identifier: String, confidence: Double, loudnessDB: Double,
                                  ambientDB: Double, at t: Double) -> HeardSound? {
        let kind = SoundCatalog.kind(of: identifier)
        guard confidence.isFinite, confidence >= min(minConfidence, socialMinConfidence) * 0.75 else { return nil }

        let previous = lastHeard[identifier]
        let familiar = previous.map { t - $0 < noveltyWindow } ?? false
        lastHeard[identifier] = t
        let above = loudnessDB - ambientDB
        let salient = confidence >= minConfidence && above >= minAboveAmbientDB

        func sound(_ unexpected: Bool) -> HeardSound {
            HeardSound(label: SoundCatalog.label(for: identifier), identifier: identifier,
                       confidence: confidence, loudnessDB: loudnessDB, isUnexpected: unexpected)
        }

        switch kind {
        case .speech, .silence, .ambient:
            return nil
        case .music:
            let ongoing = lastMusic.map { t - $0 < musicHold } ?? false
            if confidence >= minConfidence * 0.75 { lastMusic = t }
            return (!ongoing && salient && !familiar) ? sound(true) : nil
        case .laughter, .crying, .applause:
            guard confidence >= socialMinConfidence, above >= socialMinAboveAmbientDB else { return nil }
            if let last = lastSocial[kind], t - last < socialRepeat { return nil }
            lastSocial[kind] = t
            return sound(false)
        case .event:
            return (salient && !familiar) ? sound(true) : nil
        }
    }

    /// Forget everything (e.g. after a long sleep).
    public mutating func reset() {
        lastHeard.removeAll()
        lastMusic = nil
        lastSocial.removeAll()
    }
}
