import 'dart:io';

import 'package:bandstand/io/library/library_settings.dart';
import 'package:bandstand/io/json_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a missing file is the first run: defaults', () async {
    final dir = await Directory.systemTemp.createTemp('settings-test');
    addTearDown(() => dir.delete(recursive: true));
    final settings = LibrarySettings.load(File('${dir.path}/s.json'));
    expect(settings.megaFolderLink, '');
    expect(settings.hasLink, isFalse);
    expect(settings.cacheRootOverride, isNull);
  });

  test('the pasted link and the cache root survive a round trip', () async {
    final dir = await Directory.systemTemp.createTemp('settings-test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/s.json');
    const link = 'https://mega.nz/folder/AbCdEf0h#AAAAAAAAAAAAAAAAAAAAAA';
    await LibrarySettings(
      megaFolderLink: link,
      cacheRootOverride: '/srv/music',
    ).saveTo(file);
    final loaded = LibrarySettings.load(file);
    expect(loaded.megaFolderLink, link);
    expect(loaded.hasLink, isTrue);
    expect(loaded.cacheRootOverride, '/srv/music');
    // An override of blanks is no override at all once it crosses a save.
    final blankFile = File('${dir.path}/blank.json');
    await LibrarySettings(megaFolderLink: link)
        .withCacheRootOverride('  ')
        .saveTo(blankFile);
    expect(LibrarySettings.load(blankFile).cacheRootOverride, isNull);
  });

  test('the link is never printed, but it is kept', () {
    // The settings' whole job: hold the bearer secret (§7). It parses back
    // exactly, whoever asks.
    const link = 'https://mega.nz/#F!XyZ01234!AAAAAAAAAAAAAAAAAAAAAA';
    final settings = LibrarySettings().withLink(link);
    expect(settings.megaFolderLink, link);
    expect(settings.withLink('').hasLink, isFalse);
  });

  test('corrupt settings fail loudly, not silently', () {
    final dir = Directory.systemTemp.createTempSync('settings-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/s.json')..writeAsStringSync('{oops');
    expect(
      () => LibrarySettings.load(file),
      throwsA(isA<SongFormatException>()),
    );
  });

  test('a 0012-era settings file is carried across, link intact', () async {
    final dir = await Directory.systemTemp.createTemp('settings-test');
    addTearDown(() => dir.delete(recursive: true));
    const link = 'https://mega.nz/folder/AbCdEf0h#AAAAAAAAAAAAAAAAAAAAAA';
    File('${dir.path}/${LibrarySettings.legacyFileName}')
        .writeAsStringSync('{"megaFolderLink": "$link"}');
    final file = File('${dir.path}/${LibrarySettings.fileName}');
    final loaded = LibrarySettings.load(file);
    expect(loaded.megaFolderLink, link);
    expect(loaded.hasLink, isTrue);
    // The rename is a migration, not a copy: the old spelling stops
    // existing once the new one answers, and the next read finds the
    // settings where they now live.
    expect(file.existsSync(), isTrue);
    expect(
      File('${dir.path}/${LibrarySettings.legacyFileName}').existsSync(),
      isFalse,
    );
    expect(LibrarySettings.load(file).megaFolderLink, link);
  });

  test('the new name answers before the old one', () async {
    final dir = await Directory.systemTemp.createTemp('settings-test');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}/${LibrarySettings.fileName}')
        .writeAsStringSync('{"megaFolderLink": "new"}');
    File('${dir.path}/${LibrarySettings.legacyFileName}')
        .writeAsStringSync('{"megaFolderLink": "old"}');
    expect(
      LibrarySettings.load(File('${dir.path}/${LibrarySettings.fileName}'))
          .megaFolderLink,
      'new',
    );
  });
}
