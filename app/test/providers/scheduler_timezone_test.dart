import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/providers/scheduler_timezone.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_timezone');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<String?> detect() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container.read(schedulerLocalTimezoneProvider.future);
  }

  test('detects and validates the native IANA timezone identifier', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getLocalTimezone');
      return {'identifier': 'America/New_York'};
    });
    expect(await detect(), 'America/New_York');
  });

  test('accepts native string identifiers and real local UTC', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 'UTC');
    expect(await detect(), 'UTC');
  });

  test('unknown native zones remain distinct from local UTC', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 'Etc/Unknown');
    expect(await detect(), isNull);
  });

  test('missing native plugin remains distinct from local UTC', () async {
    expect(await detect(), isNull);
  });

  test('native detection failures remain distinct from local UTC', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await detect(), isNull);
  });

  test('invalidating detection picks up a changed system timezone', () async {
    var identifier = 'Asia/Kolkata';
    messenger.setMockMethodCallHandler(channel, (_) async => identifier);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      await container.read(schedulerLocalTimezoneProvider.future),
      'Asia/Kolkata',
    );
    identifier = 'Europe/London';
    container.invalidate(schedulerLocalTimezoneProvider);
    expect(
      await container.read(schedulerLocalTimezoneProvider.future),
      'Europe/London',
    );
  });
}
