import DeeCore
import DeeMemory
import DeeMind
import Foundation

// SELF.md §4.1 — what goes into Cortex and what comes out.

/// Everything DeeModel perceives, stamped with `Date` on receipt (passed to `step`).
public enum Percept: Sendable, Equatable {
    /// Volatile STT text (forwarded at ≤ 2 Hz). RAM only.
    case partial(String)
    /// From TurnPredictor (`VoiceEvent.pause`).
    case pause(turnEnd: Double, hesitation: Double)
    /// The user's finished turn. The text is RAM only and never stored.
    case heard(text: String, durationS: Double, loudnessVsBaseline: Double, appraisal: Appraisal)
    case sound(label: String, unexpected: Bool)
    case sight(camera: CameraSide, things: [String], novel: [String])
    case head(yaw: Double, pitch: Double)
    case faceLost
    case presence(arrived: Bool)
    case identified(PersonID?, distance: Float)
    case touch(kind: String, gentle: Bool, at: SIMD2<Double>?)
    /// wave / palm / thumbsUp.
    case gesture(String)
    /// DeeModel called `agent.respond`.
    case promptSubmitted
    /// Per spoken sentence (RAM only, never stored).
    case deeSaid(tag: Emotion?, sentence: String)
    /// The full reply, RAM only, for the follow-through check.
    case deeTurnFinished(text: String)
    case speakingStarted
    case speakingFinished
    case bargeIn
    case conversationStarted(Date)
    case asleep(Bool)
    /// 2 Hz.
    case tick

    /// Stable short name (traces, tests). Never includes user text.
    public var name: String {
        switch self {
        case .partial: "partial"
        case .pause: "pause"
        case .heard: "heard"
        case .sound: "sound"
        case .sight: "sight"
        case .head: "head"
        case .faceLost: "faceLost"
        case .presence: "presence"
        case .identified: "identified"
        case .touch: "touch"
        case .gesture: "gesture"
        case .promptSubmitted: "promptSubmitted"
        case .deeSaid: "deeSaid"
        case .deeTurnFinished: "deeTurnFinished"
        case .speakingStarted: "speakingStarted"
        case .speakingFinished: "speakingFinished"
        case .bargeIn: "bargeIn"
        case .conversationStarted: "conversationStarted"
        case .asleep: "asleep"
        case .tick: "tick"
        }
    }
}

/// One persisted change, executed by `SelfStore.apply` (batched per turn).
public enum SelfWrite: Sendable, Equatable {
    case episode(Episode)
    case deleteEpisode(UUID)
    /// A recall note cited the episode: `recalled += 1`, `last_recalled = at`.
    case recalled(episode: UUID, at: Date)
    case intention(Intention)
    case expectation(Expectation)
    case interest(Interest)
    case facet(Facet)
    case lesson(Lesson)
    case deleteLesson(UUID)
    case misread(Misread)
    case profile(PersonID, SocialProfile)
    case boundary(Boundary)
    case gag(Gag)
    case ritual(Ritual)
    /// The one cross-relaunch conversational exception (§7.8).
    case openRepair(PersonID, RepairPhase, togetherSecondsLeft: Double)
    case clearOpenRepair(PersonID)
    /// Daily digest counters (`day` = yyyy-MM-dd).
    case digest(day: String, person: PersonID?, conversations: Int, lowSalience: Int)

    public var name: String {
        switch self {
        case .episode: "episode"
        case .deleteEpisode: "deleteEpisode"
        case .recalled: "recalled"
        case .intention: "intention"
        case .expectation: "expectation"
        case .interest: "interest"
        case .facet: "facet"
        case .lesson: "lesson"
        case .deleteLesson: "deleteLesson"
        case .misread: "misread"
        case .profile: "profile"
        case .boundary: "boundary"
        case .gag: "gag"
        case .ritual: "ritual"
        case .openRepair: "openRepair"
        case .clearOpenRepair: "clearOpenRepair"
        case .digest: "digest"
        }
    }
}

/// What DeeModel must do after a step, in order.
public enum Effect: Sendable, Equatable {
    /// → ConversationAgent.respond(to:state:)
    case reply(userText: String?, cue: String)
    /// Dee speaks first (userText nil).
    case initiative(cue: String)
    /// Canned line, no LLM (VoiceService.say).
    case say(String)
    case stopSpeaking
    /// → ListeningCore / VoiceService.pauseScale.
    case setPauseScale(Double)
    /// → CameraSense.glanceNow.
    case glanceNow(CameraSide)
    /// → CameraSense look-around.
    case lookAround(Bool)
    /// → Mind.react.
    case appraise(Appraisal)
    /// Keeps the curiosity director's cooldowns in sync.
    case curiosity(CuriosityDirector.Stimulus)
    /// → SelfStore (batched per turn).
    case persist(SelfWrite)
    /// → MemoryStore.remember.
    case remember(ExtractedFact, person: PersonID)
    /// Schedule the Reflector.
    case reflect

    /// Stable description for golden traces (never includes user or reply text).
    public var traceName: String {
        switch self {
        case .reply: "reply"
        case .initiative: "initiative"
        case .say: "say"
        case .stopSpeaking: "stopSpeaking"
        case .setPauseScale(let s): "setPauseScale(\(String(format: "%.2f", s)))"
        case .glanceNow(let c): "glanceNow(\(c.rawValue))"
        case .lookAround(let b): "lookAround(\(b))"
        case .appraise: "appraise"
        case .curiosity: "curiosity"
        case .persist(let w): "persist(\(w.name))"
        case .remember(let f, _): "remember(\(f.category.rawValue))"
        case .reflect: "reflect"
        }
    }
}
