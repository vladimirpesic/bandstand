# The library on disk, and how it survives

Written per §1 / §15, implementing §5.4. Implemented by
`app/lib/io/song_library.dart`.

> *A corrupted library the night before a gig is the worst failure this app can
> have.* — §5.4

Everything here is cheap. None of it is clever. That is the point.

## 1. Layout

```plaintext
~/Music/Bandstand/
  songs/<id>.song.json
  playlists/<id>.playlist.json
  .backups/<id>/<timestamp>.song.json
  .journal/<id>.song.json
  corpora/
  soundbanks/
  renders/
```

The folder is user-visible and the files are flat, so syncing between machines
is Syncthing or a USB stick — no code, no cloud (§5.1).

`<id>` is a version-4 UUID and is **validated before use**. A file whose name is
not a UUID is ignored on load and refused on save: the library never builds a
path out of anything it did not generate.

## 2. Atomic writes

Never write in place. To save a song:

1. Write the whole file to `<final>.tmp`.
2. `flush` it, so the bytes are with the OS rather than in a Dart buffer.
3. Take a backup of the *existing* file, if there is one (§3).
4. `rename` the temporary over the target.

Rename within a directory is atomic on every filesystem the app targets, so a
reader either sees the old file or the new one, never a half-written one. A
crash between steps 1 and 4 leaves a stray `.tmp`, which the next save cleans
up.

## 3. Rolling backups

Before a song file is overwritten, the version being replaced is copied to
`.backups/<id>/<ISO-8601 timestamp>.song.json`.

Pruning, after every save:

- keep at most `backupsPerSong` (12) versions per song;
- delete anything older than `backupMaxAge` (90 days), *except* the newest,
  which is kept whatever its age — a song untouched for a year still deserves
  one way back.

Backups are never written for a song that did not exist: the first save of a new
song has nothing to preserve.

## 4. The journal

The editor writes the song being edited to `.journal/<id>.song.json` as it goes.
It is a plain song file, so recovery is a normal load.

- On startup, any journal file whose song is *newer than the saved song* is
  offered as a recovery.
- Saving a song clears its journal.
- A journal that cannot be parsed is deleted rather than offered: a crash that
  corrupted the journal must not also break startup.

This makes a crash cost seconds, not a session (§5.4).

## 5. Validation on load, and falling back

A song is loaded by parsing it. If the parse fails:

1. Try the newest backup, then the next, until one parses.
2. Report **which** file was used, and why the first one failed.
3. If nothing parses, report the failure and skip the song.

**Never silently show an empty library** (§5.4). A load that skipped songs says
so, names them, and the library screen shows the count.

## 6. Whole-library export

One menu item writes the entire library — songs, playlists and corpora — to a
single `.zip`. That is both the disaster recovery story and the way to move to a
new machine. Import reads the same archive back, and refuses to overwrite an
existing song unless told to.

## 7. Reading mode is read-only

On stage the app cannot write to a song file at all. `SongLibrary` takes a
`readOnly` flag; every mutating call throws while it is set. This is enforced at
the library rather than in the UI, because the UI is where the accidental
gesture happens.
