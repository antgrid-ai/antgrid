import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_tooltip.dart';
import '../providers/auth.dart';
import '../providers/device_provisioning.dart';
import '../providers/post_signin_provisioning.dart';
import '../services/devices_api.dart';

/// Shows the device-cap remediation dialog and resolves when it is dismissed.
/// Always clears [deviceCapProvider] on close so a later provisioning attempt
/// can re-surface it.
Future<void> showDeviceCapDialog(
  BuildContext context,
  WidgetRef ref,
  DeviceCapInfo info,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => DeviceCapDialog(info: info),
  );
  ref.read(deviceCapProvider.notifier).set(null);
}

/// Cap remediation dialog, shared by both caps because both are answered the
/// same way: revoke one of the listed devices, then retry provisioning this
/// machine. Only the copy differs — `deviceLimit` is flat across tiers so its
/// variant never mentions upgrading, while the worker cap is the paid axis and
/// shows an upgrade affordance (disabled until checkout ships).
class DeviceCapDialog extends ConsumerStatefulWidget {
  const DeviceCapDialog({super.key, required this.info});

  final DeviceCapInfo info;

  @override
  ConsumerState<DeviceCapDialog> createState() => _DeviceCapDialogState();
}

class _DeviceCapDialogState extends ConsumerState<DeviceCapDialog> {
  late final List<CappedDevice> _devices = List.of(widget.info.devices);
  String? _busyId;
  String? _error;

  bool get _isWorker => widget.info.kind == DeviceCapKind.worker;

  Future<void> _remove(CappedDevice d) async {
    final confirmed = await AbConfirmDialog.show(
      context: context,
      title: _isWorker ? 'Sign out worker?' : 'Remove device?',
      body: _isWorker
          ? '"${d.displayName}" will stop running agents remotely until it '
                'registers again. This frees a worker so this machine can '
                'register.'
          : '"${d.displayName}" will lose remote access until it registers '
                'again. This frees a slot so this machine can register.',
      confirmLabel: _isWorker ? 'Sign out' : 'Remove',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _busyId = d.id;
      _error = null;
    });
    final ok = await ref.read(devicesApiProvider).revoke(d.id);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busyId = null;
        _error =
            'Could not remove "${d.displayName}". '
            'Check your connection and try again.';
      });
      return;
    }
    setState(() {
      _devices.removeWhere((x) => x.id == d.id);
      _busyId = null;
    });

    // A slot is free — register this machine now and close on success.
    try {
      await retryDeviceProvisioning(ref);
      if (mounted) Navigator.of(context).pop();
    } on ProvisioningException catch (e) {
      if (!mounted) return;
      // Still capped (or transient) — keep the dialog open; the list already
      // reflects the removal so the user can free another slot.
      final stillCapped = e.code == 'DEVICE_CAP' || e.code == 'WORKER_CAP';
      setState(
        () => _error = stillCapped
            ? null
            : 'Removed, but registration failed: ${e.message}',
      );
    } catch (_) {
      // The device is already revoked; a non-provisioning failure here (e.g. a
      // keychain/secure-storage read throwing) must not escape as an unhandled
      // async error — keep the dialog open with actionable feedback.
      if (!mounted) return;
      setState(() => _error = 'Removed, but registration failed. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final busy = _busyId != null;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _isWorker
                          ? 'Worker limit reached'
                          : 'Device limit reached',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontBody,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  AbIconButton(
                    icon: AbIcons.close,
                    onTap: busy ? null : () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: AbTokens.space12),
              Text(
                widget.info.message,
                style: TextStyle(
                  fontSize: AbTokens.fontSm,
                  color: p.textSecondary,
                ),
              ),
              if (_devices.isNotEmpty) ...[
                const SizedBox(height: AbTokens.space16),
                // Bounded so a long device list scrolls instead of overflowing.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final d in _devices)
                          _DeviceRow(
                            device: d,
                            busy: busy,
                            isBusy: _busyId == d.id,
                            isWorker: _isWorker,
                            onRemove: () => _remove(d),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: AbTokens.space12),
                Text(
                  _error!,
                  style: TextStyle(fontSize: AbTokens.fontSm, color: p.error),
                ),
              ],
              const SizedBox(height: AbTokens.space16),
              // Wrap, not Row: the worker variant's three children exceed the
              // dialog's content width on a 320pt phone, and any textScaler
              // above 1.0 overflows it on every phone.
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AbTokens.space8,
                runSpacing: AbTokens.space8,
                children: [
                  if (_isWorker) ...[
                    // Checkout is not wired yet, so the paid path is shown and
                    // legibly shut rather than absent. The tooltip alone would
                    // leave the button unexplained on mobile (no hover), hence
                    // the inline label beside it.
                    Text(
                      'Coming soon',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: p.textMuted,
                      ),
                    ),
                    const AbTooltip(
                      message: 'Coming soon',
                      child: AbButton(label: 'Upgrade'),
                    ),
                  ],
                  AbButton(
                    label: 'Close',
                    onTap: busy ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.busy,
    required this.isBusy,
    required this.isWorker,
    required this.onRemove,
  });

  final CappedDevice device;
  final bool busy;
  final bool isBusy;
  final bool isWorker;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return AbListRow(
      horizontalPadding: 0,
      density: AbRowDensity.sm,
      title: Text(device.displayName),
      // deviceId is code/data → mono (overrides the row's default sans subtitle).
      subtitle: Text(
        device.deviceId,
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          color: p.textMuted,
        ),
      ),
      trailing: AbButton(
        label: switch ((isWorker, isBusy)) {
          (true, true) => 'Signing out…',
          (true, false) => 'Sign out',
          (false, true) => 'Removing…',
          (false, false) => 'Remove',
        },
        color: busy ? null : p.error,
        compact: true,
        onTap: busy ? null : onRemove,
      ),
    );
  }
}
