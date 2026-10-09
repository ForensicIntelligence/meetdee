import DeeRealtime

/// Retired (tune 1). The DNA protocol of docs/DNA.md §4.1 and the conversation
/// ledger now live in `RealtimeSession` itself: `requestResponse(dna:)`,
/// `initiative(dna:)`, `replaceDNA(_:)`, `say(instructions:)`, `addUserText(_:)`,
/// `dropUserItem(itemID:)` and `resetConversation(keeping:)`. `RealtimeBrain` uses
/// those directly.
///
/// This type is kept only so code built against the old wiring (the voice
/// harness) still compiles: `factory(_:)` returns the session's socket factory
/// unchanged and nothing is rewritten. It must never rewrite frames again — the
/// session ids and deletes its own DNA items, and a second layer would re-id and
/// double-delete them. Remove it once nothing refers to it.
@available(*, deprecated, message: "RealtimeSession carries the DNA itself; pass the socket factory straight to it.")
public final class DNAWire: Sendable {
    public init(tag: (@Sendable () -> String)? = nil) {}

    /// The session's socket factory, unchanged.
    public func factory(_ base: @escaping RealtimeSocketFactory) -> RealtimeSocketFactory { base }
}
