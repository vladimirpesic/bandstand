import 'package:bandstand/domain/generation/bass/bass_corpus.dart';
import 'package:bandstand/domain/generation/bass/root_profile.dart';
import 'package:bandstand/domain/generation/bass/wbp_source.dart';
import 'package:bandstand/io/midi/midi_file.dart';

import 'annotation.dart';

/// Why a candidate slice was not kept.
enum RejectionReason {
  /// It had no notes at all — a bar of rest.
  empty,

  /// It did not open on the root of its first chord (§5 constraint 1).
  doesNotStartOnRoot,

  /// It did not close on a chord tone (§5 constraint 2).
  doesNotEndOnChordTone,

  /// It could not be transposed to every root inside the instrument (§8).
  cannotReachEveryRoot,

  /// Another slice already carried exactly these notes over these chords.
  duplicate,
}

/// A slice the importer looked at and did not keep.
class Rejection {
  /// Create a rejection.
  const Rejection(this.startBar, this.lengthBars, this.reason);

  /// The bar it started at, zero-based.
  final int startBar;

  /// How many bars it covered.
  final int lengthBars;

  /// Why it was dropped.
  final RejectionReason reason;

  @override
  String toString() =>
      'bars ${startBar + 1}–${startBar + lengthBars}: ${reason.name}';
}

/// What one import produced.
class ImportResult {
  /// Create a result.
  ImportResult(this.corpus, List<Rejection> rejections)
    : rejections = List<Rejection>.unmodifiable(rejections);

  /// The phrases harvested.
  final BassCorpus corpus;

  /// Everything that was looked at and dropped, with the reason.
  ///
  /// Reported rather than swallowed: a take that yields three phrases from
  /// thirty-two bars usually means the annotation is out of step with the
  /// recording, and silence about that would be the worst possible outcome.
  final List<Rejection> rejections;

  /// How many slices were dropped for each reason.
  Map<RejectionReason, int> get rejectionCounts {
    final counts = <RejectionReason, int>{};
    for (final rejection in rejections) {
      counts[rejection.reason] = (counts[rejection.reason] ?? 0) + 1;
    }
    return counts;
  }
}

/// Harvests source phrases from a recorded take (§6.4).
///
/// Every 1-, 2- and 4-bar window of the take is a candidate; the ones that
/// satisfy `docs/rules/corpus-tiling.md` §5 are kept. A player recording
/// thirty-two bars over a chart therefore contributes far more than eight
/// phrases, which is what makes building a corpus by playing rather than by
/// typing worth doing.
class CorpusSlicer {
  /// Create a slicer.
  const CorpusSlicer({this.lengths = const <int>[1, 2, 4]});

  /// The phrase lengths to harvest, in bars.
  final List<int> lengths;

  /// Slice `midi` against `annotation`.
  ImportResult slice(MidiFileData midi, ChordAnnotation annotation) {
    final notes = _notes(midi, annotation);
    final kept = <WbpSource>[];
    final rejections = <Rejection>[];
    final seen = <String>{};

    for (final length in lengths) {
      for (var bar = 0; bar + length <= annotation.barCount; bar++) {
        final result = _slice(notes, annotation, bar, length, seen);
        switch (result) {
          case final WbpSource phrase:
            kept.add(phrase);
          case final RejectionReason reason:
            rejections.add(Rejection(bar, length, reason));
          case _:
            break;
        }
      }
    }

    return ImportResult(
      BassCorpus(name: annotation.name, phrases: kept, range: annotation.range),
      rejections,
    );
  }

