# Corpus tiling for walking bass

Written per §1 / §15, from the mechanism described in §6.3 of the plan.

Implemented twice: first as the M0.5 probe in `tools/tiling_probe/`, which
existed to settle whether the paradigm holds at all, and then as the M6
production generator in `app/lib/domain/generation/bass/`. The production
engine is a refinement of these rules, not a different idea — §§1–6 below are
what the probe established and the generator inherits; §§7–11 are what M6 adds
on top, each one traceable to something the probe found (§12).

## 1. The bet

A walking bass line is *not* generated note by note from rules. It is assembled
from a corpus of real phrases that a bass player actually played, chosen and
joined so the seams do not show.

The bet M0.5 had to settle was whether that produces a line that sounds like a
player having an ordinary day, or like a shuffled deck. The mechanism survived;
what it exposed is that the scoring and selection layer is where the work is,
which is what §6.3 of the plan predicted.

## 2. What a source phrase is

A **source phrase** is 1–4 bars of monophonic bass, stored with the chord
sequence it was played over. Stored per phrase:

- the notes: pitch, onset in beats, duration, velocity;
- the harmony it was played over, as a list of `(startBeat, durationBeats,
  chord)` spans;
- style tags (`walking`, `two-feel`, `chromatic`, `pedal`), for filtering;
- the tempo range it was played at, or was intended for (§9).

Derived once, when the corpus is loaded:

- **Root profile** — the phrase's harmony reduced to what is invariant under
  transposition: for each chord span, the interval in semitones from the
  *first* chord's root, plus the chord quality. `Dm7 | G7` and `Fm7 | Bb7` have
  the same root profile, `[(0, min7), (+5, dom7)]`, so a phrase played over one
  can be transposed onto the other. This is the whole reason a small corpus
  covers a large repertoire.
- **First and last note**, for join scoring.
- **Starts on the root?** and **ends on a chord tone?**, for the constraints.
- **Harmonic fit**, which is invariant under transposition (§4.1) and so is a
  property of the phrase rather than of any placement.
- **Transposibility** — the set of destination roots the phrase can reach while
  keeping every note in the instrument's range (§8).

## 3. Matching

A phrase is a **candidate** at bar `i` of a target progression when the target's
root profile over the phrase's span is identical to the phrase's own. Identical,
not similar: neither the probe nor the generator does fuzzy matching, so that a
bad result cannot be blamed on a loose match.

The **transposition** is then forced: `targetFirstRoot − phraseFirstRoot`, mod
12. The *octave* is free, and choosing it is part of scoring (§4.3).

## 4. Scoring

A candidate placement scores on independent terms, all in `0..1`, combined by a
weighted sum. Weights are the tunable part — the place where the musical
judgement lives, adjusted by ear, and not the agent's to settle (§15).

### 4.1 Harmonic fit (weight 1)

Per note, graded against the chord sounding underneath it and weighted by beat
strength (beats 1 and 3 of a 4/4 bar are strong; in other meters the strong
beats follow the meter — the downbeat plus the halfway beats of an even simple
bar, or every third beat of a compound one):

| Note is | Strong beat | Weak beat |
| --- | --- | --- |
| a chord tone | 1.0 | 1.0 |
| in the chord's scale | 0.55 | 0.9 |
| chromatic | 0.1 | 0.8 |

Chromatic notes on weak beats are the substance of walking bass, so they must
not be penalised there; the same note landing on beat 1 is a mistake, so it is.

Because a candidate's transposition preserves every interval and the match
requires an identical root profile, this term is invariant under placement. It
therefore scores the *corpus*, not the tiling — a bad phrase is visible as a bad
phrase. It is computed once when the corpus loads and never recomputed (§10).

### 4.2 Join (weight 2)

The interval in semitones between the previous phrase's last note and this
phrase's first note:

- 1 or 2 semitones: 1.0 — a step, the strongest join there is.
- 3 to 5: 0.85 — a small leap, entirely idiomatic.
- 6 to 7: 0.6.
- 8 to 12: 0.3.
- more than 12: 0.05 — an octave-and-a-half jump between phrases is the sound
  of stitching.
- 0: 0.35 — a repeated note across a join is not wrong, but it is the one thing
  that makes two phrases sound like two phrases.

Weighted double, because it is the only term that scores the *seam*, and the
seam is what the whole mechanism stands or falls on.

### 4.3 Register (weight 0.5)

The line must stay in a real instrument's range — `E1` (28) to `G3` (55) for
double bass — and should stay near the middle of it. Each candidate is tried at
every octave that keeps all its notes in range; the octave that scores best
wins. A candidate with no in-range octave is rejected.

## 5. Constraints

Applied before scoring; a candidate that fails any of them is discarded rather
than scored low.

1. The first note must be the root of the first chord. A phrase that starts on
   the third is a phrase that was played as a *continuation*, and using it as a
   phrase start sounds like a mistake.
