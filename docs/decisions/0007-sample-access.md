# ADR 0007 — Samples are memory-mapped, not resident

**Status:** accepted · **Date:** 2026-09-01 · **Milestone:** M4

## Context

§7.2 is explicit: *"Mobile memory: a full bank cannot be resident. Implement
`mmap`-backed sample access with an LRU page cache, or a preprocessed streaming
format. Decide this before writing the sampler — retrofitting is a rewrite."*

The §3 budgets are 400 MB resident on desktop and **250 MB on an Android
tablet**. A General MIDI bank worth playing is 100 MB to 1 GB of PCM. Holding it
in the heap is not an option on the device the app is for.

## Decision

**Sample data is reached through a `SampleSource` trait, and the shipping
implementation memory-maps the soundfont file.**

```rust
pub trait SampleSource: Send + Sync {
    fn len(&self) -> usize;                    // in 16-bit frames
    fn read(&self, start: usize, out: &mut [f32]);
}
```

Two implementations:

- `MappedSamples` — `memmap2::Mmap` over the `smpl` chunk. This is what a bank
  loaded from disk uses.
- `ResidentSamples` — a `Vec<i16>`. This is what tests use, and what a bank
  built in memory (a rendered corpus, a generated waveform) uses.

## Why mmap rather than a hand-rolled LRU

The OS page cache **is** the LRU, and it is a better one than anything written
here: it is shared across processes, it evicts under real memory pressure rather
than a guessed budget, and its pages are clean so eviction costs nothing. A
hand-written cache would duplicate it, badly, and add a lock to the audio path.

The cost is that a page fault can happen on the audio thread. That is real, and
it is bounded: a fault on a warm file is a memcpy, and the first pass through a
sample is the only cold one. The mitigation — a warming pass over a preset's
samples when a program is selected, off the audio thread — is cheap and lands
with the mixer at M5. Prefaulting the whole file is *not* the mitigation; it is
just being resident again with extra steps.

## Consequences

- One dependency: `memmap2` (ADR 0001's test — a platform boundary we do not
  want to own; three platforms' `mmap` semantics are not a thing to reimplement).
- **The soundfont file must outlive the bank.** `MappedSamples` holds the `Mmap`,
  which holds the file open. A bank is dropped when it is replaced, so a user
  who deletes a soundfont mid-set keeps playing until they load another.
- A file that is truncated or overwritten while mapped is undefined behaviour at
  the OS level. Bandstand loads soundfonts from `~/Music/Bandstand/soundbanks/`,
  which the app does not write to, and this is recorded here as the reason not
  to start.
- `SampleSource::read` converts to `f32` at the read, so the voice never touches
  the raw format. A 24-bit bank (`sm24`) is handled there and nowhere else.
