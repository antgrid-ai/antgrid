import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_agent_tab.dart';
import '../design/widgets/ab_cmd_bar.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_kbd.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_state_chip.dart';
import '../design/widgets/ab_status_pill.dart';
import '../design/widgets/ab_toast.dart';

class DesignGalleryScreen extends StatelessWidget {
  const DesignGalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Scaffold(
      backgroundColor: p.bgDeepest,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(48, 32, 48, 96),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Masthead(onBack: () => Navigator.of(context).pop()),
                  const SizedBox(height: 40),
                  _Section(
                    title: 'Type',
                    count: '03',
                    cards: [_TypeScaleCard(), _DisplayCard(), _MonoCard()],
                  ),
                  _Section(
                    title: 'Colors',
                    count: '06',
                    cards: [
                      _SurfacesCard(),
                      _ForegroundCard(),
                      _BordersCard(),
                      _AccentCard(),
                      _AgentStatusCard(),
                      _SemanticCard(),
                    ],
                  ),
                  _Section(
                    title: 'Spacing',
                    count: '03',
                    cards: [
                      _SpacingScaleCard(),
                      _RadiiCard(),
                      _ElevationCard(),
                    ],
                  ),
                  _Section(
                    title: 'Components',
                    count: '08',
                    cards: [
                      _Card(
                        name: 'Status pills',
                        sub: 'Agent state, breathe pulse',
                        child: _StatusPillsDemo(),
                      ),
                      _Card(
                        name: 'State chips',
                        sub: 'Neutral, active tone',
                        child: _StateChipDemo(),
                      ),
                      _Card(
                        name: 'Keyboard chips',
                        sub: 'Inline kbd',
                        child: _KbdDemo(),
                      ),
                      _Card(
                        name: 'Agent tabs',
                        sub: 'Glyph + state + duration',
                        child: _AgentTabsDemo(),
                      ),
                      _Card(
                        name: 'Command bar',
                        sub: 'Build / Lint / Test / Publish',
                        child: _CmdBarDemo(),
                      ),
                      _Card(
                        name: 'Dropdown menu',
                        sub: 'Items, shortcuts, danger',
                        child: _MenuDemo(),
                      ),
                      _Card(
                        name: 'Toast',
                        sub: 'Notification surface',
                        child: _ToastDemo(),
                      ),
                    ],
                  ),
                  _Section(
                    title: 'Brand',
                    count: '01',
                    cards: [_WordmarkCard()],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Masthead ---------------------------------------------------------------

class _Masthead extends StatelessWidget {
  const _Masthead({required this.onBack});
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      padding: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.borderDefault)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          AbIconButton(icon: AbIcons.back, tooltip: 'Back', onTap: onBack),
          const SizedBox(width: 16),
          Text(
            'Antgrid',
            style: TextStyle(
              fontSize: AbTokens.fontDisplayMd,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
              letterSpacing: -0.7,
            ),
          ),
          const SizedBox(width: 18),
          Text(
            'DESIGN SYSTEM',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              letterSpacing: 0.6,
              color: p.textMuted,
            ),
          ),
          const Spacer(),
          Text(
            '20 cards · v0.1',
            style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: p.textMuted),
          ),
        ],
      ),
    );
  }
}

// --- Section + Card chrome --------------------------------------------------

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.count,
    required this.cards,
  });
  final String title;
  final String count;
  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Padding(
      padding: const EdgeInsets.only(bottom: 56),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(
              children: [
                Text(
                  title.toUpperCase(),
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontMd,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.0,
                    color: p.textMuted,
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  count,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textMuted,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(child: Container(height: 1, color: p.borderSubtle)),
              ],
            ),
          ),
          for (final c in cards)
            Padding(padding: const EdgeInsets.only(bottom: 24), child: c),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.name, required this.sub, required this.child});
  final String name;
  final String sub;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      decoration: BoxDecoration(
        color: p.bgDeep,
        borderRadius: AbTokens.borderRadius8,
        border: Border.all(color: p.borderDefault),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.borderSubtle)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: AbTokens.fontMd,
                    fontWeight: FontWeight.w500,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(width: 14),
                Text(sub, style: TextStyle(fontSize: AbTokens.fontXs, color: p.textMuted)),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.all(20), child: child),
        ],
      ),
    );
  }
}

