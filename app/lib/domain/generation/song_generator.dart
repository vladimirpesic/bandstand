import '../phrase/note_event.dart';
import '../phrase/phrase.dart';
import '../song/rhythm.dart';
import '../song/song.dart';
import '../song/song_chord_sequence.dart';
import '../song/ticks.dart';
import 'generation_context.dart';
import 'music_generator.dart';
import 'written_part_placer.dart';

/// One voice's finished part, placed in the song.
class GeneratedVoice {
  /// Create a generated voice.
  const GeneratedVoice({
    required this.voice,
    required this.phrase,
    required this.channel,
  });

  /// Which instrument.
  final RhythmVoice voice;

  /// Its notes, positioned in **quarter notes** from the start of the song.
  ///
  /// Quarters, not beats, and this is the one place in the pipeline where that
  /// is true. A generator writes in the beats of the meter it was handed — an
  /// eighth in 6/8 — and every part is converted here, once, as it joins the
  /// song. The song timeline has to have a single unit: parts in different
  /// meters each carrying their own made the accumulated phrase mean nothing,
  /// and quarters is the unit `totalQuarters`, `lengthTicks`, the tempo map
  /// and MIDI all already count in.
  final Phrase phrase;

  /// The MIDI channel it plays on.
  final int channel;
}

/// A whole song, generated.
class GeneratedSong {
  /// Create a result.
  GeneratedSong({
    required List<GeneratedVoice> voices,
    required this.totalQuarters,
    required this.ppq,
    required List<String> problems,
  }) : voices = List<GeneratedVoice>.unmodifiable(voices),
       problems = List<String>.unmodifiable(problems);

  /// The parts, one per voice.
  final List<GeneratedVoice> voices;

  /// How long the song lasts, in quarter notes.
  final double totalQuarters;

  /// Ticks per quarter note.
  final int ppq;

  /// Anything that stopped a voice being generated.
  final List<String> problems;

  /// How many notes were written in total.
  int get noteCount =>
      voices.fold(0, (sum, voice) => sum + voice.phrase.length);

  /// Whether anything at all was written.
  bool get isEmpty => noteCount == 0;

  /// How long the song lasts, in ticks.
  int get lengthTicks => (totalQuarters * ppq).ceil();
}

/// Runs the generation pipeline of §6.1.
///
/// Rules: `docs/rules/generation-pipeline.md`. Pure, seeded, and allocation-
/// light: §3 gives it 100 ms for a whole song.
class SongGenerator {
  /// Create a pipeline over the generators available.
  SongGenerator(Iterable<MusicGenerator> generators)
    : _generators = <String, MusicGenerator>{
        for (final generator in generators) generator.id: generator,
      };

  final Map<String, MusicGenerator> _generators;

  /// The generators installed.
  Iterable<MusicGenerator> get generators => _generators.values;

  /// The generator with this id, or null.
  MusicGenerator? operator [](String id) => _generators[id];

  /// Generate a whole song.
  ///
  /// `seed` makes every random choice reproducible; changing it is the "reroll"
  /// button of §6.2.
  GeneratedSong generate(
    Song song, {
    int seed = 0,
    int ppq = kTicksPerQuarter,
  }) {
    final sequence = SongChordSequence.of(song);
    final problems = <String>[
      for (final problem in sequence.problems) '$problem',
    ];
    if (sequence.bars.isEmpty) {
      return GeneratedSong(
        voices: const <GeneratedVoice>[],
        totalQuarters: 0,
        ppq: ppq,
        problems: problems,
      );
    }

    final parts = song.structure.songParts;
    final byVoice = <String, _VoiceAccumulator>{};

    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      final generator = _generators[part.rhythmId];
      if (generator == null) {
        problems.add(
          'no generator called "${part.rhythmId}" for '
          '${part.displayName}',
        );
        continue;
      }
      final bars = sequence.barsOfPart(index);
      if (bars.isEmpty) {
        continue;
      }

      final context = GenerationContext.forPart(
        sequence: sequence,
        partIndex: index,
        partCount: parts.length,
        part: part,
        tempo: song.tempo,
        // The seed is mixed with the part, so editing one part does not reroll
        // the others (`docs/rules/generation-pipeline.md` §2).
        randomSeed: seed ^ (index * 2654435761),
      );

      final generated = generator.generate(context);
      for (final problem in generated.problems) {
        problems.add('${part.displayName}: $problem');
      }
      // A part plays one section, and a section carries one meter, so every
      // bar of a part is in the same meter and one beat length converts all of
      // them. The context reports a single time signature on the same
      // reasoning; if the domain ever grows per-bar meters, both have to be
      // revisited together, and this is where it will be noticed.
      final beatLength = bars.first.timeSignature.beatDurationInQuarters;
      assert(
        bars.every(
          (bar) => bar.timeSignature.beatDurationInQuarters == beatLength,
        ),
        'a song part spans a meter change, which the one beat grid a '
        'generation context carries cannot express',
      );

      generated.phrases.forEach((voice, phrase) {
        final accumulator = byVoice.putIfAbsent(
          voice.id,
          () => _VoiceAccumulator(voice),
        );
        accumulator.add(
          _inQuarters(phrase, beatLength, bars.first.startQuarters),
        );
      });
    }

