import 'package:bandstand/domain/harmony/diagrams/chord_diagram.dart';
import 'package:bandstand/render/chord_diagram_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const style = ChordDiagramStyle(
    line: Color(0xFF111111),
    dot: Color(0xFF222222),
    text: Color(0xFF333333),
    muted: Color(0xFF444444),
  );

  group('sizing', () {
    test('a two-digit base fret gets a wider margin for its label', () {
      expect(
        style.sizeFor(6, baseFret: 12).width,
        greaterThan(style.sizeFor(6).width),
      );
      expect(
        style.sizeFor(6, baseFret: 5).width,
        style.sizeFor(6).width,
        reason: 'a single-digit fret writes nothing wider',
      );
    });
  });

  group('shapes past the drawn frets', () {
    testWidgets('say so instead of dropping fingers', (tester) async {
      final high = ChordShape(
        type: 'maj',
        frets: const <int>[1, 3, 5, 7, 9, 10],
        rootString: 0,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(child: ChordDiagramView(shape: high)),
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('chord-diagram-overflow')),
        findsOneWidget,
      );
    });

    testWidgets('stay quiet when everything fits', (tester) async {
      final low = ChordShape(
        type: 'maj',
        frets: const <int>[1, 3, 3, 3, 1, 1],
        rootString: 0,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(child: ChordDiagramView(shape: low)),
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('chord-diagram-overflow')),
        findsNothing,
      );
    });

    testWidgets('the view reserves room for the base fret label', (
      tester,
    ) async {
      final highPosition = ChordShape(
        type: 'maj',
        frets: const <int>[1, 3, 3, 3, 1, 1],
        rootString: 0,
        baseFret: 12,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ChordDiagramView(shape: highPosition, style: style),
          ),
        ),
      );
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(ChordDiagramView),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(paint.size, style.sizeFor(6, baseFret: 12));
    });
  });
}
