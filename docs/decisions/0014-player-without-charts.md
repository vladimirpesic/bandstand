# ADR 0014 — The player stays chartless: beats and MusicXML go

**Status:** accepted · **Date:** 2026-10-13

## Context

After the 0012 pivot, two features were built on top of the plain player:

- **MusicXML chord charts** — iReal-derived charts written dev-side into a
  root `musicxml/` mirror, imported and laid out above the player controls,
  with a follower cursor driven by the audio position.
- **beat-this tempo analysis** — offline `beat-this` inference (the
  `rust/bandstand-beats` crate) writing per-track `.beats` sidecars into a
  root `beats/` mirror; the player narrowed repeat regions to the music,
  counted choruses and drove the follower's cursor from the markers.

Both shipped, and the owner's verdict on both is that they do not work: the
analysis and its tempo readings are not dependable on this library, and the
chart follower is unusable in practice. Making either trustworthy is a
research project, not a practice tool, and the plain player — the recording,
the transport, channel isolation, the marked loop, the books — is what the
app is actually for.

## Decision

**Remove both, entirely.** The setlists feature, shipped alongside the
follower arc, stays untouched. Deleted outright, the way the 0012 pivot
handled the band:

- `rust/bandstand-beats` — the whole crate; the workspace is two crates
  again — with the `just beats` and `just fetch-beat-models` recipes and the
  model-weights story.
- The chart stack: `app/lib/domain/` (harmony and song model),
  `app/lib/render/` (chart layout and painters), the MusicXML
  importer/exporter, the iReal importers, `tool/ireal_charts.dart`, the
  `just ireal-charts` and `just fetch-musicxml-suite` recipes, the `xml` and
  `archive` dependencies and the bundled harmony assets.
- The `chart` and `beats` manifest kinds, the mirror pairing, and the local
  `volumes/musicxml/…` / `volumes/beats/…` cache routing.
- The follower UI — count-in chip, chorus counter, cursor — and the
  marker-narrowed repeat. Repeat and the marked loop are the whole-track
  region they were before markers existed.

The `musicxml/` and `beats/` folders may still sit in the owner's MEGA tree;
the manifest skips both by name rather than browsing them, and the owner can
delete the folders whenever convenient. A cached manifest that still carries
`chart` or `beats` rows fails the strict parse on upgrade and is simply
re-synced — one network fetch, no migration code.

Rule documents and ADRs whose whole subject was removed are deleted with the
code: `chart-layout`, `chord-symbols`, `pitch-and-spelling`, `written-parts`,
`form-navigation`, `ireal-format`, `musicxml-import` and
`library-data-safety` (the song library it governed left with the band; the
cache's own data-safety rules live in `mega-library.md`), `docs/format/`,
ADR 0006 and ADR 0011. ADR 0012 stands as the pivot's history, with its §5
charts-and-markers roadmap superseded by this record.

## Consequences

- The APK carries no XML parser and no bundled data assets; the formats the
  app reads and writes are the manifest, the cache flags, the library
  settings and `setlists.json`.
- `PlayheadReading` carries the position, the transport state and the loop
  generation only — musical time (bpm, ppq, bar·beat) existed for the
  follower. The Rust transport's own clock, tempo map and loop regions are
  untouched.
- Bridge surface nothing called anymore — the Dart-side tempo-map installer
  and its `TempoMarker`, `monotonic_now_ns`, `player_unload`, all band-era
  leftovers — went in the same sweep; the bridge exposes what the player
  calls, no more.
- "Follow sheet music synced to the recordings" is off the roadmap for good;
  §2's non-goal against automatic transcription and score alignment now
  covers chart following in general.
