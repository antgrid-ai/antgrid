import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_tooltip.dart';
import '../models/session_entry.dart';
import '../providers/session_members.dart';
import '../util/detached.dart';

/// The machines of one multi-machine session, one tab each, mounted directly
/// under the agent header.
///
/// Renders nothing for a session that works alone, so [AgentPanel] mounts it
/// unconditionally and never re-derives what membership means. The lead is
/// always the first tab (see [visibleMemberTabsProvider]), which is what makes
/// "back to the lead" a fixed place rather than a search.
///
/// Deliberately NOT a workspace tab bar: pressing a tab moves the FOCUSED
/// project and session, so everything below — transcript, composer, files, git,
/// preview, terminals, Handler — follows to that machine on its own. The strip
/// is a selector for where the user is working, not a view switcher.
class SessionMemberTabs extends ConsumerWidget {
  const SessionMemberTabs({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(visibleMemberTabsProvider);
    // One tab is a session working alone: a strip that cannot be switched says
    // nothing the header does not already say.
    if (tabs.length < 2) return const SizedBox.shrink();
    final current = ref.watch(viewedSessionRefProvider);
    final p = context.antgrid;

    return Container(
      height: AbTokens.statusHeaderHeight,
      decoration: BoxDecoration(
        color: p.bgDeep,
        border: Border(bottom: BorderSide(color: p.borderSubtle)),
      ),
      // Horizontally scrollable for the same reason the workspace strip is: a
      // session may hold up to kMaxSessionMembers machines, and the agent pane
      // is the one panel a user narrows to make room for the workspace.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++)
              _MemberTab(
                member: tabs[i],
                isLead: i == 0,
                isActive: tabs[i].key == current?.key,
              ),
          ],
        ),
      ),
    );
  }
}

class _MemberTab extends ConsumerWidget {
  const _MemberTab({
    required this.member,
    required this.isLead,
    required this.isActive,
  });

  final SessionMemberRef member;

  /// The session's lead machine, always the first tab. Marked rather than
  /// merely ordered: with more than two machines the ordering alone stops
  /// saying which one the others answer to.
  final bool isLead;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final label = ref.watch(memberMachineLabelProvider(member));
    final color = isActive ? p.textPrimary : p.textSecondary;
    final sessionName = member.sessionName?.trim();
    final tooltip = [
      if (isLead) 'Lead machine' else 'Member machine',
      label,
      if (sessionName != null && sessionName.isNotEmpty) '"$sessionName"',
    ].join(' — ');

    return AbTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: isActive,
        label: tooltip,
        excludeSemantics: true,
        onTap: () => _select(ref),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _select(ref),
            child: Container(
              // Full bar height so the active underline anchors flush at the
              // bottom edge instead of floating at the content's height.
              height: AbTokens.statusHeaderHeight,
              padding: const EdgeInsets.symmetric(
                horizontal: AbTokens.space12,
              ),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: isActive ? p.accent : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Row(
                children: [
                  AbIcon(
                    isLead ? AbIcons.deviceDesktop : AbIcons.sessionMemberOf,
                    size: AbTokens.fontSm,
                    color: color,
                  ),
                  const SizedBox(width: AbTokens.space6),
                  Text(
                    label,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _select(WidgetRef ref) {
    if (isActive) return;
    // The container, captured before the switch: pressing a tab rebuilds the
    // strip this element belongs to, and a `WidgetRef` read afterwards throws.
    final container = ref.container;
    detached(
      'SessionMemberTabs',
      'switching to a session member failed',
      () => selectMemberTab(container, member),
    );
  }
}
