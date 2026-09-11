import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../navigation/notification_route.dart';

/// What a tapped OS notification named, or null when it carried no route.
///
/// The payload is the ONLY input, deliberately:
///
/// - The response type says nothing useful. On Windows a plain body tap arrives
///   as [NotificationResponseType.selectedNotificationAction], because the
///   plugin classifies on whether the toast's `launch` argument is non-null
///   (`src/plugin.cpp:50-53`) and our payload IS that argument — so filtering on
///   `selectedNotification` would drop every Windows tap.
/// - `actionId` says nothing either, and worse. The same Windows path fills it
///   with the payload verbatim (`lib/src/plugin/ffi.dart:127-133`), so treating
///   a non-null `actionId` as a button press misroutes every Windows tap. We add
///   no action buttons anywhere, so there is no button case to tell apart.
/// - `id` is never keyed on: it is null on Windows and, on the platforms that do
///   carry one, it is a per-isolate counter that the headless push isolate and
///   the main engine mint independently.
NotificationRoute? routeOfTapResponse(NotificationResponse r) =>
    decodeNotificationRoute(r.payload);

/// Whether `Push.addOnNotificationTap` may be registered on [platform].
///
/// iOS alone, and the narrowing is the substance rather than a transport check:
/// on Android `PushPlugin` rebuilds a RemoteMessage out of ANY launch intent's
/// extras and fires that callback whenever the resulting data map is non-empty
/// — and fln's own select-notification intent carries a `payload` String extra,
/// so registering there would deliver every Android tap a second time in a
/// different shape.
bool pushTapRegistrationSupported(TargetPlatform platform) =>
    platform == TargetPlatform.iOS;

/// Whether `getNotificationAppLaunchDetails` may be called on [platform].
///
/// fln has no Linux branch and falls through to a platform-interface base that
/// THROWS UnimplementedError; Windows both throws StateError before `initialize`
/// and hard-codes `didNotificationLaunchApp` true for a warm tap it has already
/// delivered in-process, which would replay that tap at every launch.
bool launchDetailsSupported(TargetPlatform platform) =>
    platform == TargetPlatform.iOS ||
    platform == TargetPlatform.android ||
    platform == TargetPlatform.macOS;
