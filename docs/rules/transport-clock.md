# Transport clock, tempo map and position readback

Written per §1 / §15: prose first, implementation from the prose.
Implemented by `rust/bandstand-transport`.

## 1. Units

- **Tick** — the symbolic time unit. Resolution is `ppq` ticks per quarter note,
  fixed for the lifetime of a loaded sequence. Bandstand uses 960 by default:
  divisible by 2, 3, 4, 5, 6, 8, 12 and 16, so triplets, quintuplets and
  32nd-note swing offsets are all exact integers.
- **Second** — wall-clock time on the audio timeline.
- **Frame** — one sample per channel. `frames / sample_rate` seconds.
- **Host time** — nanoseconds since an arbitrary process-fixed monotonic epoch.
  Both Rust and Dart read the same clock, so a `(tick, host_time)` pair read by
  Dart can be extrapolated forward by `now - host_time`.

## 2. Tempo map

A tempo map is a non-empty list of *tempo changes*, each `(tick, bpm)`, sorted
by ascending tick, with the first change at tick 0. Between two consecutive
changes the tempo is constant; after the last change the tempo is constant
forever.

Rules:

1. `bpm` must be finite and within `[MIN_BPM, MAX_BPM]` = `[10, 400]`. A map
   built from out-of-range or non-finite values is rejected, not clamped
   silently — a bad tempo is a bug upstream, and a clamped one hides it.
2. Two changes at the same tick collapse to the later one in list order.
3. A map with no change at tick 0 gets one synthesised at tick 0 carrying the
   first change's bpm. (Tempo before the first marker is the first marker's.)

Duration of one tick at `bpm` is `60 / (bpm * ppq)` seconds. So for a segment
starting at tick `t0` with tempo `b`, elapsed seconds at tick `t >= t0` is

```plaintext
seconds(t) = seconds(t0) + (t - t0) * 60 / (b * ppq)
```

`seconds(t0)` for each change is precomputed once when the map is built, so
`seconds_at_tick` and its inverse `tick_at_seconds` are a binary search plus one
multiply. Both are total functions on non-negative inputs and are exact
inverses of each other up to floating point.

## 3. Playhead advance

The audio thread owns the playhead. Once per audio block it calls
`advance(frames)`, which:

1. If the transport is not playing, publishes the current position and returns a
   single segment of `frames` frames with `start_tick == end_tick` (time does
   not move, but the block still has to be filled).
2. Otherwise converts the current tick to seconds, adds `frames / sample_rate`,
   converts back to ticks, and walks forward.

**Loop wrapping happens inside the block, not at block boundaries.** If looping
is enabled and the playhead would pass `loop_end`, the block is split: the
frames up to the wrap point form one segment ending exactly at `loop_end`, and
the remainder continues from `loop_start`. This repeats until the block is
consumed, so a loop shorter than one audio block still behaves correctly. A
generation counter is bumped on every wrap so that consumers (the sequencer,
later) can flush held notes.

The wrap frame is computed in the *time* domain — `seconds_at_tick(loop_end) -
seconds_at_tick(current)` converted to frames and rounded down — so a tempo
change inside the loop does not shift the wrap point.

Degenerate loops (`loop_end <= loop_start`, or a zero-length span) disable
wrapping for that block rather than spinning.

A block is split at most `MAX_BLOCK_SEGMENTS` (8) times; beyond that the loop is
shorter than the audio quantum can usefully express and wrapping is suspended
for the remainder of the block. This keeps `advance` allocation-free and
bounded, which is a hard requirement on the audio thread.

## 4. Position readback (§3, §7.3)

Rust never calls into Dart to report position. Instead the audio thread
publishes, once per block, the triple `(tick, host_time_ns, flags)` into shared
memory that Dart reads over FFI at its own rate (a `Ticker`, i.e. per frame).

The triple must be read *coherently* — a reader must never see a tick from one
block paired with a host time from another, because the resulting extrapolation
would jump. Since the payload is wider than one atomic word, it is published
through a **seqlock**:

- Writer (audio thread, single writer, never blocks): increment `seq` to an odd
  value, `Release`-store the fields, increment `seq` to the next even value.
- Reader (any thread): read `seq`; if odd, retry. Read the fields. Read `seq`
  again; if it changed, retry.

The writer is wait-free, which is what the audio thread requires; the reader may
spin, which is acceptable off the audio thread. Readers bound their retries and
fall back to the last coherent value they saw rather than spinning forever.

Dart extrapolates: `tick_now ≈ tick + (now_ns - host_time_ns) * ticks_per_ns`,
where `ticks_per_ns` comes from the tempo at `tick`. Extrapolation is clamped so
it can never run past the next block's worth of ticks, which stops the cursor
overshooting when the audio thread is late.

## 5. Control-side commands

`play`, `pause`, `stop`, `seek`, `set_loop`, `set_tempo_map` are called from the
UI thread. They are all expressed as atomic stores; the audio thread observes
them at the top of the next block. There is no lock and no allocation on either
side.

- `play` from stopped or paused starts at the current tick.
- `pause` freezes the tick.
- `stop` pauses and seeks to the *stop anchor* — tick 0, or the loop start when
  looping is enabled.
- `seek(tick)` is latched with a monotonically increasing request counter, so a
  seek issued while the audio thread is mid-block is applied exactly once at the
  top of the next block, and two seeks in one block collapse to the later one.
- `set_tempo_map` swaps a whole immutable map behind an `ArcSwap`-equivalent
  built from `Mutex<Option<Arc<..>>>` on the control side plus an audio-thread
  pickup: the control thread parks the new map in a slot, the audio thread takes
  it at the top of a block, and the old map goes into a retire slot for the
  control thread to drop on its next call. The audio thread drops one itself
  only in the bounded fallback — when every retire slot is already occupied,
  which takes a control thread stalled across several tempo changes — a rare,
  bounded deallocation, chosen over leaking.

## 6. The file timeline (ADR 0012)

When the engine loads a decoded track (`rust/src/player.rs`), the tempo map is
replaced by a constant one under which **a tick is a millisecond**: 1000 ticks
per second — 62.5 bpm at the default 960 ppq, an implementation detail of the
tick↔time conversion, never a musical claim. Everything above then reads in the
file's own units: the track's duration is its length in ticks, a scrub's
position and a loop region are milliseconds, and the same advance, wrap and
readback machinery drives the audio without a second clock. The play-along
source keeps no position of its own — each block it reads the file at the
position the segments dictate, so seek, loop and a device reopen cannot drift
from the published playhead.

Loading a track stops the transport at the top and clears any loop left from
the previous timeline, which would be meaningless in the new one.
