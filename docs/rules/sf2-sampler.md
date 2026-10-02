# Reading and playing a SoundFont

Written per §1 / §15, implementing §7.2. Implemented by `rust/bandstand-synth`.

Reference: the SoundFont 2.04 specification. This document is the subset
Bandstand implements and the decisions taken where the spec allows several.

## 1. The file

A SoundFont is RIFF, form type `sfbk`, holding three LIST chunks:

| LIST | Holds |
| --- | --- |
| `INFO` | version, bank name, engine, tools — read for display, otherwise ignored |
| `sdta` | `smpl`, 16-bit little-endian PCM, all samples end to end; optionally `sm24`, the low byte of each 24-bit sample |
| `pdta` | nine parallel arrays that describe everything else |

The nine `pdta` chunks, each a fixed-size record array with a terminal record:

`phdr` presets · `pbag` preset zones · `pmod` preset modulators ·
`pgen` preset generators · `inst` instruments · `ibag` instrument zones ·
`imod` instrument modulators · `igen` instrument generators · `shdr` samples

Every one ends with a terminal record whose only job is to bound the previous
one's index range. A file whose terminal records are missing is rejected: the
index arithmetic below would read past the end of the arrays.

## 2. From a note to a sample

```plaintext
preset (bank, program)
  └─ preset zone            key range, velocity range, generator offsets
      └─ instrument
          └─ instrument zone   key range, velocity range, generator values
              └─ sample        PCM, loop points, root key, sample rate
```

A note at `(key, velocity)` selects **every** preset zone whose ranges contain
it; each of those selects **every** instrument zone whose ranges contain it. So
one note can start several voices — which is how a layered piano, or a
round-robin, works, and why the voice pool has to be bigger than the polyphony
the user asks for.

### Global zones

The **first** zone of a preset is a *global zone* if it has no `instrument`
generator; likewise the first zone of an instrument if it has no `sampleID`.
Its generators are the defaults for every other zone in that preset or
instrument. A zone's own generator overrides the global one.

### Combining preset and instrument generators

Instrument generators are **absolute**: they say what the value is. Preset
generators are **offsets**: they are added to the instrument's value. This is
the rule that catches everyone, and getting it backwards makes every preset
that adjusts attenuation or tuning wrong in the same direction.

Four generators are never offsets and are ignored at preset level:
`keyRange` and `velRange` (which select rather than adjust), `sampleID`, and
`instrument`.

## 3. Units

The spec's units are not the ones a DSP wants, and every conversion is here so
none of them is repeated:

| Quantity | Stored as | Becomes |
| --- | --- | --- |
| Time (envelopes, LFO delay) | timecents | `2^(tc / 1200)` seconds |
| Absolute pitch (filter cutoff, LFO rate) | absolute cents | `8.176 · 2^(c / 1200)` Hz |
| Relative pitch (tuning) | cents | a ratio, `2^(c / 1200)` |
| Attenuation | centibels | gain, `10^(−cB / 200)` |
| Sustain level | centibels of *attenuation below peak* | gain, `10^(−cB / 200)`, clamped to `0..1` |
| Pan | tenths of a percent, −500 to +500 | −1 to +1 |
| Filter Q | centibels | dB, `cB / 10` |

Sustain is the one worth stating twice: `sustainVolEnv` is *attenuation*, so a
larger number is a **quieter** sustain, and 0 means full level.

## 4. A voice

One voice plays one sample. Per sample, in this order:

1. **Pitch.** The playback rate is
   `sampleRate / outputRate · 2^((key − rootKey) · scaleTuning/100 + tuning) / 12)`,
   with modulation-envelope and vibrato-LFO contributions added in cents.
2. **Interpolation.** Cubic (Catmull-Rom) over four points. Linear is audibly
   worse on anything pitched far from its root, and cubic is a handful of
   multiplies.
3. **Looping.** `sampleModes` says no loop, loop continuously, or loop until
   release. A loop whose points are outside the sample, or shorter than the
   four points interpolation needs, is treated as no loop rather than as a
   crash.
