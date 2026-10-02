# Bandstand — cross-language build and test.
#
# `just` from the repo root. Everything here must work on Ubuntu with the
# toolchain of §12.1.

app_dir := justfile_directory() / "app"
rust_dir := justfile_directory() / "rust"

# List the recipes.
default:
    @just --list

# Everything CI would run, if this project had CI (§12: a pre-commit hook is enough).
check: rust-check dart-check tools-check

# Rust: format, lint and test the whole workspace.
rust-check:
    cd {{rust_dir}} && cargo fmt --all --check
    cd {{rust_dir}} && cargo clippy --workspace --all-targets -- -D warnings
    cd {{rust_dir}} && cargo test --workspace

# Dart: analyse and unit-test.
dart-check:
    cd {{app_dir}} && dart format --output=none --set-exit-if-changed lib test integration_test
    cd {{app_dir}} && flutter analyze
    cd {{app_dir}} && flutter test

# Regenerate the FFI bindings. Never edit `app/lib/bridge/` by hand (§12.1).
bridge:
    cd {{app_dir}} && flutter_rust_bridge_codegen generate

# Run the app on the Linux desktop.
run:
    cd {{app_dir}} && flutter run -d linux

# Build the Linux desktop bundle.
build-linux:
    cd {{app_dir}} && flutter build linux --release

# Build the Android APK.
build-android:
    cd {{app_dir}} && flutter build apk --release

# Android 15 introduced 16 KB page devices and from API 35 a library that is
# not aligned for them will not load at all (docs/rules/android-audio.md §5).
# This is a build-configuration property, so it is verified rather than assumed.

# Check the packaged native libraries are 16 KB page aligned.
android-check:
    #!/usr/bin/env bash
    set -euo pipefail
    cd '{{app_dir}}'
    apk=build/app/outputs/flutter-apk/app-debug.apk
    if [ ! -f "$apk" ]; then
      flutter build apk --debug
    fi
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    unzip -o -q "$apk" 'lib/*' -d "$work"
    status=0
    for so in $(find "$work/lib" -name '*.so' | sort); do
      name="${so#$work/lib/}"
      abi="${name%%/*}"
      align=$(objdump -p "$so" 2>/dev/null | awk '/LOAD/ {print $NF; exit}')
      # 16 KB pages are a 64-bit feature: a device with them does not run
      # 32-bit code at all, so armeabi-v7a is exempt and is expected at 2**12.
      case "$abi" in
        arm64-v8a|x86_64) required=yes ;;
        *) required=no ;;
      esac
      printf '%-52s %-8s %s\n' "$name" "$align" \
        "$([ "$required" = yes ] && echo '(16 KB required)' || echo '(32-bit, exempt)')"
      if [ "$required" = yes ]; then
        case "$align" in
          2\*\*1[4-9]|2\*\*2[0-9]) ;;
          *) echo "    NOT 16 KB ALIGNED"; status=1 ;;
        esac
      fi
    done
    exit $status

# Pushes a General MIDI bank first: a phone has no /usr/share/sounds, and
# without one the sampler suites skip, which means the sampler — the part most
# likely to differ on another architecture — is not exercised there at all.

# Integration tests on a connected Android device or emulator.
android-test DEVICE="emulator-5554":
    #!/usr/bin/env bash
    set -euo pipefail
    bank=""
    for candidate in /usr/share/sounds/sf2/TimGM6mb.sf2 \
                     /usr/share/sounds/sf2/default-GM.sf2 \
                     /usr/share/soundfonts/default.sf2; do
      if [ -f "$candidate" ]; then bank="$candidate"; break; fi
    done
    remote=/data/local/tmp/bandstand-test.sf2
    if [ -n "$bank" ]; then
      adb -s '{{DEVICE}}' push "$bank" "$remote" >/dev/null
      adb -s '{{DEVICE}}' shell chmod 644 "$remote"
      echo "pushed $bank"
    else
      echo "no General MIDI bank on this box; the sampler suites will skip"
    fi
    cd '{{app_dir}}'
    logs='{{justfile_directory()}}/build/integration-logs'
    mkdir -p "$logs"
    # Serialise per device for the same reason as integration-test: two
    # suites sharing one audio device contend for it (F-01). Keyed by the
    # serial so different devices can still run in parallel.
    exec 9>"$logs/device-{{DEVICE}}.lock"
    flock 9 || exit 1
    status=0
    for suite in library audio_engine synth generation platform_audio memory page_turner reading_mode; do
      echo "--- $suite (android) ---"
      if ! flutter test "integration_test/${suite}_test.dart" -d '{{DEVICE}}' \
             --dart-define=BANDSTAND_SOUNDFONT="$remote" \
             2>&1 | tee "$logs/android-$suite.log"; then
        status=1
      fi
      if grep -q 'Some tests failed' "$logs/android-$suite.log"; then
        status=1
        kept="$logs/FAILED-android-$suite-$(date +%Y%m%d-%H%M%S).log"
        cp "$logs/android-$suite.log" "$kept"
        echo "    (failed — kept at $kept)"
      fi
    done
    exit $status

