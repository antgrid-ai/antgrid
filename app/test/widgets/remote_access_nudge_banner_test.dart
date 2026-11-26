import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/widgets/new_session/remote_access_nudge_banner.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _softMessage =
    'Drive this machine from your phone — sign in there with this '
    'account, then turn on Remote here.';

DeviceSummary _phone({String name = 'Pixel 9'}) => DeviceSummary(
  id: 'acct-1',
  deviceId: 'dev-1',
  kind: 'app',
  platform: 'android',
  displayName: name,
);

/// Skips the loopback host entirely: build() answers from a local flag and
/// setEnabled() records the call, so no HostControlClient is ever dialed.
class _FakePolicyNotifier extends RemoteAccessPolicyNotifier {
  _FakePolicyNotifier({required bool enabled}) : _enabled = enabled;

  bool _enabled;
  int setEnabledCalls = 0;

  @override
  Future<RemoteAccessPolicy> build() async =>
      RemoteAccessPolicy(enabled: _enabled);

  @override
  Future<void> setEnabled(bool enabled) async {
    setEnabledCalls++;
    _enabled = enabled;
    state = AsyncData(RemoteAccessPolicy(enabled: enabled));
  }
}

Widget _wrap(Widget child, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(body: child),
    ),
  );
}

/// Baseline overrides for a desktop user past the checklist: signed in,
/// checklist dismissed, remote off, no second device unless a test adds one.
List<Override> _overrides({
  required FirstRunStore store,
  required _FakePolicyNotifier policy,
  List<DeviceSummary> devices = const [],
}) => [
  firstRunStoreProvider.overrideWithValue(store),
  signedInProvider.overrideWith((_) => true),
  remoteAccessPolicyProvider.overrideWith(() => policy),
  otherAccountMobileDevicesProvider.overrideWith((_) async => devices),
];

Future<FirstRunStore> _storeWithChecklistDismissed() async {
  final store = await FirstRunStore.open();
  await store.write(const FirstRunState(checklistDismissed: true));
  return store;
}

