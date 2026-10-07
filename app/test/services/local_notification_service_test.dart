import 'package:antgrid/services/local_notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('notificationIdForTag', () {
    // Literal values pin the algorithm (32-bit FNV-1a, top bit masked): the id
    // must match across isolates and app versions, or a newer push for the
    // same session lands beside the old one instead of replacing it.
    test('is stable for a fixed input', () {
      expect(notificationIdForTag('a'), 1678518572);
      expect(notificationIdForTag('m1|p1|t1'), 1121081897);
      expect(notificationIdForTag(''), 18652613);
    });

    test('stays within a positive 31-bit Android id', () {
      for (final tag in [
        '',
        'a',
        'machine-1|proj-42|sess-7',
        'summary|machine-1|proj-42',
        'ü' * 300,
      ]) {
        final id = notificationIdForTag(tag);
        expect(id, inInclusiveRange(0, 0x7fffffff), reason: tag);
      }
    });
  });

  group('show on Android', () {
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final shows = <Map<Object?, Object?>>[];

    setUp(() async {
      shows.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'initialize') return true;
            if (call.method == 'show') {
              shows.add(call.arguments as Map<Object?, Object?>);
            }
            return null;
          });
      await LocalNotificationService().init();
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Map<Object?, Object?> android(Map<Object?, Object?> show) =>
        show['platformSpecifics']! as Map<Object?, Object?>;

    test(
      'an untagged notification takes a fresh id and joins no group',
      () async {
        final service = LocalNotificationService();
        await service.show(title: 't', body: 'b');
        await service.show(title: 't', body: 'b');
        expect(shows, hasLength(2));
        expect(shows[0]['id'], isNot(shows[1]['id']));
        expect(android(shows[0])['tag'], isNull);
        expect(android(shows[0])['groupKey'], isNull);
      },
    );

    test(
      'a tagged notification reuses its id so the next one replaces it',
      () async {
        final service = LocalNotificationService();
        await service.show(title: 'one', body: 'b', tag: 'm|p|s');
        await service.show(title: 'two', body: 'b', tag: 'm|p|s');
        expect(shows, hasLength(2));
        expect(shows[0]['id'], notificationIdForTag('m|p|s'));
        expect(shows[1]['id'], shows[0]['id']);
        expect(android(shows[1])['tag'], 'm|p|s');
      },
    );

    test(
      'a grouped notification is followed by a silent group summary',
      () async {
        await LocalNotificationService().show(
          title: 't',
          body: 'b',
          payload: 'route',
          tag: 'm|p|s',
          groupKey: 'm|p',
        );
        expect(shows, hasLength(2));

        final child = android(shows[0]);
        expect(shows[0]['payload'], 'route');
        expect(child['tag'], 'm|p|s');
        expect(child['groupKey'], 'm|p');
        expect(child['setAsGroupSummary'], isFalse);
        expect(child['onlyAlertOnce'], isFalse);
        expect(child['groupAlertBehavior'], GroupAlertBehavior.all.index);

        final summary = android(shows[1]);
        expect(summary['groupKey'], 'm|p');
        expect(summary['setAsGroupSummary'], isTrue);
        expect(summary['onlyAlertOnce'], isTrue);
        expect(
          summary['groupAlertBehavior'],
          GroupAlertBehavior.children.index,
        );
        expect(summary['channelId'], child['channelId']);
        // The project-level child's tag IS the group key; the summary must not
        // share its (tag, id) or the two would replace each other.
        expect(summary['tag'], isNot('m|p'));
        expect(shows[1]['id'], notificationIdForTag(summary['tag']! as String));
      },
    );

    test('the summary is stable per group', () async {
      final service = LocalNotificationService();
      await service.show(title: 't', body: 'b', tag: 'm|p|s1', groupKey: 'm|p');
      await service.show(title: 't', body: 'b', tag: 'm|p|s2', groupKey: 'm|p');
      expect(shows, hasLength(4));
      expect(shows[1]['id'], shows[3]['id']);
      expect(android(shows[1])['tag'], android(shows[3])['tag']);
      expect(shows[0]['id'], isNot(shows[2]['id']));
    });
  });
}
