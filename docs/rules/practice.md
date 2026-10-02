# Practice features

Written per §1 / §15, for the practice half of M7: *"Tempo ramp, key cycling,
loop practice."* §9 rates the first two as *"trivial once transport exists.
Disproportionately useful."* — which is true of the mechanism and not of the
edges, and the edges are what this document is about.

## 1. What a practice session is

A **session** wraps a song with a plan for how it changes as it repeats. It owns
no music. It answers one question per chorus — *what tempo, what key, which
bars?* — and the existing generation and transport do the rest.

A session is a value, like everything else in `domain/song/`: starting it makes
one, and each chorus boundary produces the next. That is what makes a
twenty-minute ramp testable in milliseconds.

## 2. Tempo ramp

Raise the tempo every *n* choruses, up to a ceiling. §10 asks that it "works
over a 20-minute session", which at 200 bpm and a 32-bar form is about forty
choruses — so the arithmetic has to still be right at the fortieth, not just
the second.

- **Step** is in bpm, and applies **every `everyChoruses` choruses**, not every
  chorus. Practising at 120 for four choruses then 124 is a rehearsal; changing
  tempo every chorus is a fairground ride.
- **Ceiling** clamps it. On reaching the ceiling the tempo stays there — it does
  not wrap, and it does not stop the session.
- **A ramp may descend.** A negative step with a floor is how you practise
  playing *slower*, which is harder and rarer and worth supporting for free.
- The tempo is always clamped to the song model's own `minTempo`/`maxTempo`, so
  a ramp cannot drive the transport somewhere the rest of the app cannot
  represent.

**Tempo changes at a chorus boundary, never mid-chorus.** The transport's tempo
map (§7.3) can change tempo anywhere; a practice ramp that did would be
unplayable.

## 3. Key cycling

Transpose every *n* choruses. The point is practising a tune in every key, which
is the oldest exercise there is.

Two orders, and the difference matters:

- **By fourths** — the default. `C F Bb Eb Ab Db Gb B E A D G`, which is the
  cycle a ii-V-I actually moves through and the one a player's hands already
  know.
- **Chromatic**, ascending or descending, for when the point is the *hard* keys
  rather than the familiar motion.

Rules:

1. **The key returns to where it started after twelve steps**, in both orders.
   A cycle that drifts is a bug, and the test asserts a full round trip.
2. **Spelling follows the destination key**, not the arithmetic. The harmony
   core already does this (`pitch-and-spelling.md`); cycling must go through it
   rather than adding semitones to pitch classes, or a chart in Gb comes out in
   F#.
3. **Cycling and ramping compose.** A session may do both, and they count
   choruses independently: "up a fourth every chorus, faster every four" is a
   real exercise.
4. **Transposition is a render-time concern** (§9, the global instrument
   transposition rule): the stored song is never mutated. A session that ends
   leaves the tune in the key it was written in.

## 4. Loop practice

Loop a bar range, optionally with the ramp applied per repeat. §9 calls looping
*"the highest-value practice feature"*, and M4 already built the transport half
of it.

- The range is **in written bars**, the way a user reads them, and is resolved
  through the same flattening as everything else (§4.5) — so looping "bars 5–8"
  of a tune with a repeat loops the right music.
- A loop of **one bar** is legal and useful.
- An **empty or inverted range** is refused at construction rather than
  producing silence.
- A loop that runs past the end of the form is **clamped**, not wrapped.
- **The count-in plays once**, at the start, not on every repeat.

## 5. Where the session lives

The session is domain; driving the transport is not. So:

- `PracticeSession` computes, from a chorus index, the tempo, the transposition
  and the loop range. Pure.
- The state layer advances it on a chorus boundary, regenerates if the key
  changed, and pushes the new tempo to the transport.

**Regeneration on a key change is required, not optional.** The bass corpus is
tiled against a root profile (`corpus-tiling.md` §3) and the profile is
transposition-invariant, so the *same* tiling is valid in the new key — but the
octave choice is not, because the register band is absolute. Transposing the
generated notes by seven semitones walks the bass out of its range. Regenerate.

## 6. What this deliberately does not do

- **Metronome-only practice**, without the band.
- **Recording the user**, which §9 puts at M9.
- **Adaptive tempo** — speeding up because you played it cleanly. That needs to
  hear the player, which is out of scope.
- **Per-section tempo**, as distinct from per-chorus.
