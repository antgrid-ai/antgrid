import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_all/webview_all.dart';

import '../services/preview_site_data.dart';
import '../storage/preview_origin_owner_store.dart';
import 'demo_mode.dart';

/// Not autoDispose: the preview screen and sign-out must share one queue and
/// one set of outstanding page retirements.
final previewSiteDataProvider = Provider<PreviewSiteData>(
  (ref) => PreviewSiteData(
    store: PreviewOriginOwnerStore(),
    wipe: _wipeDefaultProfile,
    isDemoMode: () => ref.read(demoModeProvider),
  ),
);

Future<WebViewDataClearingResult?> _wipeDefaultProfile() async {
  // WebViewDataManager asserts a registered platform; none is under
  // `flutter test`.
  if (WebViewPlatform.instance == null) return null;
  return WebViewDataManager().clearAllWebsiteData();
}
