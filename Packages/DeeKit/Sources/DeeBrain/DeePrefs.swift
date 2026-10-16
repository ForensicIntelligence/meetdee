import DeeCore
import DeeLocal
import DeeRealtime
import DeeWake
import Foundation

/// Dee's in-app preferences (v0.6, providers-wake-onboarding §5). Settings.bundle is
/// gone: everything is set in onboarding or the in-app settings and lives here, in
/// UserDefaults, **without a single secret** (K1). Keys live in the Keychain
/// (`KeychainSecrets`); the provider config only names their accounts.
public struct DeePrefs {
    public enum Key {
        public static let providerConfig = ProviderConfig.defaultsKey
        public static let onboardingVersion = OnboardingFlow.versionKey
        public static let wakePhrase = "wakePhrase"
        public static let speakFirst = "speakFirst"
        public static let usage = UsageCounter.defaultsKey
        public static let strictUntil = "wakeStrictUntil"
        public static let brainCapabilities = "serverCapabilities"
    }

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: Provider

    /// The saved provider (nil before onboarding chose one, or if it fails K1).
    public var providerConfig: ProviderConfig? {
        get {
            guard let data = defaults.data(forKey: Key.providerConfig),
                  let c = try? JSONDecoder().decode(ProviderConfig.self, from: data) else { return nil }
            return c
        }
        nonmutating set {
            guard let c = newValue else {
                defaults.removeObject(forKey: Key.providerConfig)
                return
            }
            guard let data = try? JSONEncoder().encode(c), Self.leaks(in: data).isEmpty else { return }
            defaults.set(data, forKey: Key.providerConfig)
        }
    }

    /// The last "Test connection" of the brain server (vendor, tools, realtime; no secrets):
    /// `ProviderFactory` uses it to pick tools / native routes.
    public var brainCapabilities: ServerCapabilities? {
        get { defaults.data(forKey: Key.brainCapabilities).flatMap { try? JSONDecoder().decode(ServerCapabilities.self, from: $0) } }
        nonmutating set {
            guard let c = newValue, let data = try? JSONEncoder().encode(c), Self.leaks(in: data).isEmpty else {
                defaults.removeObject(forKey: Key.brainCapabilities)
                return
            }
            defaults.set(data, forKey: Key.brainCapabilities)
        }
    }

    public var onboardingVersion: Int {
        get { defaults.integer(forKey: Key.onboardingVersion) }
        nonmutating set { defaults.set(newValue, forKey: Key.onboardingVersion) }
    }

    /// Onboarding must show (never finished, or a newer flow).
    public var needsOnboarding: Bool { onboardingVersion < OnboardingFlow.version || providerConfig == nil }

    public var wakePhrase: WakePhrase {
        get { defaults.string(forKey: Key.wakePhrase).flatMap { try? WakePhrase(validating: $0) } ?? .default }
        nonmutating set { defaults.set(newValue.text, forKey: Key.wakePhrase) }
    }

    /// "Speak first when she sees someone" — off by default.
    public var speakFirst: Bool {
        get { defaults.bool(forKey: Key.speakFirst) }
        nonmutating set { defaults.set(newValue, forKey: Key.speakFirst) }
    }

    public var shareMemories: Bool {
        get { defaults.object(forKey: CloudSettings.Key.shareMemories) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: CloudSettings.Key.shareMemories) }
    }

    public var usage: UsageCounter {
        get { UsageCounter.decoded(defaults.data(forKey: Key.usage)) }
        nonmutating set { defaults.set(newValue.encoded(), forKey: Key.usage) }
    }

    // MARK: Migration (before onboarding shows; no network)

    public struct MigrationReport: Sendable, Equatable {
        public var key: KeyIntake.Migration
        /// A mode-1 config was pre-filled from the old voice / model settings.
        public var prefilled: Bool
    }

    /// Once per launch, before onboarding: the old Settings.bundle key → Keychain (no
    /// network, plaintext always removed), the old voice/model → a mode-1 draft config
    /// when no config exists yet and the user had an OpenAI key. Also drops every
    /// leftover Settings.bundle field that held anything key-like.
    @discardableResult
    public func migrate(intake: KeyIntake) -> MigrationReport {
        let key = intake.migrateLegacyKey(from: defaults)
        var prefilled = false
        if providerConfig == nil, key == .moved || intake.keyStore.hasKey {
            let old = CloudSettings(defaults: defaults)
            providerConfig = .openAI(model: old.model, voice: old.voice)
            prefilled = true
        }
        return MigrationReport(key: key, prefilled: prefilled)
    }

    // MARK: K1

    /// Everything secret-looking in `data` (a JSON value): `sk-` strings, URLs with
    /// userinfo / a query / a fragment, and fields named like a key, token or secret
    /// (`keyAccount` names an account, not a secret, and is allowed).
    public static func leaks(in data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        var found: [String] = []
        func walk(_ v: Any, path: String) {
            if let d = v as? [String: Any] {
                for (k, x) in d {
                    let lower = k.lowercased()
                    if lower != "keyaccount", ["key", "token", "secret", "password", "apikey"].contains(where: { lower.contains($0) }),
                       !(lower == "keepalive") {
                        found.append("\(path).\(k)")
                    }
                    walk(x, path: "\(path).\(k)")
                }
            } else if let a = v as? [Any] {
                for (i, x) in a.enumerated() { walk(x, path: "\(path)[\(i)]") }
            } else if let s = v as? String {
                if s.trimmingCharacters(in: .whitespaces).hasPrefix("sk-") { found.append("\(path): sk-") }
                if s.contains("://"), let c = URLComponents(string: s),
                   c.user != nil || c.password != nil || c.query != nil || c.fragment != nil {
                    found.append("\(path): url")
                }
            }
        }
        walk(json, path: "$")
        return found
    }

    /// K1 over a whole defaults domain (tests and a DEBUG self-check): every string
    /// value that looks like a key, and every JSON blob that leaks.
    public static func leaks(inDomain values: [String: Any]) -> [String] {
        var found: [String] = []
        for (k, v) in values {
            if k == CloudSettings.Key.apiKey { found.append(k) }
            if let s = v as? String, s.trimmingCharacters(in: .whitespaces).hasPrefix("sk-") { found.append(k) }
            if let d = v as? Data { found += leaks(in: d).map { "\(k)\($0.dropFirst())" } }
        }
        return found
    }
}

/// The Keychain as a `SecretReader` (OpenAI: `sk-` keys; LAN: opaque tokens).
public struct KeychainSecrets: SecretReader {
    public let storage: any SecretStorage

    public init(storage: any SecretStorage = KeychainStorage()) { self.storage = storage }

    public func store(account: String) -> KeyStore {
        KeyStore(account: account, kind: account == SecretAccount.openAI ? .openAI : .opaque, storage: storage)
    }

    public func secret(account: String) -> String? {
        (try? store(account: account).load()) ?? nil
    }
}
