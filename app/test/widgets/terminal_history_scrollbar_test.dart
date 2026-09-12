import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/widgets/terminal_history_scrollbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('track seeks across the full archive and reaches live', (
    tester,
  ) async {
    final seeks = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [kDefaultPalette]),
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 24,
            height: 400,
            child: TerminalHistoryScrollbar(
              firstRow: 1000,
              liveRow: 11000,
              position: 11000,
              viewportRows: 24,
              onSeek: seeks.add,
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(TerminalHistoryScrollbar));
    await tester.tapAt(rect.center);
    expect(seeks.single, closeTo(6000, 1));
    await tester.tapAt(Offset(rect.center.dx, rect.top + 1));
    expect(seeks.last, 1000);
    await tester.tapAt(Offset(rect.center.dx, rect.bottom - 1));
    expect(seeks.last, 11000);
  });

  testWidgets('drag mapping is stable while new output expands the archive', (
    tester,
  ) async {
    var end = 10000;
    var position = 10000;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [kDefaultPalette]),
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 24,
                height: 400,
                child: TerminalHistoryScrollbar(
                  firstRow: 0,
                  liveRow: end,
                  position: position,
                  viewportRows: 24,
                  onSeek: (row) => setState(() => position = row),
                ),
              ),
            );
          },
        ),
      ),
    );
    final rect = tester.getRect(find.byType(TerminalHistoryScrollbar));
    final drag = await tester.startGesture(
      Offset(rect.center.dx, rect.bottom - 10),
    );
    await drag.moveBy(const Offset(0, -100));
    await tester.pump();
    final before = position;
    rebuild(() => end = 20000);
    await tester.pump();
    await drag.moveBy(const Offset(0, -1));
    await tester.pump();
    expect((position - before).abs(), lessThan(50));
    await drag.up();
  });
}
