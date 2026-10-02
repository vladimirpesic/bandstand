import 'dart:math';

import 'harmony.dart';
import 'midi.dart';
import 'tiler.dart';

/// How the probe's MIDI file is put together.
class RenderOptions {
  const RenderOptions({
    this.tempoBpm = 132,
    this.guideChords = true,
    this.click = false,
    this.humanize = false,
    this.seed = 1,
  });

  /// Tempo in beats per minute. 132 is an ordinary medium-swing walking tempo.
  final double tempoBpm;

  /// Whether to write a sustained guide-chord track, so the harmony is audible
  /// under the bass. Not a voicing engine — that is M7 — just root, third and
  /// seventh, quietly.
  final bool guideChords;

  /// Whether to write a hi-hat on every beat.
  final bool click;

  /// Whether to apply seeded timing and velocity jitter.
  ///
  /// Off by default: M0.5 asks whether *tiling* sounds musical, and
  /// humanisation would confound the answer in both directions. The flag exists
  /// so the two can be compared by ear.
  final bool humanize;

  /// RNG seed. Determinism is a hard requirement (§6.2, §11.2).
  final int seed;
}

/// MIDI channels, and the General MIDI programs on them.
const int _bassChannel = 0;
const int _guideChannel = 1;
const int _drumChannel = 9;
const int _acousticBassProgram = 32;
const int _electricPianoProgram = 4;
const int _closedHiHat = 42;

/// Render a tiling over a progression to a Standard MIDI File.
MidiFile renderTiling({
  required Tiling tiling,
  required Progression progression,
  required int formBars,
  RenderOptions options = const RenderOptions(),
}) {
  if (formBars <= 0) {
    throw ArgumentError.value(formBars, 'formBars', 'must be positive');
  }
  final random = Random(options.seed);
  final file = MidiFile();

  final conductor = file.addTrack('Bandstand tiling probe')
    ..tempo(options.tempoBpm)
    ..timeSignature(4, 4);
  for (var bar = 0; bar < progression.barCount; bar += formBars) {
    conductor.marker(
      'Chorus ${bar ~/ formBars + 1}',
      tick: bar * 4 * ticksPerQuarter,
    );
  }

  final bass = file.addTrack('Walking bass')
    ..program(_bassChannel, _acousticBassProgram);
  for (final note in tiling.notes()) {
    final jitterTicks = options.humanize ? random.nextInt(13) - 6 : 0;
    final jitterVelocity = options.humanize ? random.nextInt(13) - 6 : 0;
    final startTick = max(
      0,
      (note.beat * ticksPerQuarter).round() + jitterTicks,
    );
    bass.note(
      channel: _bassChannel,
      pitch: note.pitch,
      velocity: note.velocity + jitterVelocity,
      startTick: startTick,
      durationTicks: (note.durationBeats * ticksPerQuarter).round(),
    );
  }

  if (options.guideChords) {
    final guide = file.addTrack('Guide chords')
      ..program(_guideChannel, _electricPianoProgram);
    for (var bar = 0; bar < progression.barCount; bar++) {
      final chord = progression.bars[bar];
      if (bar > 0 && progression.bars[bar - 1] == chord) {
        continue; // Let a held chord ring rather than restriking it.
      }
      var heldBars = 1;
      while (bar + heldBars < progression.barCount &&
          progression.bars[bar + heldBars] == chord) {
        heldBars++;
      }
      for (final pitch in _guideVoicing(chord)) {
        guide.note(
          channel: _guideChannel,
          pitch: pitch,
          velocity: 52,
          startTick: bar * 4 * ticksPerQuarter,
          durationTicks: (heldBars * 4 * ticksPerQuarter * 0.97).round(),
        );
      }
    }
  }

  if (options.click) {
    final drums = file.addTrack('Click');
    for (var beat = 0; beat < progression.barCount * 4; beat++) {
      drums.note(
        channel: _drumChannel,
        pitch: _closedHiHat,
        velocity: beat % 4 == 0 ? 78 : 54,
        startTick: beat * ticksPerQuarter,
        durationTicks: ticksPerQuarter ~/ 4,
      );
    }
  }

  return file;
}

/// Root, third and seventh, placed just above the bass register.
///
/// Deliberately not a voicing engine (§6.5 item 4, M7). It exists so the
/// listener hears the harmony the bass is walking over.
List<int> _guideVoicing(Chord chord) {
  final tones = chord.quality.chordTones;
  final root = 48 + chord.rootPitchClass;
  return <int>[root, root + tones[1], root + tones[3]];
}
