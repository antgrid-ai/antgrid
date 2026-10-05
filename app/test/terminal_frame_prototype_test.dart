import 'dart:convert';
import 'dart:io';

import 'package:antgrid/util/terminal_links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  test(
    'alternate-screen frames replace blank backgrounds on the first application',
    () async {
      final result = await Process.run('bun', [
        'run',
        'scripts/terminal-frame-fixtures.ts',
      ], workingDirectory: '../bridge', stdoutEncoding: utf8);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final fixtures = (jsonDecode(result.stdout as String) as List).where(
        (f) => (f['name'] as String).startsWith('alternating background'),
      );
      final controller = GhosttyTerminalController(
        initialCols: 40,
        initialRows: 6,
      );
      try {
        for (final fixture in fixtures) {
          controller.appendOutputBytes(
            utf8.encode(fixture['frame']['ansi'] as String),
          );
          final screen = controller.renderSnapshot!;
          for (var row = 0; row < 6; row++) {
            for (var col = 0; col < 40; col++) {
              final cell = screen.rowsData[row].cells[col];
              final actual =
                  cell.metadata.backgroundColor ?? cell.style.background;
              expect(
                actual.toARGB32() & 0xffffff,
                fixture['backgrounds'][row][col] ?? 0,
                reason: '${fixture['name']} ($row, $col)',
              );
            }
          }
        }
      } finally {
        controller.dispose();
      }
    },
  );

  test(
    'independent xterm frames restore in native Ghostty, including OSC 8',
    () async {
      // A missing native engine is a qualification failure, not a passing run
      // that exercised only the TypeScript serializer.
      GhosttyVt.newTerminal(cols: 8, rows: 2).close();
      final result = await Process.run('bun', [
        'run',
        'scripts/terminal-frame-fixtures.ts',
      ], workingDirectory: '../bridge', stdoutEncoding: utf8);
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
            final rendered = controller.renderSnapshot!;
            final backgrounds = fixture['backgrounds'] as List<dynamic>;
            for (var row = 0; row < rendered.rowsData.length; row++) {
              var col = 0;
              for (final cell in rendered.rowsData[row].cells) {
                final expected = (backgrounds[row] as List<dynamic>)[col];
                final actual =
                    cell.metadata.backgroundColor ?? cell.style.background;
                expect(
                  actual.toARGB32() & 0xffffff,
                  expected ?? (rendered.backgroundColor.toARGB32() & 0xffffff),
                  reason: '${fixture['name']} background at ($row, $col)',
                );
                col += cell.width;
              }
            }
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
            for (final rawLink in fixture['links'] as List<dynamic>) {
              final link = rawLink as Map<String, dynamic>;
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
          }
        } finally {
          controller.dispose();
        }
      }
    },
  );

  test('bridge-detected links reach native Ghostty as quiet private-scheme '
      'cells', () async {
    GhosttyVt.newTerminal(cols: 8, rows: 2).close();
    // Windows decodes a child's stdout with the console code page unless told
    // otherwise, which turns the fixtures' non-ASCII text into mojibake.
    final result = await Process.run('bun', [
      'run',
      'scripts/terminal-frame-fixtures.ts',
    ], workingDirectory: '../bridge', stdoutEncoding: utf8);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final fixtures = {
      for (final f in jsonDecode(result.stdout as String) as List<dynamic>)
        (f as Map<String, dynamic>)['name'] as String: f,
    };

    String? uriAt(GhosttyTerminalController c, int row, int col) =>
        c.hyperlinkUriAt(GhosttyTerminalCellPosition(row: row, col: col));

    GhosttyTerminalController load(Map<String, dynamic> fixture) {
      final frame = fixture['frame'] as Map<String, dynamic>;
      final controller = GhosttyTerminalController(
        initialCols: frame['cols'] as int,
        initialRows: frame['rows'] as int,
      );
      controller.appendOutputBytes(utf8.encode(frame['ansi'] as String));
      return controller;
    }

    final path = load(fixtures['detected path link']!);
    try {
      // `edit src/a.ts:12 now`: the printed mention is cols 5..15, and the
      // words around it carry no link.
      final uri = uriAt(path, 0, 5)!;
      expect(isDetectedTerminalLink(uri), isTrue);
      expect(uriAt(path, 0, 15), uri);
      expect(uriAt(path, 0, 4), isNull);
      expect(uriAt(path, 0, 16), isNull);
      final link = parsePrintedPathLink(uri)!;
      expect(link.path, 'src/a.ts');
      expect(link.base, 'r');
      expect(link.kind, PrintedPathKind.file);
      expect(link.line, 12);
      expect(link.column, isNull);
    } finally {
      path.dispose();
    }

    final url = load(fixtures['detected url link']!);
    try {
      // The sentence's closing full stop is not part of the URL.
      final uri = uriAt(url, 0, 4)!;
      expect(isDetectedTerminalLink(uri), isTrue);
      expect(detectedUrlTarget(uri), 'https://example.com/a?b=1#c');
      expect(uriAt(url, 0, 3), isNull);
      expect(uriAt(url, 0, 4 + 'https://example.com/a?b=1#c'.length - 1), uri);
      expect(uriAt(url, 0, 4 + 'https://example.com/a?b=1#c'.length), isNull);
    } finally {
      url.dispose();
    }

    final longest = load(fixtures['longest accepted link uri']!);
    try {
      // The longest URI the bridge will mint must survive the engine's fixed
      // OSC 8 buffer, and one soft-wrapped path carries it on every row.
      final uri = uriAt(longest, 0, 0)!;
      expect(utf8.encode(uri).length, lessThanOrEqualTo(2000));
      final link = parsePrintedPathLink(uri)!;
      expect(link.path, 'src/${'€' * 217}.ts');
      for (var row = 0; row < 6; row++) {
        expect(uriAt(longest, row, 0), uri, reason: 'row $row');
      }
    } finally {
      longest.dispose();
    }
  });
}