// --- Type ------------------------------------------------------------------

class _TypeScaleCard extends StatelessWidget {
  const _TypeScaleCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final rows = <(String, double, FontWeight)>[
      ('Display 40', 40, FontWeight.w600),
      ('Title 28', 28, FontWeight.w600),
      ('Section 20', 20, FontWeight.w600),
      ('Body 14', 14, FontWeight.w400),
      ('UI 13', 13, FontWeight.w400),
      ('Meta 12', 12, FontWeight.w400),
      ('Micro 11', 11, FontWeight.w500),
    ];
    return _Card(
      name: 'Type scale',
      sub: 'Display → micro',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, size, w) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 90,
                    child: Text(
                      label,
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: p.textMuted,
                      ),
                    ),
                  ),
                  Text(
                    'Antgrid',
                    style: TextStyle(
                      fontSize: size,
                      fontWeight: w,
                      color: p.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DisplayCard extends StatelessWidget {
  const _DisplayCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return _Card(
      name: 'Display & marketing',
      sub: 'Large specimens',
      child: Text(
        'Multi-agent IDE.',
        style: TextStyle(
          fontSize: AbTokens.fontDisplayLg,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
          letterSpacing: -0.8,
        ),
      ),
    );
  }
}

class _MonoCard extends StatelessWidget {
  const _MonoCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return _Card(
      name: 'Monospace',
      sub: 'Paths, terminal output',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in const [
            'src/agents/router.ts',
            r'$ npm run dev',
            'refactor-auth-flow',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                s,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontMd,
                  color: p.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// --- Color cards (helper + 6 cards) ----------------------------------------

class _ColorRow extends StatelessWidget {
  const _ColorRow({required this.swatches});
  final List<(String name, Color color)> swatches;
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        for (final (name, color) in swatches)
          SizedBox(
            width: 120,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 56,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: AbTokens.borderRadius5,
                    border: Border.all(color: p.borderDefault),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  name,
                  style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: p.textMuted),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SurfacesCard extends StatelessWidget {
  const _SurfacesCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return _Card(
      name: 'Surface scale',
      sub: 'bg-0 → bg-5',
      child: _ColorRow(
        swatches: [
          ('bg-0 canvas', p.bgDeepest),
          ('bg-1 chrome', p.bgDeep),
          ('bg-2 panel', p.bgSurface),
          ('bg-3 raised', p.bgRaised),
          ('bg-4 hover', p.bgHover),
          ('bg-5 pressed', p.bgPressed),
        ],
      ),
    );
  }
}

class _ForegroundCard extends StatelessWidget {
  const _ForegroundCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return _Card(
      name: 'Foreground scale',
      sub: 'Text contrast tiers',
      child: _ColorRow(
        swatches: [
          ('fg-0 primary', p.textPrimary),
          ('fg-1 body', p.textSecondary),
          ('fg-2 muted', p.textMuted),
          ('fg-2.5 icon (3:1, non-text)', p.iconMuted),
          ('fg-3 disabled (exempt)', p.textDisabled),
        ],
      ),
    );
  }
}

class _BordersCard extends StatelessWidget {
  const _BordersCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return _Card(
      name: 'Borders',
      sub: 'Three weights on dark',
      child: _ColorRow(
        swatches: [
          ('subtle', p.borderSubtle),
          ('default', p.borderDefault),
          ('strong', p.borderStrong),
        ],
      ),
    );
  }
}

class _AccentCard extends StatelessWidget {
  const _AccentCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return _Card(
      name: 'Accent',
      sub: 'Off-white — signature',
      child: _ColorRow(
        swatches: [
          ('accent', p.accent),
          ('hover', p.accentHighlight),
          ('pressed', p.accentMuted),
          ('on accent', p.accentForeground),
        ],
      ),
    );
  }
}

class _AgentStatusCard extends StatelessWidget {
  const _AgentStatusCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return _Card(
      name: 'Agent status',
      sub: 'Idle / thinking / running / input / error',
      child: _ColorRow(
        swatches: [
          ('idle', p.statusIdle),
          ('thinking', p.statusThinking),
          ('running', p.statusRunning),
          ('needs input', p.statusAttention),
          ('error', p.error),
        ],
      ),
    );
  }
}