void main() {
  // The platform override is set/reset INSIDE each test body — the binding
  // verifies foundation debug variables before tearDown callbacks run, so a
  // tearDown reset is too late and fails every test.
  setUp(useInMemoryPrefs);

  testWidgets('device variant renders when a phone is on the account and '
      'remote is off, and supersedes the soft mention', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final store = await _storeWithChecklistDismissed();
    await tester.pumpWidget(
      _wrap(
        const RemoteAccessNudgeBanner(),
        overrides: _overrides(
          store: store,
          policy: _FakePolicyNotifier(enabled: false),
          devices: [_phone()],
        ),
      ),
    );
    await tester.pump(); // policy + devices futures resolve
    await tester.pump(); // soft-retirement latch microtask

    expect(
      find.text(
        'Pixel 9 signed in to your account. Turn on remote access to '
        'drive this machine from it.',
      ),
      findsOneWidget,
    );
    expect(find.text('Turn on'), findsOneWidget);
    // The real prompt retires the one-time mention forever.
    expect(store.read().nudgeSoftDismissed, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('soft variant renders with no action button when no second '
      'device exists', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final store = await _storeWithChecklistDismissed();
    await tester.pumpWidget(
      _wrap(
        const RemoteAccessNudgeBanner(),
        overrides: _overrides(
          store: store,
          policy: _FakePolicyNotifier(enabled: false),
        ),
      ),
    );
    await tester.pump();

    expect(find.text(_softMessage), findsOneWidget);
    expect(find.text('Turn on'), findsNothing);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.text(_softMessage), findsNothing);
    expect(store.read().nudgeSoftDismissed, isTrue);
    expect(store.read().nudgeDeviceDismissed, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('renders nothing when remote access is already on', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final store = await _storeWithChecklistDismissed();
    await tester.pumpWidget(
      _wrap(
        const RemoteAccessNudgeBanner(),
        overrides: _overrides(
          store: store,
          policy: _FakePolicyNotifier(enabled: true),
          devices: [_phone()],
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('signed in to your account'), findsNothing);
    expect(find.text(_softMessage), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('renders nothing while the first-run checklist is visible', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // Default store state: checklist neither dismissed nor completed.
    final store = await FirstRunStore.open();
    await tester.pumpWidget(
      _wrap(
        const RemoteAccessNudgeBanner(),
        overrides: _overrides(
          store: store,
          policy: _FakePolicyNotifier(enabled: false),
          devices: [_phone()],
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('signed in to your account'), findsNothing);
    expect(find.text(_softMessage), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('device dismiss hides the banner and persists across a restart', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final store = await _storeWithChecklistDismissed();
    await tester.pumpWidget(
      _wrap(
        const RemoteAccessNudgeBanner(),
        overrides: _overrides(
          store: store,
          policy: _FakePolicyNotifier(enabled: false),
          devices: [_phone()],
        ),
      ),
    );
    await tester.pump(); // policy future resolves
    await tester.pump(); // devices future resolves → device variant renders
    expect(find.textContaining('signed in to your account'), findsOneWidget);

    await tester.tap(
      find.byTooltip("Dismiss — won't ask again on this machine"),
    );
    await tester.pump();
    expect(find.textContaining('signed in to your account'), findsNothing);
    expect(store.read().nudgeDeviceDismissed, isTrue);

    // Fresh scope over the same prefs — an app restart — stays hidden.
    await tester.pumpWidget(
      _wrap(
        const RemoteAccessNudgeBanner(),
        overrides: _overrides(
          store: await FirstRunStore.open(),
          policy: _FakePolicyNotifier(enabled: false),
          devices: [_phone()],
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('signed in to your account'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('[Turn on] routes through the shared confirm dialog; confirming '
      'enables and unmounts the banner', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final store = await _storeWithChecklistDismissed();
    final policy = _FakePolicyNotifier(enabled: false);
    await tester.pumpWidget(
      _wrap(
        const RemoteAccessNudgeBanner(),
        overrides: _overrides(
          store: store,
          policy: policy,
          devices: [_phone()],
        ),
      ),
    );
    await tester.pump(); // policy future resolves
    await tester.pump(); // devices future resolves → device variant renders

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    // The one shared grant wording — asserting the title pins the reuse.
    expect(find.text('Turn on remote access?'), findsOneWidget);
    expect(policy.setEnabledCalls, 0);

    // Two 'Turn on' texts now exist (banner + dialog confirm); the dialog
    // route mounts above the banner, so .last is the confirm button.
    await tester.tap(find.text('Turn on').last);
    await tester.pumpAndSettle();

    expect(policy.setEnabledCalls, 1);
    // enabled flipped → nudge provider returns null → banner gone.
    expect(find.textContaining('signed in to your account'), findsNothing);
    expect(find.text('Turn on remote access?'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('cancelling the confirm leaves the banner up and remote off', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final store = await _storeWithChecklistDismissed();
    final policy = _FakePolicyNotifier(enabled: false);
    await tester.pumpWidget(
      _wrap(
        const RemoteAccessNudgeBanner(),
        overrides: _overrides(
          store: store,
          policy: policy,
          devices: [_phone()],
        ),
      ),
    );
    await tester.pump(); // policy future resolves
    await tester.pump(); // devices future resolves → device variant renders

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(policy.setEnabledCalls, 0);
    expect(find.textContaining('signed in to your account'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('renders nothing on mobile', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final store = await _storeWithChecklistDismissed();
    await tester.pumpWidget(
      _wrap(
        const RemoteAccessNudgeBanner(),
        overrides: _overrides(
          store: store,
          policy: _FakePolicyNotifier(enabled: false),
          devices: [_phone()],
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('signed in to your account'), findsNothing);
    expect(find.text(_softMessage), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
