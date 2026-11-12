import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

class MemoryOffState extends StatelessWidget {
  const MemoryOffState({
    super.key,
    required this.onTurnOn,
    this.busy = false,
    this.error,
    this.machineName,
  });

  final VoidCallback? onTurnOn;
  final bool busy;
  final String? error;

  /// Null for the local machine.
  final String? machineName;

  List<String> get _bullets => [
    'Stored only on ${machineName ?? 'this machine'}, never in your repository.',
    'You can read, edit or forget any memory here.',
    "Each agent's own built-in memory keeps working as before.",
  ];

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    // The scroll view fills the pane and the column centres inside it, so the
    // wheel scrolls from anywhere rather than only over the text.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.all(CarbonSpacing.spacing06),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight
                ? constraints.maxHeight - CarbonSpacing.spacing06 * 2
                : 0,
            minWidth: double.infinity,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: CarbonSpacing.spacing06 * 22,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CarbonIcon(
                    CarbonIcons.idea,
                    size: CarbonSpacing.spacing07,
                    color: t.colors.iconSecondary,
                  ),
                  const SizedBox(height: CarbonSpacing.spacing05),
                  Semantics(
                    header: true,
                    child: Text(
                      'Let your agents remember what they learn',
                      style: t.typography.headingLarge.copyWith(
                        color: t.colors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: CarbonSpacing.spacing05),
                  Text(
                    'With Memory on, a fix Codex worked out yesterday is there for Claude Code today. Agents save short notes about this repository as they work, and look them up when they need them.',
                    style: t.typography.body.copyWith(
                      color: t.colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: CarbonSpacing.spacing05),
                  for (final bullet in _bullets)
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: CarbonSpacing.spacing02,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '–',
                            style: t.typography.body.copyWith(
                              color: t.colors.textSecondary,
                            ),
                          ),
                          const SizedBox(width: CarbonSpacing.spacing03),
                          Expanded(
                            child: Text(
                              bullet,
                              style: t.typography.body.copyWith(
                                color: t.colors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: CarbonSpacing.spacing04),
                  if (error case final error?) ...[
                    CarbonNotification(
                      kind: CarbonNotificationKind.error,
                      subtitle: error,
                    ),
                    const SizedBox(height: CarbonSpacing.spacing03),
                  ],
                  CarbonButton(
                    label: 'Turn on Memory',
                    busy: busy,
                    onPressed: busy ? null : onTurnOn,
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
