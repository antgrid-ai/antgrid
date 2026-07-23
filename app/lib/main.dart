import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:push/push.dart';

import 'analytics/crash_reporting.dart';
import 'analytics/events.dart';
import 'analytics/install_id.dart';
import 'config/environment.dart';
import 'design/ab_text_density.dart';
import 'design/ab_theme.dart';
import 'design/ab_tokens.dart';
import 'launcher/host_teardown.dart';
import 'project/limits.dart';
import 'project/perf_recorder.dart';
import 'project/project_session.dart';
import 'project/project_session_registry.dart';
import 'providers/analytics.dart';
import 'providers/auth.dart';
import 'providers/cached_sessions.dart';
import 'providers/collapsed_drawer.dart';
import 'providers/drawer_order.dart';
import 'providers/local_host_warmup.dart';
import 'providers/post_signin_provisioning.dart';
import 'providers/projects.dart';
import 'providers/provider_retry.dart';
import 'providers/push.dart';
import 'providers/recent_agents.dart';
import 'providers/recent_ports.dart';
import 'navigation/nav_controller.dart';
import 'navigation/nav_serialization.dart';
import 'screens/app_shell.dart';
import 'screens/device_cap_dialog.dart';
import 'screens/sign_in_screen.dart';
import 'services/devices_api.dart' show DeviceCapInfo;
import 'services/app_settings_service.dart';
import 'services/push_background_handler.dart';
import 'storage/cached_sessions_store.dart';
import 'storage/drawer_collapsed_store.dart';
import 'storage/drawer_order_store.dart';
import 'storage/project_store.dart';
import 'storage/recent_agents_store.dart';
import 'storage/recent_ports_store.dart';
import 'update/update_gate.dart';

/// Push is Android (FCM) and iOS (APNs) only — desktop has no transport.
bool get _pushSupported =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Dedicated entrypoint for a push that arrives while the app is terminated.
///
/// `push` spawns a headless engine and runs the entrypoint named by the
/// `uk.orth.push.background_entrypoint` meta-data in AndroidManifest.xml (a
/// patch carried by our fork — stock push runs `main`, which would drag the
/// whole app bootstrap into a background receiver). Keep this cheap: it runs
/// on every terminated-state push, inside that receiver's 30s budget.
///
/// Registering the handler is also what releases the queued message — it
/// triggers push's readiness handshake. Nothing else belongs here.
@pragma('vm:entry-point')
void pushBackgroundMain() {
  WidgetsFlutterBinding.ensureInitialized();
  Push.instance.addOnBackgroundMessage(pushBackgroundHandler);
}