2. The last note must be a chord tone of the last chord.
3. Every note must lie in the instrument's range at the chosen octave.
4. **The seam floor** (M6, §7.3): a candidate whose best available octave still
   joins worse than `minimumJoinScore` is rejected outright rather than placed
   with a bad seam.

## 6. Tiling

Greedy, longest first, **without repetition** — and the second half of that
phrase carries as much weight as the first (§12).

1. At the current bar, collect every candidate at every length.
2. Walk the lengths from longest to shortest and take the first length that has
   a **fresh** candidate: one whose last use was `reuseWindow` placements ago
   or longer — the code's comparison is `placedSoFar - used >= reuseWindow`, so
   a use exactly at the window's edge is fresh again and the phrase is
   separated from its last use by `reuseWindow − 1` other placements. Longer
   phrases mean fewer seams, and a seam is the failure mode — but a long phrase
   heard four times in three choruses is a worse failure than a seam.
3. Only if every length is stale does the tiler fall back to reusing the longest.
4. Within that pool, freshness is a *gate*, not a ranking: pick the
   highest-scoring placement, breaking ties by least recently used. Ranking by
   freshness first will cheerfully choose an octave-and-a-half jump over a step,
   which is exactly what the join score exists to prevent.
5. Place it, advance by its length, repeat.

`reuseWindow` is 6 placements — roughly one A section of a 32-bar form.

A position with no candidate at any length is a **failure, reported loudly**,
not papered over with a generated fallback (but see §11 for what the production
generator is obliged to do about it).

---

## What M6 adds

## 7. Deep join scoring

The probe scored one note either side of a join. §6.3 of the plan calls for
**pre-target and post-target** scoring across several notes, and the reason is
audible: an interval that is fine in isolation can still sound like a seam if it
contradicts the line that was arriving at it.

The join term becomes a weighted blend of four sub-terms, all in `0..1`.

### 7.1 The interval itself (weight 2)

The table in §4.2, unchanged. It remains the largest single contributor.

### 7.2 Contour continuity (weight 1)

Look at the direction of the outgoing phrase's **last two notes** and the
direction of the join.

| Outgoing motion | Join continues it | Join reverses it |
| --- | --- | --- |
| by step (1–2) | 1.0 | 0.7 |
| by leap (3+) | 0.75 | 0.9 |

A line walking down that keeps walking down is the most ordinary thing a bass
player does. A line that leaps and then reverses is also ordinary — that is how
a player recovers register after a leap. What is *not* ordinary is leaping again
in the same direction, and this is the term that notices.

Where the outgoing phrase has only one note, or the join interval is zero, this
term is 1.0: there is no contour to contradict.

### 7.3 Approach quality (weight 1.5)

The strongest idiom in walking bass is the **approach to the target root**: the
note before a chord change leans into the root of the next chord. Score the join
by what the outgoing phrase's last note is, relative to the incoming root:

| Last note is, relative to the target root | Score |
| --- | --- |
| a semitone above or below | 1.0 |
| a fifth above (the dominant approach) | 0.95 |
| a whole tone above or below | 0.85 |
| a third above or below | 0.7 |
| the same note | 0.4 |
| anything else | 0.5 |

This is the term that distinguishes a phrase that *was written to lead
somewhere* from one that merely stops. It is weighted above contour because a
strong approach covers a mediocre interval, but a strong interval does not
rescue a limp approach.

### 7.4 Landing (weight 1)

Look at the **first two notes** of the incoming phrase. If the phrase opens by
moving away from the direction it was approached from, the join reads as
deliberate; if it immediately doubles back over the join interval, the seam is
audible as a hiccup.

Score 1.0 when the opening motion does not retrace the join, 0.6 when it
retraces it by the same interval or more, and 0.85 in between.

### 7.5 Why "several notes" and not "the whole phrase"

Because the phrases are already good — they were played by someone. Scoring more
than about two notes either side stops measuring the seam and starts
re-measuring the corpus, which §4.1 already covers. Two either side is where the
information about the *join* actually lives.

## 8. Transposibility

§6.3 calls for a per-destination-root transposibility map, computed when the
corpus loads. For each of the twelve destination roots, the phrase records which
octave transpositions keep every note inside the instrument's range.

This is a filter, not a score: a destination the phrase cannot reach in any
octave is one the tiler must never consider, and finding that out by scoring
twelve candidates and rejecting all of them is work done twelve times over. With
the map, a phrase that cannot reach a root is skipped before any scoring runs.

The map is also what makes M0.5's fourth finding actionable. A phrase with
exactly one reachable octave at some root is a phrase with no freedom at that
root, and §5 constraint 4 can then reject it when that one octave makes a bad
seam — rather than accepting the seam because there was nothing else.

## 9. Tempo sensitivity

§6.3 says the scorer takes tempo into account. Two effects, both of which a
bass player will confirm:

