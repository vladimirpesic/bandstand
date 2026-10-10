# Bandstand — cross-language build and test.
#
# `just` from the repo root. Everything here must work on Ubuntu with the
# toolchain of §12.1 (every §N in this file is indexed in docs/ARCHITECTURE.md).

app_dir := justfile_directory() / "app"
rust_dir := justfile_directory() / "rust"

# List the recipes.
default:
    @just --list

# Everything a pre-commit hook should run (§12).
check: rust-check dart-check

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

# Check the packaged native libraries are 16 KB page aligned. The debug APK is
# the default — the cheapest carrier of the property — but any built APK can
# be named: CI passes the release APK it just built
# (`just android-check build/app/outputs/flutter-apk/app-release.apk`).
android-check apk="build/app/outputs/flutter-apk/app-debug.apk":
    #!/usr/bin/env bash
    set -euo pipefail
    cd '{{app_dir}}'
    apk='{{apk}}'
    if [ ! -f "$apk" ]; then
      if [ "$apk" = build/app/outputs/flutter-apk/app-debug.apk ]; then
        flutter build apk --debug
      else
        echo "no APK at app/$apk — build it first" >&2
        exit 1
      fi
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
    # device contend for it (F-01). Blocking, not failing: the second run
    # waits its turn.
    exec 9>"$logs/device-linux.lock"
    flock 9 || exit 1
    status=0
    for suite in audio_engine platform_audio; do
      echo "--- $suite ---"
      if ! flutter test "integration_test/${suite}_test.dart" -d linux \
             2>&1 | tee "$logs/$suite.log"; then
        status=1
      fi
      if grep -q 'Some tests failed' "$logs/$suite.log"; then
        status=1
        kept="$logs/FAILED-$suite-$(date +%Y%m%d-%H%M%S).log"
        cp "$logs/$suite.log" "$kept"
        echo "    (failed — kept at $kept)"
      fi
    done
    exit $status

# §5.2 names the Unofficial MusicXML Test Suite as the importer's acceptance
# corpus — about 165 files, data rather than code so no licence question. It is
# fetched rather than vendored, into the git-ignored build/: a third-party
# corpus is a thing to point at, not to ship.
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

# Format everything.
fmt:
    cd {{rust_dir}} && cargo fmt --all
    cd {{app_dir}} && dart format lib test integration_test
