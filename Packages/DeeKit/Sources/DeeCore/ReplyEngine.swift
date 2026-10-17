import Foundation

/// What Dee is asked to say.
public enum ReplyRequest: Sendable, Equatable {
    /// Answer the user's latest committed turn. The model hears their audio
    /// itself; `words` is its transcript when the app already has it (it waited
    /// for the words: commands, "is this for me?", thinking requests), or nil when
    /// the reply is requested on the server's commit, before the transcript
    /// (fast mode; see `ThinkingMode.effortBeforeWords`).
    case user(words: String?)
    /// Dee speaks first: a stage direction for Dee's initiative or an event ("(The
    /// user waves at you.)"), or empty when `state` alone carries the initiative.
    case initiative(String)
}

/// What a `ReplyEngine` reports while Dee answers one request.
///
/// Dee's audio never passes through the app: the realtime session speaks it and
/// the voice plays it. These events describe it, placed on what was actually
/// played.
public enum ReplyEvent: Sendable, Equatable {
    /// The next words of Dee's reply as Dee starts saying them (captions, transcript).
    case content(String)
    /// Playback passed the end of a sentence (`heard: true`), or the reply was cut
    /// inside it (`heard`: its midpoint was played). Heard sentences go to the
    /// Cortex as what Dee said (`Percept.deeSaid`).
    case sentenceFinished(String, heard: Bool)
    /// How Dee feels saying what follows. Goes through the Cortex, which may
    /// reconcile it with Dee's actual state before the face shows it.
    case emotion(Emotion)
    case toolCall(ToolCall)
    case toolResult(name: String, result: String)
    /// One reply message is complete (there may be several per request with
    /// tools), with its final transcript.
    case messageCompleted(String)
    /// The whole request is done (Dee's audio may still be playing out).
    case turnCompleted
}

/// The brain seam: whatever thinks and speaks for Dee. The app decides *when* Dee
/// answers (the floor, commands, whether speech was for Dee, thinking) and with
/// what description of Dee (`state`); the engine does the rest.
///
/// There is no local language model: the brain is the cloud realtime model
/// (`RealtimeBrain`, built on DeeVoice's `CloudVoice` and DeeRealtime), which
/// hears the user's audio and speaks its own. Without an engine Dee stays alive —
/// Dee sees, hears, feels and reacts with Dee's face — but does not answer.
///
/// What was heard of a stopped reply is not the engine's business: the voice
/// tells the session how many milliseconds were played (barge-in, hush), so the
/// conversation already holds exactly what the listener heard. There is no text
/// truncation or retraction step.
public protocol ReplyEngine: AnyObject, Sendable {
    /// Handles one request end to end. `state` is this turn's description of Dee
    /// for the model (the Dee DNA block; see docs/DNA.md); `effort` is this
    /// response's `reasoning.effort` (`ThinkingMode`). Cancelling the consumer
    /// cancels the request.
    func respond(_ request: ReplyRequest, state: String?, effort: ReasoningEffort) -> AsyncThrowingStream<ReplyEvent, Error>
    /// Stops the current request as soon as possible: a reply without audio yet
    /// is withdrawn, one that is playing is cut where the listener is. Sticky
    /// until the next request.
    func cancel() async
    /// Starts over with this persona (conversation cleared).
    func newConversation(persona: Persona, now: Date) async
}
