# Dee's Mind — emotions, personality, age

**Developer:** Forensic Intelligence

Dee is a modern Tamagotchi with a lot more going on inside. Its inner life is
**26 parameters**: 13 personality traits and 13 feelings. Each is canonically a
byte (0–255), and the whole state is one decodable value:

```
MindCode = 26 bytes = 52 hex characters
           [ 13 trait bytes ][ 13 feeling bytes ]
e.g.       BF8CB3BF59CCD9998C99B366B3·77120008008C14668600CC0000
```

Eye colour, expression and the mood note the language model reads are all computed
from the **decoded** code, so a code fully determines how Dee behaves. You can
copy it, store it, or restore a Dee from it. Internally the dynamics run in full
precision, because personality drift is about 0.1% per interaction and would round
to nothing at byte resolution. Everything is quantised to the code whenever it's
read or saved.

## Layout

| Byte | Personality trait | Set point | What it does |
|---:|---|---:|---|
| 0 | openness | 0.75 | love of novelty; grows with varied conversation |
| 1 | conscientiousness | 0.55 | careful, focused replies |
| 2 | extraversion | 0.70 | social energy; lonelier faster when alone |
| 3 | agreeableness | 0.75 | damps anger, amplifies affection |
| 4 | neuroticism | 0.35 | volatility; bad feelings hit harder and linger |
| 5 | playfulness | 0.80 | silliness, games |
| 6 | curiosity | 0.85 | appetite for new topics |
| 7 | patience | 0.60 | tolerance for repetition/rudeness |
| 8 | confidence | 0.55 | low → aggression causes fear rather than anger |
| 9 | sensitivity | 0.60 | how much *tone* matters beyond words |
| 10 | humor | 0.70 | responds to laughter and jokes |
| 11 | assertiveness | 0.40 | pushes back, stands up for itself |
| 12 | forgiveness | 0.70 | grudge length; apology effectiveness |

| Byte | Feeling | Half-life | Notes |
|---:|---|---|---|
| 13 | joy | 20 min | baseline from extraversion/playfulness |
| 14 | sadness | 45 min | × neuroticism |
| 15 | anger | 6 min | hot and brief; × neuroticism, ÷ patience |
| 16 | fear | 5 min | threats; aggression toward an unconfident Dee |
| 17 | surprise | 30 s | mismatch between your tone and Dee's mood |
| 18 | interest | 10 min | novelty × curiosity, questions about Dee |
| 19 | boredom | 15 min | repetition; creeps up when nothing happens |
| 20 | affection | 21 days | fondness for *you*; built slowly, saturates, habituates |
| 21 | trust | 30 days | lost faster than it's rebuilt; at most +0.03 per day |
| 22 | loneliness | driven | grows while you're away (half-time 10 − 6·extraversion h, ≈5.8 h; ×0.35 while resting), eased by company |
| 23 | energy | driven | drains awake (~20 h from full), refills while resting (~6 h) |
| 24 | gratitude | 30 min | thanks and praise |
| 25 | resentment | 18 h | the grudge left after anger fades; × (2.2 − 1.8·forgiveness): ≈7 h at forgiveness 1, ≈17 h at the default 0.7, ≈40 h at 0 |

## How an interaction is judged

`Appraiser` reads **what** was said and **how**:

