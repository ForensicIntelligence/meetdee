import Foundation

public enum CameraSide: String, Sendable, Equatable { case front, back }

public struct SeenThing: Sendable, Equatable {
    public var label: String
    public var confidence: Double
    public init(label: String, confidence: Double) {
        self.label = label
        self.confidence = confidence
    }
}

/// One glance through one camera: what Dee noticed and which of it is new to Dee.
public struct SightReport: Sendable, Equatable {
    public var camera: CameraSide
    public var things: [SeenThing]          // top labels this glance
    public var novel: [SeenThing]           // not seen recently
    /// True when this glance answers `CameraSense.glanceNow` (sent even when empty).
    public var requested: Bool
    public init(camera: CameraSide, things: [SeenThing], novel: [SeenThing], requested: Bool = false) {
        self.camera = camera
        self.things = things
        self.novel = novel
        self.requested = requested
    }
}

// MARK: - Labels

/// Turns raw classifier output (Vision's ClassifyImageRequest taxonomy identifiers)
/// into a few things worth talking about. Pure.
///
/// Three tiers: *boring* labels (people, rooms, walls, materials, the sky...) are
/// dropped; *generic* categories ("animal", "food", "musical instrument") are kept only
/// when nothing concrete was recognised; everything else is concrete and preferred.
public struct SightLabels: Sendable {
    public var minConfidence = 0.3
    public var maxThings = 3

    public init() {}

    static let boring: Set<String> = [
        "people", "adult", "child", "teen", "baby", "crowd", "person", "face", "hand", "skin",
        "indoor", "outdoor", "structure", "wall", "ceiling", "floor", "room", "interior_room",
        "interior_shop", "living_room", "bedroom", "kitchen_room", "bathroom_room", "dining_room",
        "kitchen", "bathroom", "office", "cubicle", "domicile", "building", "house_single", "apartment",
        "material", "textile", "wood_processed", "wood_natural", "raw_glass", "liquid", "cord",
        "light", "daytime", "sky", "blue_sky", "cloudy", "haze", "land", "night_sky",
        "screenshot", "illustrations", "document", "printed_page", "handwriting", "media",
        "clothing", "headgear", "footwear", "frame", "window", "door", "curtain", "portal",
        "recreation", "games", "sport", "performance", "celebration", "entertainer",
        "machine", "conveyance", "container", "decoration", "rim", "pole", "road_other",
        "chair_other", "glove_other", "candy_other", "snake_other", "celestial_body_other",
        "consumer_electronics", "electronics", "art", "polka_dots", "seat",
    ]

    static let generic: Set<String> = [
        "animal", "mammal", "canine", "feline", "reptile", "insect", "arthropods", "arachnid",
        "ungulates", "marsupial", "rodent", "cetacean", "cephalopod", "mollusk", "gastropod",
        "shellfish", "raptor", "plant", "vegetation", "foliage", "decorative_plant", "food",
        "fruit", "vegetable", "dessert", "baked_goods", "drink", "meat", "seafood", "seasonings",
        "condiment", "furniture", "appliance", "housewares", "utensil", "tableware", "cookware",
        "tool", "office_supplies", "vehicle", "watercraft", "aircraft", "musical_instrument",
        "string_instrument", "brass_music", "woodwind", "music", "sports_equipment",
        "optical_equipment", "celestial_body", "water_body", "waterways", "water", "ice",
        "ballgames", "watersport", "winter_sport", "motorsport", "bag", "ball", "sign", "toy",
        "jewelry", "christmas_decoration", "painting", "frozen", "grain", "herb", "spice", "nut",
        "berry", "citrus_fruit", "flower", "tree", "shrub",
    ]

