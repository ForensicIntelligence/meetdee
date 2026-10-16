// swift-tools-version: 6.2
import PackageDescription

// voice-harness — Dee's live voice loopback harness (voice design §7.4, layer 3) and
// trace record / replay (§7.3, layer 2). A separate package so the app's build never
// sees it. Build out of the iCloud Desktop:
//
//     swift build --package-path Tools/voice-harness --scratch-path /tmp/dee-harness
//     swift test  --package-path Tools/voice-harness --scratch-path /tmp/dee-harness
//
//   HarnessCore    pure Swift + Accelerate: WAV I/O, fixtures catalog + manifest, noise /
//                  reverb synthesis, the mic mixer (fixtures + noise at SNR + synthetic
//                  echo), scenarios, run records, metrics, gates, WER, cost, reports.
//   HarnessRunner  drives DeeVoice's CloudVoice on a manual AudioGraph in real time
//                  against DeeRealtime's RealtimeSession (live API or trace replay),
//                  with DeeBrain's RealtimeBrain (real Mind / Self / Memory state in a
//                  temp dir, real DNA) or the minimal brain; socket tap + fault
//                  injection; the LLM judge client.
//   voice-harness  the CLI: `fixtures`, `suite`, `validate`, `run`, `replay`, `gates`, `judge`.
//
// DeeKit requires macOS 26, so this package does too (SwiftPM refuses a lower floor).
let package = Package(
    name: "voice-harness",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "voice-harness", targets: ["voice-harness"]),
    ],
    dependencies: [
        .package(name: "DeeKit", path: "../../Packages/DeeKit"),
    ],
    targets: [
        .target(name: "HarnessCore"),
        .target(name: "HarnessRunner", dependencies: [
            "HarnessCore",
            .product(name: "DeeVoice", package: "DeeKit"),
            .product(name: "DeeRealtime", package: "DeeKit"),
            .product(name: "DeeBrain", package: "DeeKit"),
            .product(name: "DeeCore", package: "DeeKit"),
            .product(name: "DeeMind", package: "DeeKit"),
            .product(name: "DeeMemory", package: "DeeKit"),
            .product(name: "DeeSelf", package: "DeeKit"),
            .product(name: "DeeWake", package: "DeeKit"),
            .product(name: "DeeLocal", package: "DeeKit"),
        ]),
        .executableTarget(name: "voice-harness", dependencies: ["HarnessCore", "HarnessRunner", .product(name: "DeeWake", package: "DeeKit")]),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore"]),
        .testTarget(name: "HarnessRunnerTests", dependencies: [
            "HarnessRunner", "HarnessCore",
            .product(name: "DeeVoice", package: "DeeKit"),
            .product(name: "DeeRealtime", package: "DeeKit"),
            .product(name: "DeeBrain", package: "DeeKit"),
            .product(name: "DeeMemory", package: "DeeKit"),
            .product(name: "DeeMind", package: "DeeKit"),
            .product(name: "DeeSelf", package: "DeeKit"),
            .product(name: "DeeWake", package: "DeeKit"),
            .product(name: "DeeLocal", package: "DeeKit"),
            .product(name: "DeeMockServer", package: "DeeKit"),
        ]),
    ]
)
