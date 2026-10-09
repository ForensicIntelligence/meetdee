# Dee's Mind — emotions, personality, age

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
  - Neglect above 0.85 loneliness slowly costs affection (0.01 per day, never
    below 0.3).
- **Tamagotchi needs:** loneliness, energy and boredom.
  - `asleep` means *resting*. Energy refills, and loneliness still grows if
    you're away, only slower.
  - A lively, friendly exchange gives back a little energy.
  - The sleepy face needs real tiredness (weight 0.6).
- **Babies understand tone, not words:** comprehension = min(1, 0.3 + age/4)
  scales the words' hostility, threat, praise and dismissal. Loudness and
  aggression land fully.
- **Personality drift:** interactions nudge traits toward the treatment Dee gets
  (kindness → agreeable, confident; hostility → neurotic, insecure).
  - The rate is 0.0015 × age plasticity.
  - Lukewarm small talk (|kindness| < 0.15) doesn't count.
  - Two pulls bring traits back toward the set points: 1% of the gap per
    interaction, and half the gap every 30 days over time.

## Eye colour = how Dee feels about you

`regard` (−1…+1) is mostly the long-term bond, nudged by the moment (anger and
grudges much more than passing cheerfulness):

```
bond   = (affection − 0.4)·1.1 + (trust − 0.5)·0.9
now    = joy·0.15 + gratitude·0.2 − anger·0.9 − resentment·0.6 − sadness·0.1
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
