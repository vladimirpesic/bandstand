# ADR 0003 — Riverpod for Flutter state

**Status:** accepted · **Date:** 2026-09-01 · **Milestone:** M0

## Context

§8.3: *"Riverpod or Bloc — pick one and be consistent. The domain model stays
framework-free; providers wrap it."*

## Decision

**Riverpod** (`flutter_riverpod` 3.x), using `Notifier` / `NotifierProvider` and
`FutureProvider`.

Why Riverpod over Bloc, for this app specifically:

- The app's state is mostly *derived*: the chart layout derives from the song
  and the viewport, the flattened chord sequence derives from the lead sheet and
  the song structure, the generated phrases derive from the flattened sequence
  and the parameters. Riverpod's dependency graph expresses that directly and
  recomputes only what changed. Bloc's event/state pairs would make each
  derivation a hand-written pipeline.
- Providers are ordinary top-level values, so a `dart test` can build a
  `ProviderContainer` and drive the whole app state with no widgets. That keeps
  the domain-layer test discipline of §0.3 usable one layer up.
- `ref.invalidate` is exactly the "regenerate after a chord edit" primitive of
  §3, with the 200 ms budget measurable at the provider boundary.

## Constraints this does not relax

- **`app/lib/domain/` never imports Riverpod**, or anything else from Flutter.
  Providers live in the layers above and wrap plain Dart objects. Enforced by
  lint at M1, when the domain layer exists.
- One state solution. No `setState` for anything that outlives a single widget,
  no `InheritedWidget` hand-rolled alternatives.

Local, ephemeral, single-widget state — a slider being dragged, a text field's
controller, the `Ticker` behind the playhead readout — stays in `State`. That is
not application state.

## Consequences

- One dependency (ADR 0001).
- Riverpod 3 deprecates `StateNotifierProvider`; the codebase uses `Notifier`
  from the start so there is no migration later.
