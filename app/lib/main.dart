import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:push/push.dart';

import 'analytics/crash_reporting.dart';
import 'analytics/events.dart';
import 'analytics/install_id.dart';
import 'config/build_info.dart';
import 'config/environment.dart';
import 'config/native_crypto.dart';
import 'design/ab_colors.dart';
import 'design/ab_text_density.dart';
import 'design/ab_theme.dart';
import 'design/ab_tokens.dart';
import 'design/theme_presets.dart';
import 'launcher/host_teardown.dart';
import 'project/limits.dart';
import 'project/perf_recorder.dart';
import 'project/project_session.dart';
import 'project/project_session_registry.dart';
import 'providers/account_heartbeat.dart';
import 'providers/analytics.dart';
import 'providers/auth.dart';
import 'providers/cached_sessions.dart';
import 'providers/collapsed_drawer.dart';
import 'providers/demo_mode.dart';
import 'providers/device_revocation.dart';
import 'providers/drawer_order.dart';
import 'providers/first_run.dart';
import 'providers/host_status.dart';
import 'providers/local_host_warmup.dart';
import 'providers/post_signin_provisioning.dart';
import 'providers/projects.dart';
import 'providers/provider_retry.dart';
import 'providers/push.dart';
import 'providers/recent_agents.dart';
import 'providers/recent_ports.dart';
import 'navigation/nav_console.dart';
import 'navigation/nav_controller.dart';
import 'navigation/nav_serialization.dart';
import 'navigation/platform_route_guard.dart';
import 'navigation/root_navigator.dart';
import 'screens/app_shell.dart';
import 'screens/demo_home.dart';
import 'screens/device_cap_dialog.dart';
import 'screens/sign_in_screen.dart';
import 'services/devices_api.dart' show DeviceCapInfo;
import 'services/app_settings_service.dart';
import 'services/push_background_handler.dart';
import 'providers/update_available.dart';
import 'storage/cached_sessions_store.dart';
import 'storage/drawer_collapsed_store.dart';
import 'storage/drawer_order_store.dart';
import 'storage/first_run_store.dart';
import 'storage/project_store.dart';
import 'storage/recent_agents_store.dart';
import 'storage/recent_ports_store.dart';
import 'storage/update_handoff_store.dart';
import 'update/update_gate.dart';
import 'util/ab_log.dart';
import 'widgets/auth_splash.dart';
import 'widgets/demo_frame.dart';
import 'window/window_chrome.dart';

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
  // Before any socket can seal a frame: the default cipher is pure Dart and
  // blocks the UI isolate for the whole of a tunneled preview response.
  installNativeE2eCipher();
  // OFL 1.1 obliges us to distribute the licence alongside the bundled
  // JetBrains Mono NL faces. The asset is the distribution; this makes it
  // reachable from the standard Flutter licence listing.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'JetBrains Mono NL',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  // Draw behind transparent system bars on mobile so the app's own dark
  // surfaces reach the screen edges (no opaque OS bar bands). Bar icon
  // brightness is applied per-palette via the AnnotatedRegion in AbApp.
  if (isMobilePlatform) {
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }
  // Before the first frame: a style change after the window is visible flashes
  // the OS bar.
  await initDesktopWindowChrome();
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
    firstRunStore,
    prefs,
    updateHandoffStore,
  ) = await (
    ProjectStore.open(),
    RecentAgentsStore.open(),
    RecentPortsStore.open(),
    DrawerOrderStore.open(),
    DrawerCollapsedStore.open(),
    CachedSessionsStore.open(),
    FirstRunStore.open(),
    openAppSettingsPrefs(),
    UpdateHandoffStore.open(),
  ).wait;
  final initialAppSettings = AppSettings.fromPrefs(prefs);

  // Consumed unconditionally, never behind Windows' `--after-update` argument:
  // that comes back after a crash, a hang and a reboot-to-patch as well as
  // after an update, so it is not evidence; and Sparkle's relaunch on macOS
  // passes no argument at all, so requiring it would mean no macOS or Linux
  // announcement ever. A version recorded at hand-off that no longer matches
  // the running build is the evidence, on every platform. Once per launch, so
  // it can never announce twice.
  final updatedFromVersion = await updateHandoffStore.consume(
    BuildInfo.version,
  );

  final installId = await SecureInstallIdStore().ensure();
  final platform = analyticsPlatformTag(defaultTargetPlatform);
  late final ProviderContainer container;
  final analytics = buildAnalyticsService(
    client: http.Client(),
    installId: installId,
    platform: platform,
    appVersion: BuildInfo.version,
    enabled: () => telemetryAllowed(container),
    // NOT folded into `enabled`: that predicate also decides whether a queued
    // batch is DROPPED, and the demo must not throw away the real events the
    // user queued before entering it.
    paused: () => container.read(demoModeProvider),
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
      firstRunStoreProvider.overrideWithValue(firstRunStore),
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
      updateHandoffStoreProvider.overrideWithValue(updateHandoffStore),
      afterUpdateLaunchProvider.overrideWithValue(updatedFromVersion),
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

  // Same "must stay listened" reasoning as above: keeps this device's
  // `lastSeenAt` fresh in the account Devices dashboard for the app's lifetime.
  container.listen(accountHeartbeatProvider, (_, _) {});

  // Eagerly warm the local bridge host + control plane on launch (desktop-only,
  // non-blocking). Same "must stay listened" reasoning as above.
  container.listen(localHostWarmupProvider, (_, _) {});

  // Supervision of that host: re-bind open local projects after a respawn.
  // Must stay listened for the whole app lifetime, like the warm-up above.
  container.listen(hostRestartRebindProvider, (_, _) {});

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
          AbLog.error(
            'Main',
            'PushMessagingService.registerNewSessions failed',
            fields: {'error': '$e'},
          );
        }),
      );
    });
    unawaited(
      pushService.init(sessions: warmSessions).catchError((Object e) {
        AbLog.error(
          'Main',
          'PushMessagingService.init failed',
          fields: {'error': '$e'},
        );
      }),
    );
  }

  // Deep links are routed here, never by the framework. Registered before
  // runApp so it outranks WidgetsApp's own observer, which can only crash on a
  // platform route push — see PlatformRouteGuard.
  WidgetsBinding.instance.addObserver(PlatformRouteGuard());

  // Deep-link handler: `antgrid://nav/...` applies a nav location;
  // `antgrid://auth/callback?token=<ott>` is redeemed for a session.
  final appLinks = AppLinks();
  Future<void> handleLink(Uri? uri) async {
    if (uri == null) return;
    // Navigation deep links (antgrid://nav/...) apply a location directly.
    final navLoc = navLocationFromUri(uri);
    if (navLoc != null) {
      // A link names a REAL place — a machine, a project, a session — and the
      // user asked for it, so it wins over the sample project rather than being
      // dropped. Leaving first is what makes it whole: the demo's target is
      // cleared, its transport disposed and its nav history reset, so the link
      // does not land under a banner saying nothing is connected while the
      // drawer still lists only the demo.
      if (container.read(demoModeProvider)) exitDemoMode(container);
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

/// Whether an analytics event may leave the device.
///
/// The single chokepoint for ANALYTICS while the demo is on: the sample project
/// is reachable with no account behind it, so there is nobody to attribute an
/// event to and nothing there but canned data anyway. Gating here rather than
/// per call site covers the widget-level `track(...)` calls too, which the
/// per-session sink never sees.
///
/// Crash reporting is deliberately NOT gated with it. `initCrashReporting`
/// wraps `runApp`, so its decision is made before a demo can be entered — and a
/// crash under the sample project is the one report worth having, since it is
/// exactly what a store reviewer would hit. It answers to the user's own
/// telemetry setting alone, demo or not.
@visibleForTesting
bool telemetryAllowed(ProviderContainer container) =>
    !container.read(demoModeProvider) &&
    container.read(appSettingsServiceProvider).telemetryEnabled;

/// System-bar overlay style for [palette]: transparent bars (the app draws
/// edge-to-edge on mobile, see main()) with icon brightness flipped off the
/// background luminance so bar icons stay legible on light presets too.
@visibleForTesting
SystemUiOverlayStyle systemBarStyleFor(AbColors palette) {
  final iconBrightness = palette.bgDeepest.computeLuminance() > 0.5
      ? Brightness.dark
      : Brightness.light;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: iconBrightness,
    // iOS reads statusBarBrightness as the brightness of the bar's BACKGROUND
    // (the app surface behind it), i.e. the inverse of the icon brightness.
    statusBarBrightness: iconBrightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: iconBrightness,
  );
}

/// Effective text scaler for the app subtree. Desktop replaces the OS scaler
/// outright — the in-app UI Size setting is the single source of truth there.
/// Mobile composes with the OS accessibility setting: `scale(1.0)`
/// deliberately linearizes Android 14+ nonlinear scaling (a nonlinear curve
/// composed with our own factor double-distorts mid sizes), and the product is
/// clamped so extreme OS settings can't break the terminal grid.
@visibleForTesting
TextScaler composedTextScalerFor({
  required double uiScale,
  required TextScaler osTextScaler,
}) {
  if (!isMobilePlatform) return TextScaler.linear(uiScale);
  final composed = (uiScale * osTextScaler.scale(1.0)).clamp(0.85, 2.0);
  return TextScaler.linear(composed.toDouble());
}

/// Palette actually rendered, after the follow-system-brightness setting.
/// When enabled: OS-light renders the `light` preset; OS-dark renders the
/// user's chosen preset — unless that chosen preset IS light, which would
/// blind in a dark room, so it falls back to the default dark palette.
/// When disabled the chosen palette passes through untouched.
@visibleForTesting
AbColors effectivePaletteFor({
  required AppSettings settings,
  required AbColors chosen,
  required Brightness platformBrightness,
}) {
  if (!settings.followSystemBrightness) return chosen;
  if (platformBrightness == Brightness.light) {
    return kPresets[AbThemePreset.light]!;
  }
  return settings.preset == AbThemePreset.light ? kDefaultPalette : chosen;
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
      navigatorKey: ref.watch(rootNavigatorKeyProvider),
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: theme,
      builder: (context, child) {
        // The OS-provided MediaQuery, captured BEFORE our copyWith below
        // replaces scaler/animation fields — its textScaler, disableAnimations
        // and platformBrightness are the accessibility inputs we compose with.
        final osMediaQuery = MediaQuery.of(context);

        // The snackBarTheme (floating, styling) lives in buildAbTheme; only
        // the width is dynamic — it can't live in the static theme because it
        // needs MediaQuery. A floating SnackBar with `width` is centered at
        // that width, so it doesn't span the full window on desktop/tablet
        // and isn't edge-to-edge on mobile.
        final windowWidth = osMediaQuery.size.width;
        final snackBarWidth = (windowWidth - 2 * AbTokens.space16).clamp(
          0.0,
          480.0,
        );

        // Resolved here (not in AbApp.build) so MediaQuery.platformBrightnessOf
        // re-runs the builder on every OS light/dark flip. MaterialApp's
        // `theme:` above is only the pre-follow chosen theme; everything
        // visible renders under the Theme override below, so swapping the
        // effective theme + bar style here flips the whole app in lockstep.
        final effectivePalette = effectivePaletteFor(
          settings: settings,
          chosen: palette,
          platformBrightness: MediaQuery.platformBrightnessOf(context),
        );
        final effectiveTheme = identical(effectivePalette, palette)
            ? theme
            : buildAbTheme(effectivePalette);

        // DPI scaling still flows via devicePixelRatio at the engine layer —
        // the textScaler override is unaffected by it.
        // System bars track the LIVE effective palette: the builder re-runs on
        // every settings change, so a preset switch restyles bar icons
        // immediately.
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: systemBarStyleFor(effectivePalette),
          child: MediaQuery(
            data: osMediaQuery.copyWith(
              textScaler: composedTextScalerFor(
                uiScale: settings.uiScale,
                osTextScaler: osMediaQuery.textScaler,
              ),
              // OS reduce-motion OR the in-app toggle — design widgets read
              // only MediaQuery.disableAnimationsOf, so this is the single
              // distribution point (no Riverpod in the design system).
              disableAnimations:
                  osMediaQuery.disableAnimations || settings.reduceMotion,
            ),
            child: Theme(
              data: effectiveTheme.copyWith(
                snackBarTheme: effectiveTheme.snackBarTheme.copyWith(
                  width: snackBarWidth,
                ),
              ),
              // Mounted from the builder, not from a screen: the console has to
              // outlive every route and stay out of the shell's own layout,
              // which is also what lets it drive navigation from wherever the
              // app currently is. It renders nothing unless the driver entry
              // point enabled it.
              child: AbTextDensity(
                child: NavConsole(child: DemoFrame(child: child!)),
              ),
            ),
          ),
        );
      },
      home: home,
    );
  }
}