    /// Labels that read oddly when the underscore is simply replaced.
    static let renamed: [String: String] = [
        "alligator_crocodile": "crocodile", "coyote_wolf": "wolf", "speakers_music": "speakers",
        "train_real": "train", "cake_regular": "cake", "pepper_veggie": "pepper",
        "submarine_water": "submarine", "iron_clothing": "iron", "fencing_sport": "fencing",
        "squash_sport": "squash", "cricket_sport": "cricket", "crane_construction": "crane",
        "pot_cooking": "pot", "basket_container": "basket", "organ_instrument": "organ",
        "drone_machine": "drone", "straw_drinking": "straw", "straw_hay": "hay",
        "steamer_cookware": "steamer", "swing_playground": "swing", "slide_toy": "slide",
        "jockey_horse": "jockey", "adult_cat": "cat", "engine_vehicle": "engine",
        "balloon_hotair": "hot air balloon", "sunset_sunrise": "sunset", "play_card": "playing cards",
        "tea_drink": "tea", "bathroom_faucet": "faucet", "kitchen_faucet": "faucet",
        "train_toy": "toy train", "vehicle_toy": "toy car", "stuffed_animals": "stuffed animal",
        "string_instrument": "string instrument", "brass_music": "brass instrument",
        "bernese_mountain": "bernese mountain dog", "shellfish_prepared": "shellfish",
        "computer_tower": "computer",
    ]

    /// Human words for a classifier identifier ("golf_ball" → "golf ball").
    public static func humanize(_ identifier: String) -> String {
        let key = identifier.lowercased()
        if let r = renamed[key] { return r }
        return key.replacingOccurrences(of: "_", with: " ")
    }

    static func tier(_ identifier: String) -> Int {
        let key = identifier.lowercased()
        if boring.contains(key) { return 0 }
        if generic.contains(key) { return 1 }
        return 2
    }

    /// The few things worth mentioning, best first. `animals` (from an animal
    /// recogniser, e.g. "Dog"/"Cat") are concrete and win ties.
    public func pick(_ labels: [(identifier: String, confidence: Double)],
                     animals: [(identifier: String, confidence: Double)] = []) -> [SeenThing] {
        var best: [String: (confidence: Double, tier: Int, boost: Double)] = [:]
        func consider(_ id: String, _ c: Double, boost: Double) {
            guard c.isFinite, c >= minConfidence else { return }
            let tier = Self.tier(id)
            guard tier > 0 else { return }
            let label = Self.humanize(id)
            guard !label.isEmpty else { return }
            let tierHere = boost > 0 ? 2 : tier
            if let old = best[label] {
                best[label] = (max(old.confidence, c), max(old.tier, tierHere), max(old.boost, boost))
            } else {
                best[label] = (c, tierHere, boost)
            }
        }
        for l in labels { consider(l.identifier, l.confidence, boost: 0) }
        for a in animals { consider(a.identifier, a.confidence, boost: 0.1) }
        let concrete = best.filter { $0.value.tier == 2 }
        let pool = concrete.isEmpty ? best : concrete
        return pool
            .sorted { ($0.value.confidence + $0.value.boost, $1.key) > ($1.value.confidence + $1.value.boost, $0.key) }
            .prefix(maxThings)
            .map { SeenThing(label: $0.key, confidence: min(1, $0.value.confidence)) }
    }
}

// MARK: - Novelty

/// Remembers what Dee has seen so Dee only gets excited about new things. Pure.
///
/// A label is *novel* when it hasn't been seen in the last `window` seconds (~20 min)
/// and the sighting is believable: either confident (≥ `sureConfidence`) or seen
/// twice within `confirmWithin` (so a single-frame misclassification doesn't make
/// Dee ask about a sword that isn't there). Every sighting refreshes the memory,
/// so something that stays in view never becomes novel again.
public struct NoveltyMemory: Sendable {
    public var window = 20.0 * 60
    public var sureConfidence = 0.6
    public var confirmWithin = 12.0
    public var capacity = 512

    private var lastSeen: [String: Double] = [:]
    private var candidates: [String: Double] = [:]

    public init() {}

    public func wasSeen(_ label: String, at t: Double) -> Bool {
        guard let s = lastSeen[label] else { return false }
        return t - s <= window
    }

    /// Records a glance; returns the novel subset (in the glance's order).
    public mutating func glance(_ things: [SeenThing], at t: Double) -> [SeenThing] {
        prune(at: t)
        var novel: [SeenThing] = []
        for thing in things {
            let key = thing.label
            if wasSeen(key, at: t) {
                lastSeen[key] = t
                candidates[key] = nil
            } else if thing.confidence >= sureConfidence || candidates[key].map({ t - $0 <= confirmWithin }) == true {
                novel.append(thing)
                lastSeen[key] = t
                candidates[key] = nil
            } else {
                candidates[key] = t
            }
        }
        return novel
    }

