import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/remote_connect_actions.dart';
import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_segmented.dart';
import '../design/widgets/ab_tooltip.dart';
import '../design/widgets/pulsing_opacity.dart';
import '../launcher/host_control_client.dart';
import '../providers/remote_access.dart';

/// The machine-wide remote-access switch, what it grants, and the roster of
/// devices that have connected — the panel behind the title-bar chip.
///
/// One surface for all three because they are one question. The switch alone
/// can't say what it admits; the roster alone reads as an access list, which it
/// is not — access is machine-wide, so a row is identity and housekeeping only
/// (label, device id, last seen, forget).
///
/// Turning access ON is confirmed and turning it OFF is not, on purpose: the
/// two directions carry opposite risk. Granting every account device the whole
/// machine is worth one sentence of friction; withdrawing that grant should
/// never be slower than the fear that prompted it.
class RemoteAccessPanel extends ConsumerStatefulWidget {
  const RemoteAccessPanel({super.key});

  @override
  ConsumerState<RemoteAccessPanel> createState() => _RemoteAccessPanelState();
}

class _RemoteAccessPanelState extends ConsumerState<RemoteAccessPanel>
    with RemoteConnectActions {
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _AccessSection(),
        Container(height: 1, color: p.borderSubtle),
        _DevicesSection(onPair: scanAndConnect),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// The switch
// ──────────────────────────────────────────────────────────────────────────────

class _AccessSection extends ConsumerWidget {
  const _AccessSection();

  Future<void> _set(BuildContext context, WidgetRef ref, bool next) async {
    // Resolved before the dialog: a WidgetRef read after an await can land on a
    // disposed element, and this panel is a popup route the confirm can outlive.
    final notifier = ref.read(remoteAccessPolicyProvider.notifier);
    if (next) {
      final ok = await AbConfirmDialog.show(
        context: context,
        title: 'Turn on remote access?',
        body:
            'Every device signed in to your account will be able to open and '
            'drive every project on this machine, until you turn it off.',
        confirmLabel: 'Turn on',
      );
      if (!ok) return;
    }
    await notifier.setEnabled(next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final async = ref.watch(remoteAccessPolicyProvider);
    final policy = async.value;
    final enabled = policy?.enabled == true;
    // Inert until the machine's real state is known: an OFF|ON control with
    // nothing behind it would invite a tap that writes a value the user never
    // saw. Same reason a flip in flight locks it — one flip at a time.
    final live = policy != null && !async.isLoading;

    final control = AbSegmented<bool>(
      key: const Key('remote-access-switch'),
      selected: enabled,
      onSelect: (next) => _set(context, ref, next),
      segments: [
        AbSegment(value: false, label: 'Off', enabled: live),
        AbSegment(value: true, label: 'On', enabled: live),
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(AbTokens.space8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'REMOTE ACCESS',
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs,
                    letterSpacing: 0.66,
                    color: p.textMuted,
                  ),
                ),
              ),
              async.isLoading ? PulsingOpacity(child: control) : control,
            ],
          ),
          const SizedBox(height: AbTokens.space6),
          Text(
            policy == null
                ? "Couldn't read this machine's setting. It stays as it was."
                : 'Any device signed in to your account — phone, tablet or '
                      'another desktop — can open and drive every project on '
                      'this machine.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: policy == null ? p.error : p.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Device roster
// ──────────────────────────────────────────────────────────────────────────────

class _DevicesSection extends ConsumerWidget {
  const _DevicesSection({required this.onPair});

  final VoidCallback onPair;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final async = ref.watch(remoteDevicesProvider);
    // A mutation keeps the prior data (copyWithPrevious in the notifier), so a
    // forget never blanks the roster to a spinner.
    final phones = async.value?.phones ?? const <PairedPhoneSummary>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space8,
        AbTokens.space8,
        AbTokens.space8,
        AbTokens.space6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            phones.isEmpty ? 'DEVICES' : 'DEVICES · ${phones.length}',
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              letterSpacing: 0.66,
              color: p.textMuted,
            ),
          ),
          const SizedBox(height: AbTokens.space4),
          if (async.hasError && phones.isEmpty)
            _Note(
              text: "Couldn't load this machine's devices.",
              color: p.error,
              action: AbButton(
                label: 'Retry',
                compact: true,
                onTap: () => ref.invalidate(remoteDevicesProvider),
              ),
            )
          else if (phones.isEmpty)
            _Note(
              text:
                  'None yet. A device signed in as you connects on its own — '
                  'scan only to add one that is not on your account.',
              color: p.textMuted,
              action: AbButton(
                key: const ValueKey('remote-panel-pair-cta'),
                label: 'Scan a device',
                compact: true,
                leading: AbIcon(
                  AbIcons.scan,
                  size: 11,
                  color: context.antgrid.textSecondary,
                ),
                onTap: onPair,
              ),
            )
          else
            // Bounded so a machine with many devices scrolls the roster instead
            // of growing the popup past the screen.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 208),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: phones.length,
                itemBuilder: (_, i) => _DeviceRow(phone: phones[i]),
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({required this.phone});
  final PairedPhoneSummary phone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    return AbListRow(
      key: ValueKey('device-${phone.phonePubkey}'),
      density: AbRowDensity.sm,
      horizontalPadding: 0,
      leading: AbIcon(AbIcons.deviceMobile, size: 13, color: p.textMuted),
      title: Text(
        phone.label ?? phone.phoneDeviceId,
        // A human label is chrome (sans); a raw device id is data (mono).
        style: phone.label != null
            ? AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: p.textPrimary,
                fontWeight: FontWeight.w500,
              )
            : AbTokens.monoStyle(
                fontSize: AbTokens.fontSm,
                color: p.textPrimary,
              ),
      ),
      subtitle: Text(
        // Device id and timestamp are data — mono.
        '${phone.phoneDeviceId} · last seen ${phone.lastSeenAt}',
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXxs,
          color: p.textMuted,
        ),
      ),
      // "Forget", not "Revoke": this clears the local record only. An
      // account-trusted device rewrites its row on the next connect — the
      // switch above is the only thing that actually withdraws access.
      trailing: AbTooltip(
        message: 'Clears this machine\'s record of the device. It can '
            'reconnect while remote access is on.',
        child: AbButton(
          key: ValueKey('forget-${phone.phonePubkey}'),
          label: 'Forget',
          compact: true,
          onTap: () => ref
              .read(remoteDevicesProvider.notifier)
              .unpair(phonePubkey: phone.phonePubkey),
        ),
      ),
    );
  }
}

/// One-line explanation plus its single action — the empty and error bodies,
/// kept compact so the popup doesn't grow a full-screen empty state.
class _Note extends StatelessWidget {
  const _Note({required this.text, required this.color, required this.action});

  final String text;
  final Color color;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: AbTokens.sansStyle(fontSize: AbTokens.fontXxs, color: color),
        ),
        const SizedBox(height: AbTokens.space6),
        Align(alignment: Alignment.centerLeft, child: action),
      ],
    );
  }
}
