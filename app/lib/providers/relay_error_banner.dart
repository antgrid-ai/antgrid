import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'value_controller.dart';

/// Inline relay-error notice surfaced above the workspace body for a
/// connection block the supervisor cannot climb past on its own
/// (license/auth/etc. — see `workspace_shell.dart`'s `SESSIONS`/`LICENSE`
/// codes). Replaces the deleted full-screen `LicenseBlockedScreen`.
class RelayErrorBanner {
  final String code;
  final String message;
  const RelayErrorBanner(this.code, this.message);
}

final relayErrorBannerProvider =
    NotifierProvider<ValueController<RelayErrorBanner?>, RelayErrorBanner?>(
      () => ValueController(null),
    );
