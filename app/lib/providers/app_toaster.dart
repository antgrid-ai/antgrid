import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/widgets/ab_toast.dart';

/// The app's one toast stack, rendered by the [AbToastHost] that `main.dart`
/// mounts around the Navigator.
///
/// Provider-owned for the same reason `rootNavigatorKeyProvider` is: some
/// callers speak long after their widget is gone and hold a
/// [ProviderContainer] rather than a `BuildContext`. A provider rather than a
/// top-level global so each test container gets its own.
final appToasterProvider = Provider<AbToaster>((ref) {
  final toaster = AbToaster();
  ref.onDispose(toaster.dispose);
  return toaster;
});
