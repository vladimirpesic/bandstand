# ADR 0013 — The library transport becomes a MEGA folder link

**Status:** accepted · **Date:** 2026-10-09 · **Supersedes:** the storage
transport of ADR 0012 (its "Drive + mirrored cache — straightforward"
paragraph and §7 of the Drive cache rule); everything else in ADR 0012
stands.

## Context

ADR 0012 put the library on Google Drive, and the first work item was built
there: OAuth (authorization code + PKCE, loopback redirect), a Drive v3
client, the manifest, the mirror cache, the screen. The premise was
"personal use is nowhere near quota" — true of the API quota, and wrong of
storage: the single user's Drive is full and the ~11 GB library does not
fit, and the user has re-hosted `jamey_aebersold` on MEGA behind a public
folder link.

What was verified before deciding:

- **No Dart MEGA SDK exists** (pub.dev carries nothing for mega.nz), so the
  client is written from scratch.
- **MEGA public folder links are anonymous, read-only, key-in-URL.** They
  need no account, no OAuth, no developer console — a closer fit to "the
  app is the account holder's own tool" than Google's consent flow was.
- **MEGA's API is end-to-end encrypted.** Even a folder-link reader must
  implement AES-128 key unwrapping, attribute (filename) decryption,
  CTR-mode stream decryption, and the chunked-MAC integrity scheme; the
  protocol is stable and the official webclient is its reference
  implementation.
- **Anonymous link downloads carry a dynamic per-IP transfer quota** on the
  free tier; a bulk initial sync may be throttled part-way.

## Decision

1. The library transport is a **MEGA public folder link**. The Drive client
   (`app/lib/io/drive/`) and its OAuth layer are removed; a from-scratch
   MEGA client replaces them, in `app/lib/io/mega/`.
2. Access stays exactly as read-only as ADR 0012 demanded — more so: the
   link is the only credential, pasted into the app once and kept in the
   app's private application-support directory. The app can never write to
   MEGA; there is nothing to write with.
3. The network boundary keeps the Drive client's discipline: as few calls
   as the job needs — fetch the folder's node tree, open a file's byte
   stream — with the API base URI injectable so the whole stack, crypto
   included, runs against local HTTP servers in `app/test/` with real bytes
   and real sockets. No contract with MEGA is known to the app that is not
   asserted somewhere in the tests.
4. **What survives from the Drive work, renamed not redesigned:** the
   manifest (Drive file ids become MEGA node handles), the mirror cache and
   its reconciliation rules (id-keyed, so renames move rather than
   re-download), saved/session flags, keep/discard at exit, the controller's
   phases, the screen — its sign-in card becomes a paste-one-link card.
5. The download-time integrity check of the cache rule §3 (Drive's
   `md5Checksum`) becomes MEGA's **meta-MAC**, computed over the decrypted
   bytes as they stream to `<final>.part` — still one pass, still verified
   before the atomic rename.

## Consequences

- **OAuth is deleted, whole.** No client id or secret, no consent page, no
  loopback server, no token renewal; the app's first-run flow is "paste the
  link" and nothing else.
- **New crypto surface** (key unwrap, attribute decryption, CTR streaming,
  chunked MACs) is added instead; it is mitigated the same way the Drive
  contract was — a local fake-MEGA server that speaks the real protocol,
  plus test vectors for the primitives (the reference implementation's
  published meta-MAC vector included). One new dependency provides AES;
  `crypto` alone cannot — and is dropped, nothing else used it.
- **Transfer quota is an accepted operational risk.** Downloads are serial,
  every completed file is cached forever, and the app starts against the
  cached manifest — a throttled sync simply resumes next launch.
- **The link is a bearer secret.** It is never committed (`.env` is
  gitignored), never logged, and held only in the user's paste and the
  app's private settings; leaking it is remedied by revoking the link in
  MEGA.
- `docs/rules/drive-cache.md` is rewritten as the MEGA library-cache rule
  (`docs/rules/mega-library.md`) before implementation (§1 / §15); ADR 0012
  remains the product decision, with its transport paragraph superseded
  here.

### What the live link taught, and the client honors

Two protocol facts no reference test covered, both verified against the
real folder and both asserted in `app/test/` via the fake:

- **A public link handle can be an alias.** The link's handle is accepted
  as the API context but never appears in the node tree; the folder's real
  handle is the parent the top-level nodes hang under. The client detects
  the de-facto root; the link's key unwraps either way.
- **Node keys are wrapped with the link's master key**, not per-parent —
  and a node's `k` can carry several wrapped alternatives. The client tries
  parent key, then link key, then every known folder key, with the
  attributes decrypting as the referee.

The shared link also names a folder that *wraps* `jamey_aebersold` and
carries stray files beside it — so the manifest finds the volume level
itself: the first level of folders whose children are files and nothing
else. `app/tool/mega_smoke.dart` is the one-shot live check
(`cd app && dart run tool/mega_smoke.dart`); it reads the link from the
root `.env` and prints no secret.
