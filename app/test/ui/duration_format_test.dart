import 'package:bandstand/ui/widgets/playhead_readout.dart';
import 'package:bandstand/ui/widgets/playback_panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlaybackPanel.formatDuration', () {
    test('rounds before splitting, so 119.6 s is 2:00 and not 1:60', () {
      expect(PlaybackPanel.formatDuration(119.6), '2:00');
    });

    test('formats whole seconds under a minute', () {
      expect(PlaybackPanel.formatDuration(9.4), '0:09');
      expect(PlaybackPanel.formatDuration(59.4), '0:59');
    });

    test('nothing loaded shows a dash', () {
      expect(PlaybackPanel.formatDuration(0), '—');
      expect(PlaybackPanel.formatDuration(-4), '—');
    });
  });

  group('PlayheadReadout.formatDuration', () {
    test('carries the hundredths into the seconds', () {
      expect(PlayheadReadout.formatDuration(59.997), '1:00.00');
      expect(PlayheadReadout.formatDuration(60.0), '1:00.00');
    });

    test('hundredths round to the nearest', () {
      expect(PlayheadReadout.formatDuration(61.235), '1:01.24');
    });

    test('non-positive is zero', () {
      expect(PlayheadReadout.formatDuration(-3), '0:00.00');
    });
  });
}