  /// A [WbpSource] if the window is usable, otherwise a [RejectionReason].
  Object _slice(
    List<_Note> notes,
    ChordAnnotation annotation,
    int bar,
    int length,
    Set<String> seen,
  ) {
    final beatsPerBar = annotation.beatsPerBar;
    final start = (bar * beatsPerBar).toDouble();
    final end = ((bar + length) * beatsPerBar).toDouble();
    final inWindow = notes
        .where((note) => note.beat >= start - 1e-6 && note.beat < end - 1e-6)
        .toList();
    if (inWindow.isEmpty) {
      return RejectionReason.empty;
    }

    final harmony = <BassChordSpan>[
      for (var i = 0; i < length; i++)
        BassChordSpan(
          (i * beatsPerBar).toDouble(),
          beatsPerBar.toDouble(),
          annotation.bars[bar + i],
        ),
    ];
    final specs = <BassNoteSpec>[
      for (final note in inWindow)
        BassNoteSpec(
          beat: note.beat - start,
          pitch: note.pitch,
          // A note held past the window is cut at it: the phrase has to be
          // playable on its own, and a tail into a chord it was not played
          // over is not part of it.
          durationBeats: (note.duration).clamp(0.01, end - note.beat),
          velocity: note.velocity,
        ),
    ];

    // The identity of a slice is its notes over its profile — the same lick
    // played twice over the same changes is one phrase, however many bars
    // apart it happened. Duration is part of that identity: two windows with
    // the same onsets and intervals but different note lengths are a walking
    // line and a series of held roots, which are not the same phrase.
    final profile = RootProfile.of(harmony);
    final fingerprint =
        '$profile|${specs.map((n) => '${n.beat.toStringAsFixed(3)}:'
            '${n.pitch - specs.first.pitch}:'
            '${n.durationBeats.toStringAsFixed(3)}').join(',')}';
    if (seen.contains(fingerprint)) {
      return RejectionReason.duplicate;
    }

    final phrase = WbpSource(
      name: '${annotation.name} ${bar + 1}+$length',
      harmony: harmony,
      notes: specs,
      tags: annotation.tags,
      tempoRange: annotation.tempoRange,
      range: annotation.range,
    );
    if (!phrase.startsOnRoot) {
      return RejectionReason.doesNotStartOnRoot;
    }
    if (!phrase.endsOnChordTone) {
      return RejectionReason.doesNotEndOnChordTone;
    }
    if (phrase.reachableRootCount != 12) {
      return RejectionReason.cannotReachEveryRoot;
    }
    // Recorded only now that the phrase is kept. Adding it before the
    // constraint checks let a rejected window poison the set, so a later
    // window carrying the same notes was reported as `duplicate` when it had
    // in fact been rejected for its own reason — and the rejection report is
    // the whole point of the tool.
    seen.add(fingerprint);
    return phrase;
  }

  /// The take's notes, in beats, from the chosen track.
  List<_Note> _notes(MidiFileData midi, ChordAnnotation annotation) {
    final events = annotation.track == null
        ? midi.allEvents
        : (annotation.track! < midi.tracks.length
              ? midi.tracks[annotation.track!].events
              : throw ArgumentError(
                  'the annotation asks for track ${annotation.track}, but the '
                  'file has ${midi.tracks.length}',
                ));

    final ppq = midi.ticksPerQuarter;
    final open = <int, ({double beat, int velocity})>{};
    final notes = <_Note>[];
    for (final event in events) {
      final beat = event.tick / ppq;
      if (event.isNoteOn) {
        // A second note-on for a pitch already sounding closes the first: a
        // monophonic take should not have them, and guessing is better than
        // dropping the note.
        final previous = open.remove(event.data1);
        if (previous != null) {
          notes.add(
            _Note(
              previous.beat,
              beat - previous.beat,
              event.data1,
              previous.velocity,
            ),
          );
        }
        open[event.data1] = (beat: beat, velocity: event.data2);
      } else if (event.isNoteOff) {
        final started = open.remove(event.data1);
        if (started != null) {
          notes.add(
            _Note(
              started.beat,
              beat - started.beat,
              event.data1,
              started.velocity,
            ),
          );
        }
      }
    }
    // A note still sounding at the end of the file gets a beat, so a take that
    // was trimmed short still yields its last phrase.
    for (final entry in open.entries) {
      notes.add(_Note(entry.value.beat, 1, entry.key, entry.value.velocity));
    }
    notes.sort((a, b) => a.beat.compareTo(b.beat));
    return notes;
  }
}

class _Note {
  const _Note(this.beat, this.duration, this.pitch, this.velocity);
  final double beat;
  final double duration;
  final int pitch;
  final int velocity;
}
