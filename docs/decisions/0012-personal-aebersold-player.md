# ADR 0012 — Bandstand becomes a personal Aebersold player

**Status:** accepted · **Date:** 2026-10-09 · **Supersedes:** the product scope
of §§0–9 insofar as they described a generative backing band; the architecture
they run on is untouched. **Amended by:** ADR 0013 — the library transport is
a MEGA folder link, not Drive; the product decision here stands.

## Context

Bandstand as first released — the generative product, its `v1.0.0` tag
predating the history reset — is a chord-chart editor with a generative
backing band: iReal/MusicXML/text import, walking-bass/comping/drum/voicing
generation from phrase corpora, an SF2 sampler in Rust, practice tools,
MIDI/MusicXML/PDF export. It is finished, and it is not what its single user
reaches for.

The user's actual practice material is the Jamey Aebersold play-along library
(~113 volumes, 1,523 audio tracks + 117 book PDFs, ~11 GB, already cleaned and
canonicalised on disk and mirrored to Google Drive). What is wanted is a
player for *that*, radical in its smallness:

1. **Library**: browse the Drive copy of `jamey_aebersold`, download on demand,
   cache locally, and either keep or discard downloads when the app closes.
2. **Player**: play the cached tracks with easy channel isolation — the Aebersold
   recordings put bass in one channel and piano in the other — the bass
   left, the piano right, so the player labels them by instrument — plus
   repeat and
   cycle control. No streaming: playing requires a downloaded file.
3. **Reader**: the book PDFs, with the same download/keep/discard handling,
   running concurrently with the player.
4. **Search**: flawless search across the whole tree ("autumn leaves" finds
   every volume that contains the tune), with human-readable names everywhere.
5. **Charts in sync** (later, hardest): find or derive MusicXML for the tunes
   and follow the playback in it, in the spirit of the `abcweb`/`xmlplay`
   reference projects.

## Feasibility assessment

Made before a line was removed, and kept here because it decided the shape of
the work.

**Drive + mirrored cache — straightforward.** Drive API v3 with an
installed-app OAuth flow; personal use is nowhere near quota. The no-duplicate
guarantee is structural rather than negotiated: one cache root; the remote
path maps 1:1 onto the local path, mirroring `jamey_aebersold` exactly;
downloads are atomic (`.part` then rename) and verified against Drive's
`md5Checksum`; "saved" versus "session" is a manifest flag beside the file,
never a second copy of it. Closing the app with session downloads prompts:
keep (flag as saved) or discard (delete). Reconciliation on startup runs off
Drive file ids, so renames and moves on the Drive side are merges, not
mysteries.

**The player — the reason the Rust audio stack survives.** No off-the-shelf
Flutter player exposes per-channel gain, and channel isolation is the core
feature. The plan is: decode the cached MP3/WAV (symphonia in Rust), apply a
2×2 channel-gain matrix with the existing `Smoothed` ramps (a pan move must
never click), and sum into the existing cpal/Oboe output. `bandstand-transport`
already ships `LoopRegion` — the repeat/cycle control is built and tested —
and the Android audio-focus/foreground-service integration is done
(`docs/rules/android-audio.md`). Refusing to stream *simplifies* the engine:
the file is on disk before the first sample.

**The reader — straightforward.** A PDF viewer widget over the same cache and
the same keep/discard manifest; raster work off the UI thread; no interaction
with the audio path at all, so "concurrent without interrupting" is the
default state, not a feature.

**Search — easy, because the library is disciplined.** The merged
`jamey_aebersold` tree has canonical, complete, zero-padded names. A manifest
generated from the tree, plus underscore-to-space normalisation and fuzzy
matching, answers "autumn leaves" with every volume that has the tune.

**MusicXML in sync — the genuinely hard third act, phased.**
*Sourcing* is the bottleneck: no complete public MusicXML collection of these
tunes exists. The realistic mix is curated public-domain sources, OMR
(Audiveris-class tools, with manual cleanup — the books' dense C/Bb/Eb
play-along layouts are hostile to it), and AI-assisted transcription, done
incrementally for the tunes actually practised. *Rendering* has a proven
pragmatic path: the reference projects bundle `xml2abc.js` + `abc2svg` in a
WebView and drive a cursor from the player. *Synchronisation* is a
bar-to-time mapping problem: play-along tracks are N choruses at a steady
tempo after a count-in, so a two-tap anchor (bar 1 downbeat, one later bar)
plus linear extrapolation covers most of it; the transport's tempo map and
the kept `playhead`/`playback_cursor` machinery are exactly the parts needed.
Fully automatic alignment is research-grade and explicitly not promised.

## Decision

1. Bandstand is a personal app for one user. Everything that existed only to
   make the generative band is removed from the tree; when the repository's
   history was reset at the player's 1.0.0, it was deleted outright.
2. **Kept**, because the new features are built on them:
   `bandstand-audio-host` (device I/O), `bandstand-transport` (clock, loop
   regions, tempo maps), the engine thread and its task/repost discipline,
   the Android audio-focus and foreground-service integration, the harmony
   domain (chord symbols, keys, transposition for Bb/Eb books), the song and
   leadsheet model with its undo stack, the MusicXML and iReal importers, the
   MusicXML exporter, the chart renderer with its playback cursor, the theme
   and the generic widgets, the FRB bridge, the reference test tone and the
   ramped-parameter code (ported from the retired synth into
   `rust/src/tone.rs`).
3. **Removed**: the generation pipeline and its corpora and tools, the SF2
   sampler/sequencer and soundfonts and bank download, MIDI and PDF export,
   the practice/playlist/library screens and their state, the offline bounce,
   the website, the release and pages workflows, benchmarks and the bench
   harness, and the rule documents that described them. The FFI surface lost
   every soundbank/sequence/channel-mix call; `set_channel_mix` returns as a
   player-side channel-gain matrix when the decoder lands.
4. `written_part_placer` and `rhythm_ids` moved from `domain/generation/` into
   `domain/song/`: they are model vocabulary, not generation, and MusicXML
   melody import needs them.
5. The audio engine keeps its diagnostic tone and master gain so the device
   path stays verifiable the day it starts decoding files; where the player
   plugs in is documented in `rust/src/engine.rs`.

## Consequences

- The FFI surface is smaller than §15 asked for and stays small; the player
  adds decode/load/seek/channel-gain calls and nothing else.
- The §-index and the surviving rule documents stay valid for everything they
  still describe; the ones for removed subsystems are deleted, not marked
  obsolete — git keeps them.
- The library data-safety rule (`docs/rules/library-data-safety.md`) applies
  unchanged to whatever local caches the Drive layer introduces: atomic
  writes, no silent data loss, the manifest is truth.
- The first new work items are, in order: the Drive manifest + mirror cache,
  the decoder + channel-gain matrix in the engine, the player screen, the
  PDF reader, search — then, deliberately last, MusicXML.
