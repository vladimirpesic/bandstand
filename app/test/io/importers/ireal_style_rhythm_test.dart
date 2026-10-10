import 'package:bandstand/domain/song/rhythm_ids.dart';
import 'package:bandstand/io/importers/ireal_style_rhythm.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which band an iReal style name asks for (`docs/rules/ireal-format.md`).
void main() {
  test('bossa and samba styles ask for the latin band', () {
    expect(IRealStyleRhythm.infer('Medium Bossa'), bossaRhythmId);
    expect(IRealStyleRhythm.infer('Bossa Nova'), bossaRhythmId);
    expect(IRealStyleRhythm.infer('Samba'), bossaRhythmId);
  });

  test('straight-eighth styles ask for the straight band', () {
    expect(IRealStyleRhythm.infer('Even 8ths'), straightRhythmId);
    expect(IRealStyleRhythm.infer('Even 16ths'), straightRhythmId);
    expect(IRealStyleRhythm.infer('Fusion'), straightRhythmId);
    expect(IRealStyleRhythm.infer('Pop Ballad'), straightRhythmId);
  });

  test('swing-family styles claim nothing and keep the default band', () {
    // A waltz style also claims nothing: a chart in three reaches the waltz
    // vocabulary through its meter, not through its style name.
    expect(IRealStyleRhythm.infer('Medium Up Swing'), isNull);
    expect(IRealStyleRhythm.infer('Ballad'), isNull);
    expect(IRealStyleRhythm.infer('Jazz Waltz'), isNull);
    expect(IRealStyleRhythm.infer('Jazz'), isNull);
    expect(IRealStyleRhythm.infer(''), isNull);
  });
}
