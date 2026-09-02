import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../providers/auth.dart';
import '../providers/device_provisioning.dart';
import '../providers/post_signin_provisioning.dart';
import '../services/devices_api.dart';
import '../util/detached.dart';
import '../util/external_url.dart';

/// Where the worker-cap variant sends someone who wants more machines. There is
/// no checkout to send them to during the beta, so the ask is captured on the
/// site instead; no price is named here or on the way out, because none is
/// committed to yet.
const _foundingPricingUrl = 'https://antgrid.ai/pricing';

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
/// machine. Only the copy differs — `appDeviceLimit` is an abuse ceiling that
/// pricing never mentions, so its variant never offers upgrading, while the
/// worker cap is the paid axis and points at the founding-price waitlist.
class DeviceCapDialog extends ConsumerStatefulWidget {
  const DeviceCapDialog({super.key, required this.info});

  final DeviceCapInfo info;

  @override
  ConsumerState<DeviceCapDialog> createState() => _DeviceCapDialogState();
}

class _DeviceCapDialogState extends ConsumerState<DeviceCapDialog> {
  /// The cap currently being remediated. Held in state, not read off the
  /// widget: the two caps are independent, so freeing a slot for one can expose
  /// the other, and the retry's rejection is the only thing that knows which is
  /// live now. Rendering the opening cap after that swap would offer the wrong
  /// remedy against the wrong device list.
  late DeviceCapInfo _info = widget.info;
  late List<CappedDevice> _devices = List.of(widget.info.devices);
  String? _busyId;
  String? _error;

  bool get _isWorker => _info.kind == DeviceCapKind.worker;

  Future<void> _remove(CappedDevice d) async {
    final confirmed = await AbConfirmDialog.show(
      context: context,
      title: _isWorker ? 'Sign out machine?' : 'Remove device?',
      body: _isWorker
          ? '"${d.displayName}" will stop running agents remotely until it '
                'registers again. This frees a machine slot so this one can '
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
      final stillCapped = e.code == 'APP_DEVICE_CAP' || e.code == 'WORKER_CAP';
      setState(() {
        // Re-seat on the cap the server just named. Removing a phone can clear
        // APP_DEVICE_CAP and leave WORKER_CAP standing (and vice versa), and
        // only this rejection carries the new kind, limit and remediable
        // devices.
        final next = stillCapped ? e.cap : null;
        if (next != null) {
          _info = next;
          _devices = List.of(next.devices);
        }
        _error = stillCapped
            ? null
            : 'Removed, but registration failed: ${e.message}';
      });
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
                          ? 'Machine limit reached'
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
                _info.message,
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
                    // The machine slot cannot be bought during the beta, so the
                    // paid path leads somewhere that works instead of standing
                    // there disabled. The line says why the button is a
                    // waitlist and not a purchase; a tooltip could not, having
                    // no hover on mobile.
                    Text(
                      'More machines aren\'t on sale yet.',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: p.textMuted,
                      ),
                    ),
                    AbButton(
                      label: 'Join the waitlist',
                      leading: AbIcon(
                        AbIcons.openExternal,
                        size: AbTokens.iconButtonGlyph,
                        color: p.textSecondary,
                      ),
                      onTap: () => detached(
                        'DeviceCapDialog',
                        'open founding-pricing waitlist',
                        () => openExternalUrl(context, _foundingPricingUrl),
                      ),
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
