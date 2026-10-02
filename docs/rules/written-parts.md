# Written parts

§9's list of *"what iReal Pro does not do, and you should"* has this second:
**literal playback of a written part** — a pit book, a horn part, the head —
alongside the generated backing.

Everything else Bandstand plays is *written for you* from the chords. A written
part is the opposite: it is played exactly as it is on the page, because
somebody already decided what the notes are. The two coexist, and the
distinction runs through the whole feature.

## 1. What a written part is

A named list of notes positioned on the **written page**, not on the playback
timeline:

| | |
| --- | --- |
| `id` | Stable, for the mixer and the song file. |
| `displayName` | What the player calls it: "Melody", "Tenor 1", "Cue". |
| `program` | A General MIDI program. A horn part should sound like a horn. |
| `notes` | Each with a **written bar**, a beat inside that bar, a MIDI key, a duration in beats, and a velocity. |

**Positions are (bar, beat), not beats-from-the-start.** Three reasons, all of
which have bitten notation software:

1. A meter change in the middle of a tune makes "beat 137" ambiguous. "Bar 12,
   beat 3" is not.
2. Inserting a bar in the editor should move the notes after it. With absolute
   beats every note would have to be rewritten; with bars, the ones before the
   insertion do not move at all.
3. It is how the map to playback works. §4.5 insists every playback bar knows
   its `sourceBar`, and (bar, beat) is exactly the coordinate that map takes.

## 2. Repeats play the part again

A written part is placed by walking the **flattened** sequence and, for each
playback bar, emitting the notes written in its `sourceBar`.

So a tune with a repeat plays the melody twice, an AABA form plays the A melody
three times, and a coda plays whatever is written in the coda. This is not a
special case — it is the only behaviour that makes sense, and it falls out of
using the same `sourceBar` map the cursor uses.

A note written past the end of its bar (a tie over the bar line, written as a
long note) sounds for its full length wherever the bar is played, including at
the end of a repeat, where the next bar is a different one. That is what a
player does, and cutting the note at the bar line would be worse.

## 3. It is a voice, not a generator

A written part is **not** a `MusicGenerator`. A generator is chosen per song
part and writes the backing; a written part plays over whatever backing was
chosen. So it joins the pipeline where the generated phrases are collected —
as another entry in the voice map — and from that point on it is a voice like
any other:

- it gets a MIDI channel from the same allocator,
- it appears in the mixer with its own level, pan and mute,
- it exports to MIDI as its own named track,
- it is affected by nothing the generators do, and affects nothing they do.

That last point is the whole reason to put it here rather than in the
generators: rerolling the bass must not touch the melody, and it cannot, because
the written part is not generated and has no seed.

## 4. Muted by default

A song that carries a melody plays it **only when asked**.

The common case is a singer or a horn player who has the melody covered and
wants the backing; hearing a synthesised melody doubling them is worse than
useless on stage. The uncommon case — learning a head, or checking an
unfamiliar line — is a deliberate act, so it gets a deliberate control.

The mute lives in the mixer, where every other level does, and it is stored with
the song rather than globally: whether you want the head played is a fact about
the tune you are learning, not about you.

## 5. What imports into one

MusicXML carries notes, and `docs/rules/musicxml-import.md` §5 previously listed
melody under *"deliberately dropped"* with the reason **"nowhere to put it"**.
There is somewhere to put it now, so the importer keeps it:

- the **first** part in the file that has notes and is not percussion becomes a
  written part;
- its `<part-name>` becomes the display name, falling back to "Melody";
- pitches come from `<step>`, `<alter>` and `<octave>`, durations from
  `<duration>` against the file's `<divisions>`;
- `<rest>` advances the position and writes nothing;
- a `<chord>` note starts at the same position as the note before it, which is
  how MusicXML writes a double-stop;
- ties are joined into one long note, because the point is what sounds;
- grace notes are dropped: they carry no duration, and placing them is an
  interpretation, not a fact.

**Transposing instruments are read at concert pitch.** MusicXML's `<transpose>`
element says how far the written part is from sounding, and a B♭ tenor part
written in D sounds in C. Bandstand stores what sounds, because that is what it
plays; the written page it came from is unchanged and is what a PDF of the
original would show.

## 6. What it deliberately does not do

- **No notation.** A written part is heard, not seen. §9's melody *display* is a
  separate feature and a much larger one — staves, stems, beams, ledger lines
  and a great many aesthetic decisions. Playing a part needs none of that, and
  waiting for it would mean shipping neither.
- **No editing.** Parts arrive by import. An editor for them is a notation
  editor, which is the same deferred feature.
- **Not exported to MusicXML or PDF.** Those write the *written page* — the
  chart — and the chart has never had a stave on it. Adding one on export would
  produce a document that does not match what the app shows.
- **Exported to MIDI**, though, and to audio: those are what Bandstand *played*,
  and it played the part.
