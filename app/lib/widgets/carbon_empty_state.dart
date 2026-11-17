import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// Centred message for an empty, failed or gone pane: icon, heading, body and
/// one action. Carbon has no empty-state component, so this follows the
/// Scheduler's layout. Only for use inside an `AbCarbonScope`.
///
/// The scroll view fills the pane and the column centres inside it, so the
/// wheel scrolls from anywhere rather than only over the text, and a short
/// pane or a large text scale scrolls instead of overflowing.
class CarbonEmptyState extends StatelessWidget {
  const CarbonEmptyState({
    super.key,
    required this.heading,
    this.body,
    this.action,
    this.icon,
    this.iconWidget,
    this.error = false,
  }) : compact = false;

  /// A single quiet line for a pane too short for the full layout, such as a
  /// log window that has nothing in it yet.
  const CarbonEmptyState.compact({super.key, required this.heading})
    : body = null,
      action = null,
      icon = null,
      iconWidget = null,
      error = false,
      compact = true;

  final String heading;
  final String? body;

  /// Callers pass a `CarbonButton`.
  final Widget? action;
  final CarbonIcons? icon;

  /// Replaces [icon] for a glyph that is not a plain Carbon icon.
  final Widget? iconWidget;

  /// Leads with the error status icon in place of [icon] and [iconWidget].
  final bool error;

  /// Only the [heading], as one centred helper-sized line.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    if (compact) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(CarbonSpacing.spacing04),
          child: Text(
            heading,
            textAlign: TextAlign.center,
            style: t.typography.helper.copyWith(color: t.colors.textSecondary),
          ),
        ),
      );
    }
    final glyph = error
        ? const CarbonStatusIcon(
            CarbonStatusKind.error,
            size: CarbonSpacing.spacing07,
          )
        : iconWidget ??
              (icon == null
                  ? null
                  : CarbonIcon(
                      icon!,
                      size: CarbonSpacing.spacing07,
                      color: t.colors.iconSecondary,
                    ));
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
                      heading,
                      textAlign: TextAlign.center,
                      style: t.typography.heading.copyWith(
                        color: t.colors.textPrimary,
                      ),
                    ),
                    if (body != null)
                      Text(
                        body!,
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
