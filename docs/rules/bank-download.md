# Getting a soundbank onto the machine

Written per §1 / §15, alongside §7.2. Implemented by
`app/lib/io/bank_download.dart`, `app/lib/state/bank_download_state.dart` and
the banner/controls widgets in `app/lib/ui/widgets/`.

## Why a download and not a bundle

The recommended bank is FluidR3 GM: 148 MB, MIT-licensed, the de-facto
standard free General MIDI bank. It is not in the binary, for the same reason
no bank is (§7.2): the sampler maps a bank from a real file with `mmap`, and
an APK asset is a compressed entry in a zip, not a file. Bundling would mean
~300 MB on device (the APK plus the extraction) against a Play AAB cap of
200 MB — and TimGM6mb, the bank small enough to bundle, is GPL-2 and stays
out on those grounds alone.

So the bank is fetched once, on the user's say-so, into the library's
`soundbanks/` folder — the first place `SoundbankLibrary.scan` looks.

## The offer

A machine that has any bank at all — one in the library, or a system one on a
desktop — sees no offer. A machine with none gets a banner on the library
screen, the app's home, saying what a bank is for and how big this one is.

The download does not start itself. 148 MB is not the app's data to spend
without asking, least of all on a metered phone connection. The three answers
are: **Download** (now, with progress and a pause), **Not now** (gone for this
run), and **Never ask again** (a `.recommended-bank.json` dot-file inside
`soundbanks/`, which the scan ignores). The empty bank picker on the audio
screen always offers the download regardless — that is where somebody who
wants sound *right now* is standing, and it is the way back in after a
permanent refusal.

## The contract

`BankDownloader` is where every decision lives, tested against a loopback
HTTP server rather than a mock client:

* **Nothing partial is ever installed.** Bytes land in
  `FluidR3_GM.sf2.part`; only a part whose length *and* SHA-256 match the
  pinned values is renamed over the target. The rename is within one
  directory, so it is atomic on every platform Bandstand runs on.
* **An interruption costs nothing.** The part file *is* the progress: a later
  attempt sends `Range: bytes=<part size>-` and appends. Kill the app, lose
  the network, run out of disk — the fetched bytes are kept, and resuming
  onto a different mirror is safe because the digest still judges the
  finished whole.
* **A server that ignores or rejects the range is not an error.** A plain
  `200` restarts from zero; a `416` deletes the stale part and retries the
  same mirror from the top.
* **A crash between the last byte and the rename loses nothing.** A whole,
  verifying part is renamed into place with no network at all.
* **Mirrors are tried in order, each exactly once**, and the pinned digest
  (`74594e8f…`) — not any server's word — decides what a valid bank is. A
  digest failure deletes the part: those bytes cannot prefix any valid bank.
* **A bank already on disk is never overwritten.** If the user put their own
  `FluidR3_GM.sf2` there by hand, it is theirs, whatever its digest.
* **No overall timeout.** 148 MB over a slow network is an hour well spent;
  only the connection (30 s) is bounded. Progress is reported at most about
  once per megabyte — nobody's progress bar needs thousands of rebuilds.

## The mirrors

Defined, with the pinned size and digest, in one place:
`app/lib/io/bank_download.dart`. In order: the asset of the newest GitHub
release — `.github/workflows/release.yml` attaches this same file to every
release, and `releases/latest/download/` is a stable URL that survives
version rolls — then the GitHub LFS object on `main`
(`soundfonts/FluidR3_GM.sf2`, see `soundfonts/README.md`), which is live one
release earlier than the first tag. Both must serve the exact pinned bytes;
the digest enforces that at run time, and `soundfonts/README.md` records the
procedure for re-pinning if the bank ever changes on purpose.

The website does not carry a copy: GitHub Pages is for the site's own small
files, and release assets — unmetered, resumable, 2 GB each — are where a
148 MB binary belongs.
