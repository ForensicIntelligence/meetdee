// swift-tools-version: 6.2
import Foundation
import PackageDescription

// DeeKit — every piece of Dee that is not app shell.
//
//   DeeCore   pure Swift: persona, emotion vocabulary, spoken commands, thinking
//             intent (per-response reasoning effort), turn ledger, voice health, the
//             tool protocol (JSON-schema function tools) and the ReplyEngine seam.
//   DeeFace   the Loona / Wall-E face: expression model, procedural animator, SwiftUI view.
//   DeeVoice  the audio graph (VPIO engine, 24 kHz capture, stream player, levels,
//             local VAD / prosody / sound events) and CloudVoice, which connects it to
//             the realtime session (her ears and voice).
//   DeeTools  namespace for device tools (they live in DeeBrain for now).
//   DeeSense  the front camera: who's there, where they are, hand gestures.
//   DeeMind   emotions, personality and age — appraisal, dynamics, SQLite persistence.
//   DeeMemory the people Dee knows: names, faces, facts — SQLite, on-device only.
//   DeeRealtime OpenAI Realtime (gpt-realtime) speech-to-speech client: GA event codecs,
//             WebSocket, Keychain key + ephemeral secrets, the RealtimeSession actor,
//             trace record / replay. Foundation + Network + Security only.
//   DeeBrain  RealtimeBrain: the app's ReplyEngine on the realtime session — when she
//             answers (fast / exact Dee DNA, "is this for me?"), one DNA item per
//             response (DNAWire), local prosody, the tool bridge (memory + device
//             tools), settings, key intake and the status chip mapping. App-free, so
//             a macOS harness drives it (StandaloneHost).
//   DeeWake   the wake phrase, heard ONLY on the device (Apple SpeechAnalyzer, on-device
//             assets): phrase rules, phonetic matcher, the shared on-device transcriber,
//             and the pure DORMANT ⇄ CONVERSATION window every host drives.
//   DeeLocal  (0.6) providers: LAN / OpenAI-voice cascaded pipeline, probe, factory.
//   DeeMockServer (0.6) offline OpenAI-compatible + Ollama-native server for tests.
//
// DeeLocal / DeeMockServer / DeeLocalTests are declared once their directories exist,
// so the package builds while the 0.6 modules are being written (contract
// docs/contracts-0.6/providers-wake-onboarding.md §1, owner: wake).
let root = Context.packageDirectory
/// The directory exists and holds at least one Swift file (an empty target is an error).
func present(_ path: String) -> Bool {
    guard let e = FileManager.default.enumerator(atPath: root + "/" + path) else { return false }
    while let f = e.nextObject() as? String { if f.hasSuffix(".swift") { return true } }
    return false
}
let hasLocal = present("Sources/DeeLocal")
let hasMock = present("Sources/DeeMockServer")
let hasLocalTests = present("Tests/DeeLocalTests") && hasLocal && hasMock

var products: [Product] = [
    .library(name: "DeeCore", targets: ["DeeCore"]),
    .library(name: "DeeFace", targets: ["DeeFace"]),
    .library(name: "DeeVoice", targets: ["DeeVoice"]),
    .library(name: "DeeTools", targets: ["DeeTools"]),
    .library(name: "DeeSense", targets: ["DeeSense"]),
    .library(name: "DeeMind", targets: ["DeeMind"]),
    .library(name: "DeeMemory", targets: ["DeeMemory"]),
    .library(name: "DeeSelf", targets: ["DeeSelf"]),
    .library(name: "DeeRealtime", targets: ["DeeRealtime"]),
    .library(name: "DeeBrain", targets: ["DeeBrain"]),
    .library(name: "DeeWake", targets: ["DeeWake"]),
]
if hasLocal { products.append(.library(name: "DeeLocal", targets: ["DeeLocal"])) }
if hasMock { products.append(.library(name: "DeeMockServer", targets: ["DeeMockServer"])) }

var brainDeps: [Target.Dependency] = ["DeeCore", "DeeMind", "DeeMemory", "DeeSelf", "DeeRealtime", "DeeVoice", "DeeTools", "DeeWake"]
if hasLocal { brainDeps.append("DeeLocal") }

var targets: [Target] = [
    .target(name: "DeeCore"),
    .target(name: "DeeFace", dependencies: ["DeeCore"]),
    .target(name: "DeeWake", dependencies: ["DeeCore"],
            linkerSettings: [.linkedFramework("Speech"), .linkedFramework("AVFoundation"), .linkedFramework("CoreMedia")]),
    .target(name: "DeeVoice", dependencies: ["DeeCore", "DeeRealtime", "DeeWake"]),
    .target(name: "DeeTools", dependencies: ["DeeCore"]),
    .target(name: "DeeSense"),
    .target(name: "DeeMind", dependencies: ["DeeCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
    .target(name: "DeeMemory", dependencies: ["DeeCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
    .target(name: "DeeSelf", dependencies: ["DeeCore", "DeeMind", "DeeMemory"], linkerSettings: [.linkedLibrary("sqlite3")]),
    .target(name: "DeeRealtime"),
    .target(name: "DeeBrain", dependencies: brainDeps),
    // DeeRealtime only to prove ToolSpec's JSON decodes as a RealtimeTool.
    .testTarget(name: "DeeCoreTests", dependencies: ["DeeCore", "DeeRealtime"]),
    .testTarget(name: "DeeFaceTests", dependencies: ["DeeFace"]),
    .testTarget(name: "DeeSenseTests", dependencies: ["DeeSense"]),
    .testTarget(name: "DeeMindTests", dependencies: ["DeeMind", "DeeCore"]),
    .testTarget(name: "DeeVoiceTests", dependencies: ["DeeVoice", "DeeCore"]),
    .testTarget(name: "DeeMemoryTests", dependencies: ["DeeMemory", "DeeCore"]),
    .testTarget(name: "DeeSelfTests", dependencies: ["DeeSelf", "DeeMind", "DeeCore", "DeeMemory"], exclude: ["Fixtures"]),
    .testTarget(name: "DeeRealtimeTests", dependencies: ["DeeRealtime"]),
    .testTarget(name: "DeeBrainTests", dependencies: ["DeeBrain", "DeeCore", "DeeMind", "DeeMemory", "DeeSelf", "DeeRealtime", "DeeVoice"]),
    .testTarget(name: "DeeWakeTests", dependencies: ["DeeWake", "DeeCore"], resources: [.copy("Fixtures")]),
]
if hasLocal {
    targets.append(.target(name: "DeeLocal", dependencies: ["DeeCore", "DeeRealtime", "DeeVoice", "DeeWake"]))
}
if hasMock {
    targets.append(.target(name: "DeeMockServer", linkerSettings: [.linkedFramework("Network")]))
}
if hasLocalTests {
    targets.append(.testTarget(name: "DeeLocalTests",
                               dependencies: ["DeeLocal", "DeeMockServer", "DeeRealtime", "DeeVoice", "DeeWake", "DeeCore"]))
}

let package = Package(
    name: "DeeKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: products,
    targets: targets
)
