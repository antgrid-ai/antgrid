import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../gallery_scaffold.dart';

/// A danger action that opens a confirmation modal with a busy primary
/// action, then reports the outcome inline and as a toast.
class ConfirmationFlowComposition extends StatefulWidget {
  const ConfirmationFlowComposition({super.key});

  @override
  State<ConfirmationFlowComposition> createState() =>
      _ConfirmationFlowCompositionState();
}

class _ConfirmationFlowCompositionState
    extends State<ConfirmationFlowComposition> {
  final CarbonToastController _toasts = CarbonToastController();
  bool _failNext = false;
  CarbonNotificationKind? _outcome;

  @override
  void dispose() {
    _toasts.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final fail = _failNext;
    final ok = await showCarbonModal<bool>(
      context,
      barrierDismissible: false,
      builder: (_) => _DeleteDialog(fail: fail),
    );
    if (!mounted || ok == null) return;
    final kind = ok ? CarbonNotificationKind.success : CarbonNotificationKind.error;
    setState(() => _outcome = kind);
    _toasts.show(
      kind: kind,
      title: ok ? 'Workspace deleted' : 'Deletion failed',
      subtitle: ok
          ? 'Its sessions and worktrees were removed.'
          : 'The workspace is still in use. Try again.',
      autoDismiss: const Duration(seconds: 6),
    );
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    return CarbonToastOverlay(
      controller: _toasts,
      child: GalleryPage(
        title: 'Confirmation flow',
        summary:
            'Irreversible actions ask first, keep the dialog open while they '
            'run and say what happened afterwards.',
        children: [
          GallerySection(
            title: 'Delete a workspace',
            children: [
              CarbonButton(
                key: const ValueKey('confirm-open'),
                label: 'Delete workspace antgrid-public-staging',
                kind: CarbonButtonKind.danger,
                onPressed: _confirm,
              ),
              CarbonToggle(
                value: _failNext,
                labelText: 'Make the next attempt fail',
                onChanged: (v) => setState(() => _failNext = v),
              ),
              if (outcome != null)
                CarbonNotification(
                  key: const ValueKey('confirm-outcome'),
                  kind: outcome,
                  title: outcome == CarbonNotificationKind.success
                      ? 'Workspace deleted'
                      : 'Deletion failed',
                  subtitle: outcome == CarbonNotificationKind.success
                      ? 'It no longer appears in your project list.'
                      : 'Nothing was removed.',
                  onClose: () => setState(() => _outcome = null),
                ),
            ],
          ),
          const GalleryNote(
            useWhen:
                'Destructive or hard-to-undo actions. Name the object and '
                'the consequence in the dialog.',
            keyboard:
                'Focus starts on Cancel; Tab stays inside the dialog; Escape '
                'cancels except while the action runs.',
            accessibility:
                'Dialog semantics with a title; the busy action is announced '
                'and cannot be activated twice; the outcome is a live '
                'notification.',
            carbonReference: 'Carbon Modal (danger), Notification, Toast.',
          ),
        ],
      ),
    );
  }
}

class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({required this.fail});

  final bool fail;

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  bool _busy = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _run() {
    if (_busy) return;
    setState(() => _busy = true);
    _timer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) Navigator.of(context).pop(!widget.fail);
    });
  }

  @override
  Widget build(BuildContext context) {
    return CarbonModal.confirmation(
      label: 'Workspace',
      title: 'Delete antgrid-public-staging?',
      body: const Text(
        'This removes the workspace, its 14 sessions and every isolated '
        'checkout. You cannot undo this.',
      ),
      danger: true,
      secondary: CarbonModalAction(
        label: 'Cancel',
        autofocus: true,
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
      ),
      primary: CarbonModalAction(
        label: 'Delete workspace',
        busy: _busy,
        onPressed: _run,
      ),
    );
  }
}
