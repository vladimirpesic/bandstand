# Phrases, and how a song becomes notes

Written per §1 / §15, implementing §4.2, §6.1 and §6.2. Implemented by
`app/lib/domain/phrase/` and `app/lib/domain/generation/`.

## 1. The unit of generation

```plaintext
Song
 └─ flatten → SongChordSequence          (§4.3, already built)
     └─ for each SongPart:
         └─ for each RhythmVoice:
             └─ MusicGenerator.generate(context) → SizedPhrase
                 └─ post-processing chain
             └─ assemble → Map<RhythmVoice, Phrase>
                 └─ → TimedEvent list → Rust
```

A **`NoteEvent`** is a note with a position: pitch, velocity, a start in beats
and a duration in beats. It also carries a small map of *client properties* —
free-form tags a generator attaches while working ("this note is the target of
an approach", "this hit is a fill") and a later stage reads. They are not
serialised and they never leave the pipeline.

A **`Phrase`** is an ordered collection of `NoteEvent`s on one channel, kept
sorted by position. It knows whether it is a drum part, because a drum part's
"pitch" is an instrument rather than a note and must never be transposed.

A **`SizedPhrase`** is a `Phrase` with a fixed beat range and a time signature —
the unit a generator returns, so that "how long is this" is not something every
consumer has to work out.

Positions are in **beats from the start of the phrase's range**, not from the
start of the song. A generator that has to know where it sits in the song is a
generator that cannot be tested in isolation.

## 2. The generator contract

```dart
abstract class MusicGenerator {
  String get id;
  List<RhythmVoice> get voices;
  List<RhythmParameterSpec> get parameters;
  Map<RhythmVoice, SizedPhrase> generate(GenerationContext context);
}
```

`GenerationContext` carries the chords for **this song part only**, the beat
range, the meter, the tempo, the parameter values — and an explicit
**`randomSeed`**.

> §6.2: *"Seed the RNG explicitly and thread it through. Determinism is what
> makes the whole test strategy possible, and it also gives the user a 'reroll'
> button that is reproducible."*

So: no generator may touch a global random source. The seed is derived from the
song, the part index and the voice, so that editing bar 30 does not reroll bar
2, and pressing "reroll" changes exactly one number.

## 3. Post-processing

Every generator's output goes through the same chain, in this order. The order
matters and is the specification:

1. **Range clamp.** Move notes into the voice's playable range, by octaves, so
   a bass line does not ask for a note the instrument does not have. Drums are
   exempt: a drum "pitch" is an instrument.
2. **Overlap fix.** On a monophonic voice, shorten a note that runs into the
   next one. Two overlapping notes on one string is not a thing a bass player
   can do, and it makes the sampler steal its own voice.
3. **Accents.** Raise the velocity of notes under a chord marked with an accent
   (§4.1's `ChordRenderingInfo`).
4. **Anticipation.** Move notes that begin a chord marked as anticipated
   earlier by the marked amount, along with the chord.
5. **Humanise.** Timing and velocity jitter — *correlated*, not independent
   (§6.6): a player who is dragging stays dragging for a few notes rather than
   alternating early and late. Implemented as a random walk with a pull back
   towards centre.
6. **Velocity shaping.** Apply the part's intensity, and the density arc across
   the song, as a multiplier.

Every step is a pure function from `Phrase` to `Phrase`, so each is tested on
its own and the chain is tested as a composition.

## 4. Assembling

Each part's phrases are shifted to their absolute position and concatenated per
voice, then converted to `TimedEvent`s: a note on at the start, a note off at
the end, both at ticks derived from beats through the song's PPQ.

A voice's MIDI channel comes from the mixer, which is where the user set it.
Drums go to channel 10 (index 9) because General MIDI says so and every
soundfont keeps its kits in bank 128.

## 5. The budget

§3 gives **100 ms** for a full regeneration after a chord edit, and 300 ms as
the hard limit. That is the whole pipeline: flatten, generate every voice for
every part, post-process, assemble, convert, and hand over the FFI.

What keeps it there is that generation is pure and allocation-light, and that
nothing in it does I/O. `benchmarks/` asserts it, and the number goes in
`docs/benchmarks.md` at every milestone.
