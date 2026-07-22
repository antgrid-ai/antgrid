import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_toast.dart';
import 'in_app_update_service.dart';

/// Root wrapper that drives the Google Play in-app update flow (Android only).
///
/// Checks for an update once after the first frame and again whenever the app
/// resumes, throttled so rapid background/foreground cycling doesn't hammer
/// Play. On non-Android platforms it's an inert pass-through — no observer, no
/// checks. Mounted above the auth-routed root so the check runs regardless of
/// sign-in state, and below the MaterialApp `Overlay` so the flexible-update
/// restart prompt can surface via [showAbToastOverlay].
class UpdateGate extends StatefulWidget {
  const UpdateGate({super.key, required this.child});

  final Widget child;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> with WidgetsBindingObserver {
  static const _throttle = Duration(minutes: 30);

  final InAppUpdateService _service = const InAppUpdateService();
  bool get _active => defaultTargetPlatform == TargetPlatform.android;

  DateTime? _lastCheck;

  @override
  void initState() {
    super.initState();
    if (!_active) return;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeCheck());
  }

  @override
  void dispose() {
    if (_active) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _maybeCheck();
  }

  Future<void> _maybeCheck() async {
    final now = DateTime.now();
    final last = _lastCheck;
    if (last != null && now.difference(last) < _throttle) return;
    _lastCheck = now;

    final decision = await _service.checkAndStart();
    if (!mounted) return;
    if (decision == UpdateDecision.flexibleReady) _showRestartPrompt();
  }

  void _showRestartPrompt() {
    showAbToastOverlay(
      context,
      duration: const Duration(seconds: 30),
      toast: AbToast(
        icon: AbIcons.arrowDown,
        title: 'Update ready',
        description: 'A new version has been downloaded.',
        actionLabel: 'Restart',
        onAction: () => _service.completeFlexibleUpdate(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