4. **Volume envelope**, DAHDSR, in that order: delay, attack, hold, decay,
   sustain, release. Attack is convex (the spec's curve), decay and release are
   exponential in the *attenuation* domain, which is what makes them sound
   linear.
5. **Low-pass filter**, two-pole state-variable, cutoff from
   `initialFilterFc` plus envelope and LFO contributions, resonance from
   `initialFilterQ`.
6. **Pan**, equal-power, and the reverb and chorus sends.

A voice ends when its volume envelope reaches zero in release, or when the
sample runs out without a loop.

### Exclusive classes

A voice with a non-zero `exclusiveClass` silences every other *sounding* voice
of the same class on the same channel when it starts. This is how a closed
hi-hat cuts an open one. The cut is a fast release, not an instant stop, because
an instant stop clicks.

## 5. Voice allocation

A fixed pool, allocated once. When every voice is busy, one is stolen, in this
order:

1. a voice that has finished (there should be one — this is the normal case);
2. the oldest voice already in release;
3. the quietest voice, by current envelope level.

Never steal a voice started in the current block: a note that is stolen before
it is heard is worse than a dropped note, because it costs the CPU anyway.

A stolen voice is released fast rather than cut, for the same reason as §4.

## 6. Effects

- **Reverb**, Freeverb-class: eight parallel comb filters into four series
  all-passes, per channel, with stereo spread. Fed from the per-voice reverb
  send.
- **Chorus**, three delay lines modulated by an LFO, fed from the per-voice
  chorus send.

Both are on a bus, not per voice: a hundred voices share one reverb.

## 7. What the audio thread may not do

The rule from `docs/rules/audio-output-path.md` §4 applies without exception.
Every buffer a voice needs is allocated when the pool is created; loading a bank
happens on the control thread and is handed over by the same pointer swap the
tempo map uses.

## 8. Checking it against FluidSynth

§10's acceptance for M4 is to play a General MIDI file through both this sampler
and FluidSynth and hear no defects. §11.2 calls that a null test, but it is not
one in the strict sense: two samplers reading the same bank make different
rounding, interpolation and filter choices, so the difference never cancels.
What can be compared is the *shape* — when notes start, how the loudness moves,
how the energy is spread across the spectrum — and that is what
`rust/tests/fluidsynth_ab_test.rs` measures. The last word on "no audible
defects" is still a pair of ears (§15).

### The gains are not the same scale

The two programs both take a gain, and the same number through each does not
mean the same level. Rendering the test material through FluidSynth at `-g`
0.25, 0.5 and 1.0 gives exactly twice the level at each step, so its gain is
linear; against that ruler, this sampler's `master_gain` of 0.5 lands at
FluidSynth's 0.219.

Comparing 0.5 against 0.5 therefore reports a 7 dB gap that is nothing but
convention. The comparison is made at `master_gain` 0.5 against FluidSynth's own
default `-g 0.2`, where the two agree to within about a decibel. Anything beyond
that at those settings is a real gain fault — an attenuation generator ignored,
or velocity applied twice.

### What is asserted

Against a four-bar piano progression at 120 bpm, rendered at 48 kHz:

| Measure | Why it is there | Tolerance |
| --- | --- | --- |
| Note onsets | a note missing, late, or never starting | every onset within 30 ms |
| Loudness envelope, correlated | an envelope stage skipped, a filter stuck open, a sample looping when it should not | correlation above 0.75 |
| RMS at the calibrated gains | an attenuation generator ignored, velocity applied twice | within 3 dB |
| Crest factor | dynamics squashed or exaggerated; gain-independent, so it isolates shape from level | within 2 dB |
| Energy above vs below 2 kHz | a lost top end, bad interpolation aliasing, everything an octave out | within a factor of four |
| Peak | silence, and clipping on our side | above 0.05, at or below 1.0 |

The spectral bound is deliberately loose. The two use different interpolation
and different filter implementations, and a factor of four either way is still
recognisably the same instrument; what it has to catch is a sampler that has
lost a whole region, not one that is a shade brighter.

The tests skip rather than fail when `fluidsynth` or a General MIDI bank is
absent, so the suite stays green on a machine without them.

### Listening to it

`write_the_pair_for_a_listening_test` is `#[ignore]`d, because it asserts
nothing — it exists to put both renders somewhere they can be played:

```sh
BANDSTAND_AB_DIR=build/ab \
  cargo test --test fluidsynth_ab_test write_the_pair -- --ignored --nocapture
```

## 9. Paging, and warming a preset

ADR 0007 memory-maps the sample data so the OS page cache is the LRU. That is
the right trade — the kernel's cache is shared, evicts under real pressure, and
its pages are clean — and it has one cost, named in the ADR and left unpaid
until M8: **a page fault can happen on the audio thread.**

A fault on a warm file is a memcpy. A fault on a cold one is a read from
storage, and on a tablet that is milliseconds — far past a 5 ms block. It
happens exactly once per page, and the first pass through a sample is the only
cold one, so the audible symptom is a click on the first note of a newly chosen
sound. On stage that is the worst possible moment for it.

**So a preset's pages are touched before it is played, off the audio thread.**

- Warming walks a preset's zones to its instruments, and those zones to their
  sample headers, and touches one byte per page across each sample's frame
  range. Reading one byte per page is what asks the kernel to fault it in;
  reading every byte would do the same work and take a thousand times longer.
- It runs on the **control thread**, when a program is selected — never on the
  audio thread, and never from `render`. The rule in
  `docs/rules/audio-output-path.md` §4 is not relaxed for it.
- It is **best effort and interruptible in the sense that matters**: a preset
  that is warmed and then evicted before it sounds is no worse off than one
  never warmed, and warming the wrong preset costs page cache and nothing else.
- **Prefaulting the whole file is not the mitigation.** That is being resident
  again with extra steps, and it is what ADR 0007 rejected. A preset is a few
  megabytes; a bank is hundreds.
- A resident source warms by doing nothing, because there is nothing to fault.

### What it is not

Not an LRU, not a cache, not a scheduler. The kernel already has all three. The
only thing Bandstand knows that the kernel does not is *which samples are about
to be needed*, and warming is how it says so.

## 10. The null test

§11.2 asks for an audio null test: *"render offline, compare against a stored
reference WAV within a sample-difference threshold. Catches synth regressions no
listening test will."*

`rust/tests/audio_null_test.rs` renders a fixed ii–V–I — piano and bass, two
programs, notes held and released — and compares it sample for sample against
`rust/tests/references/ii-v-i.wav`.

**The threshold is two least-significant bits.** The renderer is a pure function
of its input and does no dithering, so the honest expectation is bit-exactness;
the two bits of slack are there for the last rounding step differing between
compilers or target features, which would be a build difference and not a synth
regression. Anything a person could hear is thousands of times larger. A 0.1%
change to the master gain — inaudible by any measure — moves the peak difference
to 7 and fails the test, which is the point.

**The reference describes one bank.** Rendering `TimGM6mb.sf2` and comparing it
against a reference made from `FluidR3_GM.sf2` would fail for reasons that have
nothing to do with the synth, so the test checks the bank's size before running
and says clearly that it is skipping when the machine has a different one. A
test that passed vacuously would be worse than no test.

**The stored reference is the music, not the silence.** The offline renderer
runs a tail past the end of the sequence so releases are not cut off, and three
of this render's six and a half seconds are digital silence. Storing them would
put a megabyte of nothing into git, so the reference holds the first four
seconds and the test asserts separately that everything after is silent. That
assertion is the stronger of the two: a stuck voice or a reverb feeding back
shows up there and nowhere else.

**Re-recording it is a deliberate act.** When the synth is changed on purpose:

```sh
BANDSTAND_BLESS_REFERENCE=1 cargo test --test audio_null_test
```

Listen to the new file before committing it — that is why the reference is a
playable WAV and not a digest — and put the reason in the commit message. A
reference re-recorded to make a red test go green is how a regression becomes
the new normal.
