import Foundation

/// Builds the run record from the raw Realtime frames of every connection (the
/// harness taps the session's own sockets).
///
/// Two uses:
/// - always: connections (open / refused / `session.created` / close), the
///   `response.create`s the client sent and whether a DEE DNA item was live in the
///   conversation for each (the "every response carries the DNA" check);
/// - `events: true` (the real brain owns `CloudVoice.brainEvents`, so the runner
///   cannot read them): user items, responses (kind, items, transcript, usage),
///   her transcripts, errors and the items the session deleted as her echo.
///
/// Response kinds come from the wire itself: a `response.create` whose fresh DNA
/// says "You are speaking first." is an initiative, one after a
/// `function_call_output` without a fresh DNA is a tool follow-up, an out-of-band
/// one is a canned line (`aside`) or the rollover `summary`, anything else a reply.
/// The server's `response.created` is matched to its request by the session's
/// `metadata.dee_turn` token (in order when there is none).
public struct WireRecorder: Sendable {
    /// What the runner needs to act on.
    public enum Signal: Sendable, Equatable {
        case connected(connection: Int)
        case disconnected(connection: Int)
        case responseStarted(kind: String)
        /// A response is done (`counted`: its start was signalled, so it was open).
        case responseDone(usage: RunRecord.UsageRecord?, counted: Bool)
        case log(String)
    }

    public static let dnaPrefix = "DEE DNA"
    public static let initiativeMarker = "You are speaking first."
    public static let turnKey = "dee_turn"
    public static let summaryPurpose = "dee_rollover_summary"
    public static let cannedKey = "dee_canned"
    /// The session's own deletes use this event id prefix: user items it withdrew
    /// (her echo, or speech the brain dropped as not for her) and, since tune 1,
    /// its own superseded `dna_…` items, which are never user items.
    public static let sessionDeletePrefix = "dee_del_"

    private struct Conn: Sendable {
        var liveDNA: [String: Int] = [:]      // id → characters
        var freshDNA = false
        var freshDNAInitiative = false
        var toolOutput = false
    }
    private var conns: [Int: Conn] = [:]
    private var kindByToken: [String: String] = [:]
    /// Kinds of requests without a token, oldest first.
    private var untokened: [String] = []
    private var responseKinds: [String: String] = [:]      // response id → kind
    private var counted: Set<String> = []                  // responses counted as started
    private var audioBytes: [String: Int] = [:]            // response id → PCM bytes
    private var echoRejected: Set<String> = []

    public init() {}

    // MARK: Connections

    public mutating func opened(connection: Int, at t: Double, record: inout RunRecord) {
        var list = record.connections ?? []
        list.append(.init(index: connection, opened: t))
        record.connections = list
        conns[connection] = Conn()
    }

    public mutating func refused(connection: Int, reason: String, at t: Double, record: inout RunRecord) {
        update(connection, &record) { $0.refused = reason; $0.closedAt = t }
    }

    public mutating func closed(connection: Int, code: Int?, reason: String?, dropped: Bool, at t: Double,
                                record: inout RunRecord) -> [Signal] {
        var wasLive = false
        update(connection, &record) { c in
            guard c.closedAt == nil else { return }
            wasLive = c.createdAt != nil
            c.closedAt = t
            c.closeCode = code
            c.closeReason = reason
            if dropped { c.dropped = true }
        }
        conns[connection] = nil
        return wasLive ? [.disconnected(connection: connection)] : []
    }

    private func update(_ connection: Int, _ record: inout RunRecord, _ body: (inout RunRecord.Connection) -> Void) {
        guard var list = record.connections, let i = list.lastIndex(where: { $0.index == connection }) else { return }
        body(&list[i])
        record.connections = list
    }

    // MARK: Frames

    /// One frame on `connection` (`outgoing`: client → server).
    public mutating func frame(connection: Int, outgoing: Bool, text: String, at t: Double, events: Bool,
                               record: inout RunRecord) -> [Signal] {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        return outgoing ? client(type, obj, connection: connection, at: t, events: events, record: &record)
                        : server(type, obj, text: text, connection: connection, at: t, events: events, record: &record)
    }

