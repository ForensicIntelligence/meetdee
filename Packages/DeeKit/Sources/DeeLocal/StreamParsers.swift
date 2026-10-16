import Foundation

/// Splits a byte stream into lines (LF or CRLF), tolerating chunks cut anywhere,
/// including inside a UTF-8 sequence.
struct LineSplitter {
    private var buffer = Data()

    mutating func push(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            buffer = Data(buffer[buffer.index(after: nl)...])
        }
        return lines
    }

    /// Whatever is left without a trailing newline.
    mutating func finish() -> String? {
        defer { buffer = Data() }
        guard !buffer.isEmpty else { return nil }
        var line = buffer
        if line.last == 0x0D { line = line.dropLast() }
        let s = String(decoding: line, as: UTF8.self)
        return s.isEmpty ? nil : s
    }
}

/// Server-sent events: `data:` lines joined until a blank line; `[DONE]` ends.
struct SSEParser {
    enum Event: Equatable { case data(String), done }
    private var lines = LineSplitter()
    private var pending: [String] = []

    mutating func push(_ chunk: Data) -> [Event] {
        var out: [Event] = []
        for line in lines.push(chunk) { out += handle(line) }
        return out
    }

    mutating func finish() -> [Event] {
        var out: [Event] = []
        if let rest = lines.finish() { out += handle(rest) }
        out += flush()
        return out
    }

    private mutating func handle(_ line: String) -> [Event] {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return [] }
        if line.hasPrefix("data:") {
            var v = line.dropFirst(5)
            if v.first == " " { v = v.dropFirst() }
            // Many servers send one JSON per line without blank separators: flush each complete one.
            if v == "[DONE]" { return flush() + [.done] }
            pending.append(String(v))
            if pending.count == 1, Self.looksComplete(String(v)) { return flush() }
            return []
        }
        // Not SSE at all (a JSON error body, NDJSON): pass whole lines through.
        if line.hasPrefix("{") { return flush() + [.data(line)] }
        return []   // event:, id:, retry:
    }

    private mutating func flush() -> [Event] {
        guard !pending.isEmpty else { return [] }
        defer { pending = [] }
        return [.data(pending.joined(separator: "\n"))]
    }

    static func looksComplete(_ s: String) -> Bool {
        guard s.hasPrefix("{"), s.hasSuffix("}") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) != nil
    }
}
