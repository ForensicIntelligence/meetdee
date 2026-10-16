# Dee 0.6 — app: onboarding, in-app settings, wake window

Implements the app part of `docs/contracts-0.6/providers-wake-onboarding.md` (§4, §5). This file explains the decisions; the contract stays binding.

## Phases
`DeeApp`: splash → onboarding → Dee.
- Before the splash ends, `DeePrefs.migrate` runs. It moves the old Settings.bundle `openAIKey` field to the Keychain with **no network call** and always removes the plaintext copy (K1). If the Keychain refuses the key, the copy is removed anyway and the user enters the key again. If no provider is configured yet, the old `cloudVoice`/`cloudModel` values pre-fill a mode-1 draft.
- Onboarding shows while `onboardingVersion < OnboardingFlow.version` or no `providerConfig` is saved.
- `model.start()` runs only in `.dee`. Until then nothing uses the microphone, camera or network. Each permission is asked from its own card. The network is used only when the user taps "Check key" or "Test connection".
- DEBUG launch arguments: `-DeeResetOnboarding` shows onboarding again. `-DeeSkipOnboarding` saves a mode-1 placeholder (UI tests).

## Onboarding (`OnboardingFlow`, DeeCore, pure)
Steps in order: meet → talking → seeing → privacy → mic → speech → camera → local network → **provider** → wake phrase → voice → speak first → (permission cards still undetermined) → done.
- **Skip** is offered only before the provider step, and jumps to it.
- **Start** needs `ProviderStore.isReady`, which means three things:
  - `ProviderConfig.validate()` is empty.
  - The parts the user tested are OK.
  - Modes 1 and 2 have an OpenAI key in the Keychain; modes 2 and 3 have a brain that passed "Test connection".
- The speech card stays. On iOS, `SFSpeechRecognizer.requestAuthorization` is still asked. The SDK probe showed SpeechAnalyzer running without it on macOS only.

## In-app settings (`DeeSettingsView`)
Ways to open it:
- the gear (`settingsButton`);
- a **two-finger** long-press on the eyes (the one-finger 0.8 s press stays the hug);
- tapping an urgent status chip.

Sections:
- provider (mode cards, OpenAI key Replace/Remove showing `sk-…abcd`, LAN address/key/model + Test, mode-3 hearing and voice: same server / another server / on this iPhone);
- wake phrase (with the short-phrase warning);
- voice;
- speak first;
- share memories;
- age;
- today's usage;
- privacy;
- run the introduction again;
- start over;
- version.

Behaviour on Save:
- **Save** writes prefs only (no network).
- `DeeModel.settingsChanged()` rebuilds the voice stack only while dormant (an open window is closed first, `providerChanged`). It also rebuilds when the old stack could not work, for example when a key was just added.

**Settings.bundle: removed entirely.** Everything it held is now in-app:
- the key (now Keychain only);
- voice, model, share memories;
- age, ageing, start over.

The UserDefaults keys stay the same (`cloudVoice`, `shareMemoriesWithCloud`, `ageEnabled`, `startAge`, `agingEnabled`, `yearsPerDay`, `resetMind`), so nothing else moves. A plaintext key field in UserDefaults was the K1 leak.

## Keys
`KeychainSecrets` wraps `KeyStore(account:kind:)`. The accounts are `openai.api-key` (`sk-`) and `lan.<part>.key` (opaque).
- `providerConfig` JSON names accounts only. `DeePrefs.leaks(in:)` refuses to save a config that contains an `sk-` string, a URL with userinfo/query/fragment, or a field named key/token/secret.
- An `sk-` key entered for a plain-http LAN endpoint is refused ("…it would cross your Wi-Fi unencrypted").
- After "Paste", the pasteboard is cleared if it still holds the same item.

## The window (`WakeController`, DeeBrain)
`WakeController` drives wake's pure `ConversationWindow`:
- **Inputs:** on-device ear hits, candidates (perk-up eyes), availability, taps (`tapToTalk`, a tap outside the eyes or the wake chip), the speak-first greeting, `CloudVoice.awakeStates` (connected/failed), accepted turns, reply ends (`toAccepted` only for replies to user turns), 2 Hz ticks with `Busy` (reply outstanding, words awaited, hold, and EarCore's bed-proof `userVoiceActive`, never raw energy), close commands, background, provider change.
- **Actions** run through `WakeControllerHost` (DeeModel): eyes, `CloudVoice.wake(uplinkFromFrame:resume:)` / `sleep()`, local goodbye, problems.
- **Bookkeeping:** usage (`UsageCounter`, persisted in `usage.v1`) and the numbers-only log line.

Gates:
- **W1:** DeeModel never wakes or changes engagement from a server or LAN transcript (the `addressesDee` paths are gone). `answersOnCommit`, `heard` and partials use `Engagement.answers`.
- Initiatives, Cortex cues, curiosity, `sayAside`, event lines (touch, wave, sound) and the AI-voice disclosure all wait for an open window. With "Speak first" on, a recognised friend opens one greeting window per arrival. The disclosure is only for modes 1 and 2.
- **Voice commands:**
  - `stopListening` / `sleep` close the window at once.
  - "change your wake phrase to X" → `WakePhraseChange`: she repeats it and asks. A yes within 20 s saves it to prefs and the ear. An invalid phrase gets her reason.
  - Commands work after a custom phrase (`WakeMatcher.stripLeading`).
- **Screen:** `isIdleTimerDisabled` is on in `.dee` and off in the background and during onboarding. While dormant her eyes show the soft "not listening" look, dimmer after 2 minutes without activity.

## Status chips
- `wakeState` shows "Say “Hey Dee” or tap", "Waking up…" or "Listening"; tapping it wakes her.
- The chip above it shows, in priority order: disclosure, notice, provider problem (taps open settings), ear problem ("I can't hear my wake phrase — tap me to talk"), cloud status.

## Tests
- DeeCore `V06CoreTests`: DNASplit, UsageCounter, OnboardingFlow, close/confirm/change-phrase commands.
- DeeSelf `DNASplitSelfTests`: the split of real archetype DNA renders.
- DeeBrain:
  - `V06BrainTests`: the StandaloneHost window rule, W1 on transcripts, `WakePhraseChange`, `Options(timing:)`, DeePrefs K1 and migration with 0 requests.
  - `WakeControllerTests`: eyes before connect, preroll frame, 60 s idle close, TV-bed false wake, goodbye before disconnect, new conversation after 300 s, greeting, lost ear, candidate.
  - `WakeVoiceIntegrationTests`: a real CloudVoice. While dormant there are 0 sockets and 0 mints; with every request failing she still wakes.
- `BrainLoopTests.speechNotForHerIsNotAnswered` is now the W1 regression: "Dee, are you awake?" in a server transcript no longer wakes her.
- UI test ids: `onboardingNext`, `onboardingSkip`, `onboardingDone`, `providerOpenAI`, `providerLanBrain`, `providerLan`, `apiKeyField`, `serverAddressField`, `testConnection`, `settingsButton`, `wakeState`. The UITests file isn't owned by app; the change is proposed in `scratchpad/pw-app-to-uitests.patch`.
