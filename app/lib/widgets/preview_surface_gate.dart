import 'package:flutter/widgets.dart';

import '../utils/platform_utils.dart';
import 'display_visibility.dart';

/// Takes a mounted preview WebView off screen while nobody can see it.
///
/// Staying mounted keeps a WebView rendering. The Windows plugin stops copying
/// page frames into Flutter, and the Linux overlay hides, only when an
/// ancestor's `paintsChild` says the WebView is not painted, and an
/// `IndexedStack` never says so. Every page frame of a preview hidden behind
/// another workspace tab, or of a background preview tab, would still make
/// Flutter raster the whole window. [Offstage] answers that check and keeps the
/// page and its state alive.
///
/// The workspace panel's visibility gates desktop only. A phone's WebView is a
/// platform view, which already leaves the screen when it is not painted, so it
/// needs no help there; and a phone's workspace page reports itself visible
/// only once a swipe passes halfway, so gating on it would blank the preview
/// for the first half of every swipe in.
class PreviewSurfaceGate extends StatelessWidget {
  const PreviewSurfaceGate({
    super.key,
    required this.isActiveTab,
    required this.child,
  });

  final bool isActiveTab;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final panelShown = isMobilePlatform || DisplayVisibilityScope.of(context);
    return Offstage(offstage: !(isActiveTab && panelShown), child: child);
  }
}
