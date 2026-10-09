/// Dee's ears and voice as the app's face / floor logic sees them.
///
/// Since v0.6 Dee hears, thinks and speaks through one OpenAI realtime session
/// (`CloudVoice`): there is no text-to-speech of app-written text any more, so
/// the old `say` / `stream` / `endStream` calls are gone. What she says comes from
/// the session (`CloudVoice.respond`, `.initiative`, `.say`); what the app can
/// still make her do locally is play a pre-rendered clip (a laugh, "sorry, go
/// on") or stop.
///
/// Contract:
/// - `events` is a single-consumer stream; every access returns the same stream.
/// - `start()` asks for the microphone, brings audio up (`.ready` once she can
///   make sound) and starts listening (`.listening(true)` once the cloud hears
///   her); calling it again does nothing. `shutdown()` is final and idempotent.
/// - `.speakingStarted` means her first audio sample was rendered (it reaches the
///   speaker one output latency later), `.speakingFinished` that the last of it
///   played or was cut; between them `.speechLevel` arrives at ~30 Hz from the
///   audio being played, gaps between words included, and reads 0 right before
///   `.speakingFinished`.
/// - `.bargeIn` means the user really talked over her reply (her echo never
///   counts): she has already stopped and the server was told what was heard.
/// - Clips and laughs never end a turn the user is still in the middle of, and
///   never start over a user who is talking when `deferWhileUserSpeaks` is set.
public protocol VoiceIO: AnyObject, Sendable {
    /// The event stream. Single consumer.
    var events: AsyncStream<VoiceEvent> { get }

    func start() async
    func shutdown()

    /// Plays a pre-rendered clip. Returns false (and plays nothing) when the clip
    /// isn't available, when she is already saying a reply, or — with
    /// `deferWhileUserSpeaks` — when the user is talking.
    @discardableResult
    func play(_ clip: VoiceClip, deferWhileUserSpeaks: Bool) -> Bool
    /// A short laugh clip; `intensity` 0…1. Never over her own reply.
    func laugh(intensity: Double, age: Double?, energy: Double)
    /// Stop talking now: her reply is cut where the listener is (the server is
    /// told what was heard) and a reply that hasn't started is cancelled.
    func stopSpeaking()
    /// Stops a clip (a laugh, "sorry, go on") playing now and nothing else: a
    /// reply playing, queued or still being generated is left alone. Returns
    /// whether a clip was stopped.
    @discardableResult
    func stopClip() -> Bool

    /// The user is talking right now (voice in the last moment, or their speech is
    /// open on the server).
    var userIsSpeaking: Bool { get }
    /// App gate: false while Dee sleeps / is backgrounded (her mic stops going to
    /// the cloud; with `wakeOnVoice` sustained voice still reaches it).
    var listeningEnabled: Bool { get set }
    /// Per-person pause scale, 0.7…1.6 (1 = typical): shapes `.pause` estimates.
    var pauseScale: Double { get set }
}
