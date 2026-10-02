import '../phrase/phrase.dart';
import '../song/rhythm.dart';
import 'generation_context.dart';

/// What a generator produces for one song part.
///
/// A generator that can only return phrases has nowhere to say *"I could not
/// cover bar 12"*, and the alternatives — throwing, or an accumulator on the
/// generator — either break a shippable app or break purity. Carrying the
/// problems out with the phrases keeps `generate` a function: the same context
/// gives the same result, problems included.
class GeneratedPart {
  /// Create a result.
  GeneratedPart(
    Map<RhythmVoice, SizedPhrase> phrases, {
    List<String> problems = const <String>[],
  }) : phrases = Map<RhythmVoice, SizedPhrase>.unmodifiable(phrases),
       problems = List<String>.unmodifiable(problems);

  /// The parts written, one per voice.
  final Map<RhythmVoice, SizedPhrase> phrases;

  /// Anything the generator could not do, in words the arranger screen can
  /// show. Empty when everything went as intended.
  final List<String> problems;

  /// The phrase for a voice, or null.
  SizedPhrase? operator [](RhythmVoice voice) => phrases[voice];

  /// The voices written for.
  Iterable<RhythmVoice> get voices => phrases.keys;
}

/// Something that writes a part (§6.2).
///
/// Pure: the same context gives the same phrases, every time. That is what the
/// test strategy rests on, and what makes "reroll" a reproducible button rather
/// than a lottery.
abstract class MusicGenerator {
  /// Stable identifier, stored in a song's `rhythmId`.
  String get id;

  /// What it is called in the arrangement screen.
  String get displayName;

  /// The instruments it writes for.
  List<RhythmVoice> get voices;

  /// The knobs it offers per song part.
  List<RhythmParameterSpec> get parameters;

  /// The meter it is written for. Meter coverage is a corpus decision (§4.6).
  Rhythm get rhythm;

  /// Write one song part.
  GeneratedPart generate(GenerationContext context);
}