/// [deviceCapProvider], held back while the demo is on.
///
/// The cap dialog's remedy is revoking one of the user's REAL account devices,
/// which the demo may never do — and it opens on the root navigator, so from
/// inside the demo it lands over the sample project, under the banner saying
/// nothing is connected. Held back rather than dropped: the cap value survives
/// until the dialog itself clears it, so this provider goes null → cap on the
/// build that leaves the demo and the listener's edge fires there instead.
final _pendingDeviceCapProvider = Provider<DeviceCapInfo?>((ref) {
  if (ref.watch(demoModeProvider)) return null;
  return ref.watch(deviceCapProvider);
});

/// Root route: splash while auth is unknown; sign-in gate on mobile;
/// [AppShell] otherwise. Pricing is reached from app settings only.
class _AppHome extends ConsumerWidget {
  const _AppHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Device provisioning runs fire-and-forget at sign-in; surface its cap
    // rejections here (the one always-mounted authed root) as an actionable
    // free-a-slot dialog rather than failing silently. The cap kind travels on
    // DeviceCapInfo, so the dialog picks device-cap vs worker-cap copy itself.
    // Edge-trigger (null → non-null) so it shows once per rejection.
    ref.listen<DeviceCapInfo?>(_pendingDeviceCapProvider, (prev, next) {
      if (prev == null && next != null) {
        showDeviceCapDialog(context, ref, next);
      }
    });

    // Above every account gate below, because the demo has no account: it is
    // reached from the sign-in screen itself, which is the only surface a
    // reviewer with no desktop and no credentials ever sees.
    if (ref.watch(demoModeProvider)) return const DemoHome();

    // A revocation forces the sign-in screen on EVERY platform. Desktop is
    // otherwise ungated (it drives its own machine locally and only offers
    // sign-in from the drawer), but a revoked device has no credentials left —
    // leaving it in the shell would show a workspace it can no longer reach.
    if (ref.watch(revokedNoticeProvider)) return const SignInScreen();

    final signedIn = ref.watch(signedInProvider);
    if (signedIn == null) return const AuthSplash();

    if (isMobilePlatform && !signedIn) return const SignInScreen();

    return const AppShell();
  }
}