    public mutating func forget() {
        lastSeen.removeAll()
        candidates.removeAll()
    }

    private mutating func prune(at t: Double) {
        candidates = candidates.filter { t - $0.value <= confirmWithin }
        if lastSeen.count > capacity {
            lastSeen = lastSeen.filter { t - $0.value <= window }
            if lastSeen.count > capacity {
                let keep = lastSeen.sorted { $0.value > $1.value }.prefix(capacity)
                lastSeen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
        }
    }
}

// MARK: - Pacing

/// When to classify a frame and when a glance is worth reporting. Pure.
///
/// Front camera every `frontInterval` (~3 s), back camera every `backInterval`
/// (~4 s), both doubled when constrained, nothing while dozing. A glance is
/// reported when it holds something novel, otherwise at most every
/// `heartbeat` (~30 s) per camera.
public struct SightPacer: Sendable {
    public var frontInterval = 3.0
    public var backInterval = 4.0
    public var heartbeat = 30.0
    public var dozing = false
    public var constrained = false

    private var next: [CameraSide: Double] = [:]
    private var lastReport: [CameraSide: Double] = [:]

    public init() {}

    public func interval(_ camera: CameraSide) -> Double {
        let base = camera == .front ? frontInterval : backInterval
        return constrained ? base * 2 : base
    }

    /// True (and schedules the next glance) when this frame should be classified.
    public mutating func admit(_ camera: CameraSide, at t: Double) -> Bool {
        guard !dozing else { return false }
        if let n = next[camera], t < n - 0.005 { return false }
        next[camera] = t + interval(camera)
        return true
    }

    public mutating func shouldReport(_ camera: CameraSide, things: [SeenThing], novel: [SeenThing], at t: Double) -> Bool {
        guard !things.isEmpty || !novel.isEmpty else { return false }
        let due = lastReport[camera].map { t - $0 >= heartbeat } ?? true
        guard !novel.isEmpty || due else { return false }
        lastReport[camera] = t
        return true
    }

    /// After a stop/interruption: glance again soon.
    public mutating func reset() { next.removeAll() }
}

// MARK: - Capture format choice

/// A capture format as far as choosing one is concerned (so the choice is testable).
struct FormatCandidate: Sendable, Equatable {
    var width: Int
    var height: Int
    var multiCam: Bool
    var binned: Bool
    var fullRange420: Bool
    var maxFrameRate: Double
}

enum FormatChoice {
    /// The smallest multi-cam format that is at least `minWidth`×`minHeight` (landscape
    /// sensor dimensions), preferring 4:2:0 full range and binned, and able to reach
    /// `minFrameRate`. Falls back to the largest multi-cam format below the size.
    static func pick(_ formats: [FormatCandidate], minWidth: Int = 640, minHeight: Int = 480, minFrameRate: Double = 15) -> Int? {
        let usable = formats.indices.filter { formats[$0].multiCam && formats[$0].maxFrameRate >= minFrameRate }
        guard !usable.isEmpty else { return nil }
        func score(_ i: Int) -> (Int, Int, Int) {
            let f = formats[i]
            return (f.width * f.height, f.fullRange420 ? 0 : 1, f.binned ? 0 : 1)
        }
        let bigEnough = usable.filter { formats[$0].width >= minWidth && formats[$0].height >= minHeight }
        if !bigEnough.isEmpty { return bigEnough.min { score($0) < score($1) } }
        return usable.max { formats[$0].width * formats[$0].height < formats[$1].width * formats[$1].height }
    }
}

/// The back camera's sensor rate. It is only glanced at every ~4 s (8 s when
/// constrained), so it runs as slowly as the active format allows — usually 1–2 fps —
/// instead of making the sensor and ISP produce frames that are thrown away.
enum BackCameraRate {
    /// The lowest rate any of `ranges` (min/max fps) can run at, but not below `floor`.
    /// Nil when there is no usable range.
    static func pick(ranges: [(min: Double, max: Double)], floor: Double = 1) -> Double? {
        let usable = ranges.filter { $0.min > 0 && $0.min.isFinite && $0.max.isFinite && $0.max >= $0.min }
        return usable.map { Swift.max($0.min, Swift.min(floor, $0.max)) }.min()
    }
}
