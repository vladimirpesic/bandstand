import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/domain/song/practice_session.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_chord_sequence.dart';
import 'package:bandstand/domain/song/ticks.dart';
import 'package:bandstand/state/generation_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What a running practice session looks like from outside.
class PracticeState {
  /// Create a state.
  const PracticeState({
    this.session,
    this.chorus = 0,
    this.running = false,
    this.plan,
    this.busy = false,
    this.errorMessage,
  });

  /// The plan, or null when practice is off.
  final PracticeSession? session;

  /// Which chorus is playing, from zero.
  final int chorus;

  /// Whether the session is advancing.
  final bool running;

  /// What the current chorus is being played at.
  final ChorusPlan? plan;

  /// True while regenerating for a key change.
  final bool busy;

  /// The last failure, or null.
  final String? errorMessage;

  /// Whether a session is configured at all.
  bool get isConfigured => session != null;

  /// A copy with some fields replaced.
  PracticeState copyWith({
    PracticeSession? session,
    int? chorus,
    bool? running,
    ChorusPlan? plan,
    bool? busy,
    String? errorMessage,
    bool clearError = false,
    bool clearSession = false,
  }) => PracticeState(
    session: clearSession ? null : (session ?? this.session),
    chorus: chorus ?? this.chorus,
    running: running ?? this.running,
    plan: clearSession ? null : (plan ?? this.plan),
    busy: busy ?? this.busy,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
}

/// The transport calls a practice session makes.
///
/// One seam rather than top-level calls, for the reason `AudioEngineBridge`
/// exists: the controller's own logic — which chorus applies when, what a
/// stop restores — is worth testing, and none of it needs a running engine.
/// Without this the tests could not reach `stop` at all, because the bridge
/// throws until `RustLib.init()` has run.
class PracticeTransport {
  /// The real transport, over flutter_rust_bridge.
  const PracticeTransport();

  /// Set the loop region, in ticks.
  Future<void> setLoop({
    required bool enabled,
    required BigInt startTick,
    required BigInt endTick,
  }) => transportSetLoop(
    enabled: enabled,
    startTick: startTick,
    endTick: endTick,
  );

  /// Move the playhead.
  Future<void> seek({required double tick}) => transportSeek(tick: tick);

  /// Set a single constant tempo.
  Future<void> setTempo({required double bpm}) => transportSetTempo(bpm: bpm);
}

/// Drives a [PracticeSession] against the transport.
///
/// Rules: `docs/rules/practice.md` §5. The session computes; this pushes the
/// result at the engine. The split is what lets a twenty-minute ramp be tested
/// in milliseconds without an audio device.
class PracticeController extends Notifier<PracticeState> {
  /// Create a controller, optionally over a stand-in transport.
  PracticeController({this.transport = const PracticeTransport()});

  /// The transport this session drives. Replaced in tests.
  final PracticeTransport transport;

  @override
  PracticeState build() => const PracticeState();

  /// Begin a session over `song`, from the first chorus.
  Future<void> start(PracticeSession session, Song song) async {
    state = PracticeState(session: session, running: true);
    await _applyChorus(0, song, regenerate: true);
  }

  /// Stop practising. The song is left exactly as it was written (§3.4).
  Future<void> stop(Song song) async {
    final wasTransposed = (state.plan?.transposition ?? 0) != 0;
    state = const PracticeState();
    await transport.setLoop(
      enabled: false,
      startTick: BigInt.zero,
      endTick: BigInt.zero,
    );
    if (wasTransposed) {
      // Put the band back in the written key, so stopping practice does not
      // leave the app playing something the chart does not say.
      await ref.read(songPlaybackProvider.notifier).generateAndLoad(song);
    }
    // Unconditionally, not only after a transposition. `_applyChorus` sets the
    // tempo on every chorus, so a tempo ramp with no key change left the
    // transport at the last chorus's tempo — the one case the guard above was
    // blind to, and the commonest kind of practice session there is.
    await transport.setTempo(bpm: song.tempo.toDouble());
  }

  /// Move to the next chorus, applying whatever it changes.
  ///
  /// Called at a chorus boundary — tempo never changes mid-chorus (§2).
  Future<void> advance(Song song) async {
    if (!state.running || state.session == null || state.busy) {
      return;
    }
    await _applyChorus(state.chorus + 1, song, regenerate: false);
  }

  /// Jump to a chorus, for the practice screen's scrubber.
  Future<void> goTo(int chorus, Song song) async {
    if (state.session == null || chorus < 0 || state.busy) {
      return;
    }
    await _applyChorus(chorus, song, regenerate: false);
  }

  Future<void> _applyChorus(
    int chorus,
    Song song, {
    required bool regenerate,
  }) async {
    final session = state.session;
    if (session == null) {
      return;
    }
    final previous = state.plan;
    try {
      final plan = session.planFor(
        chorus,
        formBars: SongChordSequence.of(song).barCount,
      );

      state = state.copyWith(
        chorus: chorus,
        plan: plan,
        busy: true,
        clearError: true,
      );
      // §5 — a key change forces a regeneration. The bass tiling is valid in
      // the new key because a root profile is transposition-invariant, but the
      // octave choice is not: the register band is absolute, and transposing
      // the notes walks the bass out of it.
      if (regenerate || plan.differsInKeyFrom(previous)) {
        final transposed = plan.transposition == 0
            ? song
            : song.transposed(plan.transposition);
        await ref
            .read(songPlaybackProvider.notifier)
            .generateAndLoad(transposed);
      }

      await transport.setTempo(bpm: plan.tempo.toDouble());
      await _applyLoop(plan, song);
      state = state.copyWith(busy: false);
    } catch (error) {
      // A failure before the plan was worked out — `planFor` itself throwing
      // on chorus 0 — left `running: true` with no plan at all: a session the
      // UI shows as under way and cannot describe. There is nothing to run
      // without a plan, so the session ends and says why.
      if (state.plan == null) {
        state = PracticeState(errorMessage: error.toString());
        return;
      }
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  /// Push the loop range at the transport, in ticks.
  Future<void> _applyLoop(ChorusPlan plan, Song song) async {
    final loop = plan.loop;
    if (loop == null) {
      await transport.setLoop(
        enabled: false,
        startTick: BigInt.zero,
        endTick: BigInt.zero,
      );
      return;
    }
    final sequence = SongChordSequence.of(song);
    final bars = sequence.bars;
    if (bars.isEmpty || loop.firstBar >= bars.length) {
      await transport.setLoop(
        enabled: false,
        startTick: BigInt.zero,
        endTick: BigInt.zero,
      );
      return;
    }
    // §4 — the range is in written bars, resolved through the same flattening
    // as everything else, so looping "bars 5–8" of a tune with a repeat loops
    // the right music.
    const ppq = kTicksPerQuarter;
    final last = loop.lastBar < bars.length ? loop.lastBar : bars.length - 1;
    final startTick = (bars[loop.firstBar].startQuarters * ppq).round();
    final endTick = (bars[last].endQuarters * ppq).round();
    await transport.setLoop(
      enabled: true,
      startTick: BigInt.from(startTick),
      endTick: BigInt.from(endTick),
    );
    await transport.seek(tick: startTick.toDouble());
  }
}

/// The practice session, if one is running.
final practiceProvider = NotifierProvider<PracticeController, PracticeState>(
  PracticeController.new,
);