# The only place a screen that reads the disk can be tested: `flutter test`
# runs widgets in a fake-async zone where filesystem futures never complete.

# Integration tests, which need a real audio device and a display.
integration-test:
    #!/usr/bin/env bash
    # One at a time, not `flutter test integration_test`: each file drives a
    # real audio device, and sharing one process between them means a failure
    # in the first leaves the device open for the second.
    #
    # Every run is teed to build/integration-logs/. These suites are
    # intermittently flaky under sustained load and the failures are rare
    # enough that losing one to a terminal scrollback costs an afternoon;
    # keeping the log makes the next one diagnosable.
    set -uo pipefail
    cd '{{app_dir}}'
    logs='{{justfile_directory()}}/build/integration-logs'
    mkdir -p "$logs"
    # Serialise against any other device-driving run — a second
    # `just integration-test`, or an ad-hoc `flutter test
    # integration_test/...` in another terminal. Two suites on one audio
    # device contend for it, and the §3 drift measurement includes real
    # device scheduling, so the loser can blow a budget the transport
    # itself keeps (F-01, AUDIT_REPORT.md). Blocking, not failing: the
    # second run waits its turn.
    exec 9>"$logs/device-linux.lock"
    flock 9 || exit 1
    status=0
    for suite in library audio_engine synth generation platform_audio memory page_turner reading_mode; do
      echo "--- $suite ---"
      if ! flutter test "integration_test/${suite}_test.dart" -d linux \
             2>&1 | tee "$logs/$suite.log"; then
        status=1
      fi
      if grep -q 'Some tests failed' "$logs/$suite.log"; then
        status=1
        # Keep failures under their own name. The plain log is overwritten by
        # the next run, and a flake chased across several passes loses its
        # evidence to the pass that follows it — which is exactly what happened.
        kept="$logs/FAILED-$suite-$(date +%Y%m%d-%H%M%S).log"
        cp "$logs/$suite.log" "$kept"
        echo "    (failed — kept at $kept)"
      fi
    done
    exit $status

# M0.5 probe: tile a walking bass line over a 32-bar form and write it to MIDI.
probe *ARGS:
    cd {{justfile_directory()}}/tools/tiling_probe && dart pub get && \
      dart run bin/tiling_probe.dart --out {{justfile_directory()}}/renders/tiling-probe.mid {{ARGS}}

# Usage:
#
#   just corpus-import take.mid take.chords
#
# Adds to the shipped corpus in place. Review the diff before committing it —
# the corpus is the artefact, and it is meant to be read (ADR 0008).

# Import a recorded bass take into corpus phrases (§6.4).
corpus-import MIDI CHORDS:
    #!/usr/bin/env bash
    # One shell for the whole body, so the paths are resolved against the
    # directory you ran `just` from before the recipe changes directory.
    set -euo pipefail
    midi="$(realpath '{{MIDI}}')"
    chords="$(realpath '{{CHORDS}}')"
    cd '{{justfile_directory()}}/tools/corpus_import'
    flutter pub get
    dart run bin/corpus_import.dart \
      --midi "$midi" --chords "$chords" \
      --merge '{{app_dir}}/assets/bass_corpus.json' \
      --out '{{app_dir}}/assets/bass_corpus.json'

# Usage:
#
#   just audition                        # a ii-V-I, three choruses
#   just audition "Cmaj7 A7 Dm7 G7" 3    # any form, any number of choruses
#
# Writes MIDI to build/audition/, and a WAV beside it when a General MIDI bank
# and `fluidsynth` are on the box (§12.1).

# Generate a bass line and render it, for the §10 M6 listening test.
audition PROGRESSION="Dm7 G7 Cmaj7 Cmaj7" CHORUSES="3":
    #!/usr/bin/env bash
    set -euo pipefail
    out='{{justfile_directory()}}/build/audition'
    mkdir -p "$out"
    cd '{{justfile_directory()}}/tools/corpus_import'
    flutter pub get >/dev/null
    dart run bin/audition.dart --out "$out/audition.mid" \
      --progression '{{PROGRESSION}}' --choruses '{{CHORUSES}}'
    bank=""
    for candidate in /usr/share/sounds/sf2/TimGM6mb.sf2 \
                     /usr/share/sounds/sf2/default-GM.sf2 \
                     /usr/share/soundfonts/default.sf2 \
                     /usr/share/sounds/sf2/FluidR3_GM.sf2; do
      if [ -f "$candidate" ]; then bank="$candidate"; break; fi
    done
    if [ -n "$bank" ] && command -v fluidsynth >/dev/null; then
      fluidsynth -ni -F "$out/audition.wav" -r 48000 -g 0.6 -T wav \
        "$bank" "$out/audition.mid" >/dev/null
      echo "wrote $out/audition.wav"
    else
      echo "no fluidsynth or General MIDI bank; the MIDI file is there to play"
    fi

# The screen is cycled from here rather than from the test: an app cannot lock
# its own screen, and the test runs on the device where `adb` does not exist.
# The test watches its own lifecycle to prove the locking really happened, and
# fails if it did not (docs/rules/android-audio.md §7).
#
#   just soak            # three minutes, a lock every twenty seconds
#   just soak 90 20      # the full set §10 asks for