    private mutating func client(_ type: String, _ o: [String: Any], connection: Int, at t: Double, events: Bool,
                                 record: inout RunRecord) -> [Signal] {
        var c = conns[connection] ?? Conn()
        defer { conns[connection] = c }
        switch type {
        case "conversation.item.create":
            guard let item = o["item"] as? [String: Any] else { return [] }
            let itemType = item["type"] as? String
            if itemType == "function_call_output" { c.toolOutput = true; return [] }
            let text = Self.text(of: item)
            let id = item["id"] as? String ?? ""
            if item["role"] as? String == "system", text.hasPrefix(Self.dnaPrefix) || id.hasPrefix("dna_") {
                c.liveDNA[id] = text.count
                c.freshDNA = true
                c.freshDNAInitiative = text.contains(Self.initiativeMarker)
            }
        case "conversation.item.delete":
            guard let id = o["item_id"] as? String else { return [] }
            c.liveDNA[id] = nil
            if events, !id.hasPrefix("dna_"), (o["event_id"] as? String)?.hasPrefix(Self.sessionDeletePrefix) == true,
               !Self.wasAnswered(id, record) {
                echoRejected.insert(id)
                var list = record.echoRejected ?? []
                if !list.contains(id) { list.append(id) }
                record.echoRejected = list
                record.userItems.removeAll { $0.itemID == id }
            }
        case "response.create":
            let r = o["response"] as? [String: Any] ?? [:]
            let metadata = r["metadata"] as? [String: Any] ?? [:]
            let outOfBand = (r["conversation"] as? String) == "none"
            let purpose = metadata["purpose"] as? String
            let kind: String
            if outOfBand { kind = purpose == Self.summaryPurpose ? "summary" : "aside" }
            else if c.freshDNA { kind = c.freshDNAInitiative ? "initiative" : "reply" }
            else if c.toolOutput { kind = "toolFollowUp" }
            else { kind = (r["instructions"] as? String).map { $0.hasPrefix("Say exactly") ? "aside" : "reply" } ?? "reply" }
            if let token = metadata[Self.turnKey] as? String { kindByToken[token] = kind } else { untokened.append(kind) }
            var list = record.responseCreates ?? []
            list.append(.init(at: t, connection: connection, liveDNA: !c.liveDNA.isEmpty, freshDNA: c.freshDNA,
                              outOfBand: outOfBand, purpose: purpose,
                              dnaChars: c.liveDNA.values.max()))
            record.responseCreates = list
            c.freshDNA = false
            c.freshDNAInitiative = false
            c.toolOutput = false
        default:
            break
        }
        return []
    }

    /// A user item that was committed and then answered (an in-band
    /// `response.create` went out after its commit) and is deleted later is history
    /// cleanup (`resetConversation` on a new conversation), not her echo: it stays.
    static func wasAnswered(_ id: String, _ record: RunRecord) -> Bool {
        guard let committed = record.userItems.first(where: { $0.itemID == id })?.committedAt else { return false }
        return (record.responseCreates ?? []).contains { !$0.outOfBand && $0.at >= committed }
    }

