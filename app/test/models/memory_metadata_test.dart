import 'dart:convert';

import 'package:antgrid/models/memory.dart';
import 'package:antgrid/services/memory_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_export_fixtures.dart';

void main() {
  test(
    'metadata is optional and older records use the body as their title',
    () {
      final json = memoryExportRecord('legacy');
      final legacy = MemoryRecord.fromJson(json);
      expect(legacy.title, isNull);
      expect(legacy.description, isNull);
      expect(legacy.displayTitle, legacy.content);
      final named = MemoryRecord.fromJson({
        ...json,
        'title': 'Build recovery',
        'description': 'Use after a failed configure.',
      });
      expect(named.displayTitle, 'Build recovery');
      expect(named.description, 'Use after a failed configure.');
      expect(
        MemoryRecord.fromJson({...json, 'title': '  '}).displayTitle,
        legacy.content,
      );
    },
  );

  test('corrections submit edited metadata and omit cleared fields', () {
    final record = MemoryRecord.fromJson({
      ...memoryExportRecord('old'),
      'title': 'Old title',
      'description': 'Old description',
    });
    final updated = record.correction(
      title: ' New title ',
      description: ' New description ',
      content: record.content,
      applicability: record.applicability,
      evidence: record.evidence,
    );
    expect(updated['title'], 'New title');
    expect(updated['description'], 'New description');
    expect(updated['supersedes'], record.id);
    final cleared = record.correction(
      title: '',
      description: '  ',
      content: record.content,
      applicability: record.applicability,
      evidence: record.evidence,
    );
    expect(cleared.containsKey('title'), isFalse);
    expect(cleared.containsKey('description'), isFalse);
  });

  test('save validation counts UTF-8 bytes for each text field', () {
    final save = {
      'content': '🌱' * 4096,
      'title': '${'界' * 85}a',
      'description': '🌱' * 128,
    };
    expect(memorySaveValidation(save), isNull);
    for (final field in ['title', 'description', 'content']) {
      expect(
        memorySaveValidation({...save, field: '${save[field]}a'}),
        isNotNull,
      );
    }
    expect(
      memorySaveValidation({'content': '  '}),
      contains('must contain text'),
    );
    expect(
      memorySaveValidation({
        ...save,
        'evidence': ['x' * kMemoryRecordMaxBytes],
      }),
      contains('metadata exceed'),
    );
  });

  test(
    'export preserves metadata, history and a 16 KiB body exactly',
    () async {
      final records = [
        {
          ...memoryExportRecord('old', lifecycle: 'superseded'),
          'title': 'Original title',
          'description': 'Original description',
        },
        {
          ...memoryExportRecord('new', supersedes: 'old'),
          'title': '${'界' * 85}a',
          'description': '🌱' * 128,
          'content': '🌱' * 4096,
        },
        memoryExportRecord('legacy'),
      ];
      final bytes = await collectMemoryExport(
        (_) async => memoryExportPage(records: records),
      );
      final exported = jsonDecode(utf8.decode(bytes!)) as Map;
      expect(exported['records'], records);
    },
  );

  test(
    'export enforces UTF-8 field limits and the complete JSON record limit',
    () {
      final record = {
        ...memoryExportRecord('bounded'),
        'title': '${'界' * 85}a',
        'description': '🌱' * 128,
        'content': '🌱' * 4096,
        'evidence': [''],
      };
      final padding =
          kMemoryRecordMaxBytes - utf8.encode(jsonEncode(record)).length;
      record['evidence'] = ['x' * padding];
      expect(utf8.encode(jsonEncode(record)), hasLength(kMemoryRecordMaxBytes));
      expect(
        MemoryExportPage.fromJson(memoryExportPage(records: [record])).records,
        hasLength(1),
      );
      for (final field in ['title', 'description', 'content']) {
        expect(
          () => MemoryExportPage.fromJson(
            memoryExportPage(
              records: [
                {...record, field: '${record[field]}a', 'evidence': <String>[]},
              ],
            ),
          ),
          throwsA(isA<MemoryException>()),
        );
      }
      expect(
        () => MemoryExportPage.fromJson(
          memoryExportPage(
            records: [
              {
                ...record,
                'evidence': ['${'x' * padding}a'],
              },
            ],
          ),
        ),
        throwsA(isA<MemoryException>()),
      );
    },
  );

  test('export accepts a maximum-size task record after expiry', () async {
    final evidence = ['x' * 16384, 'y' * 16384, ''];
    final active = {
      ...memoryExportRecord('boundary'),
      'memory_type': 'task_state',
      'scope': 'task',
      'task_id': 'session',
      'content': '🌱' * 4096,
      'evidence': evidence,
    };
    evidence[2] =
        'z' * (kMemoryRecordMaxBytes - utf8.encode(jsonEncode(active)).length);
    expect(utf8.encode(jsonEncode(active)), hasLength(kMemoryRecordMaxBytes));
    final expired = {...active, 'lifecycle': 'expired'};
    expect(
      utf8.encode(jsonEncode(expired)),
      hasLength(kMemoryRecordMaxBytes + 1),
    );
    for (final record in [active, expired]) {
      for (final projectId in [null, 'project']) {
        final bytes = await collectMemoryExport(
          (_) async => memoryExportPage(records: [record]),
          projectId: projectId,
        );
        expect((jsonDecode(utf8.decode(bytes!)) as Map)['records'], [record]);
      }
      await expectLater(
        collectMemoryExport(
          (_) async => memoryExportPage(
            records: [
              {
                ...record,
                'evidence': [...evidence.take(2), '${evidence[2]}a'],
              },
            ],
          ),
        ),
        throwsA(
          isA<MemoryException>().having((e) => e.code, 'code', 'BAD_RESPONSE'),
        ),
      );
    }
    expect(expired['lifecycle'], 'expired');
  });
}
