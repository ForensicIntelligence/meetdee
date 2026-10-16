import DeeRealtime
import Foundation
import HarnessCore

/// The OpenAI key, read at run time from `~/.config/dee/openai-key`. Never printed,
/// logged or written: errors name the file, never its content.
public enum KeyFile {
    public enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case invalid(String)

        public var description: String {
            switch self {
            case .missing(let p): "no OpenAI key at \(p)"
            case .invalid(let p): "the file at \(p) does not hold an sk-… key"
            }
        }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/dee/openai-key")
    }

    public static func load(_ url: URL = defaultURL) throws -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.missing(url.path) }
        guard let key = KeyStore.normalize(raw) else { throw Failure.invalid(url.path) }
        return key
    }

    /// `RealtimeAuth` over an in-memory key store (mints `ek_` secrets like the app).
    public static func auth(key: String, ttlSeconds: Int = 600, transport: HTTPFetch? = nil) -> RealtimeAuth {
        let storage = MemorySecretStorage([KeyStore.defaultAccount: key])
        return RealtimeAuth(keyStore: KeyStore(storage: storage), ttlSeconds: ttlSeconds, transport: transport)
    }

    /// `"\(error)"` with anything secret-shaped removed.
    public static func describe(_ error: Error) -> String { Redact.secrets("\(error)") }
}
