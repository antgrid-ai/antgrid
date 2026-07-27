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
import '../design/widgets/ab_toolbar.dart';
import '../launcher/host_control_client.dart';
import '../connect/remote_connect_actions.dart';
import '../providers/mobile_devices_hub.dart';

/// Desktop hub: one card per paired phone, each with a per-project allowlist
/// checklist. The column set is the union of machine-known projects ∪ every
/// project already allowed on the phone, so CLI-granted-but-unopened projects
/// are never hidden.
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
                  : _PhoneList(state: state),
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Phone list
// ──────────────────────────────────────────────────────────────────────────────

class _PhoneList extends ConsumerWidget {
  const _PhoneList({required this.state});
  final PhonesList state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Built once here, not per card: knownProjects is the same for every phone,
    // so rebuilding this index inside each _PhoneCard.build wasted O(phones×N).
    final projectsById = {for (final k in state.knownProjects) k.projectId: k};
    return ListView.builder(
      itemCount: state.phones.length,
      itemBuilder: (context, i) =>
          _PhoneCard(phone: state.phones[i], projectsById: projectsById),
    );
  }
}

class _PhoneCard extends ConsumerWidget {
  const _PhoneCard({required this.phone, required this.projectsById});
  final PairedPhoneSummary phone;
  final Map<String, KnownProject> projectsById;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final columns = _columnsFor(phone, projectsById);
    final p = context.antgrid;
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space8,
      ),
      decoration: BoxDecoration(
        color: p.bgSurface,
        border: Border.all(color: p.borderDefault),
        borderRadius: AbTokens.borderRadius8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // AbToolbar.custom preserves the label casing — AbPanelHeader
          // uppercases via .toUpperCase() which breaks text-based finders.
          AbToolbar.custom(
            children: [
              AbIcon(AbIcons.deviceMobile, size: 14, color: p.textMuted),
              const SizedBox(width: AbTokens.space8),
              Text(
                phone.label ?? phone.phoneDeviceId,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: p.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              AbButton(
                key: ValueKey('unpair-${phone.phonePubkey}'),
                label: 'Unpair',
                compact: true,
                onTap: () => ref
                    .read(mobileDevicesHubProvider.notifier)
                    .unpair(phonePubkey: phone.phonePubkey),
              ),
            ],
          ),
          for (final project in columns)
            _ProjectToggleRow(phone: phone, project: project),
          if (columns.isEmpty)
            const AbEmptyState.compact(title: 'No projects on this machine'),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Per-project toggle row
// ──────────────────────────────────────────────────────────────────────────────

class _ProjectToggleRow extends ConsumerWidget {
  const _ProjectToggleRow({required this.phone, required this.project});
  final PairedPhoneSummary phone;
  final KnownProject project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = phone.allowedProjects.contains(project.projectId);
    final p = context.antgrid;

    return AbListRow(
      key: ValueKey('toggle-${phone.phonePubkey}-${project.projectId}'),
      hoverable: true,
      leading: AbIcon(
        allowed ? AbIcons.check : AbIcons.circle,
        size: 14,
        color: allowed ? p.accent : p.textMuted,
      ),
      title: Text(
        project.label ?? project.projectId,
        // A human label is chrome (sans); a raw project id is data (mono).
        style: project.label != null
            ? AbTokens.sansStyle(fontSize: AbTokens.fontSm)
            : AbTokens.monoStyle(fontSize: AbTokens.fontSm),
      ),
      subtitle: project.path != null
          ? Text(
              project.path!,
              // Paths are data — mono font required.
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXxs,
                color: p.textMuted,
              ),
            )
          : Text(
              project.projectId,
              // Raw project id is data.
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXxs,
                color: p.textMuted,
              ),
            ),
      onTap: () {
        final notifier = ref.read(mobileDevicesHubProvider.notifier);
        if (allowed) {
          notifier.deny(
            phonePubkey: phone.phonePubkey,
            projectId: project.projectId,
          );
        } else {
          notifier.allow(
            phonePubkey: phone.phonePubkey,
            projectId: project.projectId,
          );
        }
      },
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

// ──────────────────────────────────────────────────────────────────────────────
// Column union helper
// ──────────────────────────────────────────────────────────────────────────────

/// Returns the union of the machine-known projects ([byId]) and
/// [phone.allowedProjects]. An allowed id absent from known projects renders as
/// a stub KnownProject (label: null, path: null) so CLI-granted-but-unopened
/// entries are visible.
List<KnownProject> _columnsFor(
  PairedPhoneSummary phone,
  Map<String, KnownProject> byId,
) {
  final ids = <String>{...byId.keys, ...phone.allowedProjects};
  return ids
      .map(
        (id) =>
            byId[id] ??
            KnownProject(
              projectId: id,
              label: null,
              path: null,
              running: false,
            ),
      )
      .toList()
    ..sort(
      (a, b) => (a.label ?? a.projectId).compareTo(b.label ?? b.projectId),
    );
}
