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

/// Fair-use device-cap dialog: states the cap in plain terms ("remove a device",
/// never "upgrade" — `deviceLimit` is flat across tiers) and lets the user
/// revoke a registered device, then retries provisioning this machine.
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

  Future<void> _remove(CappedDevice d) async {
    final confirmed = await AbConfirmDialog.show(
      context: context,
      title: 'Remove device?',
      body:
          '"${d.displayName}" will lose remote access until it registers '
          'again. This frees a slot so this machine can register.',
      confirmLabel: 'Remove',
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
      setState(
        () => _error = e.code == 'DEVICE_CAP'
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
                      'Device limit reached',
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
              Align(
                alignment: Alignment.centerRight,
                child: AbButton(
                  label: 'Close',
                  onTap: busy ? null : () => Navigator.of(context).pop(),
                ),
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
    required this.onRemove,
  });

  final CappedDevice device;
  final bool busy;
  final bool isBusy;
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
        label: isBusy ? 'Removing…' : 'Remove',
        color: busy ? null : p.error,
        compact: true,
        onTap: busy ? null : onRemove,
      ),
    );
  }
}
