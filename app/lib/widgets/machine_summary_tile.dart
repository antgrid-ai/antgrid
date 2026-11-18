import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// A ghost dropdown trigger naming a machine (or a scope of machines) over a
/// one-line summary, with the chevron right after the text. Shared by the
/// desktop scope menu's trigger and the phone's machine switchers.
///
/// Not a [CarbonClickableTile]: that is a filled card whose own arrow says
/// "navigate", which in a header reads as a block wedged between the icon
/// buttons and contradicts the chevron. Like Carbon's header and inline
/// dropdown triggers, this has no fill at rest and hugs its content.
class MachineSummaryTile extends StatelessWidget {
  const MachineSummaryTile({
    super.key,
    required this.leading,
    required this.title,
    required this.summary,
    required this.semanticLabel,
    required this.onPressed,
    this.titleIsName = false,
  });

  final Widget leading;
  final String title;
  final String summary;
  final String semanticLabel;
  final VoidCallback onPressed;

  /// The title is one machine's name, which is data and takes the code face;
  /// a scope label ("All machines") is chrome.
  final bool titleIsName;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final c = t.colors;
    final titleStyle = titleIsName ? t.typography.code : t.typography.body;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      // Its child's size, not the slot's: the drawer's docked column hands a
      // pinned row the whole panel's height as a bound.
      widthFactor: 1,
      heightFactor: 1,
      child: CarbonInteraction(
        onPressed: onPressed,
        label: semanticLabel,
        excludeChildSemantics: true,
        builder: (context, state, _) => CarbonFocusRing(
          visible: state.focusVisible,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: state.pressed
                  ? c.backgroundActive
                  : state.hovered
                  ? c.backgroundHover
                  : null,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: t.minTarget),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CarbonSpacing.spacing03,
                  vertical: CarbonSpacing.spacing02,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    leading,
                    const SizedBox(width: CarbonSpacing.spacing03),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle.copyWith(color: c.textPrimary),
                          ),
                          Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.typography.helper.copyWith(
                              color: c.textHelper,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: CarbonSpacing.spacing03),
                    CarbonIcon(
                      CarbonIcons.chevronDown,
                      size: 16,
                      color: c.iconPrimary,
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
