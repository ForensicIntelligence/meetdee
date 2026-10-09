# Dee: On-device iOS 26/27 frameworks for a speaking agentic assistant (brief, 2026-10-08, fact-checked)

## 1. Speech-to-text

**SpeechAnalyzer / SpeechTranscriber (iOS 26+, use this as the primary path)**
- `SpeechAnalyzer` is a `final actor`. It takes modules: `SpeechTranscriber` (general-purpose), `DictationTranscriber`, and `SpeechDetector`. It needs no network once its assets are installed. https://developer.apple.com/documentation/speech/speechanalyzer
- Setup:
  ```swift
  let t = SpeechTranscriber(locale: loc, transcriptionOptions: [],
          reportingOptions: [.volatileResults], attributeOptions: [])
  let vad = SpeechDetector()   // also init(detectionOptions:reportResults:)
  let analyzer = SpeechAnalyzer(modules: [vad, t])   // init(modules:options:)
  guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
  else { /* nil means assets are not installed yet */ }
  ```
  - Feed audio as `AsyncStream<AnalyzerInput>` (`start(inputSequence:)`). The path is `AVAudioEngine.installTap` → `AVAudioConverter` (to `fmt`) → `AnalyzerInput`.
  - The analyzer does not resample or convert audio itself, so you must convert to `fmt` first.
  - Read `t.results` and use `result.isFinal` to tell partial text from final text.
  - https://dev.to/simple_memo/ios-26s-speechanalyzer-on-a-live-mic-the-5-things-the-docs-dont-tell-you-2ng5
- **Assets:**
  - Check `await SpeechTranscriber.installedLocales`. Then call `try await AssetInventory.assetInstallationRequest(supporting: [t])`. It returns an optional: `nil` means the assets are already installed. Otherwise call `downloadAndInstall()`.
  - Assets are system-managed and shared between apps. Each app gets a limited number of locale reservations (`maximumReservedLocales`), so check again at launch.
  - https://developer.apple.com/documentation/speech/assetinventory
- **VAD / end of utterance:**
  - `SpeechDetector` gates transcription on voice activity. `SensitivityLevel` has `.low`, `.medium` and `.high`; `.medium` is recommended. It only works alongside a `SpeechTranscriber` or `DictationTranscriber`.
  - `results` only appear with `reportResults: true`. Even then, they "currently only support error handling", so you get no reliable speech start/stop events. https://developer.apple.com/documentation/speech/speechdetector
  - Recommendation: detect end of utterance yourself. Treat it as a final result followed by about 700–900 ms with no new volatile text, combined with an RMS energy gate on the mic tap.
- **Custom vocabulary:**
  - `AnalysisContext.contextualStrings` (iOS 26) is documented for `DictationTranscriber`. Keep it to 100 phrases or fewer.
  - Apply it with `analyzer.setContext(_:)`. https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings
  - Whether `SpeechTranscriber` honours it is UNVERIFIED. To bias toward "Dee", use `DictationTranscriber`.

**SFSpeechRecognizer fallback (iOS 10+)**
- Set `requiresOnDeviceRecognition = true` after checking `supportsOnDeviceRecognition`. It supports `contextualStrings`.
- Downsides: older models, and it needs `SFSpeechRecognizer.requestAuthorization`.

## 2. Text-to-speech

**Streaming**
- Split the LLM token stream on sentence boundaries (`NLTokenizer(unit: .sentence)`).
- Queue one `AVSpeechUtterance` per sentence. The synthesizer plays them in order.
- The delegate callback `willSpeakRangeOfSpeechString` gives word timing you can use for mouth movement.

**Voices**
- Filter `AVSpeechSynthesisVoice.speechVoices()` by `.quality` (`.enhanced` / `.premium`). The user has to download these in Settings, so fall back to the default voice.
- Personal Voice doesn't fit this app.

**Cute robot voice**
- Set `pitchMultiplier` (range 0.5–2.0; try about 1.4–1.6) and `rate` (about `AVSpeechUtteranceDefaultSpeechRate * 1.05`).

**Effects and amplitude**
- `write(_:toBufferCallback:)` hands back `AVAudioBuffer`s; cast them to `AVAudioPCMBuffer`. https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)
- Chain: `AVAudioPlayerNode` → `AVAudioUnitTimePitch` (in cents) → `AVAudioUnitDistortion` (`.speechRadioTower` / `.speechAlienChatter`) or a custom ring-mod node → mainMixer.
- Tap the mixer for RMS at about 60 Hz to drive the face.
- Buffers arrive faster than real time, so drive mouth timing from the player node, not from the delegate.

**AVAudioSession**
- Category `.playAndRecord`, mode `.voiceChat`, options `[.defaultToSpeaker, .allowBluetoothHFP]`.
  - `allowBluetoothHFP` exists in the current SDK docs. `allowBluetooth` is still documented and not marked deprecated.
- Echo cancellation: call `inputNode.setVoiceProcessingEnabled(true)` before starting the engine. Tune ducking with `voiceProcessingOtherAudioDuckingConfiguration` (iOS 17+).
- Route TTS through the same engine so the echo-cancellation reference includes Dee's voice.
- Add `UIBackgroundModes: audio` only if Dee must talk while backgrounded.

## 3. On-device tool APIs (no network)

