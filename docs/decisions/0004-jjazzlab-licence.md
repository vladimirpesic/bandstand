# ADR 0004 — JJazzLab's licence ambiguity: open question

**Status:** open · **Date:** 2026-09-01 · **Milestone:** M0

## Context

§1 of the plan records that JJazzLab's `LICENSE` file and `pom.xml` say
LGPL-2.1, while 993 of ~997 Java file headers say LGPLv3. The two differ in ways
that matter for app-store distribution.

## Decision

**Unresolved, and deliberately not blocking.** The working discipline makes the
answer irrelevant to everything built so far:

- No JJazzLab source has been read, transliterated or vendored for any code in
  this repo. The transport clock, tempo map, position readback, audio host and
  test tone are all original work against the platform APIs and the written
  rules in `docs/rules/`.
- Where a JJazzLab algorithm *is* consulted later, §1's procedure applies: read
  to understand, write the rule down in `docs/rules/` in prose, implement from
  the prose. `docs/rules/` is the evidence of process.

## Action still owed

Email Jerome Lelasseux and ask which licence he intends. Record the answer by
amending this ADR to **accepted** or **superseded**. Do it before any code that
was informed by reading JJazzLab ships to anyone.

Two further exposures from §1, tracked here so they are not forgotten:

- **Sample provenance** is a bigger risk than any code licence. Before
  publishing, record the provenance of every sample set in this directory.
- **Do not vendor** the JJazzLab SoundFont or the jjSwing MIDI phrase databases.
  The corpus is built from scratch (§6.4).
