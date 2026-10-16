# Dee Face: Visual Design Brief (fact-checked)

**Developer:** Forensic Intelligence

## 1. The reference video

- **Video:** https://www.youtube.com/shorts/xakELIhs-rw. The only thing I could fetch is the title, "Robot Dog Isn't this more fun than an iron egg". The channel, the description and what happens in the video are **UNVERIFIED**. The title points to a Loona-class pet robot compared with egg-shaped robots, possibly Eilik or EBO. That comparison is **UNVERIFIED**.

## 2. Loona (KEYi Tech): what is confirmed

- Loona is "a four-wheeled robot standing 6.8 in (172 mm) high, with a 2.4-in LCD screen for a face". The screen shows "a pair of very cartoonish eyes" that express joy, anger, sadness and more. Source: New Atlas, https://newatlas.com/robotics/loona-pet-robot-kickstarter/
- It has "a pair of glowing ear-like antennas" that **rise with happiness and droop with disappointment**. Source: New Atlas only. The TechCrunch article (https://techcrunch.com/2022/09/15/ankis-spiritual-successor-hits-kickstarter-with-some-impressive-moves) does not describe the ears or the screen; it covers movement and recognition features.
- Its eyes blink, widen in surprise and droop when sad. It has "1,000+" behaviours that combine face, ears, voice and body. Sources: https://keyirobot.com/de-de/blogs/buying-guide/loona-vs-ebo-x-which-ai-companion-robot-is-right-for-your-pet and ITmedia, https://www.itmedia.co.jp/pcuser/articles/2312/28/news143.html. Neither page was re-fetched in this pass.
- It has **no mouth**. Emotion comes only from eyes, ears and body.
- **UNVERIFIED:** the exact eye color, which I remember as white-to-cyan glowing pill shapes on a black screen; whether there are heart-eye or "zzz" glyphs; whether there are pupils.

## 3. Wall-E's eyes

- The design came from binoculars. Stanton said: "I just turned the thing around and I started staring at it and I started making it go sad and then happy and then mad." Source: Mental Floss, https://www.mentalfloss.com/article/70024/10-space-age-facts-about-walle. Wikipedia (https://en.wikipedia.org/wiki/WALL-E_(character)) confirms only the binoculars. The specific mapping "tilt with outer edges dropping means sad" is a design inference and is **UNVERIFIED**.
- "Stanton added a zoom lens to make WALL-E more sympathetic." Source: Wikipedia. The Nikon camera shutter in Mental Floss is Ben Burtt's **sound effect** for the eyebrow movements. It is not a visual aperture mechanism.
- **Lesson for Dee:** rotate the whole eye (tilt) and use lids instead of brows. An optional iris ring zooms in for wonder and narrows for focus.

## 4. Procedural eye animation: best practice

- **Blinks:** humans blink every 2–6 s. In conversation that drops to 2–4 s; at idle it stretches to 4–7 s. The lid closes in about 80 ms, stays shut 50–100 ms and reopens in about 150 ms. Opening must be slower than closing. Source: https://abratabia.com/ai-talking-characters/facial-animation.php
  - Interval: draw from the ranges above.
  - Double blinks: about 1 in 8 blinks, with a 200–400 ms gap.
  - Partial blinks: some blinks close only 0.7–0.9 of the way.
  - Blink on large gaze shifts and emotion changes. This is a design rule, not from the source.
- **Saccades:** abratabia gives micro-movements every 200–600 ms of 1–3°, lerped over about 50 ms. Larger gaze holds of 0.4–2 s are a design value. Other sources: Reallusion, https://manual.reallusion.com/iclone-ai-assistant-plug-in/content/speech-graph/speech-driven-saccade.htm ; Moore 2014, https://dreuarchive.cra.org/2014/Moore/uploads/3/0/4/2/30422230/final_report.pdf. These two were not re-fetched.
- **Parametric robot eyes as precedent:** FluxGarage RoboEyes sets width, height and border radius per eye, plus spacing, which can be negative. It has the moods DEFAULT, TIRED, ANGRY and HAPPY. Its animations are `anim_confused()` (horizontal shake), `anim_laugh()` (vertical shake), `blink()`, `setAutoblinker()` and `setIdleMode()`. It also has flicker effects and a sweat drop. Whether it smooths all transitions is **UNVERIFIED**. Source: https://github.com/FluxGarage/RoboEyes
- **Classic principles (design values):**
  - Anticipation: squint about 10% for 60 ms before a surprised widen.
  - Squash and stretch: eyes widen and flatten at blink midpoint, and stretch vertically by about 8% on a fast upward look.
  - Overshoot and settle: underdamped spring.
  - Idle breathing: scale ±1.5% at 0.25 Hz.
  - Wander: drift the gaze ±3% when there is no target.
  - Gaze follows a face, found with Vision `VNDetectFaceRectanglesRequest` or the Swift-native `DetectFaceRectanglesRequest` (iOS 18+), or follows touch.

## 5. Expression spec

Units are fractions of the base eye size. The base eye is 0.26 × face width wide and 0.34 × face width tall, with corner radius 0.45 of the width (a pill shape).

- **Lid angle** is in degrees. Positive means the inner corner is lower (angry); negative means the outer corner is lower (sad).
- **Coverage** runs from 0 to 1 and is the fraction of the eye hidden by a lid.
- **Tilt** rotates the whole eye unit, positive outward.
- **Iris** is an optional inner ring scale; 0 means off.
- **Base color** is #7FE7FF on #05070A.

| # | Emotion | W | H | Radius | Upper lid ° / cov | Lower cov | Tilt° | Iris / offset | Color | Extras / ears |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Neutral | 1.0 | 1.0 | .45 | 0 / .05 | 0 | 0 | 0 | #7FE7FF | ears mid |
| 2 | Happy (^ ^) | 1.1 | .55 | .50 | 0 / 0 | .45 arched | 0 | 0 | #9FF5FF | ears up, 2 Hz bounce |
| 3 | Joy / laugh | 1.15 | .40 | .50 | 0 / 0 | .55 | 0 | 0 | #B8FFF0 | y-jitter ±4% at 6 Hz, sparkles |
| 4 | Love | 1.05 | 1.05 | — | — | — | 0 | 0 | #FF6FA8 | morph to hearts, 1.2 Hz pulse ±8% |
| 5 | Sad | .95 | .90 | .45 | −18 / .30 | 0 | −10 | .3 / y+.10 | #6FA8FF | ears droop, slow blinks |
| 6 | Angry | 1.0 | .80 | .30 | +25 / .35 | .10 | +5 | 0 | #FF5A4F | ears back |
| 7 | Surprised | 1.15 | 1.25 | .50 | 0 / 0 | 0 | 0 | .5 zoom | #FFFFFF | 60 ms anticipation squint, then pop |
| 8 | Curious | L1.0 / R1.15 | L.85 / R1.1 | .45 | L +8 / .15 | 0 | head tilt 12° | .35 | #7FE7FF | one ear up, "?" |
| 9 | Sleepy | 1.05 | .90 | .45 | 0 / .60 drifting | .10 | −4 | 0 | #5F8FB0 at 70% | "zzz", 3 s slow blink |
| 10 | Asleep | 1.1 | .06 | .50 | — | — | 0 | 0 | #3F6F90 at 40% | zzz, breathing ±3% |
| 11 | Thinking | .9 | .9 | .45 | +5 / .25 | 0 | 0 | gaze (+.25, −.25) | #A98CFF | orbiting dots while thinking mode is on |
| 12 | Listening | 1.0 | 1.05 | .45 | 0 / 0 | 0 | 0 | .4 tracks face | #7FE7FF | ears up, ring glow pulses with mic RMS |
| 13 | Confused | L.9 / R1.1 | L.7 / R1.1 | .40 | L +15 / R −10 | 0 | 0 | 0 | #7FE7FF | horizontal wobble (like RoboEyes), "?" |
| 14 | Scared | .85 | 1.15 | .45 | −10 / 0 | 0 | −6 | .25 shrink | #CFE8FF | 12 Hz tremble ±1.5%, ears back |
| 15 | Smug | 1.05 | .60 | .40 | +10 / .40 | .20 | 0 | x+.15 | #7FE7FF | one-eye wink loop |
| 16 | Excited | 1.1 | 1.1 | — | — | — | 0 | 0 | #FFD86F | morph to 4-point stars, sparkles |

Tie the Thinking expression to thinking mode so the user can see when it is on.

## 6. Speech without a mouth

1. **Eye bounce:** eye height is `H × (1 + 0.12·env)` and vertical position is `−0.03·env`. `env` comes from a 20 ms attack / 120 ms release envelope follower.
   - **Correction:** put the tap on `engine.mainMixerNode` (or the player node), not on `outputNode`.
   - `AVSpeechSynthesizer` does not play through your engine by default. Use `write(_:toBufferCallback:)` and schedule the buffers on an `AVAudioPlayerNode`, then measure RMS on those buffers. This correction is based on the API design and was not re-checked against the docs in this pass, so it is **UNVERIFIED** here.
2. **Lower-lid smile pulse:** lower coverage is `+0.1·env` when the sentiment is positive.
3. **Optional waveform "chin" glow:** five bars, 0.18 × face height below the eyes, at 40% opacity. It fades after 400 ms of silence and can be turned off in settings.
4. **Ears:** wiggle ±3° on each phrase boundary.

## 7. SwiftUI implementation

- **Rendering:** draw with `TimelineView(.animation)` and `Canvas`. Eyes are `Path(roundedRect:cornerRadius:)` minus lid paths, done with clips or `context.blendMode = .destinationOut` inside a layer. Glow comes from `context.addFilter(.blur(radius:))` on a duplicate layer. Hearts and stars are parametric paths morphed by lerping control points.
- **Parameter model:** a `struct EyeParams` interpolated per frame by a spring for each parameter. Start with stiffness 170 and damping ratio 0.75 (a design value). Write your own integrator, stepped by the TimelineView date delta and clamped to dt ≤ 1/30. Use an asymmetric curve for blinks and avoid `withAnimation`.
- **Layer stack:** emotion target → gaze/saccade → breathing → blink override → speech envelope → tremble.
- **120 Hz ProMotion:** set the Boolean `CADisableMinimumFrameDurationOnPhone` to `true` in Info.plist. iPhone needs it to go above 60 Hz; iPad Pro does not. Use `.animation(minimumInterval: 1/30, paused: false)` when the face is asleep.
- **Expression selection:** the LLM emits an `[emo:happy]` tag or calls a `set_expression` tool. Debounce changes to at most one every 0.5 s.

## Sources

- https://www.youtube.com/shorts/xakELIhs-rw
- https://newatlas.com/robotics/loona-pet-robot-kickstarter/
- https://techcrunch.com/2022/09/15/ankis-spiritual-successor-hits-kickstarter-with-some-impressive-moves
- https://keyirobot.com/de-de/blogs/buying-guide/loona-vs-ebo-x-which-ai-companion-robot-is-right-for-your-pet
- https://www.itmedia.co.jp/pcuser/articles/2312/28/news143.html
- https://en.wikipedia.org/wiki/WALL-E_(character)
- https://www.mentalfloss.com/article/70024/10-space-age-facts-about-walle
- https://abratabia.com/ai-talking-characters/facial-animation.php
- https://manual.reallusion.com/iclone-ai-assistant-plug-in/content/speech-graph/speech-driven-saccade.htm
- https://dreuarchive.cra.org/2014/Moore/uploads/3/0/4/2/30422230/final_report.pdf
- https://github.com/FluxGarage/RoboEyes
- https://www.imore.com/apple-clears-120hz-iphone-13-pro-confusion-developers

All table numbers are design starting values, not measured from Loona.

## Corrections

1. **WALL-E camera shutter:** the Nikon shutter was Ben Burtt's *sound* for the eyebrow movements, not a visual eyebrow or aperture design. Wikipedia does not mention it.
2. **WALL-E tilt:** the binoculars-and-emotion quote comes from Mental Floss, not Wikipedia. "Outer edges drop means sad" is now marked UNVERIFIED.
3. **TechCrunch:** the article does not support the ears or screen claims. Those are now sourced to New Atlas only.
4. **Blinks:** double blinks are about 1 in 8 (12.5%), not 15%. Added the 200–400 ms double-blink gap, the conversation (2–4 s) and idle (4–7 s) intervals, and partial blinks.
5. **Saccades:** added abratabia's figures (200–600 ms, 1–3°, about 50 ms lerp). The 0.4–2 s hold is now marked as a design value.
6. **RoboEyes:** corrected the moods to DEFAULT, TIRED, ANGRY and HAPPY, and named the real functions. "Spacing" can be negative. "All transitions smoothed" is now UNVERIFIED.
7. **Audio tap:** use `mainMixerNode` or the player node instead of `outputNode`. `AVSpeechSynthesizer` audio needs `write(_:toBufferCallback:)` to be measured; this correction is itself UNVERIFIED.
8. **ProMotion:** the plist key is confirmed as a Boolean and is needed only on iPhone. The `TimelineView` signature now includes `paused:`.