# `.song.json`

Bandstand's native song format (§5.1): plain JSON, versioned, human-diffable,
one file per song. No binary, no serialization framework, no reflection.

Written and read by `app/lib/io/song_json.dart`. The on-disk song library
that stored these files was retired with the editor (ADR 0012); the format
stays as the kept song model's serialisation, for the MusicXML milestone.

## Why JSON, and why by hand

- **Diffable.** A song under version control, or synced with Syncthing, produces
  a readable diff. A binary format produces a conflict.
- **Recoverable.** A truncated file can be repaired in a text editor at a gig. A
  truncated binary cannot.
- **No reflection.** Every field is read and written by name in one file, so
  adding a field is a deliberate act with a migration attached — not something
  that happens because a class gained a member.

Keys are written in a fixed order, and defaults are **omitted**. A plain chord
is `{"kind":"chord","bar":0,"beat":0,"symbol":"Dm7"}` and nothing more, so a
diff shows what changed rather than what the defaults are.

## Top level

```json
{
  "schemaVersion": 1,
  "id": "6f7d…",
  "title": "Blue Bossa",
  "composer": "Kenny Dorham",
  "tempo": 148,
  "key": "Cm",
  "tags": ["bossa", "session"],
  "meta": {"source": "ireal"},
  "createdAt": "2026-09-01T10:00:00.000Z",
  "modifiedAt": "2026-09-01T10:31:12.000Z",
  "leadSheet": { … },
  "structure": { … },
  "mixer": { … }
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `schemaVersion` | yes | Integer. A file from a *newer* version is refused, not guessed at. |
| `id` | yes | Stable; also the file name. |
| `title` | yes | Non-empty. |
| `composer` | no | Defaults to `""`. |
| `tempo` | no | 10–400, defaults to 120. |
| `key` | no | As `KeySignature` writes it: `C`, `Bb`, `F#m`. Defaults to `C`. |
| `tags` | no | Strings, sorted on write. |
| `meta` | no | String-to-string. Whatever an importer wants to remember. |
| `createdAt`, `modifiedAt` | no | ISO-8601 UTC. Default to now. |

## `leadSheet`

```json
{
  "barCount": 16,
  "pickupBeats": 0,
  "items": [ … ]
}
```

Items are written in position order. Every item has `kind` and `bar`; chords and
annotations also have `beat`.

| `kind` | Fields |
| --- | --- |
| `chord` | `bar`, `beat`, `symbol` (e.g. `"Dm7"`, `"N.C."`), optional `rendering`, optional `scale` |
| `section` | `bar`, `name`, optional `timeSignature` (default `"4/4"`) |
| `repeat` | `bar`, `start` (bool), `playCount` (end barlines only, default 2) |
| `ending` | `bar`, `passes` (integers), optional `barCount` (default 1) |
| `navigation` | `bar`, `mark` (one of the `NavigationMark` names) |
| `annotation` | `bar`, `beat`, `text` |

`rendering` carries only what is not the default:

```json
{"accent":"strong","playStyle":"hold","anticipation":"eighth",
 "pedalBass":true,"noChord":false}
```

`scale` is `{"name":"Lydian dominant","root":"Eb"}`; an unknown scale name is
dropped with a warning rather than failing the load, because a scale hint is
never worth losing a chart over.

## `structure`

```json
{"parts": [
  {"section":"A","barCount":8,"rhythmId":"swing-medium",
   "name":"A (head)","parameters":{"intensity":50}}
]}
```

Start bars are **not** stored: the parts are contiguous by construction, so
storing them would only create a way for the file to contradict itself.

`rhythmId` names a style. A song whose style is not installed still opens, still
displays and still edits — it just has nothing to play.

## `mixer`

```json
{"masterVolume":0.8,
 "channels":[{"voiceId":"bass","volume":0.8,"pan":0.0,"muted":false,
              "soloed":false,"midiBank":0,"midiProgram":32,"transpose":0}]}
```

Channels with nothing but defaults are omitted.

## Versioning and migration

`schemaVersion` is an integer, bumped whenever a field changes meaning or goes
away. Adding an optional field with a default does **not** bump it: old files
read correctly and new files read correctly in old builds.

`SongJson.applyMigrationChain` walks the file from its own version up to the
current one, applying one function per step. A missing step is a load failure
with the versions named — never a silent partial read.

A file whose version is *higher* than this build's is refused outright. Guessing
at a format from the future is how a library gets quietly corrupted.
