import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'value_controller.dart';

/// Inline relay-error notice surfaced above the workspace body when the
/// agent reports an `agent:relayError` frame (license/auth/etc.). Replaces
/// the deleted full-screen `LicenseBlockedScreen`.
class RelayErrorBanner {
  final String code;
  final String message;
  const RelayErrorBanner(this.code, this.message);
}

final relayErrorBannerProvider =
    NotifierProvider<ValueController<RelayErrorBanner?>, RelayErrorBanner?>(
      () => ValueController(null),
    );
