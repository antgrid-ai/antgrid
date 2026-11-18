import 'dart:math' as math;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/agent_work_status.dart';
import '../../providers/machine_directory.dart';
import '../../providers/machine_scope.dart';
import '../../providers/mobile_connection.dart';
import '../../providers/project_index.dart';
import '../../providers/project_composer.dart';
import '../../providers/recent_sessions.dart';
import '../../util/detached.dart';
import '../../util/relative_time.dart';
import '../carbon_empty_state.dart';
import '../drawer_entry_row.dart' show DrawerAttentionDot;
import '../project_sidebar.dart' show SidebarSectionHeader;
import '../recent_sessions/starting_session_row.dart';

/// The phone's home: what waits on the user across the machines in scope, then
/// every project in scope, merged across machines. Tapping a project points
/// the composer below at it; a needs-you card opens the session itself.
class MobileHomeList extends ConsumerWidget {
  const MobileHomeList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CarbonTheme.of(context);
    final needs = ref.watch(needsYouProvider);
    final views = ref.watch(inScopeProjectViewsProvider);
    final anyProjects = ref.watch(projectViewsProvider).isNotEmpty;
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        const SliverToBoxAdapter(child: StartingSessionRow()),
        if (needs.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SidebarSectionHeader(
              label: 'Needs you',
              count: needs.length,
              color: t.colors.supportWarning,
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
            child: SidebarSectionHeader(label: _projectsLabel(ref)),
          ),
          SliverList.list(
            children: [
              for (final v in views)
                _ProjectTile(key: ValueKey(v.group.key), view: v),
            ],
          ),
        ] else
          // Not SliverFillRemaining: that sizes its child from the child's
          // intrinsic height, which CarbonEmptyState's LayoutBuilder cannot
          // report. A minimum height centres it the same way and lets it grow
          // past the viewport.
          SliverLayoutBuilder(
            builder: (context, constraints) => SliverToBoxAdapter(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: math.max(
                    0,
                    constraints.viewportMainAxisExtent -
                        constraints.precedingScrollExtent,
                  ),
                ),
                child: Center(child: _empty(ref, anyProjects)),
              ),
            ),
          ),
        const SliverToBoxAdapter(
          child: SizedBox(height: CarbonSpacing.spacing05),
        ),
      ],
    );
  }

  Widget _empty(WidgetRef ref, bool anyProjects) =>
      ref.watch(mobileConnectEnabledProvider)
      ? const CarbonEmptyState(
          heading: 'No projects on this machine',
          body:
              'Open a folder in Antgrid on that machine to see it '
              'here.',
        )
      : anyProjects
      ? CarbonEmptyState(
          heading: 'No projects on the machines in scope',
          action: CarbonButton(
            label: 'Show all machines',
            kind: CarbonButtonKind.tertiary,
            onPressed: () => ref.read(machineScopeProvider.notifier).selectAll([
              for (final m in ref.read(machineDirectoryProvider))
                if (m.remoteAccessEnabled != false) m.id,
            ]),
          ),
        )
      : const CarbonEmptyState(
          heading: 'No projects yet',
          body: 'Connect a machine to see its projects here.',
        );
}

/// One session waiting on the user. The only one-tap action is Open: what the
/// agent is asking, and the buttons to answer it, travel only on that
/// project's own stream, which a card on the home screen does not hold.
class _NeedsYouCard extends ConsumerWidget {
  const _NeedsYouCard({super.key, required this.item});

  final NeedsYouItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CarbonTheme.of(context);
    final asking = item.status == AgentWorkStatus.attention;
    final kind = asking ? 'Waiting' : 'Failed';
    final when = DateTime.fromMillisecondsSinceEpoch(
      item.row.session.lastUsedAt,
    );
    final helper = t.typography.helper.copyWith(color: t.colors.textHelper);
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
        CarbonSpacing.spacing05,
        0,
        CarbonSpacing.spacing05,
        CarbonSpacing.spacing03,
      ),
      child: Semantics(
        container: true,
        label:
            '$kind: ${item.row.session.name}, ${item.machineName}, '
            '${item.projectName}',
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: t.layer(1),
            border: Border.all(
              color: t.borderSubtle(1),
              width: CarbonBorders.hairline,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(CarbonSpacing.spacing05),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExcludeSemantics(
                  child: Row(
                    children: [
                      DrawerAttentionDot(status: item.status),
                      const SizedBox(width: CarbonSpacing.spacing03),
                      Text(
                        kind,
                        style: t.typography.label.copyWith(
                          color: asking
                              ? t.colors.supportWarning
                              : t.colors.supportError,
                        ),
                      ),
                      const Spacer(),
                      Text(relativeTime(when), style: helper),
                    ],
                  ),
                ),
                const SizedBox(height: CarbonSpacing.spacing03),
                Text(
                  item.row.session.name,
                  style: t.typography.heading.copyWith(
                    color: t.colors.textPrimary,
                  ),
                ),
                const SizedBox(height: CarbonSpacing.spacing02),
                Text(
                  '${item.machineName} · ${item.projectName}',
                  style: t.typography.code.copyWith(color: t.colors.textHelper),
                ),
                const SizedBox(height: CarbonSpacing.spacing05),
                CarbonButton(
                  label: asking ? 'Open and respond' : 'Open',
                  expand: true,
                  onPressed: open,
                ),
              ],
            ),
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
    final t = CarbonTheme.of(context);
    final parts = [
      if (view.liveCount > 0) '${view.liveCount} live',
      if (view.allOffline) 'offline',
    ];
    return CarbonContainedListRow(
      title: [
        view.group.name,
        if (view.needsYouCount > 0) '${view.needsYouCount} need you',
        ...parts,
      ].join(', '),
      content: Text(
        view.group.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        // Carbon styles inherit nothing, so a null colour paints white.
        style: t.typography.code.copyWith(
          color: view.allOffline
              ? t.colors.textPlaceholder
              : t.colors.textPrimary,
        ),
      ),
      leading: const CarbonIcon(CarbonIcons.folder),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (view.needsYouCount > 0)
            const DrawerAttentionDot(status: AgentWorkStatus.attention),
          if (view.needsYouCount > 0 && parts.isNotEmpty)
            const SizedBox(width: CarbonSpacing.spacing03),
          if (parts.isNotEmpty)
            Text(
              parts.join(' · '),
              style: t.typography.helper.copyWith(
                color: t.colors.textSecondary,
              ),
            ),
        ],
      ),
      // Lit while it is what the composer below will start a session in.
      selected: ref.watch(
        composerProjectViewProvider.select(
          (v) => v?.group.key == view.group.key,
        ),
      ),
      onPressed: () => pointComposerAtProject(ref.container, view),
    );
  }
}

/// "Projects on MacBook Pro" on a phone connected to one machine.
String _projectsLabel(WidgetRef ref) {
  if (!ref.watch(mobileConnectEnabledProvider)) return 'Projects';
  final id = ref.watch(mobileConnectionProvider.select((c) => c.machineId));
  for (final m in ref.watch(machineDirectoryProvider)) {
    if (m.id == id) return 'Projects on ${m.name}';
  }
  return 'Projects';
}