- **Words:** Apple's on-device sentiment model (NaturalLanguage) plus
  negation-aware phrase lexicons for hostility, threats, praise, affection,
  gratitude, apology, dismissal, questions about Dee, laughter, the user's own
  distress, politeness, commanding versus hedging.
  - **Aim.** "You're stupid" is aimed at Dee; "this traffic is stupid" mostly
    isn't (×0.4), and "I feel awful" isn't at all. Rude commands ("shut up", "go
    away", "get lost") are always addressed to Dee. Threats name their target
    ("smash *you*"), so "let's smash this level" isn't one. Dismissive adjectives
    ("boring", "lame") count fully only about Dee.
  - **Negation** looks at the three words before a phrase *within the same clause*:
    "You're not stupid" isn't an insult, but in "No, I love you!" or "Never mind,
    thank you" the comma ends the negation. A question opened by a negated
    auxiliary is rhetorical: "Isn't Dee smart?" is praise.
  - **Overlaps** count once: "hate" inside "hate you", "thank" inside "thank you".
  - **Laughter** of any length ("hahahaha", "hehehe", "loool", "lmaooo").
  - **Teasing.** With play signals (laughter, or "I love you" in the same breath),
    a mild jab with no threat or swearing is mostly affectionate: "hehe dummy, I
    love you" is kind. A strong insult stays an insult ("I hate you lol").
  - **Sentiment that isn't about Dee.** Negative sentiment only counts as
    unkindness when the line is addressed to Dee. "What time is it" or "I had a
    bad day" aren't unkind. The latter is a *distress* cue, and Dee responds with
    interest and a little sympathetic sadness.
  - **Sarcasm (light heuristics only):** "thanks for nothing", "sorry not sorry",
    "yeah right" (as its own clause), and mock praise about a mishap ("Oh great,
    you broke it again"). Anything subtler is a known limitation: a lexicon can't
    hear a raised eyebrow.
- **Voice:** loudness, peak and speaking rate are compared with *your own* running
  baseline, so a naturally loud speaker isn't permanently "shouting". Loud plus
  negative reads as aggressive. Soft plus kind reads as tender. Commanding versus
  deferential phrasing sets a dominance axis (aggressive ↔ passive).
- **Typography** (debug text input): ALL CAPS and "!!!" count as intensity.

## How feelings move

- **Time:** every feeling relaxes toward a baseline that personality and age set,
  with its own half-life. Anger fading leaves a little resentment behind. Boredom
  relaxing and boredom creeping up (someone's there but nothing happens) are
  solved together exactly, so the result doesn't depend on how often the app ticks.
- **Hostility:** raises anger (or fear, for an unconfident Dee), sadness and
  resentment. Shouting amplifies these, scaled by sensitivity. It also costs
  affection (0.06 × hostility) and trust (0.05 × hostility, 0.12 × threat).
  - **Bad is stronger than good:** one insult costs the bond more than an equally
    strong compliment earns. One shouted outburst after two friendly days takes
    the eyes to red. With an apology, Dee is back to friendly about 12 h later,
    and without one about a day later, but somewhat behind where it was.
  - **Diminishing sensitivity:** recent hostility (6 h half-life) shrinks the
    *long-term* damage of each further insult, so a terrible day leaves Dee
    upset for a week, not traumatised. Anger still flares every time.
- **Kindness:** raises joy, affection, gratitude and trust, and *cools existing
  anger*. That's how Dee gets over things through conversation.
  - **Joy has headroom:** gains shrink as joy rises.
  - **Affection saturates and habituates:** gains shrink with `1.1 − affection`
    and with recent kindness (6 h half-life), and a repeated line earns nothing.
  - **Trust** rises at most 0.03 per day.
  - **Result:** 30 × "I love you" in a minute is not a shortcut. A daily friendly
    chat turns the eyes green after about 4 days, and only weeks of it bring Dee
    near the maximum.
- **Apology:** cuts anger and resentment sharply, scaled by forgiveness.
  - **Apology fatigue:** apologise constantly and each apology counts for less
    (30 min half-life).
  - **Re-offence:** an insult within 24 h of an apology is a re-offence (24 h
    half-life). It divides the sincerity of later apologies, removes their trust
    gain, and pushes the forgiveness trait *down* instead of up.
- **Absence and reunion:** a gap of more than 10 minutes with no updates (the
  app was suspended or closed) counts as the user being away. Dee is awake for
  5 minutes, then rests. Loneliness grows, energy recovers, and boredom doesn't
  pile up.
  - When you come back, a lonely Dee gets a burst of **reunion joy**. It's
    scaled by how fond Dee is of you, and much smaller if you open with
    rudeness.
  - A normal workday away gives moderate loneliness. Several days away max it
    out.
  - **Time away never lowers affection or trust.** While the user is away the
    bond only relaxes *upward* toward baseline (it can recover after a quarrel)
    and never decays downward; while the user is present it relaxes as usual.
    Loneliness feeds reunion joy and the urge to talk — never a relationship
    penalty, and never guilt ("glad you're back", not "I was lonely without
    you"). (The old neglect rule — affection lost above 0.85 loneliness — is
    gone.)
- **Tamagotchi needs:** loneliness, energy and boredom.
  - `asleep` means *resting*. Energy refills, and loneliness still grows if
    you're away, only slower.
  - A lively, friendly exchange gives back a little energy.
  - The sleepy face needs real tiredness (energy below ~0.25; dreamy comes first).
- **Babies understand tone, not words:** comprehension = min(1, 0.3 + age/4)
  scales the words' hostility, threat, praise and dismissal. Loudness and
  aggression land fully.
- **Personality drift:** interactions nudge traits toward the treatment Dee gets
  (kindness → agreeable, confident; hostility → neurotic, insecure).
  - The rate is 0.0015 × age plasticity.
  - Lukewarm small talk (|kindness| < 0.15) doesn't count.
  - Two pulls bring traits back toward the set points: 1% of the gap per
    interaction, and half the gap every 30 days over time.

## Touch, sounds and sights (v0.4)

Non-verbal stimuli are appraisals too, so they run through the same dynamics.

**Touch** (`Appraisal.touch(_:)`, mapped from DeeSense's `TouchGesture`):

| Touch | Reads as | Effect |
|---|---|---|
| tap | mild attention (interest in Dee) | a little interest |
| doubleTap | playful | humour, warmth |
| pet(gentleness, seconds) | warmth + affection + **care**, scaled by gentleness and duration (saturates ~6 s) | joy, affection, trust; care calms fear and sadness. A rough "pet" (gentleness < 0.3) is mildly unwelcome |
| hold(seconds) | a hug: affection + care | as petting, more affection |
| pokes(count) | `count` is the **burst total so far** (each event is appraised at its total, so a long burst escalates). Up to 4 pokes are a playful "hey!" (hostility ≤ 0.04, slight humour); past that irritation grows with the total (hostility 0.01·n + 0.07·(n − 4), max 0.65), bossy (dominance) | nothing much → mild → moderate anger |
| slap(force) | hostility and intensity by force, a startle | anger for a bold Dee, fear for an unconfident one |
| tickle(seconds) | humour (a giggle) for ~4 s, then **overstimulation** | joy, then surprise, a little fear, less joy |

- Kind touch is kindness: it raises joy, affection, gratitude and trust (still at
  most +0.03 trust per day) and drifts personality toward agreeable, confident
  and calm (care also lifts confidence and lowers neuroticism). Rough touch does
  the opposite.
- **No pushover:** affection gains habituate exactly like kind words, and for
  touch the personality drift is scaled by the same habituation. A hundred
  strokes in three minutes are worth far less than a hundred times one.

**Sounds** (`Appraisal.sound(label:unexpected:loudness:)`; loudness 0…1, or dBFS
when negative: −60 → 0 … −10 → 1). Labels fall into coarse kinds by word prefix:
alarming (siren, alarm, smoke, scream, crash, breaking, bang, …), crying (crying,
sobbing, whimpering), laughter, applause (applause, cheering, clapping), music
(music, singing, guitar, piano, …), pleasant (birds, purring, rain, …), other
(doorbell, knock, dog, …). Unexpected, loud sounds startle (surprise, a little
fear for a jumpy Dee) and catch interest; music, laughter and applause delight
(joy, interest); alarming sounds frighten; **crying is not alarming** — it draws
concern (distress: attention and a little sadness, no fear).

**Sights** (`Appraisal.sight(novelty:)`): novelty raises interest and surprise
and chases boredom away.

Sounds and sights are **not social**: they move feelings but never affection,
trust, loneliness ("a noise is not company"), the relationship counters or
personality.

**Surprise is a jolt, not a tally.** A new surprise mostly replaces what's left
of the last one (`max(current, jolt) + 0.15·jolt`), so a run of ordinary lines
doesn't add up to astonishment.

## The face: expression, reflex, mood

### Resting expression (`MindSnapshot.emotion`)

`EmotionEngine.dominantEmotion(_:personality:age:)` reads feelings as
**deviations from this Dee's own baseline** (anger, surprise, loneliness,
gratitude and resentment have baseline 0 and read absolutely; energy reads
absolutely). Each candidate expression gets a score and the highest wins. Calm
defaults score about 0.1–0.2, so anything clearly felt beats them.

- **At rest Dee is not "curious"** (the old perpetual "?" bug: a curious Dee's
  resting interest is high, and the old mapping read it absolutely). A fresh
  Dee at rest looks **content**. As energy drains through a quiet day Dee turns
  **dreamy**, then **sleepy**. With little bond (or joy below normal) Dee's
  **neutral**.
- Every `Emotion` except the app-driven `asleep`, `thinking` and `listening`
  (34 of 37) is reachable. Some examples (tests in `ExpressionTests`):
  - anger alone → angry (high) / grumpy (mild, or with a grudge)
  - sadness + grudge → hurt; sadness alone → sad; sadness easing with joy → hopeful
  - fear → scared (high) / worried (mild); fear easing with joy → relieved
  - two strong arousals at once → overwhelmed; surprise while exhausted → dizzy
  - surprise + strong interest → awe if joy is normal, confused if not
  - interest → curious; with a grudge → skeptical; with anger → determined
  - joy → happy → joy; with interest and energy → playful / excited; with a
    surprise → giddy; with mild anger or resentment (humorous, assertive Dee) →
    mischievous
  - gratitude → proud (confident), shy (insecure), smug (assertive)
  - loneliness → lonely; with fondness and boredom → pleading
  - boredom → bored; assertive or joyless → unimpressed
  - affection > 0.65 with joy → love
- **Personality colours the reading:** the same gratitude looks proud on a
  confident Dee and shy on an insecure one.

### Reflex (`MindSnapshot.reflex`)

A momentary reaction to the last stimulus that **sits above mood** and can
contradict it, so Dee feels alive. `Mind` computes it in `hear`/`react` from the
appraisal and the feelings just before it, and snapshots carry it for
`Mind.reflexDuration` (4 s); a neutral stimulus clears it.

| Stimulus | Reflex |
|---|---|
| joke / laughter | giddy (or joy) — **even when angry** |
| kind word, praise, affection, apology or gentle touch while upset | shy / relieved / hopeful |
| praise (not upset) | proud (shy if insecure); affection → love or shy |
| insult | hurt; angry if already angry or bold and shouted |
| threat | scared (angry if bold and already angry) |
| dismissal | hurt (unimpressed if assertive) |
| user's distress | worried |
| tickle | giddy → dizzy → overwhelmed as it drags on |
| tap / double tap | curious / playful |
| pokes (burst total) | < 6: playful (skeptical if already cross or not playful) · 6–9: grumpy (angry if already cross) · 10+: angry |
| slap | scared (unconfident or already afraid) or hurt (angry if bold and hard) |
| unexpected sound / alarming sound | surprised / scared or worried |
| music / laughter / applause heard | happy (dreamy when tired) / giddy / excited (happy when tired) |
| crying heard | worried |
| novel sight | curious, awe when very novel |
| `Appraisal.internal(relief:)` (v0.5: an expectation Dee was nervous about went well) | relieved (≥ 0.2; relief wins ties) |
| `Appraisal.internal(pride:)` (v0.5: Dee completed one of Dee's intentions) | proud (shy if very unconfident) |
| nothing notable | nil |

**Internal events (v0.5).** `Appraisal.internal(relief:pride:)` is Dee's own
event, not something the user did: it is non-social (so it never touches the
bond, loneliness, the relationship counters or personality), has no startle or
novelty, and moves only feelings. Relief removes `0.7 × relief` of current fear
and `0.3 × relief` of sadness and adds a little joy; pride adds joy
(`0.25 × pride` of the headroom), a little interest, and eases boredom. DeeSelf
fires them when an expectation resolves well or an intention is completed.

Humour does more than flash a smile: laughter that isn't a jab **genuinely
softens anger** (−0.3 × humour × (0.5 + humour trait) of current anger) and a
little sadness and resentment. Dee can laugh even when upset.

### Mood signals and urge to talk

`MindSnapshot.mood` (`MoodSignals`) gives continuous read-outs for the face's
idle director: curiosity, boredom, playfulness, affection, energy, loneliness,
arousal (0…1) and valence (−1…1). `MindSnapshot.urgeToTalk` (0…1) rises with
extraversion, curiosity, boredom, loneliness and playfulness, and falls with
tiredness, fear and deep sadness.

## Curiosity director: Dee starts conversations

`CuriosityDirector` is pure and seeded. The app reports what happens (`note`:
things seen, sounds heard, the user arriving, anyone speaking, touches) and asks
about once a second (`nextPrompt(at:snapshot:userPresent:busy:)`). The answer is
a short stage direction in parentheses for the language model, or nil.

- **Never** while busy, and never within 3 s of anyone speaking. Prompts are at
  least 6 s apart.
- **Greets** the user on arrival (not again within 10 min, and not if they spoke
  first).
- **Unexpected sounds** are raised almost immediately (crying gets a gentle
  "is everyone okay?").
- **Novel sights are paced:** at most one sight prompt per 45 s (per 2 min when
  it's the back camera, so carrying the phone around doesn't make Dee narrate
  the house). **Animals** and **awe-level novelty** (> 0.85, via
  `noteSight(_:camera:novelty:at:)`) jump the queue. Generic labels ("person",
  "wall") are ignored.
- **Empty room:** with nobody present Dee calls out ("Hello? Is someone
  there?") only for an **alarming or loud** (≥ 0.7, `noteSound(_:unexpected:
  loudness:at:)`) unexpected sound, at most every 2 min — and, if Dee was asleep
  (the app sets `asleepSince`), only after **3 min of sleep**.
  `CuriosityDirector.callsOutUnattended(sound:loudness:asleepFor:)` exposes the
  rule so the app can also decide whether the noise wakes Dee.
- **Back-off when ignored:** every prompt the user leaves unanswered doubles
  the general-initiative gap (×2 per prompt, up to ×16, capped at 10 min).
  After 3 unanswered prompts only novel sights and unexpected sounds can start
  a conversation. The user speaking, touching Dee or arriving resets it.
- **Touch remarks** ("your human is petting you") only when the app didn't
  already send the touch to the model; noting `.deeSpoke` clears a pending
  touch so Dee never answers it twice. Pokes earn "your human keeps poking you"
  only once a burst reaches ~6.
- **General initiative** while the user is present: after a gap of
  `60 − 40 × urgeToTalk` seconds (20–60 s) since anyone spoke or Dee last
  initiated. Topics, weighted by mood:
  - things seen in the last 10 min that never came up (strongly preferred) and
    music heard
  - the human: their day, what they're doing, what they love, how they feel,
    food, places, music, … (weighted up when lonely or fond)
  - games: twenty questions, I spy, riddles, would-you-rather, … (weighted up
    when bored or playful)
  - thoughts: a fun fact, a robot observation, a daydream (sleepy versions when
    tired)
  - lonely: "really glad of your company" (never guilt)
- **No subject twice within 20 min.** Wording varies (several templates per
  situation, never the same prompt twice in a row).
- **Mood-dependent phrasing:** grumpy Dee asks "a bit grumpily — you're still
  annoyed, but you can't help asking"; sad Dee quietly; tired Dee sleepily;
  playful Dee playfully; and so on.
- **Reunion greetings** (loneliness > 0.4 on arrival) say Dee's glad they're
  back — never "it got a bit lonely without them", never guilt.
- **Avoid list (v0.5):** `avoid: Set<String>` holds subjects Dee must not bring
  up (the user's boundaries, e.g. "job"). A candidate is dropped when an avoid
  term matches a whole word (plural "s"/"es" tolerated) of its label or topic
  line, so `avoid = ["food"]` removes "ask about their favourite food" and
  `["guitars"]` removes a sighted guitar. Greetings, empty-room call-outs and
  alarming sounds are exempt.
- **Candidates (v0.5):** `candidates(at:snapshot:userPresent:busy:)` returns
  every option Dee could raise — `Candidate(kind, subject, label, prompt,
  priority, urgency)`, best first — without consuming anything; phrasing comes
  from a copy of the seeded generator, so repeated calls agree.
  - `priority` (0…1): call-out 1, greeting 0.95, alarming sound 0.9, crying
    0.88, other sound 0.8, animal/awe sight 0.75, sight 0.7, touch 0.6;
    general topics `min(0.55, 0.1 + 0.1 × mood weight)`.
  - `urgency` (0…1): 1 for stimuli that are due now; general topics ramp from
    0 to 1 over the (backed-off) general-initiative gap; everything is 0 while
    busy or in a quiet window. Priority is unaffected, so DeeSelf's
    IntentionBoard can still use a candidate as an aim on a user turn.
  - The back-off limit, cooldowns, freshness and `avoid` apply exactly as in
    `nextPrompt`. With nobody present only a call-out can be listed.
  - `commit(_:at:asReply:)` raises one: subject on cooldown, stimulus consumed,
    prompt spacing started; `asReply: true` (used inside a reply to the user)
    doesn't count as an unanswered prompt.
  - `nextPrompt` is now a wrapper over the same builders (timing gates, the
    cascade greeting → sound → sight → touch → weighted general topic, then a
    commit); its behaviour is unchanged. For a single stimulus its prompt equals
    the top candidate's.

## Eye colour = how Dee feels about you

`regard` (−1…+1) is mostly the long-term bond, nudged by the moment (anger and
grudges much more than passing cheerfulness):

```
bond   = (affection − 0.4)·1.1 + (trust − 0.5)·0.9
now    = joy·0.15 + gratitude·0.1 − anger·0.9 − resentment·0.6 − sadness·0.1
regard = tanh(1.3 · (bond + now − 0.08))
```

`tanh` keeps headroom at both ends, so the colour is never pinned. The face
renderer should ease toward the hue over a few seconds rather than snapping. The
eyes map regard onto a hue:

**red** (−1, upset / angry) → **yellow** (0, no real opinion) → **green** (+1, loves you)

A brand-new Dee sits around yellow. With daily kindness it turns green over a few
days, and it nears full green only after weeks. It flashes red when mistreated,
and drifts back as it gets over it, through conversation or time.

## Age (optional)

Off by default. In the iOS Settings app you can switch age on, set a starting age,
switch ageing on, and pick a speed (real time up to one robot-year per hour).
Changing the speed never makes Dee jump in age. Age is capped at 120 and the speed
at 24 robot-years per day (the "very fast" setting).

Age shifts personality and dynamics smoothly between key ages:

| Stage | Ages | Effects |
|---|---|---|
| baby | 0–2 | very playful, impatient, volatile, forgives instantly, moods pass fast, very malleable |
| child | 3–12 | playful, curious, quick to forgive |
| teen | 13–19 | touchy (neuroticism +), assertive, holds grudges, less agreeable |
| adult | 20–59 | set points |
| elder | 60+ | patient, calm, forgiving, less energy, slow to change |

The stage also changes how Dee talks (simple words as a child, a little sarcastic
as a teen, gentle and nostalgic as an elder).

## What's stored

SQLite (`Application Support/DeeMind.sqlite`):

- `parameters`: 26 rows (name, kind, position, full-precision value, byte).
  Each save rewrites the whole set.
- `meta` holds:
  - the schema version and the current MindCode
  - age settings and relationship counters
  - short-term memory (apology fatigue, recent kindness and hostility,
    re-offence, last apology time, today's trust gain)
  - the voice baseline
- `daily`: per-day aggregates (interaction counts, average regard, end-of-day code).

**Robustness:**

- **Loading.** Full-precision rows are used when they're complete. Otherwise the
  canonical `mind_code` fills the gaps, so a changed parameter list never wipes
  Dee.
- **Schema.** A database from a newer schema is refused and left untouched.
  Upgrades run step by step.
- **Writes.**
  - An utterance's state and its daily aggregate are one transaction.
  - Ticks write at most every 30 s, unless a parameter moved by 0.25 or more.
    Call `Mind.flush()` when the app goes to the background.
  - A second connection waits up to 2 s for the lock. The store holds its lock
    for a whole transaction, and nested transactions become savepoints.
- **Snapshots** carry a rising `sequence`. When overlapping calls return out of
  order, keep the newest one.
- **On resume,** call `tick` (a long gap is handled automatically) or
  `catchUp(to:lastSeenUserAt:)`.

**No transcripts or utterances are ever stored.**
