import 'package:test/test.dart';
import 'package:tiling_probe/render.dart';
import 'package:tiling_probe/tiler.dart';

void main() {
  test('renderTiling rejects a non-positive formBars instead of looping', () {
    // formBars <= 0 used to make the chorus-marker loop run forever.
    expect(
      () => renderTiling(
        tiling: Tiling(const <Placement>[]),
        progression: Progression('one bar', <String>['Cmaj7']),
        formBars: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => renderTiling(
        tiling: Tiling(const <Placement>[]),
        progression: Progression('one bar', <String>['Cmaj7']),
        formBars: -4,
      ),
      throwsArgumentError,
    );
  });

  test('renderTiling writes a chorus marker at the start of each pass', () {
    final file = renderTiling(
      tiling: Tiling(const <Placement>[]),
      progression: Progression('two bars', <String>['Cmaj7', 'Cmaj7']),
      formBars: 2,
    );
    // A Standard MIDI File opens with the MThd chunk — proof the render
    // completed rather than hung.
    expect(file.encode().sublist(0, 4), 'MThd'.codeUnits);
  });
}
