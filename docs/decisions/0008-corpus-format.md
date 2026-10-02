# ADR 0008 — The bass corpus is JSON, not MIDI

**Status:** accepted · **Date:** 2026-09-03 · **Milestone:** M6

## Context

§6.3 records that jjSwing's walking-bass corpus is *"~96 KB in four MIDI
files"*, with the chord annotation carried alongside. §6.4 asks for our own
corpus of 50 phrases, and for an ingest tool that "takes a MIDI file plus a
chord annotation file, slices at bar boundaries, computes stats, writes
`corpora/<name>/*.json`".

So the plan already implies two representations: MIDI as the *recording*
format, JSON as the *stored* format. What this ADR settles is that the JSON is
the real corpus — the thing the app reads, the thing under version control, the
thing a test asserts against — and MIDI is only an input to the importer.

## Decision

**The corpus ships as `app/assets/bass_corpus.json` in the format of
`docs/format/bass-corpus.md`. MIDI is an import source, never a runtime one.**

`tools/corpus_import/` converts MIDI + a chord annotation into that JSON. Its
output is committed; its input need not be.

## Why not read MIDI at runtime

1. **The chord annotation has nowhere to live in a MIDI file.** A phrase is
   meaningless without the harmony it was played over — that is the whole of
   §6.3 — and SMF has no place for it but markers or lyrics, both of which are
   conventions rather than structure. Carrying the annotation in a second file
   means the runtime has to keep two files in step, which is a class of bug
   avoided entirely by having one file.
2. **Every derived statistic would be recomputed on every launch.** Root
   profiles, transposibility maps and harmonic fit are the caches of
   `corpus-tiling.md` §10, and they are computed from the harmony, not from the
   notes alone.
3. **A corpus is reviewed by ear and edited by hand.** A diff of
   `[38, 40, 41, 42]` changing to `[38, 41, 45, 47]` is a diff a person can read
   in a pull request. A diff of MIDI bytes is not. The corpus is the highest
   value artefact in the project (§6.4) and it should be the most legible.
4. **A bad phrase must fail a test, not surprise a listener.** The invariants in
   `docs/format/bass-corpus.md` — starts on the root, ends on a chord tone,
   reaches every root in some octave — are assertions over a data file. Making
   them assertions over a parsed binary adds a decoding step between the fault
   and the message.

## Why not a database

Considered and rejected: the whole corpus is tens of kilobytes and is read once
at startup. A database buys indexing we do not need — the tiler's index is a map
from root profile to phrases, built at load in microseconds — and costs a
dependency, a migration story, and a file that cannot be reviewed in a diff.

## Consequences

- **The corpus is an asset, so ADR 0006 applies**: it lives under `app/assets/`,
  because Flutter's bundler cannot reach outside the package root.
- **The importer's output is committed, its input optionally.** A contributor who
  records a phrase runs the importer and commits the JSON. Keeping the source
  MIDI is encouraged and not required; the JSON is the artefact.
- **Schema changes need a version bump**, and the loader refuses a version it
  does not understand rather than guessing. There is exactly one consumer, so
  this is cheap.
- **The format is lossy against MIDI, deliberately.** It stores pitch, onset,
  duration and velocity, and drops everything else a MIDI file can carry —
  controllers, bends, channel, program. A walking bass phrase is notes; anything
  that needs more is not a phrase for this corpus.