# §10's M8 acceptance: a set that survives the screen locking, on Android.
soak MINUTES="3" CYCLE="20" DEVICE="emulator-5554":
    #!/usr/bin/env bash
    set -euo pipefail
    bank=""
    for candidate in /usr/share/sounds/sf2/TimGM6mb.sf2 \
                     /usr/share/sounds/sf2/default-GM.sf2 \
                     /usr/share/soundfonts/default.sf2; do
      if [ -f "$candidate" ]; then bank="$candidate"; break; fi
    done
    remote=/data/local/tmp/bandstand-test.sf2
    if [ -n "$bank" ]; then
      adb -s '{{DEVICE}}' push "$bank" "$remote" >/dev/null
      adb -s '{{DEVICE}}' shell chmod 644 "$remote"
    fi

    # Wake the screen before anything starts. A set begins with the player
    # looking at the tablet, and Android correctly restricts a *backgrounded*
    # app from taking audio focus and starting a foreground service. Asking
    # from a locked screen is not the scenario §10 describes, and the first
    # attempt at this failed exactly that way: a rebuild ran long enough for
    # the cycler to lock the screen before the test asked.
    adb -s '{{DEVICE}}' shell input keyevent 224 >/dev/null 2>&1 || true

    seconds=$(( {{MINUTES}} * 60 + 300 ))
    (
      # Wait for the app to be up, then for playback to start, before touching
      # the screen. A build on a cold tree takes minutes and a fixed delay
      # would either race it or waste the soak.
      for _ in $(seq 1 900); do
        if adb -s '{{DEVICE}}' shell pidof dev.bandstand >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      sleep 25
      end=$(( $(date +%s) + seconds ))
      while [ "$(date +%s)" -lt "$end" ]; do
        adb -s '{{DEVICE}}' shell input keyevent 26 >/dev/null 2>&1 || true
        sleep {{CYCLE}}
      done
    ) &
    cycler=$!
    # Leave the screen on however the loop ends, and never leave it running.
    trap 'kill $cycler 2>/dev/null || true; \
          adb -s "{{DEVICE}}" shell input keyevent 224 >/dev/null 2>&1 || true' EXIT

    cd '{{app_dir}}'
    logs='{{justfile_directory()}}/build/integration-logs'
    mkdir -p "$logs"
    flutter test integration_test/soak_test.dart -d '{{DEVICE}}' \
      --timeout none \
      --dart-define=BANDSTAND_SOUNDFONT="$remote" \
      --dart-define=BANDSTAND_SOAK_MINUTES='{{MINUTES}}' \
      --dart-define=BANDSTAND_SOAK_CYCLE_SECONDS='{{CYCLE}}' \
      2>&1 | tee "$logs/soak.log"
    grep -q 'All tests passed' "$logs/soak.log"

# §5.2 names the Unofficial MusicXML Test Suite as the importer's acceptance
# corpus — about 165 files, data rather than code so no licence question. It is
# fetched rather than vendored, into the git-ignored build/, the same
# discipline as the soundfont: a third-party corpus is a thing to point at.
#
# The importer tests skip with a message when it is absent.

# Fetch the MusicXML acceptance corpus (§5.2).
fetch-musicxml-suite:
    #!/usr/bin/env bash
    set -euo pipefail
    out='{{justfile_directory()}}/build/musicxml-suite'
    if [ -n "$(ls -A "$out"/*.xml 2>/dev/null)" ]; then
      echo "already there: $(ls "$out"/*.xml | wc -l) files"
      exit 0
    fi
    mkdir -p "$out"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    echo "fetching LilyPond's regression tree, which carries the suite..."
    curl -sSL -o "$work/lilypond.tar.gz" \
      https://codeload.github.com/lilypond/lilypond/tar.gz/refs/heads/master
    tar xzf "$work/lilypond.tar.gz" -C "$work" --strip-components=3 \
      lilypond-master/input/regression/musicxml
    mv "$work"/musicxml/* "$out"/
    echo "$(ls "$out"/*.xml | wc -l) files in $out"

# Tests for the standalone tools.
tools-check:
    cd {{justfile_directory()}}/tools/tiling_probe && dart pub get && dart analyze && dart test
    cd {{justfile_directory()}}/tools/corpus_import && flutter pub get && dart analyze && dart test

# Format everything.
fmt:
    cd {{rust_dir}} && cargo fmt --all
    cd {{app_dir}} && dart format lib test integration_test

# The §11.3 benchmark suite: every §3 budget, measured together.
#
# Run before a milestone sign-off. Pass a heading to record the run:
#   just bench "M9 — exporters"
# which appends the numbers to docs/benchmarks.md. Without one they only print.
#
# Cold start needs a release bundle and a display; `just build-linux` first.
bench heading="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n '{{heading}}' ]; then
      '{{justfile_directory()}}/benchmarks/run.sh' --append '{{heading}}'
    else
      '{{justfile_directory()}}/benchmarks/run.sh'
    fi
