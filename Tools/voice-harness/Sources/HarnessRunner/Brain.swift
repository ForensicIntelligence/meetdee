import DeeRealtime
import DeeVoice
import Foundation
import HarnessCore

/// What decides when and how Dee answers during a harness run.
///
/// The runner is the single consumer of `CloudVoice.brainEvents`: it records every
/// event for the metrics, then hands it to the brain **in order** (`handle` is
/// awaited before the next event). A brain answers through the `CloudVoice` it was
/// attached to (`respond`, `initiative`, `say`) exactly as the app's brain does.
public protocol HarnessBrain: AnyObject, Sendable {
    /// Name for reports (`minimal`, `realtime`, …).
    var name: String { get }
    /// Adjust the session config (instructions, tools, voice) before the session exists.
    func configure(_ config: inout RealtimeSessionConfig)
    /// The voice exists (not started yet): keep it, set a tool handler, etc.
    func attach(voice: CloudVoice, log: HarnessLog) async
    /// One brain event, in order.
    func handle(_ event: CloudVoice.BrainEvent) async
    /// Scenario / step instructions for the next replies (nil = the brain's own).
    func setTurnInstructions(_ instructions: String?) async
    /// The run is over.
    func detach() async

    // With defaults (the minimal brain uses them):

    /// The brain consumes `CloudVoice.brainEvents` itself (`handle` is never called;
    /// the runner records the run from the wire).
    var ownsBrainEvents: Bool { get }
    /// Wraps the session's socket factory (pass-through since tune 1: the session carries the DNA).
    func wrapSocketFactory(_ base: @escaping RealtimeSocketFactory) -> RealtimeSocketFactory
    /// After `attach`, before `voice.start()`.
    func start() async
    /// Dee speaks first: an initiative with these words as its aim, or a verbatim
    /// line. nil = the runner calls the voice directly.
    func speak(_ line: String, initiative: Bool) async -> SpeakResult?
    /// A host step (body, clock, conversation). Returns what was done.
    func perform(_ action: Scenario.HostAction) async -> String
}

/// The outcome of `HarnessBrain.speak`.
public enum SpeakResult: Sendable, Equatable {
    case sent
    /// `retryable`: refused because someone (or she) was talking — try again shortly.
    case refused(String, retryable: Bool)
}

public extension HarnessBrain {
    var ownsBrainEvents: Bool { false }
    func wrapSocketFactory(_ base: @escaping RealtimeSocketFactory) -> RealtimeSocketFactory { base }
    func start() async {}
    func speak(_ line: String, initiative: Bool) async -> SpeakResult? { nil }
    func perform(_ action: Scenario.HostAction) async -> String { "ignored (\(name) brain has no body or clock)" }
}

/// Lets a brain put requests and notes into the run record.
public struct HarnessLog: Sendable {
    public let request: @Sendable (_ kind: String, _ outcome: String) -> Void
    public let note: @Sendable (_ text: String) -> Void
    /// One of her sentences finished playing (`heard`) or was cut (real brain).
    public let sentence: (@Sendable (_ text: String, _ heard: Bool) -> Void)?
    /// A brain decision (`BrainTrace`, no text).
    public let trace: (@Sendable (_ entry: String) -> Void)?

    public init(request: @escaping @Sendable (String, String) -> Void, note: @escaping @Sendable (String) -> Void,
                sentence: (@Sendable (String, Bool) -> Void)? = nil, trace: (@Sendable (String) -> Void)? = nil) {
        self.request = request
        self.note = note
        self.sentence = sentence
        self.trace = trace
    }
}

/// The built-in brain the harness works with before RealtimeBrain lands: fixed
/// instructions, and `response.create` on every `.userCommitted` the voice forwards
/// (which is always a real user turn: echo is filtered upstream). No cue item, no
/// memory tools, no initiatives of its own.
public final class MinimalBrain: HarnessBrain, @unchecked Sendable {
    public static let instructions = """
    You are Dee, a small, warm, curious robot companion who lives on a shelf in someone's home. \
    You are talking out loud with the person in front of you. Reply in plain spoken English, \
    one to three short sentences, like a friend would. Never use lists, markdown, brackets, \
    tags, stage directions or emoji. Never say you are an AI or a language model. If the \
    person tells you to stop or be quiet, just say okay in a word or two.
    """

    public let name = "minimal"
    private let lock = NSLock()
    private var voice: CloudVoice?
    private var log: HarnessLog?
    private var turnInstructions: String?

    public init() {}

    public func configure(_ config: inout RealtimeSessionConfig) {
        config.instructions = Self.instructions
    }

    public func attach(voice: CloudVoice, log: HarnessLog) async {
        lock.withLock {
            self.voice = voice
            self.log = log
        }
    }

    public func setTurnInstructions(_ instructions: String?) async {
        lock.withLock { turnInstructions = instructions }
    }

    public func handle(_ event: CloudVoice.BrainEvent) async {
        guard case .session(.userCommitted) = event else { return }
        let (voice, log, extra) = lock.withLock { (self.voice, self.log, self.turnInstructions) }
        guard let voice else { return }
        let instructions = extra.map { Self.instructions + "\n\n" + $0 } ?? Self.instructions
        do {
            let outcome = try await voice.respond(instructions: instructions)
            log?.request("reply", "\(outcome)")
        } catch {
            log?.request("reply", "error: \(error)")
        }
    }

    public func detach() async {
        lock.withLock { voice = nil }
    }
}

/// Brains selectable with `--brain`.
public enum BrainRegistry {
    public struct NotWired: Error, CustomStringConvertible {
        public var description: String
    }

    public static let names = ["realtime", "minimal"]

    /// - Parameters:
    ///   - scenario: the scenario the brain serves (person, state).
    ///   - stateRoot: the real brain's Mind / memory / self databases go under here.
    public static func make(_ name: String, scenario: Scenario? = nil, stateRoot: URL? = nil,
                            voice: String = "marin") throws -> any HarnessBrain {
        switch name {
        case "minimal": return MinimalBrain()
        case "realtime":
            let root = stateRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("dee-harness-state")
            return try RealtimeBrainAdapter(scenario: scenario ?? Scenario(name: "adhoc", steps: []), stateRoot: root, voice: voice)
        default:
            throw NotWired(description: "unknown brain \(name); known: \(names.joined(separator: ", "))")
        }
    }
}