    private mutating func server(_ type: String, _ o: [String: Any], text: String, connection: Int, at t: Double,
                                 events: Bool, record: inout RunRecord) -> [Signal] {
        var out: [Signal] = []
        if type == "session.created" {
            let sid = (o["session"] as? [String: Any])?["id"] as? String
            update(connection, &record) { $0.createdAt = $0.createdAt ?? t; $0.sessionID = sid }
            if events {
                if record.connectedAt == nil { record.connectedAt = t }
                if let sid, !record.sessionIDs.contains(sid) { record.sessionIDs.append(sid) }
            }
            out.append(.connected(connection: connection))
        }
        guard events else { return out }
        switch type {
        case "input_audio_buffer.speech_started":
            guard let item = o["item_id"] as? String, !echoRejected.contains(item) else { break }
            let i = userItem(item, t, &record)
            record.userItems[i].speechStartedAt = record.userItems[i].speechStartedAt ?? t
            record.userItems[i].audioStartMs = o["audio_start_ms"] as? Int
            out.append(.log("server: speech started \(item)"))
        case "input_audio_buffer.committed":
            guard let item = o["item_id"] as? String, !echoRejected.contains(item) else { break }
            let i = userItem(item, t, &record)
            record.userItems[i].committedAt = t
            out.append(.log("server: committed \(item)"))
        case "conversation.item.input_audio_transcription.completed":
            guard let item = o["item_id"] as? String, !echoRejected.contains(item),
                  let i = record.userItems.firstIndex(where: { $0.itemID == item }) else { break }
            let words = o["transcript"] as? String ?? ""
            record.userItems[i].transcript = words
            out.append(.log("server heard: “\(words)”"))
        case "conversation.item.input_audio_transcription.failed":
            guard let item = o["item_id"] as? String, !echoRejected.contains(item),
                  let i = record.userItems.firstIndex(where: { $0.itemID == item }) else { break }
            record.userItems[i].transcriptFailed = true
            let m = (o["error"] as? [String: Any])?["message"] as? String ?? ""
            record.errors.append(.init(t: t, text: "transcript failed \(item): \(Redact.secrets(m))"))
        case "response.created":
            guard let r = o["response"] as? [String: Any], let id = r["id"] as? String else { break }
            let metadata = r["metadata"] as? [String: Any] ?? [:]
            var kind: String
            if metadata["purpose"] as? String == Self.summaryPurpose { kind = "summary" }
            else if let token = metadata[Self.turnKey] as? String, let k = kindByToken.removeValue(forKey: token) { kind = k }
            else if metadata[Self.cannedKey] != nil { kind = "aside" }
            else if !untokened.isEmpty { kind = untokened.removeFirst() }
            else { kind = "reply" }
            if metadata[Self.cannedKey] != nil { kind = "aside" }
            responseKinds[id] = kind
            guard kind != "summary", !record.responses.contains(where: { $0.responseID == id }) else { break }
            var resp = RunRecord.Response(responseID: id, kind: kind)
            resp.startedAt = t
            record.responses.append(resp)
            counted.insert(id)
            out.append(.responseStarted(kind: kind))
        case "response.output_item.added":
            guard let rid = o["response_id"] as? String, let item = o["item"] as? [String: Any],
                  item["type"] as? String == "message", let iid = item["id"] as? String,
                  let i = record.responses.firstIndex(where: { $0.responseID == rid }) else { break }
            if !record.responses[i].itemIDs.contains(iid) { record.responses[i].itemIDs.append(iid) }
        case "response.output_audio.delta":
            guard let rid = o["response_id"] as? String else { break }
            // Base64 length → PCM bytes without decoding.
            let b64 = (o["delta"] as? String)?.utf8.count ?? 0
            audioBytes[rid, default: 0] += b64 / 4 * 3
        case "response.output_audio_transcript.done":
            guard let item = o["item_id"] as? String else { break }
            let words = o["transcript"] as? String ?? ""
            record.deeTranscripts[item] = words
            out.append(.log("dee: “\(words)”"))
        case "response.done":
            guard let r = o["response"] as? [String: Any] else { break }
            let id = r["id"] as? String
            if let id, responseKinds[id] == "summary" { break }
            var resp: RunRecord.Response
            let idx = record.responses.firstIndex { $0.responseID != nil && $0.responseID == id }
            if let idx { resp = record.responses[idx] } else { resp = .init(responseID: id, kind: id.flatMap { responseKinds[$0] } ?? "reply") }
            resp.doneAt = t
            resp.status = r["status"] as? String
            resp.reason = (r["status_details"] as? [String: Any])?["reason"] as? String
            let output = r["output"] as? [[String: Any]] ?? []
            var transcript: [String] = []
            for item in output where item["type"] as? String == "message" {
                if let iid = item["id"] as? String, !resp.itemIDs.contains(iid) { resp.itemIDs.append(iid) }
                for c in item["content"] as? [[String: Any]] ?? [] {
                    if let tr = c["transcript"] as? String { transcript.append(tr) }
                    else if let tx = c["text"] as? String { transcript.append(tx) }
                }
            }
            if !transcript.isEmpty { resp.transcript = transcript.joined(separator: " ") }
            if let id { resp.audioMs = (audioBytes.removeValue(forKey: id) ?? 0) / 48 }
            var usage: RunRecord.UsageRecord?
            if let u = r["usage"] as? [String: Any] { usage = Self.usage(u); resp.usage = usage }
            if let idx { record.responses[idx] = resp } else { record.responses.append(resp) }
            let wasCounted = id.map { counted.remove($0) != nil } ?? false
            out.append(.responseDone(usage: usage, counted: wasCounted))
            out.append(.log("response done \(resp.kind) \(resp.status ?? "?")\(resp.reason.map { " (\($0))" } ?? "")"))
        case "error":
            let e = o["error"] as? [String: Any] ?? [:]
            let code = e["code"] as? String ?? ""
            let message = e["message"] as? String ?? ""
            record.errors.append(.init(t: t, text: "server error \(code) \(Redact.secrets(message))"))
        default:
            break
        }
        return out
    }

    private func userItem(_ item: String, _ t: Double, _ record: inout RunRecord) -> Int {
        if let i = record.userItems.firstIndex(where: { $0.itemID == item }) { return i }
        record.userItems.append(.init(itemID: item, firstSeen: t))
        return record.userItems.count - 1
    }

    static func text(of item: [String: Any]) -> String {
        (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func usage(_ u: [String: Any]) -> RunRecord.UsageRecord {
        var rec = RunRecord.UsageRecord()
        let inD = u["input_token_details"] as? [String: Any] ?? [:]
        let cached = inD["cached_tokens_details"] as? [String: Any] ?? [:]
        let outD = u["output_token_details"] as? [String: Any] ?? [:]
        rec.inputText = inD["text_tokens"] as? Int ?? 0
        rec.inputAudio = inD["audio_tokens"] as? Int ?? 0
        rec.cachedText = cached["text_tokens"] as? Int ?? 0
        rec.cachedAudio = cached["audio_tokens"] as? Int ?? 0
        rec.outputText = outD["text_tokens"] as? Int ?? 0
        rec.outputAudio = outD["audio_tokens"] as? Int ?? 0
        return rec
    }
}
