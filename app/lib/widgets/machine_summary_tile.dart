import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// A pressable tile naming a machine (or a scope of machines) over a one-line
/// summary, with a chevron saying it opens a chooser. Shared by the desktop
/// scope menu's trigger and the phone's machine switchers.
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
    final titleStyle = titleIsName ? t.typography.code : t.typography.body;
    return CarbonClickableTile(
      semanticLabel: semanticLabel,
      onPressed: onPressed,
      child: Row(
        children: [
          leading,
          const SizedBox(width: CarbonSpacing.spacing04),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle.copyWith(color: t.colors.textPrimary),
                ),
                Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.typography.helper.copyWith(
                    color: t.colors.textHelper,
                  ),
                ),
              ],
            ),
          ),
          const CarbonIcon(CarbonIcons.chevronDown),
        ],
      ),
    );
  }
}