- **Wide joins get harder as the tempo rises.** At 120 bpm a tenth between two
  phrases is a shift a player makes without thinking. At 280 it is a scramble.
  The join interval score of §7.1 is therefore sharpened by a tempo factor: the
  penalty for anything above a fifth is scaled by `tempo / 160`, clamped to
  `0.75..1.5`. Below about 120 the wide join is nearly free; above 240 it is
  close to disqualifying.
- **Phrases carry a tempo range.** A phrase full of chromatic eighth-note
  motion belongs at a ballad tempo and falls apart at 300; a sparse phrase
  belongs where there is no time for more. A phrase whose range excludes the
  song's tempo is filtered out, exactly like an unreachable root. A phrase with
  no declared range is usable at any tempo — the corpus should not have to
  answer a question nobody asked.

## 10. Cached partial scores

Tiling is a search, and the same partial scores are recomputed constantly across
attempts. Three caches, in order of how much they save:

1. **Harmonic fit** — invariant under transposition (§4.1), so it is computed
   once per phrase when the corpus loads and stored on the phrase. This is the
   most expensive term, being per note, and it is computed exactly once.
2. **Register score** — depends only on `(phrase, transposition)`, of which
   there are at most seven octaves per phrase. Computed when the transposibility
   map is built (§8), and stored beside it.
3. **Join score** — depends only on `(outgoing phrase, outgoing transposition,
   incoming phrase, incoming transposition)`. Memoised on that key for the life
   of one tiling run, because a greedy tiler that backtracks or that runs
   several tilers over the same progression (§11) will ask the same question
   repeatedly.

The first two make the corpus more expensive to load and tiling much cheaper,
which is the right trade: a corpus loads once, and §3 of the plan gives the
whole generation pipeline 100 ms.

## 11. Two tilers, and what happens when tiling fails

§6.3 records that jjSwing ships two greedy tilers. Both are implemented, and
they differ only in how they break the tie between equally-long candidates:

- **Longest-first without repetition** — §6, as the probe established it.
  Freshness gates, score ranks.
- **Maximum distance between reuses** — among candidates that pass the same
  freshness gate, prefer the one used longest ago, and only then rank by score.
  This trades a little smoothness for more variety, which is the better trade
  over a long form and the worse one over eight bars.

The generator runs both and keeps the better tiling, compared
lexicographically: fewer fallback bars wins outright — a gap is a bar of
root-and-fifth, and no amount of smoothness elsewhere makes up for one — then
the better **quality** (mean score minus the repetition penalty; ranking on
the mean alone picks the *more* repetitive line, §10), and only then does the
tiling with the narrower widest join win the tie. Running both is cheap
because §10 means the second run is mostly cache hits.

**Failure is different in production than in the probe.** The probe reported a
gap loudly and stopped, because its purpose was to learn whether tiling works
and a fallback would have hidden the answer. A generator that throws when a user
plays an unusual chord is not shippable. So:

1. If no phrase matches at the current bar, **shorten the window**: try to match
   one bar at a time rather than the longest span.
2. If a single bar still has no match, emit a **root-and-fifth bar** for it —
   the plainest thing a bass player plays when they do not know the tune — and
   record the gap in `GeneratedSong.problems` so the arranger screen can say
   which bars the corpus does not cover.

That fallback is deliberately dull. It has to be recognisable as a gap when you
hear it, so that the honest fix — adding a phrase to the corpus — is the one
that gets made. Dressing it up would hide exactly the information §12 finding 3
says the corpus needs.

## 12. What the M0.5 probe found

Running `tools/tiling_probe` over a 32-bar AABA form for three choruses, with a
corpus of twenty hand-entered phrases:

1. **Pure longest-first collapses.** The first implementation always took the
   longest match, so the five four-bar phrases covered everything and the other
   fifteen were never used. The result was a 4-placement loop repeating every
   16 bars — audibly a shuffled deck, and exactly the failure mode M0.5 exists
   to catch. The fix is §6.2: fall back to shorter phrases rather than reuse a
   long one.
2. **Freshness must gate, not rank.** Sorting the fresh pool by recency first
   produced a 14-semitone join. Sorting by score within the fresh pool brought
   the widest join back to 10 semitones and the mean placement score from 0.844
   to 0.885.
3. **Coverage is a corpus property, and it shows up immediately.** The four
   "held major" phrases are never chosen, because the only place a held major
   appears in the form is inside the four-bar `ii V I I` cadence. A corpus is
   not a bag of phrases; it has to be shaped to the *segmentations* the tiler
   will actually ask for. → §11's fallback exists to make the remaining gaps
   visible rather than silent.
4. **Octave choice is doing real work.** One phrase spans B1 to C3 and has
   exactly one in-range octave, which forces a 10-semitone join wherever it
   lands. → §5 constraint 4 and §8.

None of these is evidence against the paradigm; all four are evidence that the
scoring and selection layer is where the work is.

The remaining question — *does it sound like a bass player having an ordinary
day* — is a listening test, and not the agent's to answer (§15).
