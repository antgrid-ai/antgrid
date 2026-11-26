import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../providers/account_agents.dart';
import '../../providers/control_plane.dart';
import '../../providers/machine_directory.dart';
import '../../providers/mobile_connection.dart';
import '../../providers/project_work_status.dart';
import '../../providers/recent_sessions.dart';
import '../../util/detached.dart';
import '../../util/relative_time.dart';
import '../machine_scope_menu.dart' show machineActivityLine;
import '../project_sidebar.dart' show SidebarSectionLabel;

/// The phone's canvas until it is connected: pick a machine, watch it
/// connect, or learn why it did not.
class MobileConnectScreen extends ConsumerWidget {
  const MobileConnectScreen({super.key, required this.status});

  final MobileConnectStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = status.machineId;
    return ColoredBox(
      color: context.antgrid.bgDeepest,
      child: switch (status.phase) {
        MobileConnectPhase.connecting => MobileConnecting(
          machineId: id!,
          reached: status.reached,
        ),
        MobileConnectPhase.failed => MobileConnectFailed(
          machineId: id!,
          failure: status.failure ?? MobileConnectFailure.unreachable,
        ),
        _ => const MobileMachinePicker(),
      },
    );
  }
}

String _machineName(WidgetRef ref, String id) =>
    ref
        .watch(machineDirectoryProvider)
        .firstWhereOrNull((m) => m.id == id)
        ?.name ??
    ref
        .watch(accountAgentsProvider)
        .value
        ?.firstWhereOrNull((a) => a.deviceUuid == id)
        ?.displayName ??
    'this machine';

/// Machines a phone can be pointed at: never this device, which runs no
/// bridge of its own.
List<MachineInfo> _remoteMachines(WidgetRef ref) => [
  for (final m in ref.watch(machineDirectoryProvider))
    if (!m.isLocal) m,
];

String _offlineLine(MachineInfo m) {
  final seen = m.lastSeenAt;
  return [
    ?platformLabel(m.platform),
    seen == null ? 'offline' : 'seen ${relativeTime(seen)}',
  ].join(' · ');
}

void _refreshInventory(ProviderContainer c) => detached(
  'MobileConnect',
  'refresh failed',
  () => refreshMachineInventoryAndControlPlanes(
    RefreshRef.ofContainer(c),
    const [],
  ),
);

class MobileMachinePicker extends ConsumerWidget {
  const MobileMachinePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final connection = ref.watch(mobileConnectionProvider);
    final rows = ref.watch(recentSessionsProvider);
    final statuses = ref.watch(recentSessionStatusesProvider);
    final machines = _remoteMachines(ref);
    final locked = [
      for (final m in machines)
        if (m.remoteAccessEnabled == false) m,
    ];
    final online =
        [
          for (final m in machines)
            if (m.online && m.remoteAccessEnabled != false) m,
        ]..sort((a, b) {
          final last = connection.lastMachineId;
          return (b.id == last ? 1 : 0) - (a.id == last ? 1 : 0);
        });
    final offline = [
      for (final m in machines)
        if (!m.online && m.remoteAccessEnabled != false) m,
    ];
    final loading = ref.watch(accountAgentsProvider).isLoading;
    final container = ref.container;

