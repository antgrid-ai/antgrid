// Test helper replacing the legacy `SharedPreferences.setMockInitialValues`.
// The app now uses SharedPreferencesWithCache / SharedPreferencesAsync, both of
// which route through SharedPreferencesAsyncPlatform — so tests install an
// in-memory async platform instead. Seed maps use RAW keys (no `flutter.`
// prefix); call once per test in setUp/at the top of the test body.
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void useInMemoryPrefs([Map<String, Object>? seed]) {
  SharedPreferencesAsyncPlatform.instance = seed == null
      ? InMemorySharedPreferencesAsync.empty()
      : InMemorySharedPreferencesAsync.withData(seed);
}
