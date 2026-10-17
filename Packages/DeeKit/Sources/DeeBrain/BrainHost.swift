import DeeCore
import DeeMind
import DeeSelf
import Foundation

/// The user's words for one turn, as the brain hands them to its host.
public struct HeardTurn: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// A server transcript of their audio (`itemID`).
        case voice(itemID: String)
        /// Typed in the debug keyboard (already checked for commands by the app).
        case typed
    }
    public var source: Source
    public var text: String
    /// Measured on the device (nil for typed text, or nothing voiced).
    public var prosody: Prosody?
    /// Seconds (server span).
    public var duration: Double
    /// The brain already asked for a reply to this utterance (fast mode).
    public var replyRequested: Bool

    public init(source: Source, text: String, prosody: Prosody? = nil, duration: Double = 0, replyRequested: Bool = false) {
        self.source = source
        self.text = text
        self.prosody = prosody
        self.duration = duration
        self.replyRequested = replyRequested
    }
}

/// What the host made of the words.
public enum HeardVerdict: Sendable, Equatable {
    /// For Dee: answer (the appraisal that was committed, for exact mode).
    case answer(Appraisal?)
    /// A spoken command the app carried out ("stop", "goodnight", "start over"):
    /// never answered by the model. The app has already stopped any reply.
    case handled
    /// Not for Dee (asleep or nobody engaged, and not addressed by name).
    case ignored

    /// The case alone (traces never carry an appraisal).
    public var name: String {
        switch self {
        case .answer: "answer"
        case .handled: "handled"
        case .ignored: "ignored"
        }
    }
}

/// What the brain asks for to build the next DNA (docs/DNA.md §4.1 step 1).
public struct DNARequest: Sendable {
    public var turn: TurnContext
    public var appraisal: TurnAppraisal
    /// Run `Cortex.cue(at:)` first (pick notes, run their bookkeeping). False for a
    /// Cortex initiative, whose aim was already issued with it.
    public var pickNotes: Bool
    /// RAM rings and corpus the brain owns (§1.4, §2.7).
    public var rings: DNARings
    public var corpus: DNAGuardCorpus
    public var lastUserTurnAt: Date?
    public var now: Date

    public init(turn: TurnContext, appraisal: TurnAppraisal = TurnAppraisal(), pickNotes: Bool = true,
                rings: DNARings = DNARings(), corpus: DNAGuardCorpus = DNAGuardCorpus(), lastUserTurnAt: Date? = nil,
                now: Date = Date()) {
        self.turn = turn
        self.appraisal = appraisal
        self.pickNotes = pickNotes
        self.rings = rings
        self.corpus = corpus
        self.lastUserTurnAt = lastUserTurnAt
        self.now = now
    }
}

/// The host's part of a DNA: the inputs, and any short lexicon-safe notes of its
/// own (the people layer: "Their name is Maya.") for section 7.
public struct DNAParts: Sendable {
    public var inputs: DNAInputs
    /// Fixed templates and names only — never user words.
    public var extraNotes: [String]
    public init(inputs: DNAInputs, extraNotes: [String] = []) {
        self.inputs = inputs
        self.extraNotes = extraNotes
    }
}

/// Where the brain's own replies go: one stream per response it requested on
/// its own (the user's spoken turns), consumed like `ReplyEngine.respond`'s.
public struct BrainReply: Sendable {
    public enum Kind: String, Sendable, Equatable { case voice, retry }
    public var kind: Kind
    public var events: AsyncThrowingStream<ReplyEvent, Error>
}

/// Everything RealtimeBrain needs from the app (DeeModel) or a harness
/// (`StandaloneHost`). All on the main actor; nothing here touches audio.
@MainActor
public protocol BrainHost: AnyObject {
    /// Answer speech at its commit (fast path): Dee is engaged and awake. Otherwise
    /// the brain waits for the words and `heard` decides (Dee's name wakes Dee).
    var answersOnCommit: Bool { get }
    /// The Mind's running voice baseline (`Mind.voiceBaseline`, refreshed after each hear).
    var voiceBaseline: Appraiser.VoiceBaseline { get }
    /// What the exact-vs-fast rule needs from the Cortex right now (§4.3).
    func modeSignals(at now: Date) -> CueModeSignals
    /// The user's words: run the normal path (commands, "is this for me?", people,
    /// Mind preview → Cortex.adjust → commit → Cortex `.heard`). The brain feeds the
    /// cause ring from `MindChange`s the host reports with `brain.noteMind`.
    func heard(_ turn: HeardTurn) async -> HeardVerdict
    /// No words will come for this utterance (transcription failed): close the floor.
    func wordsFailed()
    /// The DNA inputs for the next response (§4.1 step 1).
    func dnaParts(_ request: DNARequest) async -> DNAParts?
    /// A reply the brain started on its own (a spoken turn).
    func brainStartedReply(_ reply: BrainReply)
    /// Thinking mode changed for this conversation (on/off).
    func thinkingModeChanged(_ on: Bool)
    /// They talked over Dee and Dee stopped for it, and the brain is answering them
    /// (tune 3: CloudVoice pauses Dee's reply for a barge-in and emits `.bargeIn` only
    /// when it ends the pause itself; when the brain's answer ends it, this is the
    /// signal). Sense it (`Percept.bargeIn`); never stop anything here — the reply
    /// being started is the answer to it.
    func bargedIn()
}

extension BrainHost {
    public func bargedIn() {}
}

/// The Cortex state the exact-mode rule reads (docs/DNA.md §4.3).
public struct CueModeSignals: Sendable, Equatable {
    public var repair: RepairPhase
    public var statedHypothesis: Bool
    public var distressLive: Bool
    public var unidentifiedSpeaker: Bool
    public var turnsThisConversation: Int

    public init(repair: RepairPhase = .fine, statedHypothesis: Bool = false, distressLive: Bool = false,
                unidentifiedSpeaker: Bool = false, turnsThisConversation: Int = 0) {
        self.repair = repair
        self.statedHypothesis = statedHypothesis
        self.distressLive = distressLive
        self.unidentifiedSpeaker = unidentifiedSpeaker
        self.turnsThisConversation = turnsThisConversation
    }

    /// From the Cortex's moment.
    public init(moment m: Moment, identified: Bool, at now: Date) {
        self.init(repair: m.ongoing.repair,
                  statedHypothesis: m.ongoing.hypotheses.contains { $0.stated && now < $0.expires },
                  distressLive: m.ongoing.distressLive(at: now),
                  unidentifiedSpeaker: !identified,
                  turnsThisConversation: m.ongoing.turnsThisConversation)
    }
}