class _SemanticCard extends StatelessWidget {
  const _SemanticCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return _Card(
      name: 'Semantic',
      sub: 'Success / warning / danger',
      child: _ColorRow(
        swatches: [
          ('success', p.success),
          ('warning', p.warning),
          ('error', p.error),
          ('signal', p.signalMut),
        ],
      ),
    );
  }
}

// --- Spacing / Radii / Elevation -------------------------------------------

class _SpacingScaleCard extends StatelessWidget {
  const _SpacingScaleCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    const sizes = [2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 16.0, 24.0, 32.0, 48.0];
    return _Card(
      name: 'Spacing scale',
      sub: '4px base, --s-1 → --s-24',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in sizes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 50,
                    child: Text(
                      '${s.toInt()}px',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: p.textMuted,
                      ),
                    ),
                  ),
                  Container(width: s, height: 14, color: p.accent),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RadiiCard extends StatelessWidget {
  const _RadiiCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    const items = [
      ('r-1 · 3px', 3.0),
      ('r-2 · 5px', 5.0),
      ('r-3 · 8px', 8.0),
      ('r-4 · 12px', 12.0),
      ('pill · 999', 999.0),
    ];
    return _Card(
      name: 'Corner radii',
      sub: '3 / 5 / 8 / 12 / pill',
      child: Wrap(
        spacing: 14,
        runSpacing: 14,
        children: [
          for (final (label, r) in items)
            Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: p.bgRaised,
                    borderRadius: BorderRadius.circular(r),
                    border: Border.all(color: p.borderDefault),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: p.textMuted),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ElevationCard extends StatelessWidget {
  const _ElevationCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return _Card(
      name: 'Elevation',
      sub: 'Border + highlight',
      child: Wrap(
        spacing: 14,
        runSpacing: 14,
        children: [
          for (final level in const [1, 2, 3])
            Container(
              width: 120,
              height: 70,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.bgRaised,
                borderRadius: AbTokens.borderRadius8,
                border: Border.all(
                  color: level == 1 ? p.borderDefault : p.borderStrong,
                  width: 1,
                ),
                boxShadow: level >= 2
                    ? [
                        BoxShadow(
                          color: Color.fromRGBO(0, 0, 0, 0.4 + 0.15 * level),
                          blurRadius: 8.0 * level,
                          offset: Offset(0, 2.0 * level),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                'elev-$level',
                style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: p.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

// --- Component demos -------------------------------------------------------

class _StatusPillsDemo extends StatelessWidget {
  const _StatusPillsDemo();
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: const [
        AbStatusPill(status: AbAgentStatus.idle, label: 'Idle'),
        AbStatusPill(status: AbAgentStatus.thinking, label: 'Thinking'),
        AbStatusPill(status: AbAgentStatus.running, label: 'Running tool'),
        AbStatusPill(status: AbAgentStatus.attention, label: 'Needs input'),
        AbStatusPill(status: AbAgentStatus.error, label: 'Failed'),
      ],
    );
  }
}

class _StateChipDemo extends StatelessWidget {
  const _StateChipDemo();
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AbStateChip(
          icon: AbIcons.radioTower,
          label: 'Remote off',
          onTap: (_) {},
        ),
        const SizedBox(width: 14),
        AbStateChip(
          icon: AbIcons.radioTower,
          label: 'Remote on',
          tone: context.antgrid.statusRunning,
          active: true,
          onTap: (_) {},
        ),
      ],
    );
  }
}

class _KbdDemo extends StatelessWidget {
  const _KbdDemo();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final rows = const [
      ('Switch session', ['⌘', 'K']),
      ('New session', ['⌘', '⇧', 'N']),
      ('Toggle context panel', ['⌘', r'\\']),
      ('Send to agent', ['⌘', '↵']),
      ('Interrupt', ['ESC']),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, keys) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 170,
                  child: Text(
                    label,
                    style: TextStyle(fontSize: AbTokens.fontMd, color: p.textMuted),
                  ),
                ),
                AbKbdGroup(keys),
              ],
            ),
          ),
      ],
    );
  }
}

