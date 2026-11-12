import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// Centred message for an empty, failed or gone Memory pane. Carbon has no
/// empty-state component, so this follows the Scheduler's: icon, heading,
/// body and one action.
///
/// The scroll view fills the pane and the column centres inside it, so the
/// wheel scrolls from anywhere rather than only over the text.
class MemoryEmptyState extends StatelessWidget {
  const MemoryEmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.error = false,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final Widget? action;

  /// Leads with the error status icon in place of [icon].
  final bool error;
  final CarbonIcons? icon;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final glyph = error
        ? const CarbonStatusIcon(
            CarbonStatusKind.error,
            size: CarbonSpacing.spacing07,
          )
        : icon == null
        ? null
        : CarbonIcon(
            icon!,
            size: CarbonSpacing.spacing07,
            color: t.colors.iconSecondary,
          );
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
            minWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 0,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(CarbonSpacing.spacing06),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: CarbonSpacing.spacing09 * 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: CarbonSpacing.spacing03,
                  children: [
                    ?glyph,
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: t.typography.heading.copyWith(
                        color: t.colors.textPrimary,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        textAlign: TextAlign.center,
                        style: t.typography.body.copyWith(
                          color: t.colors.textSecondary,
                        ),
                      ),
                    if (action != null)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: CarbonSpacing.spacing03,
                        ),
                        child: action,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
