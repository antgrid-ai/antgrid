import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// The floating "Send to Agent" pill for a Carbon surface; the Ab
/// `SendToAgentButton` stays for the terminal. Place inside a Stack: it
/// positions itself top-right.
class CarbonSendToAgentButton extends StatelessWidget {
  const CarbonSendToAgentButton({
    super.key,
    required this.onPressed,
    required this.link,
  });

  final VoidCallback onPressed;

  /// Tracks this button's position so the follow-up comment popover
  /// (`showSendToAgentComment`'s `anchorLink`) hangs off it instead of
  /// opening in the window's centre; the caller owns the link so it can pass
  /// the same one to that call.
  final LayerLink link;

  @override
  Widget build(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    return Positioned(
      top: CarbonSpacing.spacing03,
      right: CarbonSpacing.spacing03,
      child: CompositedTransformTarget(
        link: link,
        // A tertiary button has no fill of its own, and this one floats over
        // code.
        child: ColoredBox(
          color: colors.background,
          child: CarbonButton(
            label: 'Send to Agent',
            kind: CarbonButtonKind.tertiary,
            size: CarbonButtonSize.small,
            icon: const CarbonIcon(CarbonIcons.send),
            onPressed: onPressed,
          ),
        ),
      ),
    );
  }
}