| Tool | API | Info.plist / entitlement |
|---|---|---|
| Calendar | EventKit `requestFullAccessToEvents()` / `requestWriteOnlyAccessToEvents()` (iOS 17+) | `NSCalendarsFullAccessUsageDescription`, `NSCalendarsWriteOnlyAccessUsageDescription` |
| Reminders | `requestFullAccessToReminders()` | `NSRemindersFullAccessUsageDescription` |
| Alarms/timers | AlarmKit `AlarmManager.shared.requestAuthorization()`, `schedule(id:configuration:) async throws -> Alarm` (iOS 26+) | `NSAlarmKitUsageDescription` (verified; without it, scheduling fails); widget extension for countdown UI |
| Contacts | `CNContactStore.requestAccess(for: .contacts)` | `NSContactsUsageDescription` |
| Location | `CLLocationUpdate.liveUpdates()`; reverse geocoding needs network | `NSLocationWhenInUseUsageDescription` |
| Battery | `UIDevice.current.isBatteryMonitoringEnabled` | none |
| Music | `MPMusicPlayerController.systemMusicPlayer` + `MPMediaQuery` | `NSAppleMusicUsageDescription` |
| Health | `HKHealthStore.requestAuthorization(toShare:read:)` | `NSHealthShareUsageDescription`; `com.apple.developer.healthkit` |
| Photos | `PHPhotoLibrary.requestAuthorization(for: .readWrite)` or `PhotosPicker` | `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription` |
| NaturalLanguage | `NLTagger` (sentiment → face emotion), `NLEmbedding` | none |
| Mic / Speech | as above | `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` (UNVERIFIED for SpeechTranscriber; include it) |
| App Intents | `AppShortcutsProvider` | none |

**Required for the 2.7 GB model**
- `com.apple.developer.kernel.increased-memory-limit` (iOS 15+). It is a capability, not something Apple reviews or grants separately.
- The docs say the higher limit exists "only on some device models", and the app must behave correctly without it.
- Add `com.apple.developer.kernel.extended-virtual-addressing` (iOS 14+, the "Extended Virtual Addressing" capability) for mmapped weights.
- Check `os_proc_available_memory()` at runtime. Device RAM thresholds are UNVERIFIED.

**Foundation Models as a fallback**
- `SystemLanguageModel.default.availability` must be `.available`.
- The 26.x context is 4096 tokens. Read `SystemLanguageModel.contextSize` at runtime instead of hard-coding it, because the model versions differ (26.0–26.3, 26.4, 27.0).
- It supports `Tool` calling and `@Generable` guided output.
- Good uses: a fallback while the Qwen download is pending, intent classification, and summarizing a conversation for memory.

## 4. iOS 27 (WWDC26)
- **Foundation Models:**
  - New public `LanguageModel` protocol (iOS 27), with an `Executor`, `capabilities` and `executorConfiguration`. Apple's docs tell implementers to "distribute your solution with Swift Package Manager", and the protocol is open to third-party implementations. Its conformers include `SystemLanguageModel` and `PrivateCloudComputeLanguageModel`. https://developer.apple.com/documentation/foundationmodels/languagemodel
  - Implication: a llama.cpp/Qwen executor can sit behind the FM session/`Tool` API. Fit with a 4096-token context and Qwen's chat template is UNVERIFIED.
  - Also new: multimodal prompts, Vision tools, Dynamic Profiles, and an Evaluations framework. https://developer.apple.com/wwdc26/guides/ios/, https://www.fonearena.com/blog/484623/apple-wwdc26-foundation-models-gemini-support-xcode-27-agentic-coding-tools.html
  - Private Cloud Compute is free for Small Business Program apps (UNVERIFIED; secondary source).
- **Core AI:** a Swift API for running your own models on-device. GGUF support is UNVERIFIED and likely absent.
- **App Intents:** intent schemas without predefined phrases, entity schemas, a View Annotations API, and a Testing framework.
- **NowPlaying** and **Music Understanding** frameworks.
- I found no iOS 27 changes to Speech, AVSpeechSynthesizer, AlarmKit, EventKit or HealthKit (UNVERIFIED that none exist).

**App size (verified):**
- On iOS 9+, the limit is 4 GB uncompressed after app thinning, and the executable's `__TEXT` sections are limited to 80 MB. https://developer.apple.com/help/app-store-connect/reference/maximum-build-file-sizes
- A ~2.7 GB GGUF fits in the bundle. Apple recommends Background Assets for large assets.

Sources: as above, plus https://developer.apple.com/documentation/speech/assetinventory · https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit · https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp · https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide · https://dev.to/arshtechpro/wwdc-2025-wake-up-to-the-alarmkit-api-ios-26-4e67

## Corrections
1. `bestAvailableAudioFormat(compatibleWith:)` returns `AVAudioFormat?`, which is `nil` when assets are missing. `assetInstallationRequest(supporting:)` is `async throws` and returns an optional (`nil` when already installed). The "fails silently" wording is replaced with the documented fact that the analyzer does not convert audio.
2. Custom vocabulary: `AnalysisContext.contextualStrings` exists in iOS 26, is documented for `DictationTranscriber`, and is capped at about 100 phrases. The brief said no biasing existed.
3. `SpeechDetector` results need `reportResults: true` and only report errors. The levels are low/medium/high, with `.medium` recommended rather than described as the default.
4. `.allowBluetoothHFP` is confirmed in the docs. `.allowBluetooth` is still listed and not deprecated, so "renamed, UNVERIFIED" is resolved.
5. The `LanguageModel` protocol (iOS 27) is confirmed open to third-party SPM implementations through an `Executor`, so the UNVERIFIED is resolved.
6. The increased-memory-limit entitlement is iOS 15+ and only raises the limit on some device models. The extended-virtual-addressing entitlement is iOS 14+.
7. The app size limit is confirmed at 4 GB uncompressed after thinning, with an 80 MB `__TEXT` limit. FM context size should be read from `contextSize` at runtime. `NSAlarmKitUsageDescription` is confirmed as required.