class _AgentTabsDemo extends StatelessWidget {
  const _AgentTabsDemo();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      decoration: BoxDecoration(
        color: p.bgDeep,
        border: Border(bottom: BorderSide(color: p.borderSubtle)),
      ),
      child: Row(
        children: [
          AbAgentTab(
            glyph: 'cc',
            name: 'claude-code',
            status: AbAgentStatus.running,
            duration: '0:42',
            active: true,
            onTap: () {},
            onClose: () {},
          ),
          AbAgentTab(
            glyph: 'cx',
            name: 'codex',
            status: AbAgentStatus.attention,
            duration: '2:18',
            active: false,
            onTap: () {},
            onClose: () {},
          ),
          AbAgentTab(
            glyph: 'o3',
            name: 'o3',
            status: AbAgentStatus.idle,
            active: false,
            onTap: () {},
            onClose: () {},
          ),
        ],
      ),
    );
  }
}

class _CmdBarDemo extends StatelessWidget {
  const _CmdBarDemo();
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 800,
        child: AbCmdBar(
          commands: [
            AbCmd(
              name: 'Build',
              state: AbCmdState.success,
              last: '4.2s',
              onTap: () {},
            ),
            AbCmd(
              name: 'Lint',
              state: AbCmdState.running,
              last: '0:08',
              onTap: () {},
            ),
            AbCmd(
              name: 'Test',
              state: AbCmdState.error,
              last: '2 failed',
              onTap: () {},
            ),
            AbCmd(
              name: 'Publish',
              state: AbCmdState.idle,
              last: '2h ago',
              onTap: () {},
            ),
          ],
          onRun: () {},
          onAdd: () {},
        ),
      ),
    );
  }
}

class _MenuDemo extends StatelessWidget {
  const _MenuDemo();
  @override
  Widget build(BuildContext context) {
    return AbMenu(
      header: 'Session · refactor-auth-flow',
      items: [
        AbMenuItem(
          label: 'Export transcript',
          icon: AbIcons.arrowDown,
          shortcut: '⌘E',
          onTap: () {},
        ),
        AbMenuItem(
          label: 'Share with team…',
          icon: AbIcons.account,
          shortcut: '⌘⇧S',
          onTap: () {},
        ),
        AbMenuItem(label: 'View raw log', icon: AbIcons.list, onTap: () {}),
        const AbMenuDivider(),
        AbMenuItem(
          label: 'Restart agent',
          icon: AbIcons.refresh,
          shortcut: '⌘R',
          onTap: () {},
        ),
        AbMenuItem(
          label: 'Delete session',
          icon: AbIcons.trash,
          shortcut: '⌫',
          danger: true,
          onTap: () {},
        ),
      ],
    );
  }
}

class _ToastDemo extends StatelessWidget {
  const _ToastDemo();
  @override
  Widget build(BuildContext context) {
    return const AbToast(
      icon: AbIcons.check,
      title: 'Session committed',
      description: '14 files · feat/auth-flow',
      actionLabel: 'Open PR',
    );
  }
}

class _WordmarkCard extends StatelessWidget {
  const _WordmarkCard();
  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return _Card(
      name: 'Wordmark',
      sub: 'antgrid. — colony lockup',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: 'antgrid',
                style: TextStyle(
                  fontSize: AbTokens.fontDisplayLg,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                  letterSpacing: -1,
                ),
              ),
              TextSpan(
                text: '.',
                style: TextStyle(
                  fontSize: AbTokens.fontDisplayLg,
                  fontWeight: FontWeight.w600,
                  color: p.statusThinking,
                  letterSpacing: -1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
