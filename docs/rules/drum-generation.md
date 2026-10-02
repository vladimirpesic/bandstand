# Generating drums

Written per §1 / §15, implementing the first generator of §6.5. Implemented by
`app/lib/domain/generation/drum_generator.dart`, with the patterns as data in
`app/assets/drum_patterns.json`.

> §6.5: *"Drums — pattern-based with fills and variation slots. Easiest, and it
> is what makes everything else feel like music."*

Drums are pattern-based rather than corpus-tiled. A drum part is a groove
repeated with variation, and the thing that makes it sound alive is *where the
variation goes*, not how many patterns there are.

## 1. What a pattern is

A **pattern** is one or two bars of hits. A hit is an instrument, a position in
beats, a velocity, and a probability.

```json
{
  "id": "swing-ride",
  "name": "Swing (ride)",
  "meter": "4/4",
  "bars": 1,
  "role": "groove",
  "intensity": [30, 80],
  "hits": [
    {"instrument": "ride",      "beat": 0.0,  "velocity": 90},
    {"instrument": "ride",      "beat": 1.0,  "velocity": 72},
    {"instrument": "rideBell",  "beat": 1.66, "velocity": 64, "chance": 0.85},
    {"instrument": "hiHatPedal","beat": 1.0,  "velocity": 70},
    {"instrument": "hiHatPedal","beat": 3.0,  "velocity": 70}
  ]
}
```

- **`instrument`** is a name, not a MIDI note. The mapping to General MIDI keys
  is one table in one place, so a kit that puts the ride somewhere unusual is a
  change to data rather than to code.
- **`chance`** is how often the hit is played, 0 to 1, defaulting to 1. It is
  what stops a two-bar loop being a two-bar loop: the same pattern comes out
  slightly different each time round, and *deterministically so*, because the
  draw comes from the context's seed.
- **`intensity`** is the range of the part's intensity parameter this pattern
  suits. A quiet head and a shouting last chorus should not be the same groove.
- **`role`** is `groove`, `fill` or `ending`.

## 2. Choosing patterns

For each bar of the part, in order:

1. **Is this a fill bar?** Fills go at section boundaries and every four or
   eight bars (§6.6) — specifically, the last bar of the part, and every bar
   whose index is `fillEvery - 1` modulo `fillEvery`. The part's `fill`
   parameter turns them off.
2. **If so**, choose a fill whose intensity range covers the part's intensity.
   Otherwise choose a groove the same way.
3. Among the candidates, prefer one **not used recently**, then take the
   highest-scoring — the same "freshness gates, score ranks" rule the bass
   tiler uses (`docs/rules/corpus-tiling.md` §6), and for the same reason.

The last bar of the last part takes an `ending` pattern if there is one.

## 3. Variation without randomness

Every random choice — whether a `chance` hit lands, which of several equal
candidates is used — comes from a generator seeded with
`GenerationContext.randomSeed`, mixed with the bar number. So:

- the same song generates the same drums, every time;
- editing bar 30 does not change bar 2, because the seed for a bar depends on
  the bar;
- "reroll" changes one number and gives a different, reproducible take.

## 4. Velocity

Three things scale a hit's velocity, multiplied together:

1. the hit's own velocity, from the pattern;
2. the beat's weight — beat 1 heaviest, then 3, then 2 and 4, then offbeats,
   which is what makes a pattern swing rather than march;
3. the part's intensity, and the density arc across the song (§6.6): the head
   quieter, the middle building, the last chorus back down.

## 5. What this deliberately does not do

- **Swing feel by displacing offbeats.** The patterns are written where they are
  played, so a swung ride pattern has its offbeats at 1.66 rather than 1.5. That
  keeps the feel in the data, where it can be heard and edited, rather than in a
  parameter nobody can hear.
- **Following the bass.** The interaction between a drummer and a bass player is
  real and is M6/M7 work; a drum part that ignores the bass still sounds like
  drums.
- **Anything for a meter with no patterns.** §4.6: meter coverage is a corpus
  decision. A part in 5/4 with no 5/4 patterns generates nothing, and says so,
  rather than playing 4/4 over it.
