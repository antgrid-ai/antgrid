import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_panel_header.dart';
import '../launcher/host_control_client.dart';
import '../connect/remote_connect_actions.dart';
import '../providers/mobile_devices_hub.dart';
import '../widgets/mobile_access_toggle.dart';

/// Desktop hub: the machine-wide mobile-access switch plus a plain roster of the
/// phones that have connected to this machine. Access is not differentiated per
/// phone or per project — the switch admits every account-trusted phone or none
/// — so a row is identity and housekeeping only (label, device id, last seen,
/// unpair).
class MobileDevicesHub extends ConsumerWidget {
  const MobileDevicesHub({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mobileDevicesHubProvider);
    final p = context.antgrid;
    return Scaffold(
      backgroundColor: p.bgDeepest,
      body: Column(
        children: [
          AbPanelHeader(
            title: 'MOBILE DEVICES',
            actions: [
              AbIconButton(
                icon: AbIcons.close,
                onTap: onClose ?? () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const _MachineSwitch(),
          Expanded(
            child: async.when(
              // A mutation/refresh keeps the prior data (copyWithPrevious in the
              // notifier); skip the reload spinner so the list stays on screen
              // instead of flashing the whole hub to a loading state on every toggle.
              skipLoadingOnReload: true,
              loading: () => const AbLoading(message: 'Loading paired phones…'),
              error: (e, _) => _ErrorState(message: '$e'),
              data: (state) => state.phones.isEmpty
                  ? const _EmptyState()
                  : _PhoneList(phones: state.phones),
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Machine-wide switch
// ──────────────────────────────────────────────────────────────────────────────

/// The one control that actually grants access. Kept above the roster so the
/// list below reads as "who has connected", not "who is authorized" — the phone
/// rows carry no authorization of their own.
class _MachineSwitch extends StatelessWidget {
  const _MachineSwitch();

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space10,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mobile access',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    color: p.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: AbTokens.space2),
                Text(
                  'When on, any phone signed in to your account can drive every '
                  'project on this machine.',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXxs,
                    color: p.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AbTokens.space12),
          const MobileAccessToggle(),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Phone list
// ──────────────────────────────────────────────────────────────────────────────

class _PhoneList extends StatelessWidget {
  const _PhoneList({required this.phones});
  final List<PairedPhoneSummary> phones;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: phones.length,
      itemBuilder: (context, i) => _PhoneRow(phone: phones[i]),
    );
  }
}

class _PhoneRow extends ConsumerWidget {
  const _PhoneRow({required this.phone});
  final PairedPhoneSummary phone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    return AbListRow(
      key: ValueKey('phone-${phone.phonePubkey}'),
      leading: AbIcon(AbIcons.deviceMobile, size: 14, color: p.textMuted),
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
      trailing: AbButton(
        key: ValueKey('unpair-${phone.phonePubkey}'),
        label: 'Unpair',
        compact: true,
        onTap: () => ref
            .read(mobileDevicesHubProvider.notifier)
            .unpair(phonePubkey: phone.phonePubkey),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Empty state
// ──────────────────────────────────────────────────────────────────────────────

/// Machine-level pair entry for the hub. Same-account phones (signed in as the
/// same user) pair automatically on first connect — no QR needed. QR is the
/// secondary path for phones not on your account. Reuses [RemoteConnectActions]
/// so the CTA cannot drift from the other connect entry points.
class _EmptyState extends ConsumerStatefulWidget {
  const _EmptyState();

  @override
  ConsumerState<_EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends ConsumerState<_EmptyState>
    with RemoteConnectActions {
  @override
  Widget build(BuildContext context) {
    return AbEmptyState(
      icon: AbIcons.deviceMobile,
      title: 'No phones paired',
      subtitle:
          'same-account: a phone signed in as you pairs automatically on '
          'first connect (no QR). QR: scan to pair a phone that\'s not on '
          'your account.',
      action: AbButton(
        key: const ValueKey('hub-empty-pair-cta'),
        label: 'Pair a phone',
        variant: AbButtonVariant.primary,
        fontSize: AbTokens.fontBody,
        leading: AbIcon(
          AbIcons.add,
          size: 12,
          color: context.antgrid.accentForeground,
        ),
        onTap: scanAndConnect,
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Error state
// ──────────────────────────────────────────────────────────────────────────────

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return AbEmptyState.error(
      title: 'Failed to load devices',
      subtitle: message,
    );
  }
}
