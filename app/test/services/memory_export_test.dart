import 'dart:async';
import 'dart:convert';

import 'package:antgrid/models/memory.dart';
import 'package:antgrid/services/memory_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_export_fixtures.dart';

Matcher memoryError(String code) =>
    isA<MemoryException>().having((error) => error.code, 'code', code);

void main() {
  test(
    'collects dependent pages and preserves complete version-one records',
    () async {
      final records = [
        memoryExportRecord('old', lifecycle: 'superseded'),
        memoryExportRecord('new', supersedes: 'old'),
        memoryExportRecord('expired', lifecycle: 'expired'),
      ];
      final calls = <Map<String, dynamic>>[];
      final last = Completer<Map<String, dynamic>>();
      final export = collectMemoryExport((request) async {
        calls.add(request);
        return switch (request['cursor']) {
          null => memoryExportPage(records: [records[0]], cursor: 'page-2'),
          'page-2' => memoryExportPage(records: [records[1]], cursor: 'page-3'),
          'page-3' => await last.future,
          _ => throw StateError('Unexpected cursor'),
        };
      });
      await Future<void>.delayed(Duration.zero);
      expect(calls, [
        {'op': 'export'},
        {'op': 'export', 'cursor': 'page-2'},
        {'op': 'export', 'cursor': 'page-3'},
      ]);
      last.complete(memoryExportPage(records: [records[2]]));
      final bytes = (await export)!;
      final data = {
        'version': 1,
        'owner_id': 'owner',
        'exported_at': 1000,
        'records': records,
      };
      expect(jsonDecode(utf8.decode(bytes)), data);
      expect(
        utf8.decode(bytes),
        const JsonEncoder.withIndent('  ').convert(data),
      );
    },
  );

  test('a project filter rides on every page request', () async {
    final calls = <Map<String, dynamic>>[];
    await collectMemoryExport((request) async {
      calls.add(request);
      return request['cursor'] == null
          ? memoryExportPage(records: [memoryExportRecord('a')], cursor: 'c2')
          : memoryExportPage(records: [memoryExportRecord('b')]);
    }, projectId: 'p');
    expect(calls, [
      {'op': 'export', 'project_id': 'p'},
      {'op': 'export', 'cursor': 'c2', 'project_id': 'p'},
    ]);
  });

  test('an empty export is the same file the whole-document encoder writes', () async {
    final bytes = await collectMemoryExport((_) async => memoryExportPage());
    expect(
      utf8.decode(bytes!),
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'owner_id': 'owner',
        'exported_at': 1000,
        'records': <Object>[],
      }),
    );
  });

  test('a later-page failure returns no partial export', () async {
    final calls = <Map<String, dynamic>>[];
    final export = collectMemoryExport((request) async {
      calls.add(request);
      if (calls.length == 1) {
        return memoryExportPage(
          records: [memoryExportRecord('one')],
          cursor: 'next',
        );
      }
      throw const MemoryException('EXPORT_CHANGED', 'Changed during export');
    });
    await expectLater(export, throwsA(memoryError('EXPORT_CHANGED')));
    expect(calls, hasLength(2));
  });

  for (final changedField in ['owner_id', 'exported_at']) {
    test('rejects changed $changedField between pages', () async {
      var calls = 0;
      final export = collectMemoryExport((request) async {
        calls++;
        if (calls == 1) {
          return memoryExportPage(
            records: [memoryExportRecord('one')],
            cursor: 'next',
          );
        }
        return memoryExportPage(
          owner: changedField == 'owner_id' ? 'other-owner' : 'owner',
          timestamp: changedField == 'exported_at' ? 2000 : 1000,
        );
      });
      await expectLater(export, throwsA(memoryError('EXPORT_CHANGED')));
      expect(calls, 2);
    });
  }

  test('rejects cursor cycles before requesting another page', () async {
    var calls = 0;
    final export = collectMemoryExport((request) async {
      calls++;
      return memoryExportPage(
        records: [memoryExportRecord('record-$calls')],
        cursor: calls == 2 ? 'second-cursor' : 'first-cursor',
      );
    });
    await expectLater(export, throwsA(memoryError('BAD_RESPONSE')));
    expect(calls, 3);
  });

  test(
    'rejects duplicate record IDs across otherwise distinct pages',
    () async {
      var calls = 0;
      final export = collectMemoryExport((request) async {
        calls++;
        return memoryExportPage(
          records: [memoryExportRecord('same-record')],
          cursor: calls == 1 ? 'next' : null,
        );
      });
      await expectLater(export, throwsA(memoryError('BAD_RESPONSE')));
      expect(calls, 2);
    },
  );

  final malformed = <String, Map<String, dynamic>>{
    'missing cursor': memoryExportPage()..remove('next_cursor'),
    'empty cursor': memoryExportPage(cursor: ''),
    'whitespace cursor': memoryExportPage(cursor: '  '),
    'non-string cursor': memoryExportPage(cursor: 42),
    'oversized UTF-8 cursor': memoryExportPage(cursor: '界' * 700),
    'empty continuation page': memoryExportPage(cursor: 'next'),
    'wrong version': memoryExportPage()..['version'] = 2,
    'non-integer timestamp': memoryExportPage()..['exported_at'] = 1.5,
    'non-record entry': memoryExportPage()..['records'] = ['bad'],
    'record owner mismatch': memoryExportPage(
      records: [memoryExportRecord('one', owner: 'other')],
    ),
    'malformed provenance': memoryExportPage(
      records: [
        memoryExportRecord('one')..['source'] = {'actor': 'unknown'},
      ],
    ),
    'missing lifecycle': memoryExportPage(
      records: [memoryExportRecord('one')..remove('lifecycle')],
    ),
    'oversized page': memoryExportPage(
      records: [memoryExportRecord('one')..['content'] = '界' * (90 * 1024)],
    ),
  };
  for (final entry in malformed.entries) {
    test('rejects ${entry.key}', () async {
      var calls = 0;
      await expectLater(
        collectMemoryExport((_) async {
          calls++;
          return entry.value;
        }),
        throwsA(memoryError('BAD_RESPONSE')),
      );
      expect(calls, 1);
    });
  }

  test('inactive export makes no request', () async {
    var requested = false;
    expect(
      await collectMemoryExport((_) async {
        requested = true;
        return memoryExportPage();
      }, isActive: () => false),
      isNull,
    );
    expect(requested, isFalse);
  });

  test(
    'deactivation during a page discards it and stops the next request',
    () async {
      var active = true;
      var calls = 0;
      final response = Completer<Map<String, dynamic>>();
      final export = collectMemoryExport((_) {
        calls++;
        return response.future;
      }, isActive: () => active);
      active = false;
      response.complete(
        memoryExportPage(records: [memoryExportRecord('one')], cursor: 'next'),
      );
      expect(await export, isNull);
      expect(calls, 1);
    },
  );
}
