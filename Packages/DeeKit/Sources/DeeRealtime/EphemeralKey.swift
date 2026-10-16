import Foundation

/// The bearer token a Realtime socket authenticates with.
public enum RealtimeCredential: Sendable, Equatable {
    /// A short-lived `ek_…` client secret minted from the project key.
    case ephemeral(String, expiresAt: Date)
    /// The project key itself (minting unavailable).
    case direct(String)

    public var bearer: String {
        switch self {
        case .ephemeral(let v, _), .direct(let v): v
        }
    }

    public var isEphemeral: Bool { if case .ephemeral = self { true } else { false } }
}

public enum RealtimeAuthError: Error, Sendable, Equatable {
    /// No key in the Keychain: show the key sheet.
    case noKey
    /// 401 / 403: the key is wrong, revoked, or lacks Realtime permission.
    case unauthorized(status: Int, message: String?)
    /// 429: rate limit or the project's hard spend cap (`code` tells which when given).
    case rateLimited(retryAfter: Double?, code: String?)
    /// A transcription session can't be minted for this key (400 / 404 / 405 / 501):
    /// "OpenAI hearing isn't available for this key". Never falls back to the key itself.
    case transcriptionUnavailable(status: Int)
}

/// Kept for existing callers: `RealtimeAuth` is `OpenAIAuth`.
public typealias RealtimeAuth = OpenAIAuth

/// Produces credentials for Realtime sockets.
///
/// Mints a **fresh** `ek_` client secret via `POST /v1/realtime/client_secrets`
/// with the stored project key for **every** connection (connect, reconnect,
/// rollover, retry). A secret is never handed out twice: the live API treats a
/// client secret as single-use (a second socket with it gets `error
/// ephemeral_token_already_used` and close code 3000), whatever the reference
/// says about "multiple sessions" (verified live 2026-10-09, voice harness). A
/// session outlives its secret, so nothing needs to be kept. For a single-device
/// sideload this adds no security, but it keeps the media socket free of the
/// long-lived key and makes a later server-side minter a one-line change.
///
/// Falls back to the project key itself when minting is unavailable (404/405/400,
/// 5xx, network trouble on the minting call). Never falls back on 401/403/429:
/// the direct key would fail the same way, so those surface as errors.
///
/// **v0.6.** The mint endpoint is fixed to `api.openai.com` by type (no endpoint
/// parameter): an OpenAI key can only ever be sent to OpenAI, and LAN keys never
/// come through here (their credentials are `{ .direct(lanKey) }`). A
/// `.transcription` auth mints transcription sessions (mode 2's hearing,
/// `OpenAITranscription`) and never falls back to the key itself: a refused mint
/// there is `transcriptionUnavailable`, a hard problem.
public actor OpenAIAuth {
    public static let clientSecretsURL = URL(string: "https://api.openai.com/v1/realtime/client_secrets")!

    public enum SessionType: String, Sendable, Equatable { case realtime, transcription }

    public let sessionType: SessionType
    private let transcription: OpenAITranscription.Session
    private let keyStore: KeyStore
    private let endpoint = OpenAIAuth.clientSecretsURL
    private let ttlSeconds: Int
    private let mint: Bool
    private let safetyIdentifier: String?
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    private var mintingUnavailable = false
    /// Secrets minted so far (tests, diagnostics). Never their values.
    public private(set) var minted = 0

    /// - Parameters:
    ///   - mint: false always uses the project key directly.
    ///   - ttlSeconds: 10…7200 (server default 600).
    ///   - safetyIdentifier: a stable, hashed user id sent as `OpenAI-Safety-Identifier`.
    ///   - sessionType: `.transcription` mints `OpenAITranscription` sessions (always mints).
    ///   - transport: the HTTP call; default the shared OpenAI `Transport` (recorded,
    ///     same-host redirects only).
    public init(keyStore: KeyStore, sessionType: SessionType = .realtime, mint: Bool = true, ttlSeconds: Int = 600,
                safetyIdentifier: String? = nil, transcription: OpenAITranscription.Session = .default,
                transport: HTTPTransport? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.keyStore = keyStore
        self.sessionType = sessionType
        self.transcription = transcription
        self.mint = mint || sessionType == .transcription
        self.ttlSeconds = min(max(ttlSeconds, 10), 7200)
        self.safetyIdentifier = safetyIdentifier
        self.transport = transport ?? Transport.openAIDefault.fetch
        self.now = now
    }

    /// A credential for opening **one** socket now: a newly minted secret every
    /// call (single-use; never cached or reused).
    public func credential(model: String) async throws -> RealtimeCredential {
        guard let key = try keyStore.load(), !key.isEmpty else { throw RealtimeAuthError.noKey }
        guard mint, !mintingUnavailable else { return .direct(key) }
        do {
            let credential = try await mintSecret(key: key, model: model)
            minted += 1
            return credential
        } catch let e as RealtimeAuthError {
            throw e
        } catch MintFallback.unsupported(let status) {
            if sessionType == .transcription { throw RealtimeAuthError.transcriptionUnavailable(status: status) }
            mintingUnavailable = true
            return .direct(key)
        } catch {
            // A transcription session is never opened with the key itself.
            if sessionType == .transcription { throw error }
            // Transient trouble on the minting call only; the socket may still work.
            return .direct(key)
        }
    }

    /// Kept for API compatibility: nothing is cached any more (every
    /// `credential(model:)` mints a fresh secret), so there is nothing to drop.
    public func invalidate() {}

    private enum MintFallback: Error { case unsupported(Int), transient }

    private func mintSecret(key: String, model: String) async throws -> RealtimeCredential {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("mint", forHTTPHeaderField: Transport.purposeHeader)
        if let safetyIdentifier { request.setValue(safetyIdentifier, forHTTPHeaderField: "OpenAI-Safety-Identifier") }
        let session: RealtimeJSON = sessionType == .transcription
            ? transcription.mintSession()
            : ["type": "realtime", "model": .string(model)]
        let body: RealtimeJSON = [
            "expires_after": ["anchor": "created_at", "seconds": .number(Double(ttlSeconds))],
            "session": session,
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONDecoder().decode(RealtimeJSON.self, from: data)
        switch status {
        case 200...299:
            guard let value = json?["value"]?.stringValue, !value.isEmpty else { throw MintFallback.transient }
            let expires = json?["expires_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
                ?? now().addingTimeInterval(Double(ttlSeconds))
            return .ephemeral(value, expiresAt: expires)
        case 401, 403:
            throw RealtimeAuthError.unauthorized(status: status, message: json?["error"]?["message"]?.stringValue)
        case 429:
            let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw RealtimeAuthError.rateLimited(retryAfter: retry, code: json?["error"]?["code"]?.stringValue)
        case 400, 404, 405, 501:
            throw MintFallback.unsupported(status)
        default:
            throw MintFallback.transient
        }
    }
}
