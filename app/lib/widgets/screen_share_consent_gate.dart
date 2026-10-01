import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/screen_share_service.dart';
import 'screen_preview_panel.dart';

/// Invisible host for the window picker.
///
/// A remote peer's `screen:request` can land while the user is anywhere in the
/// workspace, and the consent decision cannot wait for them to find the preview
/// tab — so the picker is raised from the shell rather than from the panel. The
/// panel's own "Choose a window" button is the same dialog reached deliberately.
class ScreenShareConsentGate extends ConsumerStatefulWidget {
  const ScreenShareConsentGate({super.key});

  @override
  ConsumerState<ScreenShareConsentGate> createState() =>
      _ScreenShareConsentGateState();
}

class _ScreenShareConsentGateState
    extends ConsumerState<ScreenShareConsentGate> {
  bool _pickerOpen = false;

  Future<void> _prompt() async {
    if (_pickerOpen) return;
    // Never the throwing façade from a listener: the focused project's session
    // can be mid-rebuild here, and that throw would land outside any build().
    final service = focusedServiceOrNull(
      ref.container,
      (s) => s.screenShareService,
    );
    if (service == null || !service.canHost) return;
    _pickerOpen = true;
    try {
      await pickAndShareWindow(
        context,
        service,
        prompt:
            'A signed-in device asked to see a window on this machine. Pick the '
            'one to stream, or close this to decline.',
      );
    } finally {
      _pickerOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(screenShareStateProvider.select((s) => s.value?.stage), (
      previous,
      next,
    ) {
      // Only the transition INTO awaiting-consent raises the dialog. The state
      // re-emits on every focus switch, and re-prompting for a request the user
      // already answered would be indistinguishable from a new one.
      if (next != ScreenShareStage.awaitingConsent) return;
      if (previous == ScreenShareStage.awaitingConsent) return;
      unawaited(_prompt());
    });
    return const SizedBox.shrink();
  }
}
