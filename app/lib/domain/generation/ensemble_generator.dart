import '../phrase/phrase.dart';
import '../song/rhythm.dart';
import 'generation_context.dart';
import 'music_generator.dart';

/// Several generators playing as one band.
///
/// A [SongPart] names a single `rhythmId` (§4.3), and a rhythm in the sense of
/// §6.5 is a *style* — a way of playing a tune — not a single instrument. The
/// drum generator of M5 and the walking bass of M6 are each one instrument, so
/// something has to put them on the same stand. This is that something.
///
/// It is a composite and nothing more: it holds no musical opinion of its own,
/// delegating every note to a member. What it owns is the bookkeeping — voices
/// that must not collide, parameters that must stay tellable apart, and
/// problems that must all reach the arranger screen.
class EnsembleGenerator implements MusicGenerator {
  /// Create a band.
  ///
  /// Throws [ArgumentError] if two members write for the same voice — two
  /// generators writing a bass part would stack two lines on one channel, and
  /// the mixer has no way to tell them apart.
  EnsembleGenerator({
    required this.id,
    required this.displayName,
    required List<MusicGenerator> members,
  }) : members = List<MusicGenerator>.unmodifiable(members) {
    if (this.members.isEmpty) {
      throw ArgumentError.value(members, 'members', 'a band needs a player');
    }
    final seen = <String>{};
    for (final member in this.members) {
      for (final voice in member.voices) {
        if (!seen.add(voice.id)) {
          throw ArgumentError.value(
            voice.id,
            'members',
            'two members write for this voice',
          );
        }
      }
    }
  }

  /// Stable identifier, stored in a song's `rhythmId`.
  @override
  final String id;

  /// What the arrangement screen calls it.
  @override
  final String displayName;

  /// The players, in the order they were given.
  final List<MusicGenerator> members;

  /// Separates a member's id from a parameter's own in a namespaced key.
  static const String parameterSeparator = '.';

  @override
  List<RhythmVoice> get voices => <RhythmVoice>[
    for (final member in members) ...member.voices,
  ];

  /// Every member's parameters, namespaced by the member that owns them.
  ///
  /// Both the drums and the bass call their loudness knob `intensity`, and a
  /// flat merge would silently give one of them the other's setting.
  @override
  List<RhythmParameterSpec> get parameters => <RhythmParameterSpec>[
    for (final member in members)
      for (final parameter in member.parameters)
        RhythmParameterSpec(
          id: qualify(member.id, parameter.id),
          displayName: '${member.displayName}: ${parameter.displayName}',
          kind: parameter.kind,
          defaultValue: parameter.defaultValue,
          minimum: parameter.minimum,
          maximum: parameter.maximum,
          choices: parameter.choices,
        ),
  ];

  @override
  Rhythm get rhythm => Rhythm(
    id: id,
    displayName: displayName,
    timeSignature: members.first.rhythm.timeSignature,
    voices: voices,
    parameters: parameters,
  );

  /// The namespaced key a member's parameter is stored under.
  static String qualify(String memberId, String parameterId) =>
      '$memberId$parameterSeparator$parameterId';

  @override
  GeneratedPart generate(GenerationContext context) {
    final phrases = <RhythmVoice, SizedPhrase>{};
    final problems = <String>[];
    for (final member in members) {
      final result = member.generate(_contextFor(member, context));
      phrases.addAll(result.phrases);
      for (final problem in result.problems) {
        problems.add('${member.displayName}: $problem');
      }
    }
    return GeneratedPart(phrases, problems: problems);
  }

  /// The context a member sees: the same music, its own knobs.
  ///
  /// A member is written and tested standing alone (§6.2), so it must not have
  /// to know it is in a band. Its parameters arrive under the ids it declared,
  /// with the namespace stripped.
  GenerationContext _contextFor(
    MusicGenerator member,
    GenerationContext context,
  ) {
    final prefix = '${member.id}$parameterSeparator';
    final values = <String, Object>{
      for (final entry in context.parameterValues.entries)
        if (entry.key.startsWith(prefix))
          entry.key.substring(prefix.length): entry.value,
    };
    return GenerationContext(
      chords: context.chords,
      beatRange: context.beatRange,
      timeSignature: context.timeSignature,
      tempo: context.tempo,
      // Mixed with the member's id, so that changing the drums does not reroll
      // the bass — the same reasoning as §2 of the generation-pipeline rules,
      // one level down.
      randomSeed: context.randomSeed ^ (member.id.hashCode * 2654435761),
      parameterValues: values,
      partIndex: context.partIndex,
      partCount: context.partCount,
      isFirstPart: context.isFirstPart,
      isLastPart: context.isLastPart,
    );
  }
}
