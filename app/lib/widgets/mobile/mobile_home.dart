import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../models/agent_work_status.dart';
import '../../providers/machine_directory.dart';
import '../../providers/machine_scope.dart';
import '../../providers/mobile_connection.dart';
import '../../providers/project_index.dart';
import '../../providers/project_composer.dart';
import '../../providers/recent_sessions.dart';
import '../../util/detached.dart';
import '../../util/relative_time.dart';
import '../project_sidebar.dart' show SidebarSectionLabel;
import '../recent_sessions/starting_session_row.dart';

/// The phone's home: what waits on the user across the machines in scope, then
/// every project in scope, merged across machines. Tapping a project points
/// the composer below at it; a needs-you card opens the session itself.
class MobileHomeList extends ConsumerWidget {
  const MobileHomeList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needs = ref.watch(needsYouProvider);
    final views = ref.watch(inScopeProjectViewsProvider);
    final anyProjects = ref.watch(projectViewsProvider).isNotEmpty;
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        const SliverToBoxAdapter(child: StartingSessionRow()),
        if (needs.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SidebarSectionLabel(
              label: 'NEEDS YOU',
              count: needs.length,
              color: context.antgrid.warning,
            ),
          ),
          SliverList.list(
            children: [
              for (final item in needs)
                _NeedsYouCard(
                  key: ValueKey(
                    '${item.row.origin.registrationId}:${item.row.session.id}',
                  ),
                  item: item,
                ),
            ],
          ),
        ],
        if (views.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SidebarSectionLabel(label: _projectsLabel(ref)),
          ),
          SliverList.list(
            children: [
              for (final v in views)
                _ProjectTile(key: ValueKey(v.group.key), view: v),
            ],
          ),
        ] else
          SliverFillRemaining(
            hasScrollBody: false,
            child: ref.watch(mobileConnectEnabledProvider)
                ? const AbEmptyState(
                    title: 'No projects on this machine',
                    subtitle:
                        'Open a folder in Antgrid on that machine to see it '
                        'here.',
                  )
                : anyProjects
                ? AbEmptyState(
                    title: 'No projects on the machines in scope',
                    action: AbButton(
                      label: 'Show all machines',
                      onTap: () =>
                          ref.read(machineScopeProvider.notifier).selectAll([
                            for (final m in ref.read(machineDirectoryProvider))
                              if (m.remoteAccessEnabled != false) m.id,
                          ]),
                    ),
                  )
                : const AbEmptyState(
                    title: 'No projects yet',
                    subtitle: 'Connect a machine to see its projects here.',
                  ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: AbTokens.space16)),
      ],
    );
  }
}

/// One session waiting on the user. The only one-tap action is Open: what the
/// agent is asking, and the buttons to answer it, travel only on that
/// project's own stream, which a card on the home screen does not hold.
class _NeedsYouCard extends ConsumerWidget {
  const _NeedsYouCard({super.key, required this.item});

  final NeedsYouItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final asking = item.status == AgentWorkStatus.attention;
    final kind = asking ? 'WAITING' : 'FAILED';
    final when = DateTime.fromMillisecondsSinceEpoch(
      item.row.session.lastUsedAt,
    );
    void open() {
      final container = ref.container;
      detached(
        'MobileHome',
        'open failed',
        () => openRecentSession(context, container, item.row),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        0,
        AbTokens.space12,
        AbTokens.space8,
      ),
      child: Semantics(
        container: true,
        label:
            '$kind: ${item.row.session.name}, ${item.machineName}, '
            '${item.projectName}',
        child: Container(
          padding: const EdgeInsets.all(AbTokens.space12),
          decoration: BoxDecoration(
            color: p.bgSurface,
            border: Border.all(color: p.borderDefault),
            borderRadius: AbTokens.borderRadius8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Row(
                  children: [
                    AbStatusDot(
                      tone: asking ? AbStatusTone.warning : AbStatusTone.danger,
                      pulse: asking,
                    ),
                    const SizedBox(width: AbTokens.space6),
                    Text(
                      kind,
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontXxs,
                        letterSpacing: 0.4,
                        color: asking ? p.warning : p.error,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      relativeTime(when),
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontXs,
                        color: p.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AbTokens.space6),
              Text(
                item.row.session.name,
                style: AbTokens.sansStyle(
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: AbTokens.space4),
              Text(
                '${item.machineName} · ${item.projectName}',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: p.textMuted,
                ),
              ),
              const SizedBox(height: AbTokens.space10),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AbTokens.tapTargetMin,
                ),
                child: AbButton(
                  label: asking ? 'Open and respond' : 'Open',
                  variant: AbButtonVariant.primary,
                  expand: true,
                  onTap: open,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectTile extends ConsumerWidget {
  const _ProjectTile({super.key, required this.view});

  final ProjectView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final parts = [
      if (view.liveCount > 0) '${view.liveCount} live',
      if (view.allOffline) 'offline',
    ];
    return Semantics(
      button: true,
      label: [
        view.group.name,
        if (view.needsYouCount > 0) '${view.needsYouCount} need you',
        ...parts,
      ].join(', '),
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AbTokens.touchControlMin),
        child: AbListRow(
          leading: AbIcon(
            AbIcons.folder,
            size: AbTokens.iconButtonGlyph,
            color: p.textMuted,
          ),
          title: Text(
            view.group.name,
            style: AbTokens.monoStyle(
              fontWeight: FontWeight.w600,
              color: view.allOffline ? p.textMuted : p.textPrimary,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (view.needsYouCount > 0) const AbStatusDot(tone: AbStatusTone.warning),
              if (view.needsYouCount > 0 && parts.isNotEmpty)
                const SizedBox(width: AbTokens.space8),
              if (parts.isNotEmpty)
                Text(
                  parts.join(' · '),
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    color: p.textSecondary,
                  ),
                ),
            ],
          ),
          horizontalPadding: AbTokens.space12,
          // Lit while it is what the composer below will start a session in.
          selected: ref.watch(
            composerProjectViewProvider.select(
              (v) => v?.group.key == view.group.key,
            ),
          ),
          selectionStyle: AbRowSelection.surface,
          onTap: () => pointComposerAtProject(ref.container, view),
        ),
      ),
    );
  }
}

/// "PROJECTS ON MACBOOK PRO" on a phone connected to one machine.
String _projectsLabel(WidgetRef ref) {
  if (!ref.watch(mobileConnectEnabledProvider)) return 'PROJECTS';
  final id = ref.watch(mobileConnectionProvider.select((c) => c.machineId));
  for (final m in ref.watch(machineDirectoryProvider)) {
    if (m.id == id) return 'PROJECTS ON ${m.name.toUpperCase()}';
  }
  return 'PROJECTS';
}
