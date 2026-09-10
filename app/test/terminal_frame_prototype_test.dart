import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

bool _hasNative() {
  try {
    GhosttyVt.newTerminal(cols: 8, rows: 2).close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  test(
    'prototype xterm frames restore in native Ghostty, including OSC 8',
    () async {
      final result = await Process.run('bun', [
        'run',
        'scripts/terminal-frame-fixtures.ts',
      ], workingDirectory: '../bridge');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final fixtures = jsonDecode(result.stdout as String) as List<dynamic>;
      for (final raw in fixtures) {
        final fixture = raw as Map<String, dynamic>;
        final frame = fixture['frame'] as Map<String, dynamic>;
        final controller = GhosttyTerminalController(
          initialCols: frame['cols'] as int,
          initialRows: frame['rows'] as int,
        );
        try {
          controller.appendOutputBytes(utf8.encode('stale content\x1b[?1049h'));
          for (var i = 0; i < 3; i++) {
            controller.appendOutputBytes(utf8.encode(frame['ansi'] as String));
          }
          final rendered = controller.renderSnapshot!;
          final lines = rendered.rowsData
              .map(
                (row) => row.cells
                    .map(
                      (cell) =>
                          cell.text.isEmpty ? ' ' * cell.width : cell.text,
                    )
                    .join()
                    .trimRight(),
              )
              .toList();
          expect(lines, fixture['lines'], reason: fixture['name'] as String);
          final cursor = fixture['cursor'] as Map<String, dynamic>;
          expect(rendered.cursor.row, cursor['row']);
          expect(rendered.cursor.col, cursor['col']);
          final link = fixture['link'] as Map<String, dynamic>?;
          if (link != null) {
            expect(
              controller.hyperlinkUriAt(
                GhosttyTerminalCellPosition(
                  row: link['row'] as int,
                  col: link['col'] as int,
                ),
              ),
              link['uri'],
            );
          }
        } finally {
          controller.dispose();
        }
      }
    },
    skip: _hasNative() ? false : 'Native Ghostty library unavailable',
  );
}