    Widget list;
    if (machines.isEmpty) {
      list = CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: loading
                ? const Center(child: AbLoading(message: 'Loading machines'))
                : const AbEmptyState(
                    title: 'No machines yet',
                    subtitle:
                        'Install Antgrid on a computer and sign in with this '
                        'account to connect to it from here.',
                  ),
          ),
        ],
      );
    } else {
      list = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: AbTokens.space8),
        children: [
          SidebarSectionLabel(label: 'ONLINE', count: online.length),
          if (online.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AbTokens.space8),
              child: Text(
                'None of your machines are online. Open Antgrid on one, '
                'then refresh.',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontMd,
                  color: p.textMuted,
                ),
              ),
            ),
          for (final m in online)
            MobileMachineRow(
              key: ValueKey('pick:${m.id}'),
              machine: m,
              lastUsed: m.id == connection.lastMachineId,
              subtitle: [
                ?platformLabel(m.platform),
                machineActivityLine(m, rows, statuses) ?? 'online',
              ].join(' · '),
              onTap: () => chooseMobileMachine(container, m.id),
            ),
          if (offline.isNotEmpty) ...[
            SidebarSectionLabel(label: 'OFFLINE', count: offline.length),
            for (final m in offline)
              MobileMachineRow(
                key: ValueKey('pick:${m.id}'),
                machine: m,
                subtitle: _offlineLine(m),
              ),
          ],
          if (locked.isNotEmpty) ...[
            SidebarSectionLabel(
              label: 'REMOTE ACCESS OFF',
              count: locked.length,
            ),
            for (final m in locked)
              MobileMachineRow(
                key: ValueKey('pick:${m.id}'),
                machine: m,
                subtitle:
                    'Turn on remote access on that machine to connect from '
                    'here',
              ),
          ],
          const SizedBox(height: AbTokens.space16),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space16,
            AbTokens.space16,
            AbTokens.space8,
            AbTokens.space4,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        'Choose a machine',
                        style: AbTokens.sansStyle(
                          fontSize: AbTokens.fontLg,
                          fontWeight: FontWeight.w600,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(height: AbTokens.space4),
                    Text(
                      'Your phone connects to one machine at a time. Pick '
                      'the one to work on. The app reopens on it until '
                      '${kMobileMachineStickyWindow.inHours} hours pass '
                      'without connecting.',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontMd,
                        color: p.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              AbIconButton(
                icon: AbIcons.refresh,
                tooltip: 'Refresh machines',
                onTap: () => _refreshInventory(container),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => refreshMachineInventoryAndControlPlanes(
              RefreshRef.ofContainer(container),
              const [],
            ),
            color: p.accent,
            backgroundColor: p.bgElevated,
            child: list,
          ),
        ),
      ],
    );
  }
}

/// One machine in the picker or the switch sheet. Tappable only when
/// [onTap] is given: an offline or locked machine is listed so the user sees
/// it is known, not missing.
class MobileMachineRow extends StatelessWidget {
  const MobileMachineRow({
    super.key,
    required this.machine,
    required this.subtitle,
    this.onTap,
    this.lastUsed = false,
    this.current = false,
  });

  final MachineInfo machine;
  final String subtitle;
  final VoidCallback? onTap;
  final bool lastUsed;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final m = machine;
    final p = context.antgrid;
    final locked = m.remoteAccessEnabled == false;
    final reachable = m.online && !locked;
    final state = locked
        ? 'remote access off'
        : m.online
        ? (current ? 'connected' : 'online')
        : 'offline';
    return Semantics(
      button: onTap != null,
      selected: current,
      label: [m.name, state, subtitle, if (lastUsed) 'last used'].join(', '),
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: AbTokens.rowHeightXl),
        decoration: BoxDecoration(
          color: current
              ? p.bgSelected
              : lastUsed
              ? p.bgSurface
              : null,
          borderRadius: AbTokens.borderRadius5,
        ),
        child: AbListRow(
          leading: locked
              ? AbIcon(AbIcons.lock, size: AbTokens.fontLg, color: p.textMuted)
              : AbStatusDot(
                  tone: m.online ? AbStatusTone.success : AbStatusTone.disabled,
                  style: m.online ? AbDotStyle.filled : AbDotStyle.hollow,
                  size: AbDotSize.md,
                ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  m.name,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontBody,
                    color: reachable ? p.textPrimary : p.textMuted,
                  ),
                ),
              ),
              if (lastUsed) ...[
                const SizedBox(width: AbTokens.space8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AbTokens.space4,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: p.borderStrong),
                    borderRadius: AbTokens.borderRadius3,
                  ),
                  child: Text(
                    'last used',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXxs,
                      color: p.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(subtitle),
          subtitleMaxLines: 2,
          trailing: current
              ? AbIcon(AbIcons.check, size: AbTokens.fontLg, color: p.accent)
              : onTap == null
              ? null
              : AbIcon(
                  AbIcons.chevronRight,
                  size: AbTokens.fontSm,
                  color: p.textMuted,
                ),
          horizontalPadding: AbTokens.space8,
          onTap: onTap,
        ),
      ),
    );
  }
}

/// While the chosen machine connects. Owns the attempt's deadline: past
/// [kMobileConnectTimeout] the flow offers Try again rather than leaving the
/// user watching a machine that is not going to answer.
class MobileConnecting extends ConsumerStatefulWidget {
  const MobileConnecting({
    super.key,
    required this.machineId,
    required this.reached,
  });

  final String machineId;
  final bool reached;

  @override
  ConsumerState<MobileConnecting> createState() => _MobileConnectingState();
}

class _MobileConnectingState extends ConsumerState<MobileConnecting> {
  Timer? _deadline;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(MobileConnecting old) {
    super.didUpdateWidget(old);
    if (old.machineId != widget.machineId) _arm();
  }