Future<void> main() async {
  // markdown_widget's CodeBlockNode.build() uses a try/catch as control flow
  // for language-less fenced code blocks (no `class` attr -> null-check throw)
  // and debugPrints the swallowed exception on every render — drowns out
  // real log lines. Package issue, not ours; filter this one known line.
  final defaultDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null && message.startsWith('get language error:')) return;
    defaultDebugPrint(message, wrapWidth: wrapWidth);
  };
  WidgetsFlutterBinding.ensureInitialized();
  // Register the background-message handler before runApp so background and
  // terminated deliveries reach our isolate. This registration covers the
  // backgrounded-but-alive case, where push routes to this existing engine;
  // pushBackgroundMain covers the terminated case, where it spawns a new one.
  if (_pushSupported) {
    Push.instance.addOnBackgroundMessage(pushBackgroundHandler);
  }
  // Reap the app-spawned bridge host on window close so the machine-level host
  // daemon doesn't outlive the app (desktop-only in effect).
  WidgetsBinding.instance.addObserver(HostTeardownObserver());
  if (kDebugPerf) {
    // Best-effort: never let instrumentation block app startup.
    unawaited(perfRecorder.start());
  }
  // Resolve the project store eagerly so UI consumers of [projectsProvider]
  // never hit the FutureProvider's loading state. These opens are
  // independent — run them in parallel.
  final (
    projectStore,
    recentAgentsStore,
    recentPortsStore,
    drawerOrderStore,
    drawerCollapsedStore,
    cachedSessionsStore,
    prefs,
  ) = await (
    ProjectStore.open(),
    RecentAgentsStore.open(),
    RecentPortsStore.open(),
    DrawerOrderStore.open(),
    DrawerCollapsedStore.open(),
    CachedSessionsStore.open(),
    openAppSettingsPrefs(),
  ).wait;
  final initialAppSettings = AppSettings.fromPrefs(prefs);

  final installId = await SecureInstallIdStore().ensure();
  final platform = analyticsPlatformTag(defaultTargetPlatform);
  const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
  late final ProviderContainer container;
  final analytics = buildAnalyticsService(
    client: http.Client(),
    installId: installId,
    platform: platform,
    appVersion: appVersion,
    enabled: () => container.read(appSettingsServiceProvider).telemetryEnabled,
    plausibleUrl: AppEnvironment.plausibleUrl,
    plausibleDomain: AppEnvironment.plausibleDomain,
    eventsApiUrl: AppEnvironment.eventsApiUrl,
  );
  container = ProviderContainer(
    // Riverpod 3 auto-retries any build that throws a plain Exception (10-attempt
    // backoff), keeping `.future` PENDING meanwhile.
    retry: noProviderRetry,
    overrides: [
      projectStoreProvider.overrideWithValue(projectStore),
      recentAgentsStoreProvider.overrideWithValue(recentAgentsStore),
      recentPortsStoreProvider.overrideWithValue(recentPortsStore),
      drawerOrderStoreProvider.overrideWithValue(drawerOrderStore),
      drawerCollapsedStoreProvider.overrideWithValue(drawerCollapsedStore),
      cachedSessionsStoreProvider.overrideWithValue(cachedSessionsStore),
      appSettingsServiceProvider.overrideWith(
        () => AppSettingsService(prefs, initialAppSettings),
      ),
      projectSessionRegistryProvider.overrideWith(
        () => AppProjectSessionRegistryController(
          localCap: warmCapForBucket(isLocal: true, isMobile: isMobilePlatform),
          relayCap: warmCapForBucket(
            isLocal: false,
            isMobile: isMobilePlatform,
          ),
        ),
      ),
      analyticsServiceProvider.overrideWithValue(analytics),
    ],
  );

  // Activate the post-sign-in provisioning hook. `listen` (not a bare `read`)
  // is required: riverpod 3 deactivates a provider's OWN internal `ref.listen`
  // subscriptions once it has zero listeners of its own (see riverpod
  // CHANGELOG "provider is now considered paused if all of its listeners are
  // also paused"), and `container.read` closes its subscription immediately
  // after resolving the value. A no-op persistent listener keeps this hook's
  // `ref.listen(currentUserProvider, ...)` live for the container's lifetime.
  container.listen(postSignInProvisioningProvider, (_, _) {});

  // Eagerly warm the local bridge host + control plane on launch (desktop-only,
  // non-blocking). Same "must stay listened" reasoning as above.
  container.listen(localHostWarmupProvider, (_, _) {});

  // Register the push token on every warm RELAY session (Android + iOS).
  // requestPermission/token can throw on a device without Google Play Services;
  // never let that take down startup. Fire-and-forget: registration completing
  // after first paint is fine, unlike the deep-link/provisioning hooks above.
  //
  // Two triggers are needed because at cold start the registry is EMPTY (no
  // warm projects yet), so init()'s one-shot pass would register with nothing:
  //   (a) init() registers whatever is warm;
  //   (b) a registry listener re-runs registration whenever the warm-project
  //       set grows, so a relay session that pairs AFTER startup still gets the
  //       token. PushMessagingService dedups per-projectId so this is idempotent.
  // Token refresh (c) is handled inside init().
  if (_pushSupported) {
    Iterable<ProjectSession> warmSessions() => container
        .read(projectSessionRegistryProvider)
        .map((id) => container.read(projectSessionProvider(id)).value)
        .whereType<ProjectSession>();
    // Shared instance (not a local `PushMessagingService()`): the sign-out flow
    // resets THIS same instance so a re-sign-in re-registers — see push.dart.
    final pushService = container.read(pushMessagingServiceProvider);
    // (b) Re-register as projects become warm. `fireImmediately: false` — the
    // one-shot init() below covers the already-warm set. Kept alive for the
    // container's lifetime (same "must stay listened" reasoning as above).
    container.listen(projectSessionRegistryProvider, (_, _) {
      unawaited(
        pushService.registerNewSessions(warmSessions()).catchError((Object e) {
          debugPrint('PushMessagingService.registerNewSessions failed: $e');
        }),
      );
    });
    unawaited(
      pushService.init(sessions: warmSessions).catchError((Object e) {
        debugPrint('PushMessagingService.init failed: $e');
      }),
    );
  }

  // Deep-link handler: `antgrid://nav/...` applies a nav location;
  // `antgrid://auth/callback?token=<ott>` is redeemed for a session.
  final appLinks = AppLinks();
  Future<void> handleLink(Uri? uri) async {
    if (uri == null) return;
    // Navigation deep links (antgrid://nav/...) apply a location directly.
    final navLoc = navLocationFromUri(uri);
    if (navLoc != null) {
      container.read(navControllerProvider.notifier).applyDeepLink(navLoc);
      return;
    }
    // Auth callback (antgrid://auth/callback?token=...) — unchanged.
    await container.read(authServiceProvider).handleDeepLink(uri);
    container.invalidate(currentUserProvider);
  }

  // Subscribe for in-flight links while the app is running.
  appLinks.uriLinkStream.listen((uri) => unawaited(handleLink(uri)));

  analytics.track(AnalyticsEvents.appActive);
  WidgetsBinding.instance.addObserver(
    _TelemetryLifecycleObserver(onPause: analytics.flush),
  );

  await initCrashReporting(
    enabled: container.read(appSettingsServiceProvider).telemetryEnabled,
    dsn: AppEnvironment.sentryDsn,
    runApp: () async {
      runApp(
        UncontrolledProviderScope(container: container, child: const AbApp()),
      );
    },
  );

  // Consume the cold-start link (app launched via a `antgrid://` URL) WITHOUT
  // blocking first paint. handleDeepLink performs a network round-trip (OTT
  // redemption), so awaiting it before runApp would stall launch on a slow or
  // half-open connection. It's best-effort and invalidates currentUserProvider
  // when it completes, so the UI updates as soon as the session lands.
  unawaited(appLinks.getInitialLink().then(handleLink));
}

