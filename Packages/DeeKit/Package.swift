// swift-tools-version: 6.2
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
let package = Package(
    name: "DeeKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
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
    ],
    targets: [
        .target(name: "DeeCore"),
        .target(name: "DeeFace", dependencies: ["DeeCore"]),
        .target(name: "DeeVoice", dependencies: ["DeeCore", "DeeRealtime"]),
        .target(name: "DeeTools", dependencies: ["DeeCore"]),
        .target(name: "DeeSense"),
        .target(name: "DeeMind", dependencies: ["DeeCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "DeeMemory", dependencies: ["DeeCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "DeeSelf", dependencies: ["DeeCore", "DeeMind", "DeeMemory"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "DeeRealtime"),
        .target(name: "DeeBrain", dependencies: ["DeeCore", "DeeMind", "DeeMemory", "DeeSelf", "DeeRealtime", "DeeVoice", "DeeTools"]),
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
    ]
)
