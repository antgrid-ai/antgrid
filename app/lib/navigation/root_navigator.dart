import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Key on the app's one Navigator, handed to `MaterialApp.navigatorKey`.
///
/// Provider-owned for the same reason `sessionSearchFocusProvider` is: the
/// Navigator mounts above every route, and the code that needs to drive it
/// holds a [ProviderContainer] rather than a `BuildContext` — `enterDemoMode`
/// and `exitDemoMode` are called from callbacks whose widget is already being
/// popped out from under them.
///
/// A provider rather than a top-level global so each test container gets its
/// own key; two live containers sharing one would attach it twice.
final rootNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>(
  (ref) => GlobalKey<NavigatorState>(),
);
