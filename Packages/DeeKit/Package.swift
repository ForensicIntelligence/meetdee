// swift-tools-version: 6.2
import PackageDescription

// DeeKit — every piece of Dee that is not app shell.
//
//   DeeCore   pure Swift: prompt rendering (Qwen3.5 template), streaming output
//             parser, thinking-intent detection, agent loop, tool protocol.
//   DeeLLM    llama.cpp wrapper (binary xcframework built by scripts/build-llama.sh).
//   DeeFace   the Loona / Wall-E face: expression model, procedural animator, SwiftUI view.
//   DeeVoice  on-device speech in (SpeechAnalyzer) and out (AVSpeechSynthesizer + FX).
//   DeeTools  on-device tools the agent can call (clock, calendar, reminders, ...).
//   DeeSense  the front camera: who's there, where they are, hand gestures.
//   DeeMind   emotions, personality and age — appraisal, dynamics, SQLite persistence.
//   DeeMemory the people Dee knows: names, faces, facts — SQLite, on-device only.
let package = Package(
    name: "DeeKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "DeeCore", targets: ["DeeCore"]),
        .library(name: "DeeLLM", targets: ["DeeLLM"]),
        .library(name: "DeeFace", targets: ["DeeFace"]),
        .library(name: "DeeVoice", targets: ["DeeVoice"]),
        .library(name: "DeeTools", targets: ["DeeTools"]),
        .library(name: "DeeSense", targets: ["DeeSense"]),
        .library(name: "DeeMind", targets: ["DeeMind"]),
        .library(name: "DeeMemory", targets: ["DeeMemory"]),
        .library(name: "DeeSelf", targets: ["DeeSelf"]),
    ],
    targets: [
        .binaryTarget(name: "llama", path: "Binaries/llama.xcframework"),
        .target(name: "DeeCore"),
        .target(name: "DeeLLM", dependencies: ["DeeCore", "llama"]),
        .target(name: "DeeFace", dependencies: ["DeeCore"]),
        .target(name: "DeeVoice", dependencies: ["DeeCore"]),
        .target(name: "DeeTools", dependencies: ["DeeCore"]),
        .target(name: "DeeSense"),
        .target(name: "DeeMind", dependencies: ["DeeCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "DeeMemory", dependencies: ["DeeCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "DeeSelf", dependencies: ["DeeCore", "DeeMind", "DeeMemory"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "DeeCoreTests", dependencies: ["DeeCore"], exclude: ["Fixtures"]),
        .testTarget(name: "DeeFaceTests", dependencies: ["DeeFace"]),
        .testTarget(name: "DeeLLMTests", dependencies: ["DeeLLM", "DeeCore"]),
        .testTarget(name: "DeeSenseTests", dependencies: ["DeeSense"]),
        .testTarget(name: "DeeMindTests", dependencies: ["DeeMind", "DeeCore"]),
        .testTarget(name: "DeeVoiceTests", dependencies: ["DeeVoice", "DeeCore"]),
        .testTarget(name: "DeeMemoryTests", dependencies: ["DeeMemory", "DeeCore"]),
        .testTarget(name: "DeeSelfTests", dependencies: ["DeeSelf", "DeeMind", "DeeCore", "DeeMemory"], exclude: ["Fixtures"]),
    ]
)