  void _arm() {
    _deadline?.cancel();
    final id = widget.machineId;
    final container = ref.container;
    _deadline = Timer(
      kMobileConnectTimeout,
      () => container.read(mobileConnectionProvider.notifier).markTimedOut(id),
    );
  }

  @override
  void dispose() {
    _deadline?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final name = _machineName(ref, widget.machineId);
    // Known to this phone already counts: a machine picked from the list was
    // found before the tap, and a restored one may beat the inventory read.
    final found =
        ref.watch(
          machineDirectoryProvider.select(
            (d) => d.any((m) => m.id == widget.machineId),
          ),
        ) ||
        ref.watch(
          accountAgentsProvider.select(
            (a) =>
                a.value?.any((x) => x.deviceUuid == widget.machineId) ?? false,
          ),
        );
    final reached = widget.reached;
    return _Centered(
      children: [
        AbIcon(
          AbIcons.deviceDesktop,
          size: AbTokens.fontDisplaySm,
          color: p.textMuted,
        ),
        const SizedBox(height: AbTokens.space16),
        _Title(lead: 'Connecting to ', name: name),
        const SizedBox(height: AbTokens.space4),
        Text(
          'This takes a few seconds the first time.',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontMd,
            color: p.textMuted,
          ),
        ),
        const SizedBox(height: AbTokens.space24),
        Semantics(
          label: 'Progress',
          container: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Step(
                'Found on your account',
                state: found || reached ? _StepState.done : _StepState.active,
              ),
              _Step(
                'Reaching the machine',
                state: reached
                    ? _StepState.done
                    : found
                    ? _StepState.active
                    : _StepState.pending,
              ),
              _Step(
                'Opening its projects',
                state: reached ? _StepState.active : _StepState.pending,
              ),
            ],
          ),
        ),
        const SizedBox(height: AbTokens.space24),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AbTokens.tapTargetMin),
          child: AbButton(
            label: 'Cancel',
            onTap: () => disconnectMobileMachine(ref.container),
          ),
        ),
      ],
    );
  }
}

enum _StepState { done, active, pending }

class _Step extends StatelessWidget {
  const _Step(this.label, {required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final glyph = switch (state) {
      _StepState.done => AbIcon(
        AbIcons.check,
        size: AbTokens.fontMd,
        color: p.accent,
      ),
      _StepState.active => const AbLoadingDot(size: AbTokens.space6),
      _StepState.pending => const AbStatusDot(
        tone: AbStatusTone.disabled,
        style: AbDotStyle.hollow,
      ),
    };
    final suffix = switch (state) {
      _StepState.done => 'done',
      _StepState.active => 'in progress',
      _StepState.pending => 'not started',
    };
    return Semantics(
      container: true,
      label: '$label, $suffix',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AbTokens.space6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: AbTokens.fontMd,
              child: Center(child: glyph),
            ),
            const SizedBox(width: AbTokens.space10),
            Text(
              label,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontMd,
                color: switch (state) {
                  _StepState.done => p.textSecondary,
                  _StepState.active => p.textPrimary,
                  _StepState.pending => p.textMuted,
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MobileConnectFailed extends ConsumerWidget {
  const MobileConnectFailed({
    super.key,
    required this.machineId,
    required this.failure,
  });

  final String machineId;
  final MobileConnectFailure failure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final container = ref.container;
    final why = switch (failure) {
      MobileConnectFailure.unreachable =>
        'It stopped answering. It may be asleep or off the network — check '
            'that Antgrid is running on it.',
      MobileConnectFailure.remoteAccessOff =>
        'Remote access is off on this machine. Turn it on there to connect '
            'from your phone.',
    };
    return _Centered(
      children: [
        AbIcon(AbIcons.error, size: AbTokens.fontDisplaySm, color: p.error),
        const SizedBox(height: AbTokens.space14),
        _Title(
          lead: 'Couldn’t connect to ',
          name: _machineName(ref, machineId),
        ),
        const SizedBox(height: AbTokens.space10),
        Text(
          why,
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontMd,
            color: p.textSecondary,
          ),
        ),
        const SizedBox(height: AbTokens.space24),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AbTokens.tapTargetMin),
          child: AbButton(
            label: 'Try again',
            variant: AbButtonVariant.primary,
            expand: true,
            onTap: () => detached(
              'MobileConnect',
              'retry failed',
              () => retryMobileMachine(container),
            ),
          ),
        ),
        const SizedBox(height: AbTokens.space8),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AbTokens.tapTargetMin),
          child: AbButton(
            label: 'Choose another machine',
            expand: true,
            onTap: () => disconnectMobileMachine(container),
          ),
        ),
      ],
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AbTokens.space24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ),
  );
}

