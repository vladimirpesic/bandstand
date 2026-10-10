# The MEGA library and its local mirror

Written per §1 / §15, rewritten before the pivot implementation (ADR 0013; the
Drive-era original was written for ADR 0012). Implemented by
`app/lib/io/mega/` (the network and the crypto) and `app/lib/io/library/`
(the library and its cache).

> *A corrupted library the night before a gig is the worst failure this app can
> have.* — §5.4. The rule document for the song library
> (`library-data-safety.md`) applies to this cache unchanged: atomic writes,
> no silent data loss, the manifest is truth. This document adds the parts
> that are specific to mirroring a MEGA public folder.

## 1. What is mirrored

The `jamey_aebersold` tree behind one MEGA **public folder link**: one folder
per volume (`001_how_to_play_and_improvise_jazz`, …), each holding numbered
tracks (`006_blues_in_bb.wav`, `010_minor_to_dominant_progression.mp3`) and
`book.pdf`. Nothing else is understood or fetched. The tree is already
canonical — zero-padded numbers, underscores for spaces — and the cache relies
on that discipline rather than fighting it.

## 2. One copy, ever

There is exactly one cache root. The remote path maps 1:1 onto the local path,
mirroring the folder exactly:

```plaintext
<cache root>/
  manifest.json         the folder tree as of the last sync (§4)
  cache-state.json      per-file local state: saved or session (§5)
  volumes/<volume>/<track>.mp3
  volumes/<volume>/book.pdf
```

"Saved" versus "session" is a flag in `cache-state.json` beside the file,
never a second copy of the file. A saved download and a session download of
the same track are byte-identical, so there is nothing to reconcile between
them, and promoting a session file to saved is a flag write.

## 3. Downloads

1. Ask MEGA for the file's download URL, then stream the **ciphertext** —
   but what lands on disk is the **plaintext**: an AES-128-CTR stream
   decrypts as the bytes pass through, and the chunked MAC is computed over
   the same plaintext on its way to `<final>.part` — one read, one write,
   one pass.
2. Verify the 8-byte **meta-MAC** the MAC chain condenses to against the
   one carried inside the file's own node key. MEGA's end-to-end encryption
   means the server can never vouch for a byte; the key can, and does.
   Mismatch: delete the `.part`, report, keep nothing.
3. `flush`, then `rename` the `.part` over the final name — atomic on every
   filesystem the app targets, so a player either sees the whole file or no
   file.
4. Only then write the flag.

A crash anywhere leaves at most a stray `.part`, which the next sweep deletes.
Downloads are serialised — one at a time, never parallel — for two reasons:
this is a personal app on one network, and anonymous link downloads draw on a
per-IP transfer quota on MEGA's free tier; a bulk initial sync may be
throttled part-way (HTTP 509 with a time-until-reset), which the app reports
as "try again later", not as corruption. Every completed file is cached
forever, so a throttled sync simply resumes next launch.

## 4. The manifest

The manifest is the remote tree, fetched on demand: the root folder's node
handle and decrypted name, when it was generated, and for every volume and
file the **node handle**, the canonical name (decrypted from the node's
attributes), the size, the meta-MAC and the modified time. It is written to
`manifest.json` with the same atomic discipline as everything else, and the
app starts against the cached copy — MEGA is only needed to refresh it.

Everything downstream keys off **node handles, not names**. A volume renamed
on MEGA keeps its entries; a file moved between volumes keeps its cached
bytes; a file replaced on MEGA (new handle, or same handle with a new key)
is a different download. Reconciliation is therefore a merge, never a
mystery.

## 5. Local state and reconciliation

`cache-state.json` maps file id → `{saved: yes/no, path}`. Presence is
existence on disk plus a size match against the manifest — the MD5 is paid
once, at download time. On startup:

- a flag whose file is gone loses the flag (the file may have been deleted
  outside the app, or a rename was interrupted after the flag read but before
  the flag write);
- a file on disk with no flag — possible when a crash lands between the rename
  and the flag write — is adopted as a *session* file, the conservative
  choice;
- a file under `volumes/` that no manifest entry claims is an orphan from an
  older tree; it is reported, and deleted only when the user confirms a sweep;
- stray `.part` files are deleted outright — they were never files.

## 6. Closing the app

With session files present, exit is intercepted and the user chooses once:
**keep** (every session file is flagged saved) or **discard** (every session
file is deleted). There is no per-file interrogation at closing time; the
list of what is at stake is one screen away before that.

## 7. The link, and whose

The app speaks to exactly one MEGA folder — its owner's — through one public
folder link pasted on first run. The link is a **bearer secret**: its handle
names the folder and its fragment *is* the folder's AES key, so possession is
read access, forever, until the owner revokes the link in MEGA. There is no
account, no OAuth, no consent page and no token renewal; a link that stops
working is pasted again. The link lives in the app's private
application-support directory and nowhere else — never in a commit, never in
a log, never on the screen after it is pasted. The app can never write to
MEGA; anonymous link access is read-only by construction.

## 8. The network boundary

The MEGA client is two commands, no more: `f` (the folder's node tree, one
POST to the API gateway with the link handle as the context) and `g` (a
file's download URL, followed by one ranged GET of the ciphertext). The API
gateway's base URI is injected, so the entire stack — key unwrapping,
attribute decryption, CTR streaming, the chunked MAC, the download handshake
— is exercisable in tests against a local fake-MEGA server that speaks the
real protocol with real sockets and real bytes, plus published test vectors
for the primitives. No contract with MEGA is known to the app that is not
asserted somewhere in `app/test/`.
