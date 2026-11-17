import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

class TooltipPage extends StatelessWidget {
  const TooltipPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Tooltip',
      summary:
          'A short, text-only description that appears on hover and keyboard '
          'focus, and on long press for touch. It supplements a control; it '
          'never replaces the control\'s name.',
      children: [
        GallerySection(
          title: 'Triggers',
          description:
              'Hover for a moment, Tab to the button, or long-press on touch.',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing05,
              runSpacing: CarbonSpacing.spacing05,
              children: [
                CarbonTooltip(
                  message: 'Saves every open file in the project',
                  child: CarbonButton(label: 'Save all', onPressed: () {}),
                ),
                CarbonTooltip(
                  message: 'Opens the project settings',
                  child: CarbonButton.iconOnly(
                    icon: const CarbonIcon(CarbonIcons.settings),
                    semanticLabel: 'Settings',
                    onPressed: () {},
                  ),
                ),
                CarbonTooltip(
                  message: 'Shown for a disabled-looking hint, not an instruction',
                  child: CarbonButton(
                    label: 'Export',
                    kind: CarbonButtonKind.tertiary,
                    onPressed: () {},
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Placement',
          description:
              'Above when it fits, below otherwise; start or end aligned; '
              'always clamped inside the window.',
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: CarbonSpacing.spacing05,
              runSpacing: CarbonSpacing.spacing05,
              children: [
                CarbonTooltip(
                  message: 'Aligned to the start edge of the trigger',
                  child: CarbonButton(
                    label: 'Start',
                    kind: CarbonButtonKind.secondary,
                    onPressed: () {},
                  ),
                ),
                CarbonTooltip(
                  message: 'Aligned to the end edge of the trigger',
                  alignment: CarbonTooltipAlignment.end,
                  child: CarbonButton(
                    label: 'End',
                    kind: CarbonButtonKind.secondary,
                    onPressed: () {},
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: CarbonSpacing.spacing05,
              runSpacing: CarbonSpacing.spacing05,
              children: [
                CarbonTooltip(
                  message: 'Prefers below, and flips above at the bottom edge',
                  preferAbove: false,
                  child: CarbonButton(
                    label: 'Below',
                    kind: CarbonButtonKind.secondary,
                    onPressed: () {},
                  ),
                ),
                CarbonTooltip(
                  message: 'No caret',
                  caret: false,
                  child: CarbonButton(
                    label: 'No caret',
                    kind: CarbonButtonKind.secondary,
                    onPressed: () {},
                  ),
                ),
                CarbonTooltip(
                  message:
                      'A longer description wraps at the maximum width instead '
                      'of stretching across the window, and stays readable at '
                      'large text sizes and in right-to-left layouts.',
                  child: CarbonButton(
                    label: 'Long text',
                    kind: CarbonButtonKind.secondary,
                    onPressed: () {},
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Supplement, not substitute',
          description:
              'The field states what is wrong in visible text; the tooltip '
              'only adds background.',
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    'Port 80 is reserved. Choose a port above 1024.',
                    style: theme.typography.helper.copyWith(
                      color: theme.colors.textError,
                    ),
                  ),
                ),
                const SizedBox(width: CarbonSpacing.spacing03),
                CarbonTooltip(
                  message: 'Ports below 1024 need administrator rights.',
                  child: CarbonButton.iconOnly(
                    icon: const CarbonIcon(CarbonIcons.information),
                    semanticLabel: 'About reserved ports',
                    onPressed: () {},
                  ),
                ),
              ],
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'To name or explain an icon-only control, or to add a short '
              'clarification to a visible label. Not for instructions, '
              'validation errors or anything interactive; use a popover or '
              'inline text instead.',
          keyboard:
              'Appears when focus arrives by keyboard and hides on blur. '
              'Escape dismisses it without closing an enclosing dialog or '
              'moving focus. Long press shows it on touch until you tap '
              'elsewhere.',
          accessibility:
              'The message is read as supplementary description of the '
              'control; the control still needs its own accessible name. '
              'Hover is not available to touch or keyboard users, so '
              'nothing required may live only in a tooltip.',
          carbonReference:
              'Carbon v11 Tooltip. Toggletip and definition tooltip are not '
              'included.',
        ),
      ],
    );
  }
}
