import 'dart:io';

import 'package:bandstand/io/json_support.dart';
import 'package:bandstand/io/library/setlists.dart';
import 'package:flutter_test/flutter_test.dart';

Future<File> tempFile() async {
  final home = await Directory.systemTemp.createTemp('setlists-io-test');
  addTearDown(() async {
    try {
      await home.delete(recursive: true);
    } on FileSystemException {
      // Not the test's point.
    }
  });
  return File('${home.path}${Platform.pathSeparator}${Setlists.fileName}');
}

void main() {
  test('a missing file is the first run: no setlists, no error', () async {
    final file = await tempFile();
    expect(Setlists.load(file).setlists, isEmpty);
  });

  test('save and load round-trip: order, names, ids, members', () async {
    final file = await tempFile();
    final one = Setlist.named('Gig Saturday').withEntryAdded('a');
    final two = Setlist.named('Practice');
    await Setlists(setlists: <Setlist>[one, two]).saveTo(file);

    final loaded = Setlists.load(file);
    expect(loaded.setlists.length, 2);
    expect(loaded.setlists.first.name, 'Gig Saturday');
    expect(loaded.setlists.first.entryIds, <String>['a']);
    expect(loaded.setlists.last.id, two.id);
    expect(loaded.byId(one.id)!.entryIds, <String>['a']);
  });

  test('a member cannot be added twice — the tune appears once', () {
    final setlist = Setlist.named('Gig Saturday')
        .withEntryAdded('a')
        .withEntryAdded('b')
        .withEntryAdded('a');
    expect(setlist.entryIds, <String>['a', 'b']);
  });

  test('removing a member leaves the others in order', () {
    final setlist = Setlist.named('Gig Saturday')
        .withEntryAdded('a')
        .withEntryAdded('b')
        .withEntryAdded('c')
        .withEntryRemoved('b')
        .withEntryRemoved('not-there');
    expect(setlist.entryIds, <String>['a', 'c']);
  });

  test('replacing by id keeps the list in place; a new id appends', () {
    final one = Setlist.named('One');
    final two = Setlist.named('Two');
    final withBoth = Setlists(setlists: <Setlist>[one, two]);
    final renamed = withBoth.withSetlist(
      Setlist(id: one.id, name: 'Uno', entryIds: one.entryIds),
    );
    expect(renamed.setlists.map((s) => s.name), <String>['Uno', 'Two']);
    final appended = withBoth.withSetlist(Setlist.named('Three'));
    expect(appended.setlists.map((s) => s.name), <String>[
      'One',
      'Two',
      'Three',
    ]);
  });

  test('deleting a setlist deletes only the list', () {
    final one = Setlist.named('One').withEntryAdded('a');
    final two = Setlist.named('Two').withEntryAdded('b');
    final left = Setlists(setlists: <Setlist>[one, two]).withoutSetlist(one.id);
    expect(left.setlists.single.name, 'Two');
    expect(left.setlists.single.entryIds, <String>['b']);
  });

  test('name rules: empty, reserved, duplicates — in any casing', () {
    final one = Setlist.named('Gig Saturday');
    final lists = Setlists(setlists: <Setlist>[one]);
    expect(lists.problemWithName('   '), isNotNull);
    expect(lists.problemWithName('Favorites'), isNotNull);
    expect(lists.problemWithName('favorites'), isNotNull);
    expect(lists.problemWithName('  gig saturday '), isNotNull);
    expect(lists.problemWithName('GIG SATURDAY'), isNotNull);
    // Renaming a list may keep its own name.
    expect(lists.problemWithName('Gig Saturday', exceptId: one.id), isNull);
    expect(lists.problemWithName('Sunday Brunch'), isNull);
  });

  test('two ids made in a row differ', () {
    expect(Setlist.newSetlistId(), isNot(Setlist.newSetlistId()));
  });

  test('a file that is not JSON fails naming the file', () async {
    final file = await tempFile();
    await file.writeAsString('not json');
    expect(() => Setlists.load(file), throwsA(isA<JsonFormatException>()));
  });

  test('an unknown version is refused', () async {
    final file = await tempFile();
    await file.writeAsString('{"version": 99, "setlists": []}');
    expect(
      () => Setlists.load(file),
      throwsA(
        isA<JsonFormatException>().having(
          (e) => e.field,
          'field',
          'setlists.version',
        ),
      ),
    );
  });

  test('a hand-edited duplicate member is dropped at load', () async {
    final file = await tempFile();
    await file.writeAsString(
      '{"version": 1, "setlists": ['
      '{"id": "s1", "name": "Gig", "entryIds": ["a", "a", "b"]}]}',
    );
    expect(Setlists.load(file).byId('s1')!.entryIds, <String>['a', 'b']);
  });

  test('an object without a setlists key is simply empty', () async {
    final file = await tempFile();
    await file.writeAsString('{"version": 1}');
    expect(Setlists.load(file).setlists, isEmpty);
  });
}