    // Written parts join here rather than in the loop above: a part is played
    // over whatever backing was chosen, not written by the generator that chose
    // it, so rerolling the bass cannot touch the melody
    // (`docs/rules/written-parts.md` §3). A muted part is not placed at all —
    // it would only be silenced downstream, and the notes cost time and memory.
    for (final part in song.writtenParts) {
      if (part.muted || part.isEmpty) {
        continue;
      }
      final phrase = WrittenPartPlacer.place(part, sequence);
      if (phrase.isEmpty) {
        problems.add(
          '${part.displayName}: nothing in this arrangement plays any bar it '
          'is written in',
        );
        continue;
      }
      byVoice
          .putIfAbsent(
            WrittenPartPlacer.voiceFor(part).id,
            () => _VoiceAccumulator(WrittenPartPlacer.voiceFor(part)),
          )
          .add(phrase);
    }

    final voices = <GeneratedVoice>[];
    final assigned = <int>{};
    var nextChannel = 0;
    for (final accumulator in byVoice.values) {
      final voice = accumulator.voice;
      int channel;
      if (voice.isDrums) {
        // General MIDI percussion is channel 10 however many drum voices the
        // arrangement names.
        channel = 9;
      } else {
        final preferred = voice.preferredChannel;
        if (preferred != null &&
            preferred != 9 &&
            !assigned.contains(preferred)) {
          channel = preferred;
        } else {
          channel = _nextFreeChannel(nextChannel, assigned);
          if (channel < 0) {
            problems.add(
              'ran out of MIDI channels: '
              '"${voice.displayName}" shares channel 15',
            );
            channel = 15;
          }
        }
        assigned.add(channel);
        nextChannel = channel + 1;
      }
      voices.add(
        GeneratedVoice(
          voice: voice,
          phrase: accumulator.phrase.onChannel(channel, drums: voice.isDrums),
          channel: channel,
        ),
      );
    }

    return GeneratedSong(
      voices: voices,
      totalQuarters: sequence.totalQuarters,
      ppq: ppq,
      problems: problems,
    );
  }

  /// The next channel that is free and not the drum channel, or -1 when
  /// every channel is taken.
  static int _nextFreeChannel(int from, Set<int> assigned) {
    for (var channel = from; channel <= 15; channel++) {
      if (channel != 9 && !assigned.contains(channel)) {
        return channel;
      }
    }
    return -1;
  }
}

/// Collects one voice's parts as the pipeline walks the arrangement.
/// `phrase`, converted from a part's written beats into quarter notes and
/// placed at `startQuarters` on the song timeline.
///
/// The one unit conversion between a generator's output and the song. It has to
/// happen exactly once: doing it in the generators would make every one of them
/// responsible for a unit none of them cares about, and not doing it at all
/// left a 6/8 part playing at half speed and a mixed-meter song with its bars
/// out of order.
///
/// A plain [Phrase], not a [SizedPhrase]: the accumulator keeps only the notes,
/// and a scaled phrase's old `beatRange` would silently drop the ones that no
/// longer fall inside it.
Phrase _inQuarters(Phrase phrase, double beatLength, double startQuarters) =>
    Phrase(
      channel: phrase.channel,
      isDrums: phrase.isDrums,
      notes: <NoteEvent>[
        for (final note in phrase.notes)
          note.copyWith(
            positionInBeats: startQuarters + note.positionInBeats * beatLength,
            beatDuration: note.beatDuration * beatLength,
          ),
      ],
    );

class _VoiceAccumulator {
  _VoiceAccumulator(this.voice)
    : phrase = Phrase.empty(
        channel: voice.preferredChannel ?? 0,
        isDrums: voice.isDrums,
      );

  final RhythmVoice voice;
  Phrase phrase;

  void add(Phrase part) {
    phrase = phrase.withNotes(part.notes);
  }
}

/// A note with its channel, for callers that want the flat list.
extension GeneratedSongNotes on GeneratedSong {
  /// Every note, with the channel it plays on, in time order.
  List<({int channel, NoteEvent note})> get allNotes {
    final all = <({int channel, NoteEvent note})>[
      for (final voice in voices)
        for (final note in voice.phrase.notes)
          (channel: voice.channel, note: note),
    ]..sort((a, b) => a.note.positionInBeats.compareTo(b.note.positionInBeats));
    return all;
  }
}
