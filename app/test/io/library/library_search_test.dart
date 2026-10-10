import 'package:bandstand/io/library/library_search.dart';
import 'package:bandstand/io/library/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

/// A manifest from `{volume name: entry names}` — insertion order is the
/// tree's canonical order.
LibraryManifest _manifestOf(Map<String, List<String>> tree) => LibraryManifest(
  rootId: 'root',
  rootName: 'jamey_aebersold',
  generatedUtc: epochUtc,
  volumes: <LibraryVolume>[
    for (final volumeName in tree.keys)
      LibraryVolume(
        id: volumeName,
        name: volumeName,
        entries: <LibraryEntry>[
          for (final entryName in tree[volumeName]!)
            LibraryEntry(
              id: '$volumeName/$entryName',
              name: entryName,
              kind: LibraryEntryKind.ofName(entryName),
              sizeBytes: 1,
              checksum: '',
              modifiedUtc: epochUtc,
            ),
        ],
      ),
  ],
);

/// The library the suite runs against: two volumes that contain the tune
/// the ADR names, one that does not, and the odd names — punctuation,
/// roman numerals, a `book.pdf` — that search must not trip on.
final LibraryManifest _tree = _manifestOf(<String, List<String>>{
  '001_how_to_play_and_improvise_jazz': <String>[
    '001_medley_a_track.wav',
    '005_late_autumn.mp3',
  ],
  '054_maiden_voyage': <String>[
    '004_maiden_voyage.mp3',
    '011_autumn_leaves.mp3',
    '013_ii_v7_i.mp3',
    '021_siris_blues.mp3',
    'book.pdf',
    'notes.txt',
  ],
  '116_miles_davis': <String>[
    '003_autumn_leaves.mp3',
    '007_miles_runs_the_voodoo_down.mp3',
  ],
  '067_famous_jazz_composers': <String>['002_st_thomas.mp3'],
});

List<LibrarySearchHit> _search(String query) => searchLibrary(_tree, query);

Set<String> _trackNames(String query) => <String>{
  for (final hit in _search(query))
    if (hit is LibraryTrackHit) hit.entry.name,
};

void main() {
  test('the ADR sentence: autumn leaves finds every volume with the tune', () {
    final hits = _search('autumn leaves');
    expect(
      <String>[
        for (final hit in hits)
          if (hit is LibraryTrackHit) hit.volume.name,
      ],
      <String>['054_maiden_voyage', '116_miles_davis'],
    );
    expect(
      <String>[
        for (final hit in hits)
          if (hit is LibraryTrackHit) hit.entry.name,
      ],
      <String>['011_autumn_leaves.mp3', '003_autumn_leaves.mp3'],
    );
  });

  test('formatting never decides a find: case, spacing, punctuation', () {
    for (final query in <String>[
      '  AUTUMN   leaves ',
      'autumn_leaves',
      'Autumn Leaves',
      'autumn, leaves',
      "autumn's leaves",
      'leaves autumn',
    ]) {
      expect(
        _trackNames(query),
        contains('011_autumn_leaves.mp3'),
        reason: query,
      );
      expect(
        _trackNames(query),
        contains('003_autumn_leaves.mp3'),
        reason: query,
      );
    }
  });

  test('a typo per word still finds the tune', () {
    for (final query in <String>[
      'autum leaves',
      'autumn laeves',
      'autumn leav',
    ]) {
      expect(
        _trackNames(query),
        contains('011_autumn_leaves.mp3'),
        reason: query,
      );
    }
  });

  test('a word that matches nothing matches nothing', () {
    expect(_search('autumn zzqq'), isEmpty);
    expect(_search('voodoo autumn'), isEmpty);
  });

  test('a volume name is a find of its own, above its tracks', () {
    final hits = _search('maiden voyage');
    final first = hits.first;
    expect(first, isA<LibraryVolumeHit>());
    expect((first as LibraryVolumeHit).volume.name, '054_maiden_voyage');
    // The volume's own title track rides along, in tree order after it.
    expect((hits[1] as LibraryTrackHit).entry.name, '004_maiden_voyage.mp3');
  });

  test('the obvious match outranks the generous one, across volumes', () {
    // Volume 1's `005_late_autumn` contains the word but does not start
    // with it; volume 54's `011_autumn_leaves` starts with it — and comes
    // first despite the higher volume number.
    final hits = _search('autumn');
    expect((hits.first as LibraryTrackHit).entry.name, '011_autumn_leaves.mp3');
    expect(
      hits.whereType<LibraryVolumeHit>(),
      isEmpty,
      reason: 'no volume name carries the word',
    );
  });

  test('ordinals are searchable, extensions are not there to find', () {
    expect(
      <String>{
        for (final hit in _search('054'))
          if (hit is LibraryVolumeHit) hit.volume.name,
      },
      <String>{'054_maiden_voyage'},
    );
    expect(_trackNames('011'), <String>{'011_autumn_leaves.mp3'});
    // And an ordinal does not drift to the next one over.
    expect(_trackNames('001'), <String>{'001_medley_a_track.wav'});
    expect(_search('mp3'), isEmpty);
    expect(_search('pdf'), isEmpty);
  });

  test('books and stray files are not tune names', () {
    expect(_search('book'), isEmpty);
    expect(_search('notes'), isEmpty);
  });

  test('punctuation in names reads as spaces both ways', () {
    for (final query in <String>['st thomas', 'st. thomas', 'St Thomas']) {
      expect(_trackNames(query), <String>{'002_st_thomas.mp3'}, reason: query);
    }
  });

  test("roman numerals are the library's own words", () {
    expect(_trackNames('ii v7 i'), <String>{'013_ii_v7_i.mp3'});
    expect(_trackNames('v7'), <String>{'013_ii_v7_i.mp3'});
  });

  test('a query run together finds the words it swallowed', () {
    final names = <String>[
      for (final hit in _search('autumnleaves'))
        if (hit is LibraryTrackHit) hit.entry.name,
    ];
    expect(names.take(2), <String>[
      '011_autumn_leaves.mp3',
      '003_autumn_leaves.mp3',
    ]);
    // The generosity drags `late_autumn` in too — last, in the fuzzy tier,
    // where generosity belongs.
    expect(names, contains('005_late_autumn.mp3'));
  });

  test('an empty or punctuation-only query finds nothing', () {
    expect(_search(''), isEmpty);
    expect(_search('   '), isEmpty);
    expect(_search("'''"), isEmpty);
  });

  test('fuzziness has bounds: nonsense stays unfound', () {
    expect(_search('zzzzz'), isEmpty);
    expect(_search('qzf autumn'), isEmpty);
  });
}
