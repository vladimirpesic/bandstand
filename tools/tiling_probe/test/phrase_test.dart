import 'package:test/test.dart';
import 'package:tiling_probe/phrase.dart';

void main() {
  test('lengthBars honours a non-4/4 beatsPerBar', () {
    final phrase = BassPhrase.walking(
      name: '3/4 walking',
      chordsPerBar: <String>['Cmaj7', 'Cmaj7'],
      pitches: <int>[36, 40, 43, 36, 40, 43],
      beatsPerBar: 3,
    );
    expect(phrase.lengthBeats, 6);
    // 6 beats at three to the bar is two bars, not one.
    expect(phrase.lengthBars, 2);
  });

  test('lengthBars still measures a 4/4 phrase in bars', () {
    final phrase = BassPhrase.walking(
      name: '4/4 walking',
      chordsPerBar: <String>['Dm7', 'G7'],
      pitches: <int>[38, 41, 45, 48, 47, 45, 43, 41],
    );
    expect(phrase.lengthBeats, 8);
    expect(phrase.lengthBars, 2);
  });
}
