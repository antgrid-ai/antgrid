import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart' show showDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../providers/auth.dart';
import '../providers/device_provisioning.dart';
import '../providers/provisioning_coordinator.dart';
import '../services/devices_api.dart';
import '../util/detached.dart';
import '../util/external_url.dart';
import '../widgets/carbon_confirm.dart';

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
  final container = ref.container;
  await showDialog<void>(
    context: context,
    // The scrim is painted by the dialog inside its Carbon scope so it follows
    // Carbon's overlay token instead of Material's black54 barrier.
    barrierColor: const Color(0x00000000),
    builder: (_) => DeviceCapDialog(info: info),
  );
  container.read(deviceCapProvider.notifier).set(null);
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

  /// Keys the modal so [_remove] can present its confirmation from beneath the
  /// Carbon scope this dialog builds: the state's own context sits above it.
  final _modalKey = GlobalKey();

  bool get _isWorker => _info.kind == DeviceCapKind.worker;

  Future<void> _remove(CappedDevice d) async {
    final devicesApi = ref.read(devicesApiProvider);
    final provisioning = ref.read(provisioningCoordinatorProvider);
    final confirmed = await showCarbonConfirm(
      _modalKey.currentContext ?? context,
      title: _isWorker ? 'Sign out machine?' : 'Remove device?',
      body: _isWorker
          ? '"${d.displayName}" will stop running agents remotely until it '
                'registers again. This frees a machine slot so this one can '
                'register.'
          : '"${d.displayName}" will lose remote access until it registers '
                'again. This frees a slot so this machine can register.',
      confirmLabel: _isWorker ? 'Sign out' : 'Remove',
      danger: true,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _busyId = d.id;
      _error = null;
    });
    final ok = await devicesApi.revoke(d.id);
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
      await provisioning.retryCurrentUser();
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
    final busy = _busyId != null;
    // The caller sits outside any Carbon scope and a plain dialog route gives
    // none, so the scope is built here rather than demanded of the caller.
    return AbCarbonScope(
      child: Builder(
        builder: (scoped) {
          final t = CarbonTheme.of(scoped);
          void close() => Navigator.of(context).pop();
          return Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: t.colors.overlay),
              Padding(
                padding: const EdgeInsets.all(CarbonSpacing.spacing05),
                child: Center(
                  child: CarbonModal(
                key: _modalKey,
                size: CarbonModalSize.xs,
                title: _isWorker
                    ? 'Machine limit reached'
                    : 'Device limit reached',
                // The header's close button cannot be disabled, so while a
                // revoke is in flight it does nothing instead.
                onClose: busy ? () {} : close,
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _info.message,
                      style: t.typography.body.copyWith(
                        color: t.colors.textPrimary,
                      ),
                    ),
                    if (_isWorker) ...[
                      const SizedBox(height: CarbonSpacing.spacing03),
                      // The machine slot cannot be bought during the beta, so
                      // the paid path leads somewhere that works instead of
                      // standing there disabled. The line says why the button
                      // is a waitlist and not a purchase; a tooltip could not,
                      // having no hover on mobile.
                      Text(
                        'More machines aren\'t on sale yet.',
                        style: t.typography.helper.copyWith(
                          color: t.colors.textSecondary,
                        ),
                      ),
                    ],
                    if (_devices.isNotEmpty) ...[
                      const SizedBox(height: CarbonSpacing.spacing05),
                      // Bounded so a long device list scrolls instead of
                      // overflowing.
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 260),
                        child: SingleChildScrollView(
                          child: CarbonContainedList(
                            label: null,
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
                      const SizedBox(height: CarbonSpacing.spacing05),
                      CarbonNotification(
                        kind: CarbonNotificationKind.error,
                        subtitle: _error,
                      ),
                    ],
                  ],
                ),
                actions: [
                  CarbonModalAction(
                    label: 'Close',
                    kind: CarbonButtonKind.secondary,
                    onPressed: busy ? null : close,
                  ),
                  if (_isWorker)
                    CarbonModalAction(
                      label: 'Join the waitlist',
                      onPressed: () => detached(
                        'DeviceCapDialog',
                        'open founding-pricing waitlist',
                        () => openExternalUrl(context, _foundingPricingUrl),
                      ),
                    ),
                ],
              ),
            ),
          ),
            ],
          );
        },
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
    final t = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    final label = switch ((isWorker, isBusy)) {
      (true, true) => 'Signing out…',
      (true, false) => 'Sign out',
      (false, true) => 'Removing…',
      (false, false) => 'Remove',
    };
    final action = CarbonButton(
      label: label,
      kind: CarbonButtonKind.dangerGhost,
      onPressed: busy ? null : onRemove,
    );
    // One accessible name carrying the id, which is what tells two
    // same-named devices apart.
    final text = Semantics(
      label: '${device.displayName}, ${device.deviceId}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              device.displayName,
              style: t.typography.body.copyWith(color: t.colors.textPrimary),
            ),
            // deviceId is code/data, so it takes the code style.
            Text(
              device.deviceId,
              style: t.typography.code.copyWith(color: t.colors.textSecondary),
            ),
          ],
        ),
      ),
    );
    // Not a CarbonContainedListRow: its actions cell never shrinks or wraps,
    // so large accessibility text on a phone crushes the name beside it. This
    // keeps the row's fill, padding and rule, and moves the action under the
    // name once its label would take more than a third of the row, past
    // which a device id wraps a few characters to a line beside it.
    return ColoredBox(
      color: t.layer(level),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final painter = TextPainter(
                text: TextSpan(text: label, style: t.typography.control),
                textDirection: TextDirection.ltr,
                textScaler: MediaQuery.textScalerOf(context),
                maxLines: 1,
              )..layout();
              final actionWidth = painter.width + 2 * CarbonSpacing.spacing05;
              painter.dispose();
              final inline = actionWidth <= constraints.maxWidth / 3;
              final named = Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: CarbonSpacing.spacing05,
                ),
                child: text,
              );
              return Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: CarbonSpacing.spacing02,
                ),
                child: inline
                    ? Row(
                        children: [
                          Expanded(child: named),
                          const SizedBox(width: CarbonSpacing.spacing03),
                          action,
                        ],
                      )
                    // Unpadded, so the ghost button's own inline padding puts
                    // its label on the name's edge.
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsetsDirectional.only(
                              end: CarbonSpacing.spacing05,
                            ),
                            child: named,
                          ),
                          action,
                        ],
                      ),
              );
            },
          ),
          SizedBox(
            height: CarbonBorders.hairline,
            child: ColoredBox(color: t.borderSubtle(level)),
          ),
        ],
      ),
    );
  }
}
