import 'phrase.dart';

/// The M0.5 probe corpus: twenty walking bass phrases, entered by hand.
///
/// Small on purpose. §6.3 of the plan puts the whole jjSwing walking-bass corpus
/// at 84 KB of MIDI; the question at M0.5 is not whether a large corpus works,
/// it is whether the *mechanism* works, and a corpus you can read in one screen
/// is one whose failures you can attribute.
///
/// Every phrase obeys the constraints in `docs/rules/corpus-tiling.md` §5 —
/// opens on the root, closes on a chord tone — and `corpus_test.dart` asserts
/// that, so a typo here fails a test rather than becoming a mystery in the
/// audio.
///
/// Coverage is three two-bar shapes and two four-bar ones:
///
/// | Shape | Root profile | Variants |
/// |---|---|---|
/// | `Imaj7 | VI7` | `+0maj7 +9dom7` | 5 |
/// | `ii7 | V7` | `+0m7 +5dom7` | 6 |
/// | `Imaj7` held | `+0maj7 +0maj7` | 4 |
/// | `I VI ii V` | `+0maj7 +9dom7 +2m7 +7dom7` | 3 |
/// | `ii V I I` | `+0m7 +5dom7 +10maj7 +10maj7` | 2 |
List<BassPhrase> probeCorpus() => <BassPhrase>[
  // ---- ii–V, written over Dm7 | G7 -----------------------------------
  BassPhrase.walking(
    name: 'ii-V up the chord, down the scale',
    chordsPerBar: <String>['Dm7', 'G7'],
    pitches: <int>[38, 41, 45, 48, 47, 45, 43, 41],
    tags: <String>{'walking', 'arpeggio'},
  ),
  BassPhrase.walking(
    name: 'ii-V chromatic into the five',
    chordsPerBar: <String>['Dm7', 'G7'],
    pitches: <int>[38, 40, 41, 42, 43, 45, 47, 50],
    tags: <String>{'walking', 'chromatic', 'ascending'},
  ),
  BassPhrase.walking(
    name: 'ii-V descending',
    chordsPerBar: <String>['Dm7', 'G7'],
    pitches: <int>[50, 48, 45, 41, 43, 41, 40, 38],
    tags: <String>{'walking', 'descending'},
  ),
  BassPhrase.walking(
    name: 'ii-V root fifth octave',
    chordsPerBar: <String>['Dm7', 'G7'],
    pitches: <int>[38, 45, 50, 48, 47, 43, 41, 38],
    tags: <String>{'walking', 'wide'},
  ),
  BassPhrase.walking(
    name: 'ii-V low chromatic',
    chordsPerBar: <String>['Dm7', 'G7'],
    pitches: <int>[38, 36, 35, 34, 33, 35, 38, 41],
    tags: <String>{'walking', 'chromatic', 'low'},
  ),
  BassPhrase.walking(
    name: 'ii-V arpeggio and turn',
    chordsPerBar: <String>['Dm7', 'G7'],
    pitches: <int>[38, 41, 45, 43, 41, 40, 38, 35],
    tags: <String>{'walking', 'arpeggio'},
  ),

  // ---- I–VI, written over Cmaj7 | A7 ---------------------------------
  BassPhrase.walking(
    name: 'I-VI scalar up, down to the third',
    chordsPerBar: <String>['Cmaj7', 'A7'],
    pitches: <int>[36, 38, 40, 43, 45, 43, 40, 37],
    tags: <String>{'walking'},
  ),
  BassPhrase.walking(
    name: 'I-VI down the scale, up the chord',
    chordsPerBar: <String>['Cmaj7', 'A7'],
    pitches: <int>[36, 35, 33, 31, 33, 37, 40, 43],
    tags: <String>{'walking', 'low'},
  ),
  BassPhrase.walking(
    name: 'I-VI octave drop',
    chordsPerBar: <String>['Cmaj7', 'A7'],
    pitches: <int>[48, 43, 40, 36, 33, 35, 37, 40],
    tags: <String>{'walking', 'wide'},
  ),
  BassPhrase.walking(
    name: 'I-VI up to the seventh',
    chordsPerBar: <String>['Cmaj7', 'A7'],
    pitches: <int>[36, 40, 43, 47, 45, 43, 42, 40],
    tags: <String>{'walking', 'chromatic'},
  ),
  BassPhrase.walking(
    name: 'I-VI around the root',
    chordsPerBar: <String>['Cmaj7', 'A7'],
    pitches: <int>[36, 33, 35, 34, 33, 37, 40, 45],
    tags: <String>{'walking', 'chromatic'},
  ),

  // ---- static major, written over Cmaj7 | Cmaj7 -----------------------
  BassPhrase.walking(
    name: 'held major, up and back',
    chordsPerBar: <String>['Cmaj7', 'Cmaj7'],
    pitches: <int>[36, 40, 43, 45, 47, 45, 43, 40],
    tags: <String>{'walking'},
  ),
  BassPhrase.walking(
    name: 'held major, scale to the octave',
    chordsPerBar: <String>['Cmaj7', 'Cmaj7'],
    pitches: <int>[36, 38, 40, 41, 43, 45, 47, 48],
    tags: <String>{'walking', 'ascending'},
  ),
  BassPhrase.walking(
    name: 'held major, fifths and a fall',
    chordsPerBar: <String>['Cmaj7', 'Cmaj7'],
    pitches: <int>[36, 40, 45, 43, 40, 38, 36, 35],
    tags: <String>{'walking', 'descending'},
  ),
  BassPhrase.walking(
    name: 'held major, pedal figure',
    chordsPerBar: <String>['Cmaj7', 'Cmaj7'],
    pitches: <int>[36, 43, 36, 40, 43, 47, 48, 47],
    tags: <String>{'walking', 'pedal'},
  ),

  // ---- I VI ii V, written over Cmaj7 | A7 | Dm7 | G7 ------------------
  BassPhrase.walking(
    name: 'turnaround, chromatic connectors',
    chordsPerBar: <String>['Cmaj7', 'A7', 'Dm7', 'G7'],
    pitches: <int>[
      36, 40, 43, 44, //
      45, 43, 42, 41, //
      38, 41, 45, 47, //
      43, 41, 40, 38,
    ],
    tags: <String>{'walking', 'chromatic'},
  ),
  BassPhrase.walking(
    name: 'turnaround, scalar',
    chordsPerBar: <String>['Cmaj7', 'A7', 'Dm7', 'G7'],
    pitches: <int>[
      36, 38, 40, 41, //
      45, 43, 40, 37, //
      38, 40, 41, 45, //
      47, 45, 43, 41,
    ],
    tags: <String>{'walking'},
  ),
  BassPhrase.walking(
    name: 'turnaround, from the octave',
    chordsPerBar: <String>['Cmaj7', 'A7', 'Dm7', 'G7'],
    pitches: <int>[
      48, 47, 45, 43, //
      45, 43, 40, 37, //
      38, 45, 41, 40, //
      43, 41, 38, 35,
    ],
    tags: <String>{'walking', 'descending'},
  ),

  // ---- ii V I I, written over Dm7 | G7 | Cmaj7 | Cmaj7 ----------------
  BassPhrase.walking(
    name: 'cadence, arch',
    chordsPerBar: <String>['Dm7', 'G7', 'Cmaj7', 'Cmaj7'],
    pitches: <int>[
      38, 41, 45, 47, //
      43, 41, 40, 38, //
      36, 40, 43, 45, //
      47, 45, 43, 40,
    ],
    tags: <String>{'walking'},
  ),
  BassPhrase.walking(
    name: 'cadence, long climb',
    chordsPerBar: <String>['Dm7', 'G7', 'Cmaj7', 'Cmaj7'],
    pitches: <int>[
      38, 40, 41, 42, //
      43, 45, 47, 50, //
      48, 47, 43, 40, //
      36, 38, 40, 43,
    ],
    tags: <String>{'walking', 'ascending'},
  ),
];
