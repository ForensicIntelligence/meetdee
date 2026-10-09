import DeeRealtime
import Foundation
import Synchronization
import Testing
@testable import DeeVoice

/// A fake `/v1/audio/speech`: records requests, answers with PCM.
final class FakeSpeechServer: Sendable {
    private let requests = Mutex<[URLRequest]>([])
    let status: Int
    let body: @Sendable (URLRequest) -> Data

    init(status: Int = 200, body: (@Sendable (URLRequest) -> Data)? = nil) {
        self.status = status
        self.body = body ?? { _ in FakeSpeechServer.clipPCM() }
    }

    var fetch: ClipCache.Fetch {
        { [self] request in
            requests.withLock { $0.append(request) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (body(request), response)
        }
    }

    var all: [URLRequest] { requests.withLock { $0 } }

    func json(_ i: Int) -> [String: Any] {
        guard let d = all[i].httpBody, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    /// 200 ms silence, 400 ms tone, 300 ms silence (what TTS tends to return).
    static func clipPCM() -> Data {
        var d = Data(count: 200 * 48)
        d.append(PCMTone.data(ms: 400, hz: 500, amplitude: 0.4))
        d.append(Data(count: 300 * 48))
        return d
    }
}

@Suite struct ClipCacheTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dee-clips-\(UUID().uuidString)", isDirectory: true)
    }

    func cache(_ server: FakeSpeechServer, dir: URL, voice: DeeRealtime.RealtimeVoice = .named("marin"),
               key: String? = "sk-test-key-0123456789", clips: [VoiceClip] = [.giggle, .laugh1]) -> ClipCache {
        var c = ClipCache.Configuration(voice: voice, directory: dir)
        c.clips = clips
        return ClipCache(configuration: c, key: { key }, fetch: server.fetch)
    }

    @Test func rendersOnceWithTheSessionVoiceAndKeepsThemOnDisk() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakeSpeechServer()
        let c = cache(server, dir: dir)
        let report = await c.prepare()
        #expect(report.rendered == [.giggle, .laugh1])
        #expect(server.all.count == 2)
        let r = server.all[0]
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key-0123456789")
        let body = server.json(0)
        #expect(body["model"] as? String == "gpt-4o-mini-tts")
        #expect(body["voice"] as? String == "marin")
        #expect(body["response_format"] as? String == "pcm")
        #expect(body["input"] as? String == VoiceClip.giggle.text)
        #expect((body["instructions"] as? String)?.contains("ticklish") == true)

        // Trimmed: the 0.5 s of silence around the tone is gone (10 ms margins kept).
        let pcm = try #require(c.pcm(.giggle))
        let ms = Double(pcm.count) / 48
        #expect(ms > 395 && ms < 425, "\(ms)")

        // A new cache over the same directory serves from disk without a request.
        let again = cache(server, dir: dir)
        let second = await again.prepare()
        #expect(second.alreadyThere == [.giggle, .laugh1] && second.rendered.isEmpty)
        #expect(server.all.count == 2)
        #expect(again.pcm(.laugh1) == c.pcm(.laugh1))
        #expect(again.available == [.giggle, .laugh1])
    }

    @Test func aDifferentVoiceRendersAgainAndLeavesTheOtherVoicesFile() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakeSpeechServer()
        let marin = cache(server, dir: dir, clips: [.oneSec])
        _ = await marin.prepare()
        let cedar = cache(server, dir: dir, voice: .named("cedar"), clips: [.oneSec])
        #expect(cedar.pcm(.oneSec) == nil)
        let r = await cedar.prepare()
        #expect(r.rendered == [.oneSec])
        #expect(server.json(1)["voice"] as? String == "cedar")
        // Two caches over one directory never delete each other's clips.
        let files = { try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("-oneSec-") } }
        #expect(try files().count == 2)
        let again = cache(server, dir: dir, clips: [.oneSec])
        #expect(await again.prepare().alreadyThere == [.oneSec])
        #expect(server.all.count == 2)
        // Once the voice changed for good, the old voice's clips can go.
        cedar.removeOtherVoices()
        #expect(try files() == [cedar.fileURL(.oneSec).lastPathComponent])
    }

    @Test func aChangedStyleReplacesTheClipInTheSameVoice() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakeSpeechServer()
        _ = await cache(server, dir: dir, clips: [.oneSec]).prepare()
        var c = ClipCache.Configuration(voice: .named("marin"), directory: dir)
        c.clips = [.oneSec]
        c.style = "A different base style."
        let restyled = ClipCache(configuration: c, key: { "sk-test-key-0123456789" }, fetch: server.fetch)
        #expect(await restyled.prepare().rendered == [.oneSec])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("-oneSec-") }
        #expect(files == [restyled.fileURL(.oneSec).lastPathComponent])
    }

    @Test func customVoiceIsSentAsAnObject() {
        let c = ClipCache(configuration: .init(voice: .custom(id: "voice_123"), directory: tempDir()), key: { nil })
        let v = c.requestBody(.oneSec)["voice"] as? [String: String]
        #expect(v == ["id": "voice_123"])
    }

    @Test func noKeyIsGraceful() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakeSpeechServer()
        let c = cache(server, dir: dir, key: nil)
        let r = await c.prepare()
        #expect(r.stopped == "no key")
        #expect(server.all.isEmpty)
        #expect(c.pcm(.giggle) == nil)
        #expect(c.available.isEmpty)
    }

    @Test func refusedKeyStopsAfterTheFirstClip() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakeSpeechServer(status: 401) { _ in Data(#"{"error":{"message":"bad key"}}"#.utf8) }
        let r = await cache(server, dir: dir).prepare()
        #expect(server.all.count == 1)
        #expect(r.failed == [.giggle])
        #expect(r.stopped?.contains("401") == true)
    }

    @Test func anErrorBodyWithStatus200IsNotAClip() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakeSpeechServer { _ in Data(#"{"error":"nope"}"#.utf8) }
        let c = cache(server, dir: dir, clips: [.oneSec])
        let r = await c.prepare()
        #expect(r.failed == [.oneSec])
        #expect(c.pcm(.oneSec) == nil)
    }

    @Test func laughsRotateWithinTheirIntensity() {
        #expect(VoiceClip.laugh(intensity: 0.1, variant: 0) == .chuckle1)
        #expect(VoiceClip.laugh(intensity: 0.1, variant: 4) == .chuckle2)
        #expect(VoiceClip.laugh(intensity: 0.5, variant: 2) == .laugh3)
        #expect(VoiceClip.laugh(intensity: 0.9, variant: 1) == .bigLaugh2)
        #expect(VoiceClip.laugh(intensity: .nan, variant: -1) == .laugh3)
        #expect(VoiceClip.allCases.filter(\.isLaugh).count == 9)
    }

    @Test func trimFadesAndKeepsMargins() {
        let pcm = FakeSpeechServer.clipPCM()
        let t = ClipCache.trim(pcm)
        let s = PCM16.samples(t)
        #expect(s.first.map { abs(Int($0)) } ?? 99 < 50)
        #expect(s.last.map { abs(Int($0)) } ?? 99 < 50)
        #expect(ClipCache.trim(Data(count: 4800)).isEmpty)
    }
}
