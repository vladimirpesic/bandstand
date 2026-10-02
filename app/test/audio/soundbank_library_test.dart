import 'dart:io';

import 'package:bandstand/audio/soundbank_library.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scanning the soundbank folders. Plain `test`: real file I/O, and nothing
/// here needs a widget tree or the engine.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bandstand-soundbank-test');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('a broken symlink does not abort the scan', () {
    File('${root.path}/good.sf2').writeAsBytesSync(<int>[0, 1, 2, 3]);
    final broken = Link('${root.path}/broken.sf2')
      ..createSync('/definitely/not/there.sf2');

    final found = SoundbankLibrary.scan(root)
        .where((bank) => !bank.isSystem)
        .toList();

    expect(found, hasLength(1));
    expect(found.single.name, 'good');
    expect(
      File(broken.path).existsSync(),
      isFalse,
      reason: 'the symlink really is dead',
    );
  });

  test('an entry that cannot be stat\'ed is skipped, not fatal', () {
    File('${root.path}/good.sf2').writeAsBytesSync(<int>[0, 1, 2, 3]);
    // A symlink loop: resolving it fails with "too many levels", the same
    // FileSystemException family a vanished file or a permissions wall
    // produces.
    Link('${root.path}/loop-a.sf2').createSync('${root.path}/loop-b.sf2');
    Link('${root.path}/loop-b.sf2').createSync('${root.path}/loop-a.sf2');

    final found = SoundbankLibrary.scan(root)
        .where((bank) => !bank.isSystem)
        .toList();

    expect(found.map((bank) => bank.name), <String>['good']);
  });

  test('the extension is stripped case-insensitively', () {
    File('${root.path}/BIGBAND.SF2').writeAsBytesSync(<int>[0, 1, 2, 3]);

    final found = SoundbankLibrary.scan(root)
        .where((bank) => !bank.isSystem)
        .toList();

    expect(found.single.name, 'BIGBAND');
  });

  test('only soundfonts are offered', () {
    File('${root.path}/notes.txt').writeAsBytesSync(<int>[0, 1, 2, 3]);
    File('${root.path}/bank.sf3').writeAsBytesSync(<int>[0, 1, 2, 3]);

    final found = SoundbankLibrary.scan(root)
        .where((bank) => !bank.isSystem)
        .toList();
    expect(found, isEmpty);
  });

  test('an unreadable directory does not abort the whole scan', () {
    // `listSync` sat outside the try that guards the per-file work, so a
    // directory the process cannot read threw straight out of `scan` — and
    // the player's own folder is scanned alongside the system paths, so one
    // unreadable path took the whole list down with it.
    final root = Directory.systemTemp.createTempSync('bandstand-soundbanks');
    addTearDown(() {
      // Put the permissions back first, or the delete fails too.
      Process.runSync('chmod', <String>['u+rwx', root.path]);
      root.deleteSync(recursive: true);
    });

    File('${root.path}/good.sf2').writeAsBytesSync(<int>[0, 1, 2, 3]);
    Process.runSync('chmod', <String>['000', root.path]);
    if (Process.runSync('test', <String>['-r', root.path]).exitCode == 0) {
      // Running as root, where nothing is unreadable.
      markTestSkipped('this user can read a chmod-000 directory');
      return;
    }

    // The banks in it are genuinely out of reach, but the scan itself must
    // still answer — with whatever the readable paths hold.
    expect(SoundbankLibrary.scan(root), isA<List<SoundbankFile>>());
  });
}
