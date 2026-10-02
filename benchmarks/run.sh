#!/usr/bin/env bash
#
# The §11.3 benchmark suite: run before each milestone sign-off.
#
# Every benchmark lives beside the code it measures — a render benchmark in the
# render tests, a synth benchmark in the synth tests — because a benchmark kept
# in a separate tree stops being run and then stops compiling. What lives here
# is the runner that drives all of them and writes the results down, so §3's
# budgets are checked together and the numbers land in docs/benchmarks.md where
# a regression is visible months later rather than on stage.
#
# Usage:  benchmarks/run.sh [--append "Heading"]
#
# Without --append the results go to stdout only.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

append_heading=""
if [[ ${1-} == "--append" ]]; then
    append_heading="${2:?--append needs a heading}"
fi

results="$(mktemp)"
trap 'rm -f "$results"' EXIT

say() {
    printf '%s\n' "$*" | tee -a "$results"
}

# The budgets in the suites are assertions only when this is set; without it
# they print their numbers and pass, so a developer's laptop or a shared CI
# container cannot fail the build on a scheduler hiccup. A sign-off run is
# exactly the place they should be hard, which is what this script is for.
#
# One name, used by test/render/render_benchmark_test.dart and
# test/io/importers/musicxml_suite_test.dart. There used to be two names and
# this script exported neither, so no budget was ever enforced anywhere.
export BANDSTAND_ENFORCE_BENCHMARKS=1

failed=0

# Run a suite, print its BENCH lines, and remember whether it passed.
#
# Not a bare pipeline into grep: that discards the exit status, so a suite that
# failed its budget looked exactly like one that met it — the numbers simply
# did not appear. The status is checked, and a failure is reported at the end
# rather than aborting, so one blown budget still leaves the other numbers
# measured.
run_suite() {
    local label="$1"
    shift
    local log
    log="$(mktemp)"
    if "$@" >"$log" 2>&1; then
        :
    else
        failed=1
        say "FAILED $label — a budget was not met (rerun without \
BANDSTAND_ENFORCE_BENCHMARKS to see the numbers alone)"
        sed -n '/\[E\]/,/^$/p' "$log" >&2 || true
    fi
    grep '^BENCH' "$log" | while read -r line; do say "$line"; done
    rm -f "$log"
}

# ---------------------------------------------------------------- generation
# §3: full regeneration after a chord edit, 100 ms target, 300 ms hard.
echo "== generation ==" >&2
run_suite generation env --chdir=app flutter test \
    test/domain/generation/song_generator_test.dart \
    test/domain/generation/ensemble_generator_test.dart \
    test/domain/generation/bass/walking_bass_generator_test.dart \
    test/domain/generation/comping/comping_generator_test.dart

# -------------------------------------------------------------------- render
# §3: chart repaint on a cursor frame, 4 ms target, 8 ms hard.
# §11.3: layout time per 100 bars.
echo "== render ==" >&2
run_suite render env --chdir=app flutter test \
    test/render/render_benchmark_test.dart

# ------------------------------------------------------------------ importer
echo "== importers ==" >&2
run_suite importers env --chdir=app flutter test \
    test/io/importers/musicxml_suite_test.dart

# --------------------------------------------------------------------- synth
# §11.3: synth CPU at 64 voices. Release, because a debug build measures the
# optimiser rather than the DSP.
echo "== synth ==" >&2
run_suite synth env --chdir=rust cargo test --release \
    --test synth_load_test -- --nocapture

# ---------------------------------------------------------------- cold start
# §3: launch to a visible library, 1 s target, 3 s hard. Needs the real binary,
# because exec, linking and engine boot all happen before main() runs.
echo "== cold start ==" >&2
bundle="app/build/linux/x64/release/bundle/bandstand"
if [[ -x $bundle && -n ${DISPLAY-}${WAYLAND_DISPLAY-} ]]; then
    times=()
    for _ in 1 2 3 4 5; do
        log="$(mktemp)"
        BANDSTAND_STARTUP_REPORT=1 timeout 30 "$bundle" >"$log" 2>&1 &
        app=$!
        # The app has no reason to exit on its own, so wait for the line rather
        # than for the process, and stop it as soon as the number is in.
        for _ in $(seq 1 300); do
            grep -q '^STARTUP library visible' "$log" 2>/dev/null && break
            kill -0 "$app" 2>/dev/null || break
            sleep 0.1
        done
        if measured=$(grep -m1 '^STARTUP library visible' "$log"); then
            times+=("$(printf '%s' "$measured" | awk '{print $4}')")
        fi
        kill "$app" 2>/dev/null || true
        wait "$app" 2>/dev/null || true
        rm -f "$log"
    done
    if ((${#times[@]} > 0)); then
        say "BENCH cold start to library visible: $(printf '%s ' "${times[@]}")s"
    else
        echo "the app never reported; is a display available?" >&2
    fi
else
    echo "no release bundle or no display; skipping cold start" >&2
    echo "  build one with: just build-linux" >&2
fi

# ------------------------------------------------------------------ recording
if [[ -n $append_heading ]]; then
    {
        printf '\n## %s — %s\n\n' "$append_heading" "$(date +%F)"
        printf 'Measured by `benchmarks/run.sh` on %s.\n\n' "$(uname -sr)"
        printf '```\n'
        cat "$results"
        printf '```\n'
    } >>docs/benchmarks.md
    echo "appended to docs/benchmarks.md" >&2
fi

if ((failed)); then
    echo "one or more budgets were not met; see FAILED above" >&2
    exit 1
fi
