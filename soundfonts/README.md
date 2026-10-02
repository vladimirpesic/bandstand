# Soundfonts hosted in this repository

The app downloads its recommended General MIDI bank on first run rather than
bundling it (see `docs/rules/bank-download.md` for why). This directory is
where that bank lives in the repository, stored with Git LFS.

## The file

| | |
| --- | --- |
| Name | `FluidR3_GM.sf2` |
| Size | 148,398,306 bytes (141.5 MiB) |
| SHA-256 | `74594e8f4250680adf590507a306655a299935343583256f3b722c48a1bc1cb0` |
| Licence | MIT (Frank Wen's FluidR3; same bytes as Debian's `fluid-soundfont-gm`) |

The digest is pinned in `app/lib/io/bank_download.dart`. If the bank ever
changes **on purpose**, update the size and digest there and in this table,
and put the reason in the commit message.

## Hosting it

The file is tracked by LFS (see `.gitattributes`). Once committed to `main`
under this path, it is served from two places:

1. Every GitHub release: `.github/workflows/release.yml` attaches this file
   when it cuts a release, and the stable URL

   ```plaintext
   https://github.com/vladimirpesic/bandstand/releases/latest/download/FluidR3_GM.sf2
   ```

   keeps pointing at the newest one. Release downloads are unmetered, which
   the LFS CDN's quota is not, so this is the app's primary mirror.

2. The LFS object itself, straight off `main`:

   ```plaintext
   https://media.githubusercontent.com/media/vladimirpesic/bandstand/main/soundfonts/FluidR3_GM.sf2
   ```

   Live one release earlier than the first tag.

Both answer `Range` requests, which is what resuming a 148 MB download over
flaky network needs. The mirrors, and their order, are the `mirrors:` list
in `app/lib/io/bank_download.dart` — repoint, add or reorder them there; the
pinned digest does the rest. A mirror that serves different bytes is detected
at run time and skipped, never installed.

The GitHub Pages site deliberately does **not** carry a copy: Pages is for
the site's own small files, and release assets are where big binaries belong.

## Do not bundle it

Resist the temptation to also declare this file as a Flutter asset: the
sampler memory-maps a bank from a real filesystem path, and an APK asset is
a zip entry — bundling would double the on-device cost (~300 MB) and still
need extraction before the first note.