/// "Connecting to " + the machine's name, the name in mono because it is
/// the machine's own identifier.
class _Title extends StatelessWidget {
  const _Title({required this.lead, required this.name});

  final String lead;
  final String name;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final style = AbTokens.sansStyle(
      fontSize: AbTokens.fontLg,
      fontWeight: FontWeight.w600,
      color: p.textPrimary,
    );
    return Semantics(
      header: true,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: lead, style: style),
            TextSpan(
              text: name,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontLg,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// The connected machine, heading the phone's home. Opens
/// [SwitchMachineSheet].
class ConnectedMachineButton extends ConsumerWidget {
  const ConnectedMachineButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final id = ref.watch(mobileConnectionProvider.select((c) => c.machineId));
    if (id == null) return const SizedBox.shrink();
    final machine = ref
        .watch(machineDirectoryProvider)
        .firstWhereOrNull((m) => m.id == id);
    final name = _machineName(ref, id);
    final activity = machine == null
        ? null
        : machineActivityLine(
            machine,
            ref.watch(recentSessionsProvider),
            ref.watch(recentSessionStatusesProvider),
          );
    final line = 'Connected · ${activity ?? 'idle'}';
    return Semantics(
      button: true,
      label: 'Connected to $name, ${activity ?? 'idle'}. Switch machine',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: p.borderDefault),
          borderRadius: AbTokens.borderRadius5,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AbTokens.tapTargetMin),
          child: AbListRow(
            leading: const AbStatusDot(
              tone: AbStatusTone.success,
              size: AbDotSize.md,
            ),
            title: Text(
              name,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontMd,
                color: p.textPrimary,
              ),
            ),
            subtitle: Text(line),
            trailing: AbIcon(
              AbIcons.chevronDown,
              size: AbTokens.fontSm,
              color: p.textMuted,
            ),
            density: AbRowDensity.sm,
            horizontalPadding: AbTokens.space10,
            onTap: () => showAbAdaptiveSheet<void>(
              context,
              child: const SwitchMachineSheet(),
            ),
          ),
        ),
      ),
    );
  }
}

class SwitchMachineSheet extends ConsumerWidget {
  const SwitchMachineSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final current = ref.watch(
      mobileConnectionProvider.select((c) => c.machineId),
    );
    final rows = ref.watch(recentSessionsProvider);
    final statuses = ref.watch(recentSessionStatusesProvider);
    final machines = _remoteMachines(ref);
    final container = ref.container;
    void close() => Navigator.of(context).pop();

    String subtitleFor(MachineInfo m) {
      if (m.remoteAccessEnabled == false) {
        return 'Remote access is off on this machine';
      }
      if (!m.online) return _offlineLine(m);
      final activity = machineActivityLine(m, rows, statuses) ?? 'idle';
      return m.id == current ? 'Connected · $activity' : 'Online · $activity';
    }

    final reachable = [
      for (final m in machines)
        if (m.online && m.remoteAccessEnabled != false) m,
    ];
    final unreachable = [
      for (final m in machines)
        if (!m.online || m.remoteAccessEnabled == false) m,
    ];

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: AbTokens.space8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: AbTokens.space10),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Switch machine',
                        style: AbTokens.monoStyle(
                          fontSize: AbTokens.fontMd,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  AbIconButton(
                    icon: AbIcons.close,
                    tooltip: 'Close',
                    onTap: close,
                  ),
                ],
              ),
            ),
            for (final m in reachable)
              MobileMachineRow(
                key: ValueKey('switch:${m.id}'),
                machine: m,
                current: m.id == current,
                subtitle: subtitleFor(m),
                onTap: () {
                  close();
                  if (m.id != current) chooseMobileMachine(container, m.id);
                },
              ),
            for (final m in unreachable)
              MobileMachineRow(
                key: ValueKey('switch:${m.id}'),
                machine: m,
                subtitle: subtitleFor(m),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AbTokens.space4),
              child: AbSeparator.horizontal(),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AbTokens.touchControlMin,
              ),
              child: AbListRow(
                title: Text(
                  'Disconnect',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontMd,
                    color: p.error,
                  ),
                ),
                horizontalPadding: AbTokens.space10,
                onTap: () {
                  close();
                  disconnectMobileMachine(container);
                },
              ),
            ),
            const SizedBox(height: AbTokens.space8),
          ],
        ),
      ),
    );
  }
}
