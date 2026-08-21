import 'package:flutter/widgets.dart';

import '../util/ab_log.dart';

/// Claims the platform's route-push notifications so `WidgetsApp` never sees one.
///
/// The app is a single-route shell (`MaterialApp.home`) with no `routes` table,
/// no `onGenerateRoute` and no `onUnknownRoute`. `WidgetsApp`'s own observer
/// answers a platform route push with `Navigator.pushNamed(<the uri's path>)`,
/// which matches nothing and then dereferences `widget.onUnknownRoute!` — a
/// null-check TypeError that shipped as a fatal in 1.20677.173. Android's
/// embedding forwards every `antgrid://` VIEW intent down this channel unless
/// `flutter_deeplinking_enabled` is false, so the OAuth return leg crashed the
/// moment the browser handed the app back.
///
/// Deep links belong to `app_links` (`handleLink` in main.dart), which reads the
/// intent through its own listener and is unaffected by this. What this must NOT
/// do is re-dispatch the link itself: the auth callback carries a single-use
/// OTT, and a second redemption fails.
///
/// Register before `runApp` — observers are consulted in registration order and
/// the first `true` wins, so this outranks `WidgetsApp` only if it is added
/// before `_WidgetsAppState.initState` adds its own observer.
class PlatformRouteGuard extends WidgetsBindingObserver {
  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async {
    final uri = routeInformation.uri;
    // Path only, never the query: the auth callback's token is a credential and
    // this log line lands in a file on disk.
    AbLog.debug(
      'DeepLink',
      'swallowed platform route push',
      fields: {'scheme': uri.scheme, 'host': uri.host, 'path': uri.path},
    );
    return true;
  }
}
