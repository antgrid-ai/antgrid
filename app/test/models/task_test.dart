import 'package:antgrid/models/task.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _wire(Map<String, Object?> extra) => {
  'number': 14,
  'title': 'ship the thing',
  'body': '',
  'status': 'open',
  'sortKey': 'a',
  'source': 'local',
  'createdBy': 'user-1',
  'createdAt': '2026-08-18T00:00:00.000Z',
  'updatedAt': '2026-08-18T00:00:00.000Z',
  ...extra,
};

void main() {
  group('Task.ref', () {
    test('is the display id the server sent', () {
      final task = Task.fromJson(_wire({'displayId': 'ACME-14'}));
      expect(task!.ref, 'ACME-14');
    });

    // The fallback exists for an account service older than `displayId`, not as
    // the normal path: the prefix belongs to the server.
    test('falls back to the default prefix when the server sends none', () {
      expect(Task.fromJson(_wire(const {}))!.ref, 'ANT-14');
    });

    test('survives a copyWith', () {
      final task = Task.fromJson(_wire({'displayId': 'ACME-14'}))!;
      expect(task.copyWith(title: 'renamed').ref, 'ACME-14');
    });
  });

  group('Task.fromJson', () {
    test('refuses a payload with no number or an unknown status', () {
      expect(Task.fromJson(_wire({'number': '14'})), isNull);
      expect(Task.fromJson(_wire({'status': 'archived'})), isNull);
    });

    test('keeps an external assignee unwritable', () {
      final task = Task.fromJson(
        _wire({
          'assignee': {'kind': 'external', 'externalId': 'gh-9', 'login': 'oct'},
        }),
      )!;
      expect(task.assignee, isA<TaskExternalAssignee>());
      expect(task.assignee!.toJson(), isNull);
    });
  });

  group('Task.otherAssignees', () {
    test('parses both arms of the list', () {
      final task = Task.fromJson(
        _wire({
          'otherAssignees': [
            {'kind': 'member', 'userId': 'u-2'},
            {
              'kind': 'external',
              'externalId': '5',
              'login': 'octocat',
              'avatarUrl': 'https://example.test/a.png',
            },
          ],
        }),
      )!;
      expect(task.otherAssignees, [
        const TaskMemberAssignee('u-2'),
        const TaskExternalAssignee(externalId: '5', login: 'octocat'),
      ]);
    });

    // An account service older than the field sends no key at all, and a task
    // with at most one assignee sends an empty list.
    test('defaults to empty when the server sends no list', () {
      expect(Task.fromJson(_wire(const {}))!.otherAssignees, isEmpty);
    });

    // A shape we do not understand is not a reason to lose the task: the list
    // is a read-only footnote, and the row it hangs off still has to render.
    test('drops an unparseable element rather than the task', () {
      final task = Task.fromJson(
        _wire({
          'otherAssignees': [
            {'kind': 'wat'},
            {'kind': 'member', 'userId': 'u-3'},
          ],
        }),
      );
      expect(task, isNotNull);
      expect(task!.otherAssignees, [const TaskMemberAssignee('u-3')]);
    });

    test('survives a copyWith', () {
      final task = Task.fromJson(
        _wire({
          'otherAssignees': [
            {'kind': 'member', 'userId': 'u-2'},
          ],
        }),
      )!;
      expect(task.copyWith(title: 'renamed').otherAssignees, hasLength(1));
    });
  });

  group('Task.conflict', () {
    Map<String, Object?> conflicted([Map<String, Object?>? override]) =>
        _wire({
          'syncState': 'conflict',
          'conflict':
              override ??
              {
                'fields': [
                  {
                    'field': 'title',
                    'localValue': 'ship the thing',
                    'remoteValue': 'Ship the thing',
                    'at': '2026-08-18T09:00:00.000Z',
                  },
                ],
                'labelRemoveWins': ['needs-triage'],
              },
        });

    test('parses both arms', () {
      final conflict = Task.fromJson(conflicted())!.conflict!;
      expect(conflict.fields, hasLength(1));
      final field = conflict.fields.single;
      expect(field.field, 'title');
      expect(field.localValue, 'ship the thing');
      expect(field.remoteValue, 'Ship the thing');
      expect(field.at, isNotNull);
      expect(conflict.labelRemoveWins, ['needs-triage']);
    });

    test('is null when the server sends none', () {
      expect(Task.fromJson(_wire(const {}))!.conflict, isNull);
    });

    // An acknowledged conflict and one that never happened read the same to a
    // person, so they must not render differently.
    test('is null when there is nothing left to settle', () {
      final task = Task.fromJson(
        conflicted(const {'fields': [], 'labelRemoveWins': []}),
      )!;
      expect(task.conflict, isNull);
    });

    test('drops an unparseable element rather than the task', () {
      final task = Task.fromJson(
        conflicted(const {
          'fields': [
            {'localValue': 'no field name at all'},
            'not even a map',
            {'field': 'body', 'localValue': 'mine', 'remoteValue': 'theirs'},
          ],
        }),
      );
      expect(task, isNotNull);
      expect(task!.conflict!.fields.single.field, 'body');
    });

    // Every value the server can send is legal on the wire, including the ones
    // that say "this side had nothing".
    test('keeps a null value and an unreadable stamp', () {
      final task = Task.fromJson(
        conflicted(const {
          'fields': [
            {
              'field': 'assignee',
              'localValue': {'kind': 'member', 'userId': 'u-2'},
              'remoteValue': null,
              'at': 'not a date',
            },
          ],
        }),
      )!;
      final field = task.conflict!.fields.single;
      expect(field.remoteValue, isNull);
      expect(field.at, isNull);
    });

    test('survives a copyWith, and can be cleared by one', () {
      final task = Task.fromJson(conflicted())!;
      expect(task.copyWith(title: 'renamed').conflict, isNotNull);
      expect(task.copyWith(conflict: null).conflict, isNull);
    });
  });

  group('Task.pushBlocked', () {
    Map<String, Object?> blocked([List<Object?>? fields]) => _wire({
      'pushBlocked': {
        'fields':
            fields ??
            [
              {
                'field': 'title',
                'reason': 'GitHub accepted the title and kept its own.',
                'count': 3,
                'lastAt': '2026-08-18T09:00:00.000Z',
              },
            ],
      },
    });

    test('parses every part of an entry', () {
      final block = Task.fromJson(blocked())!.pushBlocked!;
      final field = block.fields.single;
      expect(field.field, 'title');
      expect(field.reason, 'GitHub accepted the title and kept its own.');
      expect(field.count, 3);
      expect(field.lastAt, isNotNull);
    });

    test('is null when the server sends none', () {
      expect(Task.fromJson(_wire(const {}))!.pushBlocked, isNull);
    });

    // A task whose every value is reaching the provider must carry no marker,
    // the way an acknowledged conflict carries none.
    test('is null when nothing is blocked', () {
      expect(Task.fromJson(blocked(const []))!.pushBlocked, isNull);
    });

    test('drops an unparseable entry rather than the task', () {
      final task = Task.fromJson(
        blocked(const [
          {'reason': 'no field name at all'},
          'not even a map',
          {'field': 'labels', 'reason': 'still there', 'count': 4},
        ]),
      );
      expect(task, isNotNull);
      expect(task!.pushBlocked!.fields.single.field, 'labels');
    });

    // A field name from a newer server is still clearable by its wire spelling,
    // so it is kept rather than filtered out here.
    test('keeps a field name this build has no label for', () {
      final task = Task.fromJson(
        blocked(const [
          {'field': 'milestone', 'reason': 'unchanged', 'count': 3},
        ]),
      )!;
      expect(task.pushBlocked!.fields.single.field, 'milestone');
    });

    test('tolerates a missing reason, count and stamp', () {
      final task = Task.fromJson(
        blocked(const [
          {'field': 'status', 'lastAt': 'not a date'},
        ]),
      )!;
      final field = task.pushBlocked!.fields.single;
      expect(field.reason, '');
      expect(field.count, 0);
      expect(field.lastAt, isNull);
    });

    test('survives a copyWith, and can be cleared by one', () {
      final task = Task.fromJson(blocked())!;
      expect(task.copyWith(title: 'renamed').pushBlocked, isNotNull);
      expect(task.copyWith(pushBlocked: null).pushBlocked, isNull);
    });
  });

  group('TaskPublishTarget', () {
    Map<String, Object?> target(Map<String, Object?> extra) => {
      'id': 'repo-1',
      'owner': 'antgrid',
      'name': 'antgrid',
      'visibility': 'public',
      'publishNewByDefault': false,
      ...extra,
    };

    test('decodes the slug the API will actually address', () {
      final parsed = TaskPublishTarget.fromJson(target(const {}))!;
      expect(parsed.id, 'repo-1');
      expect(parsed.slug, 'antgrid/antgrid');
      expect(parsed.publishNewByDefault, isFalse);
    });

    test('a row missing an addressable half is dropped, not half-built', () {
      expect(TaskPublishTarget.fromJson(target(const {'owner': null})), isNull);
      expect(TaskPublishTarget.fromJson(target(const {'name': 7})), isNull);
      expect(TaskPublishTarget.fromJson('antgrid/antgrid'), isNull);
    });

    test('publishNewByDefault reads only a literal true', () {
      expect(
        TaskPublishTarget.fromJson(
          target(const {'publishNewByDefault': true}),
        )!.publishNewByDefault,
        isTrue,
      );
      // A hint arriving as a string must not arm a switch.
      expect(
        TaskPublishTarget.fromJson(
          target(const {'publishNewByDefault': 'true'}),
        )!.publishNewByDefault,
        isFalse,
      );
    });

    // The reassuring half of the pair must never be said about a spelling this
    // build does not know.
    test('an unknown visibility claims neither public nor private', () {
      expect(
        TaskPublishTarget.fromJson(target(const {}))!.visibilitySentence,
        contains('public'),
      );
      expect(
        TaskPublishTarget.fromJson(
          target(const {'visibility': 'private'}),
        )!.visibilitySentence,
        contains('private'),
      );
      final unknown = TaskPublishTarget.fromJson(
        target(const {'visibility': 'internal'}),
      )!.visibilitySentence;
      expect(unknown, isNot(contains('private')));
      expect(unknown, contains('antgrid/antgrid'));
    });
  });

  group('link state', () {
    Task task(Map<String, Object?> extra) => Task.fromJson(_wire(extra))!;

    test('a task written here and never published is publishable', () {
      final local = task(const {});
      expect(local.isLinked, isFalse);
      expect(local.hasUnlinkedIdentity, isFalse);
      expect(local.isPublishable, isTrue);
    });

    test('a linked task is not publishable and can be unlinked', () {
      final linked = task(const {'externalId': 'I_1', 'syncState': 'synced'});
      expect(linked.isLinked, isTrue);
      expect(linked.isPublishable, isFalse);
    });

    // The tombstone: the identity survives so the confirm sheet can name the
    // issue that already exists.
    test('an unlinked task is publishable again and still names its issue', () {
      final unlinked = task(const {
        'externalId': 'I_1',
        'externalKey': 'o/r#12',
        'syncState': 'unlinked',
      });
      expect(unlinked.isLinked, isFalse);
      expect(unlinked.hasUnlinkedIdentity, isTrue);
      expect(unlinked.isPublishable, isTrue);
    });

    // The drain has not written the id yet, so the server's ALREADY_LINKED
    // check would not catch a second press — this is the only thing that does.
    test('a publish already in flight is not publishable again', () {
      final pending = task(const {'syncState': 'pending'});
      expect(pending.isLinked, isFalse);
      expect(pending.isPublishable, isFalse);
    });
  });
}