class _TelemetryLifecycleObserver extends WidgetsBindingObserver {
  _TelemetryLifecycleObserver({required this.onPause});
  final Future<void> Function() onPause;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(onPause());
  }
}

class AbApp extends ConsumerWidget {
  const AbApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsServiceProvider);
    final palette = paletteFor(
      preset: settings.preset,
      customBg: settings.customBg,
      customPrimary: settings.customPrimary,
      customAccent: settings.customAccent,
    );
    final theme = buildAbTheme(palette);
    // Sign-in is optional on desktop. Mobile (iOS/Android) requires an account
    // for relay pairing. Splash only while session state is genuinely unknown
    // (cold start with no cached cookie).
    const home = UpdateGate(child: _AppHome());
    return MaterialApp(
      title: 'Antgrid',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: theme,
      builder: (context, child) {
        // The snackBarTheme (floating, styling) lives in buildAbTheme; only
        // the width is dynamic — it can't live in the static theme because it
        // needs MediaQuery. A floating SnackBar with `width` is centered at
        // that width, so it doesn't span the full window on desktop/tablet
        // and isn't edge-to-edge on mobile.
        final windowWidth = MediaQuery.sizeOf(context).width;
        final snackBarWidth = (windowWidth - 2 * AbTokens.space16).clamp(
          0.0,
          480.0,
        );

        // Replace (don't compose with) the OS-provided text scaler so the
        // in-app UI Size setting is the single source of truth for text
        // scale. DPI scaling still flows via devicePixelRatio at the
        // engine layer — that is unaffected.
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(settings.uiScale)),
          child: Theme(
            data: theme.copyWith(
              snackBarTheme: theme.snackBarTheme.copyWith(width: snackBarWidth),
            ),
            child: AbTextDensity(child: child!),
          ),
        );
      },
      home: home,
    );
  }
}

/// Root route: splash while auth is unknown; sign-in gate on mobile;
/// [AppShell] otherwise. Pricing is reached from app settings only.
class _AppHome extends ConsumerWidget {
  const _AppHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Device provisioning runs fire-and-forget at sign-in; surface its
    // fair-use-cap rejection here (the one always-mounted authed root) as an
    // actionable "remove a device" dialog rather than failing silently.
    // Edge-trigger (null → non-null) so it shows once per rejection.
    ref.listen<DeviceCapInfo?>(deviceCapProvider, (prev, next) {
      if (prev == null && next != null) {
        showDeviceCapDialog(context, ref, next);
      }
    });

    final signedIn = ref.watch(signedInProvider);
    if (signedIn == null) return const _AuthSplash();

    if (isMobilePlatform && !signedIn) return const SignInScreen();

    return const AppShell();
  }
}

/// Neutral splash shown while sign-in state is unknown (cold start before
/// `currentUserProvider` resolves and no cached cookie was observed). Renders
/// in the design-system theme so there's no flash to a contrasting palette.
class _AuthSplash extends StatelessWidget {
  const _AuthSplash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SvgPicture.asset(
          'assets/logo/antgrid-wordmark.svg',
          height: AbTokens.space16 * 4.5,
          semanticsLabel: 'antgrid',
        ),
      ),
    );
  }
}
